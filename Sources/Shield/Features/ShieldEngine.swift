import AppKit
import Combine
import IOKit.hid
import ShieldCore

/// What the menu bar and the monitor report about the machinery.
struct EngineStatus: Equatable {
    var running = false
    var tapLive = false
    var watching: String? = nil
    var fieldRole: String? = nil
    var suspendedReason: String? = nil
}

/// State shared between the watcher queue and the main thread.
///
/// Deliberately a lock rather than a queue hop: the watcher must never block
/// on main and main must never block on the watcher, or a wedged app takes the
/// whole keyboard down with it.
private final class WatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _holding = false
    private var _allowed = Set<Int>()
    private var _context: [String] = []
    private var _contextReadAt = Date.distantPast
    private var _changedAt = Date.distantPast
    private var _quickDone = true
    private var _contextDone = true
    private var _analysing = false

    var text: String {
        get { lock.lock(); defer { lock.unlock() }; return _text }
        set { lock.lock(); _text = newValue; lock.unlock() }
    }
    var holding: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holding }
        set { lock.lock(); _holding = newValue; lock.unlock() }
    }
    var context: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _context }
        set { lock.lock(); _context = newValue; _contextReadAt = Date(); lock.unlock() }
    }
    var contextIsStale: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_contextReadAt) > 2.0
    }
    var analysing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _analysing }
        set { lock.lock(); _analysing = newValue; lock.unlock() }
    }

    func allow(_ hash: Int) { lock.lock(); _allowed.insert(hash); lock.unlock() }
    func disallow(_ hash: Int) { lock.lock(); _allowed.remove(hash); lock.unlock() }
    func isAllowed(_ hash: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return _allowed.contains(hash)
    }

    /// Records a new draft and reports whether it actually changed.
    func noteText(_ new: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard new != _text else { return false }
        _text = new
        _changedAt = Date()
        _quickDone = false
        _contextDone = false
        return true
    }

    func stableFor() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_changedAt)
    }

    /// Claims the quick or context pass exactly once per draft.
    func claimQuick() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_quickDone else { return false }
        _quickDone = true
        return true
    }
    func claimContext() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_contextDone else { return false }
        _contextDone = true
        return true
    }

    func matches(_ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _text == candidate
    }

    func reset() {
        lock.lock()
        _text = ""
        _quickDone = true
        _contextDone = true
        lock.unlock()
    }
}

/// Send Shield, end to end.
///
/// A background watcher reads the focused field and keeps a verdict warm; the
/// event tap decides in microseconds whether a Return is a send or a pause.
@MainActor
final class ShieldEngine: ObservableObject {

    static let shared = ShieldEngine()

    let cascade: Cascade
    let telemetry = TelemetryStore()
    let crisis = CrisisRouter()
    let rephraser = Rephraser()
    let stats = StatsSync()
    let tap = EventTap()
    let settings = AppSettings.shared

    @Published private(set) var traces: [Trace] = []
    @Published private(set) var snapshot = TelemetrySnapshot()
    @Published private(set) var status = EngineStatus()
    @Published private(set) var quotaRemaining: Int = 0
    @Published private(set) var quotaBudget: Int = 0
    @Published private(set) var tier1Loaded = false
    @Published private(set) var contextAvailable = false

    /// What Shield has actually done, newest first. In memory only.
    @Published private(set) var events: [ShieldEvent] = []

    /// Non-nil while a rewrite is in flight or has just failed.
    @Published private(set) var rephrase: RephraseState?

    enum RephraseState: Equatable {
        case working
        case failed(String)
    }

    @Published private(set) var held: HeldDraft?
    @Published private(set) var crisisOffer: CrisisOffer?

    struct HeldDraft: Equatable {
        var text: String
        var verdict: Verdict
        var fieldFrame: CGRect?
        var appName: String?
        var bundleID: String?
        /// A rehearsal hold: the same panel, the same animation, the same
        /// tone — but no keystroke is ever re-posted and no field is cleared.
        var preview: Bool = false
    }

    struct CrisisOffer: Equatable {
        var id = UUID()
        var incoming: Bool
        var anchor: CGRect?
    }

    private let queue = DispatchQueue(label: "shield.watcher", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let state = WatchState()
    /// Insurance: if a hold somehow outlives its overlay, the keyboard comes
    /// back on its own rather than staying swallowed.
    private var holdWatchdog: Timer?
    private var statsTimer: Timer?
    /// The field the held draft lives in. Focus flickers in web views; the
    /// element itself does not, so this is what the overlay tracks.
    private(set) var heldElement: AXUIElement?
    /// Consecutive ticks with no focused field. See `tick`.
    private nonisolated(unsafe) var focusMisses = 0
    /// Ticks since the last attempt to create the event tap.
    private let tapRetry = ManagedAtomicInt32(0)
    /// Verdicts keyed by draft, so the Return handler never waits on anything.
    private nonisolated let warm = WarmCache()

    private init() {
        let t1 = Tier1Classifier()
        let t2 = Tier2Gemini()
        cascade = Cascade(onDevice: t1, context: t2, contextEnabled: AppSettings.shared.contextTierEnabled)
        tier1Loaded = t1.isModelLoaded
        contextAvailable = t2.isAvailable
        snapshot = telemetry.current

        cascade.onTrace = { [weak self] trace in
            guard let self else { return }
            self.telemetry.record(trace)
            Task { @MainActor in self.append(trace) }
        }

        tap.onSendKey = { [weak self] in self?.handleSendKey() ?? false }
        tap.onHoldAction = { [weak self] action in self?.handle(action) }
        tap.onDisabled = { [weak self] in self?.noteTapRecovered() }

        NotificationCenter.default.addObserver(
            forName: .shieldSettingsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySettings() }
            }
    }

    // MARK: Lifecycle

    func start() {
        guard !status.running else { return }
        let ok = tap.start()
        DebugLog.write("tap.start -> \(ok)  IOHIDCheckAccess=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0=granted 1=denied 2=unknown)")
        status.running = true
        status.tapLive = ok
        Permissions.shared.tapIsLive = ok
        tap.mode = .watching
        tap.isArmed = false
        startWatching()
        startStatsSync()
        refreshQuota()
    }

    func stop() {
        statsTimer?.invalidate(); statsTimer = nil
        pushStats()
        timer?.cancel(); timer = nil
        tap.stop()
        status = EngineStatus()
        held = nil
        state.holding = false
    }

    private func noteTapRecovered() {
        status.tapLive = tap.isRunning
    }

    private func applySettings() {
        cascade.contextEnabled = settings.contextTierEnabled
        if settings.sendShieldEnabled {
            if !status.running { start() }
        } else {
            tap.mode = .idle
            tap.isArmed = false
            dismissHold()
        }
    }

    /// Pushes today's counts every few minutes, and only when switched on.
    private func startStatsSync() {
        guard stats.isConfigured else { return }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushStats() }
        }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
        pushStats()
    }

    private func pushStats() {
        guard AppSettings.shared.shareStatsEnabled else { return }
        let snapshot = telemetry.current
        let settings = AppSettings.shared
        let stored = Passcode.shared.storedDigest
        Task {
            await stats.registerInstall(sensitivity: settings.sensitivity,
                                        outgoing: settings.sendShieldEnabled,
                                        incoming: settings.inboxShieldEnabled,
                                        passcodeDigest: stored?.digest,
                                        passcodeSalt: stored?.salt)
            await stats.send(snapshot, sensitivity: settings.sensitivity)
        }
    }

    private func startWatching() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.06, leeway: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: The watcher (runs on `queue`, never blocks on main)

    private nonisolated func tick() {
        guard !state.holding else { return }
        retryTapIfNeeded()

        guard AppSettings.shared.sendShieldEnabled else {
            suspend("Send Shield is off"); return
        }
        guard AX.isTrusted else {
            suspend("Accessibility is off"); return
        }

        guard let field = AX.focusedField() else {
            // Web views drop their focused element for a frame on every
            // repaint. Disarming on the first blink means Return slips through
            // on exactly the message that should have been caught, so hold the
            // last known state briefly.
            focusMisses += 1
            if focusMisses < 6 { return }
            DebugLog.focus("no focused field in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            tap.isArmed = false
            tap.mode = .watching
            state.reset()
            publish(watching: nil, role: nil, reason: nil)
            return
        }
        focusMisses = 0

        if field.isSecure {
            suspend("Password field, standing down"); return
        }
        if let bid = field.bundleID, Lexicon.excludedBundleIDs.contains(bid) {
            suspend("Off in \(field.appName ?? bid)"); return
        }

        tap.mode = .watching
        publish(watching: field.appName, role: field.role, reason: nil)

        let text = field.value
        DebugLog.focus("field role=\(field.role) app=\(field.appName ?? "?") len=\(text.count) text=\(text.prefix(40))")
        if state.noteText(text) {
            // Sub-millisecond, synchronous, on every change: the armed flag is
            // never stale by more than one tick.
            armFromRules(text)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tap.isArmed = false
            return
        }

        let stable = state.stableFor()
        if stable >= 0.14, state.claimQuick() {
            runCascade(text: text, element: field.element, withContext: false)
        } else if stable >= 0.75, state.claimContext() {
            runCascade(text: text, element: field.element, withContext: true)
        }
    }

    /// Input Monitoring is almost always granted after launch, so rather than
    /// demanding a relaunch Shield keeps asking for the tap, about once a
    /// second, until macOS hands it over.
    private nonisolated func retryTapIfNeeded() {
        guard !tap.isRunning else { return }
        let n = tapRetry.load() + 1
        tapRetry.store(n)
        guard n % 12 == 0 else { return }
        if tap.start() {
            tap.mode = .watching
            Task { @MainActor in
                self.status.tapLive = true
                Permissions.shared.tapIsLive = true
            }
        }
    }

    private nonisolated func suspend(_ reason: String) {
        tap.isArmed = false
        tap.mode = .idle
        state.reset()
        publish(watching: nil, role: nil, reason: reason)
    }

    private nonisolated func publish(watching: String?, role: String?, reason: String?) {
        let next = EngineStatus(running: true, tapLive: tap.isRunning,
                                watching: watching, fieldRole: role, suspendedReason: reason)
        Task { @MainActor in
            if self.status != next { self.status = next }
        }
    }

    private nonisolated func armFromRules(_ text: String) {
        let hash = VerdictHash.of(text)
        if state.isAllowed(hash) { tap.isArmed = false; return }
        if let cached = warmVerdict(hash) {
            tap.isArmed = HoldPolicy.shouldHold(cached, sensitivity: AppSettings.shared.sensitivity)
            return
        }
        let report = cascade.rules.evaluate(text, context: state.context)
        setWarm(hash, report.verdict)
        tap.isArmed = HoldPolicy.shouldHold(report.verdict, sensitivity: AppSettings.shared.sensitivity)
    }

    private nonisolated func runCascade(text: String, element: AXUIElement, withContext: Bool) {
        guard !state.analysing else { return }
        state.analysing = true

        if withContext && state.contextIsStale {
            state.context = AXContextReader.conversation()
        }
        let ctx = state.context
        let sensitivity = AppSettings.shared.sensitivity
        let crisisOn = AppSettings.shared.crisisSurfaceEnabled
        let hash = VerdictHash.of(text)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.cascade.analyze(text, context: ctx, allowContext: withContext)
            self.state.analysing = false
            guard self.state.matches(text) else { return }

            self.setWarm(hash, result.verdict)
            if !self.state.isAllowed(hash) {
                self.tap.isArmed = HoldPolicy.shouldHold(result.verdict, sensitivity: sensitivity)
            }

            await MainActor.run {
                self.refreshQuota()
                if crisisOn, withContext,
                   let offer = self.crisis.consider(result.verdict, text: text) {
                    self.crisisOffer = CrisisOffer(incoming: offer.incoming,
                                                   anchor: AX.frame(of: element))
                    self.record(.resources, text: text)
                }
            }
        }
    }

    // MARK: Warm verdicts

    private nonisolated func warmVerdict(_ hash: Int) -> Verdict? { warm.get(hash) }

    private nonisolated func setWarm(_ hash: Int, _ v: Verdict) { warm.set(hash, v) }

    // MARK: The catch

    /// Runs on the main queue, immediately after the tap swallowed a Return.
    /// The verdict is already computed; this is presentation only.
    private func handleSendKey() -> Bool {
        DebugLog.write("send key swallowed")
        guard held == nil else { return true }
        guard let field = AX.focusedField(),
              !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            tap.isArmed = false
            EventTap.repostReturn()
            return true
        }
        let text = field.value
        let hash = VerdictHash.of(text)
        let verdict = warmVerdict(hash) ?? cascade.rules.evaluate(text, context: state.context).verdict

        guard HoldPolicy.shouldHold(verdict, sensitivity: settings.sensitivity) else {
            // The draft moved under us between the tap and here. Let it go.
            tap.isArmed = false
            EventTap.repostReturn()
            return true
        }

        DebugLog.write("HOLD text=\(text.prefix(50)) score=\(verdict.score) app=\(field.appName ?? "?")")
        heldElement = field.element
        tap.mode = .holding
        state.holding = true
        held = HeldDraft(text: text,
                         verdict: verdict,
                         fieldFrame: AX.caretFrame(of: field.element) ?? AX.frame(of: field.element),
                         appName: field.appName,
                         bundleID: field.bundleID)
        telemetry.recordHold()
        snapshot = telemetry.current
        markHeld(text)
        record(.caught, text: text, reason: reason(for: verdict), app: field.appName,
               score: verdict.score)
        Feedback.catchHappened()
        startHoldWatchdog()
        return true
    }

    private func append(_ trace: Trace) {
        traces.insert(trace, at: 0)
        if traces.count > 200 { traces.removeLast(traces.count - 200) }
        snapshot = telemetry.current
    }

    /// A short human reason, preferring what the context tier said.
    private func reason(for v: Verdict) -> String? {
        if let r = v.rationale, !r.isEmpty { return r }
        guard let c = v.categories.first else { return nil }
        switch c {
        case .exclusion:   return "Shuts someone out"
        case .backhanded:  return "A compliment with an insult inside it"
        case .sarcasm:     return "Reads as mockery"
        case .pileOn:      return "Repeats what others already said at one person"
        case .threat:      return "Reads as a threat"
        case .slur:        return "Contains a slur"
        case .harassment:  return "Tells someone to hurt themselves"
        default:           return "Aimed at a person"
        }
    }

    func record(_ kind: ShieldEvent.Kind, text: String, reason: String? = nil,
                app: String? = nil, rewritten: String? = nil, score: Double = 0) {
        events.insert(ShieldEvent(text: String(text.prefix(160)), kind: kind,
                                  rewritten: rewritten, score: score,
                                  reason: reason, app: app), at: 0)
        if AppSettings.shared.shareStatsEnabled {
            let length = text.count
            Task {
                await stats.send(event: kind.wireName,
                                 score: score,
                                 severity: score > 0 ? Palette.severityLabel(score) : nil,
                                 tier: nil, category: nil,
                                 textLength: length)
            }
        }
        if events.count > 60 { events.removeLast(events.count - 60) }
    }

    private func markHeld(_ text: String) {
        let snippet = String(text.prefix(140))
        if let i = traces.firstIndex(where: { $0.snippet == snippet }) {
            traces[i].held = true
        }
    }

    // MARK: Resolving a hold

    private func handle(_ action: EventTap.HoldAction) {
        guard held != nil else { tap.mode = .watching; return }
        switch action {
        case .sendAnyway:
            if case .failed = rephrase { sendUnchanged() } else { rephraseAndSend() }
        case .edit, .typedThrough: editDraft()
        case .delete: deleteDraft()
        }
    }

    func sendAnyway() {
        guard let draft = held else { return }
        let preview = draft.preview
        state.allow(VerdictHash.of(draft.text))
        telemetry.recordSentAnyway()
        if !preview { record(.sentAnyway, text: draft.text, app: draft.appName) }
        dismissHold()
        guard !preview else { snapshot = telemetry.current; return }
        // Give the panel a frame to leave before the keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            EventTap.repostReturn()
        }
        snapshot = telemetry.current
    }

    func editDraft() {
        guard let draft = held else { return }
        // Escape is the person saying "I have read it". If they send the same
        // words again, they go. One pause is the whole design; two is a wall,
        // and a wall with no visible panel is a message you can never send.
        state.allow(VerdictHash.of(draft.text))
        telemetry.recordEdited()
        if !draft.preview { record(.edited, text: draft.text, app: draft.appName) }
        dismissHold()
        snapshot = telemetry.current
    }

    func deleteDraft() {
        guard let draft = held else { return }
        let preview = draft.preview
        telemetry.recordDeleted()
        if !preview { record(.deleted, text: draft.text, app: draft.appName) }
        dismissHold()
        guard !preview else { snapshot = telemetry.current; return }
        if let field = AX.focusedField() {
            if !AX.clear(field.element) { EventTap.clearFocusedFieldWithKeys() }
        } else {
            EventTap.clearFocusedFieldWithKeys()
        }
        snapshot = telemetry.current
    }

    private func startHoldWatchdog() {
        holdWatchdog?.invalidate()
        let t = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let draft = self.held else { return }
                // Let it through rather than re-catching the same words for
                // ever. A hold nobody resolved is a bug, not a decision.
                DebugLog.write("watchdog released a stuck hold")
                self.state.allow(VerdictHash.of(draft.text))
                self.dismissHold()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        holdWatchdog = t
    }

    func dismissHold() {
        holdWatchdog?.invalidate()
        holdWatchdog = nil
        heldElement = nil
        rephrase = nil
        held = nil
        state.holding = false
        state.reset()
        tap.mode = .watching
        tap.isArmed = false
    }

    /// Rewrites the draft and sends it, in one keystroke.
    ///
    /// Nothing is sent until the rewrite is in the field, and a failure leaves
    /// the original text exactly where it was. Shield never sends something
    /// the person has not seen.
    func rephraseAndSend() {
        DebugLog.write("rephrase requested held=\(held != nil) inflight=\(rephrase != nil) key=\(rephraser.isAvailable)")
        guard let draft = held, rephrase == nil else { return }

        if draft.preview {
            dismissHold()
            return
        }
        guard rephraser.isAvailable else {
            rephrase = .failed("No API key, so edit it yourself")
            return
        }

        rephrase = .working
        let element = heldElement
        let text = draft.text
        let ctx = state.context

        Task { [weak self] in
            guard let self else { return }
            do {
                let rewritten = try await self.rephraser.rephrase(text, context: ctx)
                DebugLog.write("rewrite came back: \(rewritten.prefix(80))")
                await MainActor.run {
                    guard self.held != nil else { self.rephrase = nil; return }
                    let wrote = element.map { AX.setString($0, kAXValueAttribute as String, rewritten) } ?? false
                    DebugLog.write("wrote into field: \(wrote)")
                    guard let element, wrote else {
                        _ = element
                        self.rephrase = .failed("Could not replace the text, so edit it yourself")
                        return
                    }
                    _ = element
                    // Let the app observe the new value before Return lands.
                    self.state.allow(VerdictHash.of(rewritten))
                    self.telemetry.recordEdited()
                    self.record(.rephrased, text: text, reason: nil,
                                app: draft.appName, rewritten: rewritten,
                                score: draft.verdict.score)
                    self.rephrase = nil
                    self.dismissHold()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        EventTap.repostReturn()
                    }
                    self.snapshot = self.telemetry.current
                }
            } catch {
                await MainActor.run {
                    DebugLog.write("rephrase failed: \(error)")
                    let why: String
                    switch error {
                    case Rephraser.Failure.quotaExhausted: why = "Out of requests today, so edit it yourself"
                    case Rephraser.Failure.noKey: why = "No API key, so edit it yourself"
                    default: why = "Rewrite did not come back, so edit it yourself"
                    }
                    self.rephrase = .failed(why)
                }
            }
        }
    }

    /// Sends the draft untouched. Only reachable after a rewrite has failed,
    /// because a message Shield cannot rewrite is a message it has no business
    /// keeping.
    func sendUnchanged() {
        guard let draft = held else { return }
        state.allow(VerdictHash.of(draft.text))
        telemetry.recordSentAnyway()
        if !draft.preview { record(.sentAnyway, text: draft.text, app: draft.appName) }
        let preview = draft.preview
        dismissHold()
        guard !preview else { snapshot = telemetry.current; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { EventTap.repostReturn() }
        snapshot = telemetry.current
    }

    func dismissCrisis() { crisisOffer = nil }

    // MARK: Monitor support

    func refreshSnapshot() { snapshot = telemetry.current }

    func refreshQuota() {
        let s = cascade.context.status
        quotaRemaining = s.remainingToday
        quotaBudget = s.dailyBudget
        contextAvailable = s.hasKey
    }

    func clearHistory() {
        events.removeAll()
    }

    func clearTraces() {
        traces.removeAll()
        cascade.clearCache()
        warm.removeAll()
    }

    func resetTelemetry() {
        telemetry.reset()
        snapshot = telemetry.current
        traces.removeAll()
    }

    /// Shows the catch exactly as it appears in the wild, for rehearsal.
    func previewHold(_ text: String, verdict: Verdict, near rect: CGRect?) {
        guard held == nil else { return }
        held = HeldDraft(text: text, verdict: verdict, fieldFrame: rect,
                         appName: nil, bundleID: nil, preview: true)
        tap.mode = .holding
        state.holding = true
        Feedback.catchHappened()
        startHoldWatchdog()
    }

    /// Offers resources for a message that arrived rather than one being written.
    func offerCrisis(incoming: Bool, near rect: CGRect?) {
        guard AppSettings.shared.crisisSurfaceEnabled else { return }
        guard crisisOffer == nil else { return }
        crisisOffer = CrisisOffer(incoming: incoming, anchor: rect)
    }

    /// Runs a fixture through the real pipeline, exactly as a live draft would.
    func replay(_ fixture: Fixture) async -> Verdict {
        let result = await cascade.analyze(fixture.draft, context: fixture.context, allowContext: true)
        refreshQuota()
        if AppSettings.shared.crisisSurfaceEnabled,
           let offer = crisis.consider(result.verdict, text: fixture.draft) {
            crisisOffer = CrisisOffer(incoming: offer.incoming, anchor: nil)
        }
        return result.verdict
    }
}

/// The warm verdict store. Written by the watcher, read by the Return handler.
private final class WarmCache: @unchecked Sendable {
    private var store: [Int: Verdict] = [:]
    private let lock = NSLock()

    func get(_ k: Int) -> Verdict? {
        lock.lock(); defer { lock.unlock() }; return store[k]
    }

    func set(_ k: Int, _ v: Verdict) {
        lock.lock()
        if store.count > 400 { store.removeAll(keepingCapacity: true) }
        store[k] = v
        lock.unlock()
    }

    func removeAll() { lock.lock(); store.removeAll(); lock.unlock() }
}

enum VerdictHash {
    static func of(_ s: String) -> Int {
        var h = Hasher()
        h.combine(s)
        return h.finalize()
    }
}
