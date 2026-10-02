import AppKit
import Carbon.HIToolbox
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

/// The text Shield is judging right now, and where it came from.
struct Candidate {
    enum Source: Equatable {
        /// The whole value of the focused field: a chat box, a search bar.
        case field
        /// A window around the caret in a long document.
        case fieldWindow
        /// Keystrokes, for apps whose text Accessibility cannot see.
        case typed
    }

    var text: String
    var source: Source
    var element: AXUIElement?
    var pid: pid_t
    var appName: String?
    var bundleID: String?
    var role: String?
    var isWeb: Bool
    var typed: TypedBuffer.Snapshot?
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
    private var _allowed: [Int: Date] = [:]
    private var _suppressed: [Int: Date] = [:]
    private var _context: [String] = []
    private var _contextReadAt = Date.distantPast
    private var _changedAt = Date.distantPast
    private var _quickDone = true
    private var _contextDone = true
    private var _analysing = false
    private var _lastDismissAt = Date.distantPast
    private var _candidate: Candidate?
    private var _verdict: Verdict?

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
    /// The last thing the watcher looked at, for the Return handler to fall
    /// back on when focus blinks at the exact moment of the keypress.
    var candidate: (Candidate, Verdict?)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = _candidate else { return nil }
        return (c, _verdict)
    }
    func setCandidate(_ c: Candidate?, verdict: Verdict?) {
        lock.lock(); _candidate = c; _verdict = verdict; lock.unlock()
    }

    /// Text the person has explicitly chosen to send: a Shield rewrite, or
    /// "send as is" after a rewrite failed. Never the text they pressed
    /// Escape on. Expires, so it cannot become a permanent loophole.
    func allow(_ hash: Int) { lock.lock(); _allowed[hash] = Date(); lock.unlock() }
    func isAllowed(_ hash: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = _allowed[hash] else { return false }
        if Date().timeIntervalSince(at) > 600 { _allowed[hash] = nil; return false }
        return true
    }

    /// Offending passages the person has already been shown while typing.
    /// The live catch does not pop again for the same words; Return still
    /// holds them, every time.
    func suppress(_ key: Int) {
        lock.lock()
        _suppressed[key] = Date()
        if _suppressed.count > 300 { _suppressed.removeAll() }
        lock.unlock()
    }
    func isSuppressed(_ key: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = _suppressed[key] else { return false }
        return Date().timeIntervalSince(at) < 300
    }
    /// The draft was sent or cleared: what was waved through for it is over.
    /// The next message gets a fresh catch, every time.
    func clearSuppressions() {
        lock.lock(); _suppressed.removeAll(); _insertsAtDismiss = nil; lock.unlock()
    }

    /// When the watcher took the keyboard for a catch that main has not
    /// shown yet. Lets the hold check tell "about to appear" from "stuck".
    private var _holdTakenAt: Date?
    var holdTakenAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _holdTakenAt }
        set { lock.lock(); _holdTakenAt = newValue; lock.unlock() }
    }

    func noteDismissed() { lock.lock(); _lastDismissAt = Date(); lock.unlock() }

    /// How many characters had been typed when a typing catch was closed.
    /// The live catch stays away while the person only deletes, and comes
    /// straight back the moment they type anything new.
    private var _insertsAtDismiss: Int?
    var insertsAtDismiss: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _insertsAtDismiss }
        set { lock.lock(); _insertsAtDismiss = newValue; lock.unlock() }
    }
    var sinceDismiss: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastDismissAt)
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
        _candidate = nil
        _verdict = nil
        lock.unlock()
    }
}

/// Send Shield, end to end.
///
/// A background watcher reads what the person is writing — from the focused
/// field when Accessibility can see it, from their keystrokes when it cannot —
/// and keeps a verdict warm. Cruel text is caught two ways: the moment it is
/// typed (anywhere, not only in chat apps), and again if Return is pressed on
/// it. Neither path ever lets the same words through just because they were
/// caught once before.
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

    /// Bumped when a key is blocked during a hold, so the panel can nudge.
    @Published private(set) var nudge = 0

    enum RephraseState: Equatable {
        case working
        case failed(String)
    }

    @Published private(set) var held: HeldDraft?
    @Published private(set) var crisisOffer: CrisisOffer?

    struct HeldDraft: Equatable {
        enum Trigger: Equatable {
            /// Return was pressed on it.
            case send
            /// It was typed; nothing was being sent yet.
            case typing
        }

        var id = UUID()
        /// Everything Shield judged: the message, or the passage around the caret.
        var text: String
        /// The sentences that crossed the line. What "Remove" takes out.
        var span: String
        var verdict: Verdict
        var trigger: Trigger = .send
        var source: Candidate.Source = .field
        var fieldFrame: CGRect?
        var appName: String?
        var bundleID: String?
        var pid: pid_t = 0
        var isWeb = false
        var role: String?
        var typed: TypedBuffer.Snapshot?
        /// A rehearsal hold: the same panel, the same animation, the same
        /// tone — but no keystroke is ever re-posted and no field is touched.
        var preview: Bool = false

        /// What a rewrite replaces: the whole message in a chat box, only
        /// the offending passage in a document.
        var rewriteTarget: String {
            source == .field ? text : span
        }

        static func == (a: HeldDraft, b: HeldDraft) -> Bool { a.id == b.id && a.verdict == b.verdict }
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
    /// back on its own.
    private var holdWatchdog: Timer?
    private var statsTimer: Timer?
    private var holdGuard: Timer?
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
        // The transformer loads in the background; the first launch compiles
        // it for the Neural Engine, which used to freeze the app for seconds.
        let t1 = Tier1Classifier(background: true)
        DispatchQueue.global(qos: .utility).async { Normalizer.warmUp() }
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

        tap.onSendKey = { [weak self] in self?.handleSendKey() }
        tap.onHoldAction = { [weak self] action in self?.handle(action) }
        tap.onDisabled = { [weak self] in self?.noteTapRecovered() }
        // Runs on the tap thread when Return beats the watcher to the latest
        // keystroke. Local tiers only, about a millisecond.
        let cascade = self.cascade
        tap.freshCheck = { text in
            let v = cascade.localVerdict(text).verdict
            return v.pendingReview || HoldPolicy.shouldHold(v, sensitivity: AppSettings.shared.sensitivity)
        }

        NotificationCenter.default.addObserver(
            forName: .shieldSettingsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySettings() }
            }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    AX.forgetWebAccessibility(pid: app.processIdentifier)
                }
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
        startHoldGuard()
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

    // MARK: Reading what is being written

    /// How much of a long document is judged at once: the passage around the
    /// caret, not the whole file. One cruel sentence on page one should not
    /// block the Return key on page nine.
    nonisolated static let windowBefore = 600
    /// Mostly what is behind the caret: that is what the person just wrote.
    nonisolated static let windowAfter = 40
    nonisolated static let wholeFieldLimit = 1500

    /// Builds the candidate from the focused field and the typed buffer.
    /// Pure apart from the AX read, so the watcher and the Return handler
    /// agree on what the person wrote.
    nonisolated static func buildCandidate(field: AX.FocusedField?, typed snap: TypedBuffer.Snapshot,
                                           app: NSRunningApplication) -> Candidate? {
        let typedText = snap.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedLive = snap.pid == app.processIdentifier && !typedText.isEmpty
            && Date().timeIntervalSince(snap.lastKeyAt) < TypedBuffer.idleReset

        if let f = field, f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ReadableFields.contains(f.pid) {
            // This app's field has shown its real text before, so empty
            // means empty: the person deleted what they typed, or sent it.
            // The keystroke record is stale and must not speak for them.
            return nil
        }
        if let f = field, !f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (text, whole) = window(f.value, caret: f.caret)
            if !typedLive || covers(text, typedTail: typedText) { ReadableFields.insert(f.pid) }
            // Accessibility and the keyboard disagree: the field's value does
            // not contain what was just typed. Google Docs and canvas editors
            // do this. Believe the keyboard.
            if typedLive, !ReadableFields.contains(f.pid), !covers(text, typedTail: typedText) {
                return Candidate(text: typedText, source: .typed, element: f.element, pid: f.pid,
                                 appName: f.appName, bundleID: f.bundleID, role: f.role,
                                 isWeb: f.isWeb, typed: snap)
            }
            return Candidate(text: text, source: whole ? .field : .fieldWindow, element: f.element,
                             pid: f.pid, appName: f.appName, bundleID: f.bundleID, role: f.role,
                             isWeb: f.isWeb, typed: typedLive ? snap : nil)
        }
        if typedLive {
            return Candidate(text: typedText, source: .typed, element: field?.element,
                             pid: app.processIdentifier, appName: app.localizedName,
                             bundleID: app.bundleIdentifier, role: field?.role,
                             isWeb: field?.isWeb ?? false, typed: snap)
        }
        return nil
    }

    nonisolated static func window(_ value: String, caret: Int?) -> (String, Bool) {
        let ns = value as NSString
        guard ns.length > wholeFieldLimit else { return (value, true) }
        let c = min(max(caret ?? ns.length, 0), ns.length)
        var start = max(0, c - windowBefore)
        let end = min(ns.length, c + windowAfter)
        // Start on a word boundary so the first word is not half a word.
        while start > 0 && start < end,
              let scalar = UnicodeScalar(ns.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start += 1
        }
        let r = NSRange(location: start, length: max(0, end - start))
        return (ns.substring(with: rangeAligned(r, in: ns)), false)
    }

    /// Never cut a surrogate pair in half.
    private nonisolated static func rangeAligned(_ r: NSRange, in ns: NSString) -> NSRange {
        ns.rangeOfComposedCharacterSequences(for: r)
    }

    /// True when the last few typed characters appear in the field's text.
    nonisolated static func covers(_ fieldText: String, typedTail typed: String) -> Bool {
        func squash(_ s: String) -> String {
            String(s.lowercased().filter { !$0.isWhitespace })
        }
        let tail = String(squash(typed).suffix(12))
        guard tail.count >= 3 else { return true }
        return squash(fieldText).contains(tail)
    }

    /// The sentences that are actually over the line, joined. Falls back to
    /// the whole text when the harm only shows in the sum of its parts.
    nonisolated func offendingSpan(of text: String) -> String {
        let sensitivity = AppSettings.shared.sensitivity
        var sentences: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, r, _, _ in
            sentences.append(r)
        }
        guard sentences.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hot = sentences.filter {
            HoldPolicy.shouldHold(cascade.localVerdict(String(text[$0])).verdict, sensitivity: sensitivity)
        }
        guard let first = hot.first, let last = hot.last else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[first.lowerBound..<last.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func spanKey(_ span: String) -> Int {
        Normalizer.normalize(span).squashed.hashValue
    }

    // MARK: The watcher (runs on `queue`, never blocks on main)

    private nonisolated func tick() {
        guard !state.holding else { return }
        retryTapIfNeeded()

        guard ProtectionGate.onboarded else {
            suspend("Finish setup to start protecting"); return
        }
        guard AppSettings.shared.sendShieldEnabled else {
            suspend("Shield is off"); return
        }
        guard AX.isTrusted else {
            suspend("Accessibility is off"); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            suspend(nil); return
        }
        if let bid = app.bundleIdentifier, Lexicon.excludedBundleIDs.contains(bid) {
            suspend("Off in \(app.localizedName ?? bid)"); return
        }
        // A password prompt anywhere on the machine turns on secure input.
        // Shield has no business near it.
        if IsSecureEventInputEnabled() {
            suspend("Secure input, standing down"); return
        }

        let field = AX.focusedField()
        if let field, field.isSecure {
            suspend("Password field, standing down"); return
        }
        tap.mode = .watching

        let snap = tap.typed.snapshot()
        guard let candidate = ShieldEngine.buildCandidate(field: field, typed: snap, app: app) else {
            // Web views drop their focused element for a frame on every
            // repaint. Disarming on the first blink means Return slips through
            // on exactly the message that should have been caught, so hold the
            // last known state briefly.
            if field == nil {
                focusMisses += 1
                if focusMisses < 8 { return }
            }
            tap.isArmed = false
            state.reset()
            // An empty field means the last message was sent or deleted, and
            // whatever the keyboard remembers of it is history.
            if let field, field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               ReadableFields.contains(field.pid) {
                tap.typed.reset()
            }
            if field != nil { state.clearSuppressions() }
            publish(watching: field == nil ? nil : app.localizedName, role: field?.role, reason: nil)
            return
        }
        focusMisses = 0
        publish(watching: candidate.appName, role: candidate.role, reason: nil)

        let text = candidate.text
        let changed = state.noteText(text)
        var verdict = state.candidate?.1
        if changed || verdict == nil {
            verdict = arm(candidate)
            tap.typed.markScored(snap.version)
        } else {
            state.setCandidate(candidate, verdict: verdict)
        }

        if let verdict { maybeCatchWhileTyping(candidate, verdict) }

        let stable = state.stableFor()
        if stable >= 0.14, state.claimQuick() {
            // Something only the transformer saw goes to review at once, so
            // the answer is usually back before Return is pressed.
            runCascade(candidate, withContext: verdict?.pendingReview ?? false)
        } else if stable >= 0.75, state.claimContext() {
            runCascade(candidate, withContext: true)
        }
    }

    /// Scores a candidate locally and sets the tap's armed flag from it.
    @discardableResult
    private nonisolated func arm(_ c: Candidate) -> Verdict {
        let hash = VerdictHash.of(c.text)
        let local = cascade.localVerdict(c.text, context: state.context).verdict
        // A context-tier verdict for exactly this text outranks the local one.
        let v: Verdict
        if let w = warm.get(hash), w.tier == .context { v = w } else { v = local; warm.set(hash, local) }
        state.setCandidate(c, verdict: v)
        // A verdict waiting on review arms Return too: the keystroke is held
        // back until the context tier answers, rather than sent on a guess.
        tap.isArmed = !state.isAllowed(hash)
            && (v.pendingReview || HoldPolicy.shouldHold(v, sensitivity: AppSettings.shared.sensitivity))
        return v
    }

    /// The live catch: cruel text is stopped as it is written, in any app,
    /// whether or not Return is ever pressed.
    private nonisolated func maybeCatchWhileTyping(_ c: Candidate, _ v: Verdict) {
        guard AppSettings.shared.liveCatchEnabled else { return }
        // Only while the person is actually typing here. Opening a reply that
        // quotes someone else's cruel message is not writing one.
        let snap = tap.typed.snapshot()
        guard snap.pid == c.pid, Date().timeIntervalSince(snap.lastKeyAt) < 8 else { return }
        guard HoldPolicy.shouldHold(v, sensitivity: AppSettings.shared.sensitivity) else { return }
        guard !state.isAllowed(VerdictHash.of(c.text)) else { return }
        guard state.sinceDismiss > 0.8 else { return }

        // Wait for the word to finish: a pause, or a space or punctuation
        // after it. Popping up mid-word reads as a glitch.
        let stable = state.stableFor()
        let ended = c.text.last.map { $0.isWhitespace || $0.isPunctuation } ?? false
        guard stable >= 0.6 || (ended && stable >= 0.12) else { return }

        // After Escape, deleting is fixing: no catch. Typing anything new
        // onto text that is still over the line is a new attempt: catch.
        if let n = state.insertsAtDismiss, snap.inserts <= n { return }
        let span = offendingSpan(of: c.text)

        // Take the keyboard now, on this thread, so nothing typed between
        // here and the panel appearing gets through.
        state.holding = true
        state.holdTakenAt = Date()
        tap.mode = .holding
        Task { @MainActor in
            self.present(c, verdict: v, span: span, trigger: .typing)
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

    private nonisolated func suspend(_ reason: String?) {
        tap.isArmed = false
        tap.mode = .idle
        tap.typed.reset()
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

    private nonisolated func runCascade(_ c: Candidate, withContext: Bool) {
        guard !state.analysing else { return }
        state.analysing = true

        if withContext && state.contextIsStale {
            state.context = AXContextReader.conversation()
        }
        let text = c.text
        let ctx = state.context
        let sensitivity = AppSettings.shared.sensitivity
        let crisisOn = AppSettings.shared.crisisSurfaceEnabled
        let hash = VerdictHash.of(text)
        let element = c.element

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.cascade.analyze(text, context: ctx, allowContext: withContext)
            self.state.analysing = false
            guard self.state.matches(text) else { return }

            self.warm.set(hash, result.verdict)
            if result.verdict.tier == .context || result.verdict.score > (self.state.candidate?.1?.score ?? 0) {
                if var cur = self.state.candidate, cur.0.text == text {
                    cur.1 = result.verdict
                    self.state.setCandidate(cur.0, verdict: result.verdict)
                }
                if !self.state.isAllowed(hash) {
                    self.tap.isArmed = result.verdict.pendingReview
                        || HoldPolicy.shouldHold(result.verdict, sensitivity: sensitivity)
                }
            }

            await MainActor.run {
                self.refreshQuota()
                if crisisOn, withContext,
                   let offer = self.crisis.consider(result.verdict, text: text) {
                    self.crisisOffer = CrisisOffer(incoming: offer.incoming,
                                                   anchor: element.flatMap { AX.frame(of: $0) })
                    self.record(.resources, text: text)
                }
            }
        }
    }

    // MARK: The catch

    /// Runs on the main queue, immediately after the tap swallowed a Return.
    /// Fails closed: if anything about the field is uncertain, the last thing
    /// the watcher saw decides, not a shrug that lets the message go.
    private func handleSendKey() {
        DebugLog.write("send key swallowed")
        guard held == nil else { return }

        var candidates: [Candidate] = []
        if let app = NSWorkspace.shared.frontmostApplication,
           let c = ShieldEngine.buildCandidate(field: AX.focusedField(), typed: tap.typed.snapshot(), app: app) {
            candidates.append(c)
            // The keyboard may have seen words the field has not reported yet.
            if c.source != .typed, !ReadableFields.contains(c.pid), let snap = c.typed, !snap.text.isEmpty {
                candidates.append(Candidate(text: snap.text, source: .typed, element: c.element, pid: c.pid,
                                            appName: c.appName, bundleID: c.bundleID, role: c.role,
                                            isWeb: c.isWeb, typed: snap))
            }
        }
        if let (last, _) = state.candidate { candidates.append(last) }

        let sensitivity = settings.sensitivity
        var awaitingReview: [Candidate] = []
        for c in candidates where !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hash = VerdictHash.of(c.text)
            if state.isAllowed(hash) { continue }
            var verdict = cascade.localVerdict(c.text, context: state.context).verdict
            if let w = warm.get(hash), w.tier == .context { verdict = w }
            if verdict.pendingReview { awaitingReview.append(c); continue }
            guard HoldPolicy.shouldHold(verdict, sensitivity: sensitivity) else { continue }
            DebugLog.write("HOLD on send len=\(c.text.count) score=\(verdict.score) app=\(c.appName ?? "?") src=\(c.source)")
            present(c, verdict: verdict, span: offendingSpan(of: c.text), trigger: .send)
            return
        }

        // Only the transformer objected, and the context tier has not ruled
        // yet. Ask it now, briefly; the keystroke waits.
        if let c = awaitingReview.first {
            reviewThenSend(c)
            return
        }

        // Nothing over the line after all: the draft changed between the tap
        // and here. Let the keystroke through.
        tap.isArmed = false
        tap.typed.noteSend()
        state.clearSuppressions()
        EventTap.repostReturn()
    }

    /// Asks the context tier about a draft only the transformer flagged, then
    /// holds or sends. Gives up after 2.5 s and lets the transformer decide,
    /// so a slow network never swallows a message for good.
    private func reviewThenSend(_ c: Candidate) {
        let ctx = state.context
        let cascade = self.cascade
        let sensitivity = settings.sensitivity
        Task { [weak self] in
            let verdict: Verdict = await withTaskGroup(of: Verdict?.self) { group in
                group.addTask { await cascade.analyze(c.text, context: ctx, allowContext: true).verdict }
                group.addTask { try? await Task.sleep(nanoseconds: 2_500_000_000); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                if let first { return first }
                var v = cascade.localVerdict(c.text, context: ctx).verdict
                Cascade.applyOfflineFallback(&v)
                return v
            }
            guard let self else { return }
            self.warm.set(VerdictHash.of(c.text), verdict)
            if HoldPolicy.shouldHold(verdict, sensitivity: sensitivity) {
                DebugLog.write("HOLD after review score=\(verdict.score) tier=\(verdict.tier)")
                self.present(c, verdict: verdict, span: self.offendingSpan(of: c.text), trigger: .send)
            } else {
                DebugLog.write("review cleared the draft, sending")
                self.tap.isArmed = false
                self.tap.typed.noteSend()
                EventTap.repostReturn(after: 0.01)
            }
        }
    }

    private func present(_ c: Candidate, verdict: Verdict, span: String, trigger: HeldDraft.Trigger) {
        state.holdTakenAt = nil
        guard held == nil else { return }
        // The person may have switched away in the moment between the catch
        // and here. A panel over the wrong app is worse than none.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == c.pid else {
            DebugLog.write("present skipped: app changed")
            releaseKeyboard()
            return
        }
        let frame = c.element.flatMap { AX.caretFrameChecked(of: $0) }
            ?? ShieldEngine.fallbackAnchor(pid: c.pid)
        heldElement = c.element
        tap.mode = .holding
        state.holding = true
        held = HeldDraft(text: c.text, span: span, verdict: verdict, trigger: trigger,
                         source: c.source, fieldFrame: frame, appName: c.appName,
                         bundleID: c.bundleID, pid: c.pid, isWeb: c.isWeb, role: c.role,
                         typed: c.typed ?? tap.typed.snapshot())
        DebugLog.write("present \(trigger) spanLen=\(span.count) score=\(verdict.score) frame=\(String(describing: frame))")
        telemetry.recordHold()
        snapshot = telemetry.current
        markHeld(c.text)
        record(.caught, text: span, reason: reason(for: verdict), app: c.appName, score: verdict.score)
        Feedback.catchHappened()
        startHoldWatchdog()
    }

    /// Where to put the panel when the text has no field Shield can see:
    /// low and centred in the window the person is typing in.
    private static func fallbackAnchor(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
        guard let win = AX.element(app, kAXFocusedWindowAttribute as String),
              let wf = AX.frame(of: win) else { return nil }
        return CGRect(x: wf.midX - CatchOverlayView.width / 2, y: wf.minY + 90,
                      width: CatchOverlayView.width, height: 1)
    }

    private func append(_ trace: Trace) {
        traces.insert(trace, at: 0)
        if traces.count > 200 { traces.removeLast(traces.count - 200) }
        snapshot = telemetry.current
    }

    /// A short human reason, preferring what the context tier said.
    private func reason(for v: Verdict) -> String? {
        if let r = v.rationale, !r.isEmpty { return r }
        guard let c = v.primaryCategory else { return nil }
        switch c {
        case .exclusion:   return "Shuts someone out"
        case .backhanded:  return "A compliment with an insult inside it"
        case .sarcasm:     return "Reads as mockery"
        case .pileOn:      return "Repeats what others already said at one person"
        case .threat:      return "Reads as a threat"
        case .slur:        return "Contains a slur"
        case .harassment:  return "Aimed at hurting someone"
        case .explicit:    return "Explicit language"
        case .profanity:   return "Swearing"
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
        case .primary:
            if case .failed = rephrase {
                let wordPolicy = held.map { $0.verdict.categories.contains(.profanity) || $0.verdict.categories.contains(.explicit) } ?? false
                if held?.trigger == .send && !wordPolicy { sendUnchanged() } else { editDraft() }
            } else {
                rephraseAndSend()
            }
        case .edit, .typedThrough:
            editDraft()
        case .remove:
            deleteDraft()
        case .blockedKey:
            nudge &+= 1
            NSSound.beep()
        }
    }

    /// Back to the field to fix it by hand. The words are not allowed
    /// through: if Return is pressed on them again, they are held again.
    func editDraft() {
        guard let draft = held else { return }
        state.insertsAtDismiss = tap.typed.snapshot().inserts
        telemetry.recordEdited()
        if !draft.preview { record(.edited, text: draft.span, app: draft.appName) }
        dismissHold()
        snapshot = telemetry.current
    }

    /// Takes the offending passage out of the field.
    func deleteDraft() {
        guard let draft = held, rephrase != .working else { return }
        if draft.preview { dismissHold(); return }
        let ok = replace(draft.span, with: "", in: draft)
        guard ok else {
            rephrase = .failed("Couldn't remove it here, so select it and delete it yourself")
            return
        }
        telemetry.recordDeleted()
        record(.deleted, text: draft.span, app: draft.appName)
        dismissHold()
        snapshot = telemetry.current
    }

    private func startHoldWatchdog() {
        holdWatchdog?.invalidate()
        let t = Timer(timeInterval: 90, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.held != nil else { return }
                // Give the keyboard back. Nothing is allowed through: the
                // same words will be held again if sent.
                DebugLog.write("watchdog released a stuck hold")
                self.editDraft()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        holdWatchdog = t
    }

    /// Gives the keyboard back without touching anything else.
    private func releaseKeyboard() {
        state.holding = false
        state.holdTakenAt = nil
        tap.isArmed = false
        tap.mode = .watching
    }

    /// Five times a second: the keyboard is never held without a panel on
    /// screen, and a held draft never sits without one. Whatever path got
    /// there, this is where it stops.
    private func startHoldGuard() {
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHoldInvariant() }
        }
        RunLoop.main.add(t, forMode: .common)
        holdGuard = t
    }

    private func checkHoldInvariant() {
        guard held == nil else { return }
        if tap.mode == .holding || state.holding {
            if let taken = state.holdTakenAt, Date().timeIntervalSince(taken) < 0.5 { return }
            DebugLog.write("hold guard: keyboard held with no panel, releasing")
            releaseKeyboard()
        }
    }

    func dismissHold() {
        holdWatchdog?.invalidate()
        holdWatchdog = nil
        heldElement = nil
        rephrase = nil
        held = nil
        state.noteDismissed()
        state.reset()
        state.holding = false
        tap.isArmed = false
        tap.mode = .watching
    }

    /// Rewrites the offending text, and sends it when Return is what
    /// triggered the hold — in one keystroke.
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
            rephrase = .failed("No API key for rewrites. Remove it, or press Esc and edit it yourself")
            return
        }

        rephrase = .working
        let target = draft.rewriteTarget
        let ctx = state.context

        Task { [weak self] in
            guard let self else { return }
            do {
                let rewritten = try await self.rephraser.rephrase(target, context: ctx)
                DebugLog.write("rewrite came back, \(rewritten.count) chars")
                await MainActor.run {
                    guard let current = self.held, current.id == draft.id else { self.rephrase = nil; return }
                    // A rewrite that would itself be held is no rewrite.
                    let check = self.cascade.localVerdict(rewritten).verdict
                    if HoldPolicy.shouldHold(check, sensitivity: self.settings.sensitivity) {
                        DebugLog.write("rewrite still over the line, not used")
                        self.rephrase = .failed("There's no kind way to send this one. Remove it, or press Esc to change it yourself")
                        return
                    }
                    guard self.replace(target, with: rewritten, in: draft) else {
                        self.rephrase = .failed("Couldn't change the text here, so edit it yourself")
                        return
                    }
                    // The rewrite is the person's choice; let it through.
                    let newText = draft.text.replacingLastOccurrence(of: target, with: rewritten)
                    self.state.allow(VerdictHash.of(newText))
                    self.state.allow(VerdictHash.of(rewritten))
                    self.state.suppress(ShieldEngine.spanKey(rewritten))
                    self.telemetry.recordEdited()
                    self.record(.rephrased, text: target, reason: nil,
                                app: draft.appName, rewritten: rewritten,
                                score: draft.verdict.score)
                    self.rephrase = nil
                    self.dismissHold()
                    if draft.trigger == .send {
                        // Queued behind the replacement on the same serial
                        // queue, so it can never land first.
                        EventTap.repostReturn(after: 0.15)
                        self.tap.typed.noteSend()
                    }
                    self.snapshot = self.telemetry.current
                }
            } catch {
                await MainActor.run {
                    DebugLog.write("rephrase failed: \(error)")
                    let why: String
                    switch error {
                    case Rephraser.Failure.quotaExhausted: why = "Out of rewrites today, so edit it yourself"
                    case Rephraser.Failure.noKey: why = "No API key for rewrites, so edit it yourself"
                    case Rephraser.Failure.noRewrite: why = "There's no kind way to send this one. Remove it, or press Esc to change it yourself"
                    default: why = "The rewrite did not come back, so edit it yourself"
                    }
                    self.rephrase = .failed(why)
                }
            }
        }
    }

    /// Sends the draft untouched. Only reachable after a rewrite has failed,
    /// because a message Shield cannot rewrite is a message it has no business
    /// keeping. While typing, there is nothing to send, so it simply closes.
    func sendUnchanged() {
        guard let draft = held else { return }
        // Banned words are never sent as is.
        if draft.verdict.categories.contains(.profanity) || draft.verdict.categories.contains(.explicit) {
            editDraft(); return
        }
        state.allow(VerdictHash.of(draft.text))
        state.suppress(ShieldEngine.spanKey(draft.span))
        telemetry.recordSentAnyway()
        if !draft.preview { record(.sentAnyway, text: draft.span, app: draft.appName) }
        let preview = draft.preview
        dismissHold()
        guard !preview, draft.trigger == .send else { snapshot = telemetry.current; return }
        EventTap.repostReturn()
        tap.typed.noteSend()
        snapshot = telemetry.current
    }

    // MARK: Changing the text

    /// Replaces `target` with `replacement` in the held field, by whatever
    /// route this app accepts. Each route is verified before it counts.
    private func replace(_ target: String, with replacement: String, in draft: HeldDraft) -> Bool {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        if draft.source != .typed, let el = heldElement ?? AX.focusedField()?.element {
            if replaceWithAX(target, replacement, el, draft) { return true }
        }
        return replaceWithKeys(target, replacement, draft)
    }

    private func replaceWithAX(_ target: String, _ replacement: String, _ el: AXUIElement, _ draft: HeldDraft) -> Bool {
        guard let full = AX.readValue(el), !full.isEmpty else { return false }
        let ns = full as NSString
        let r = ns.range(of: target, options: .backwards)
        guard r.location != NSNotFound else { return false }
        let isWhole = full.trimmingCharacters(in: .whitespacesAndNewlines) == target
        let newFull = ns.replacingCharacters(in: r, with: replacement)
            .replacingOccurrences(of: "  ", with: " ")

        func landed() -> Bool {
            for _ in 0..<3 {
                if let now = AX.readValue(el) {
                    let gone = !(now as NSString).contains(target) || (now as NSString).range(of: target, options: .backwards).location != r.location
                    if gone && (replacement.isEmpty || now.contains(replacement)) { return true }
                }
                usleep(40_000)
            }
            return false
        }

        // Web and Electron editors render an AXValue write but never tell
        // the page, so the old text is what gets sent. Typing is the only
        // thing they reliably hear.
        if draft.isWeb {
            if isWhole, full.count <= 4000 {
                EventTap.replaceAllWithKeys(replacement)
                return true
            }
            if AX.setSelectedRange(el, r) {
                usleep(30_000)
                if let sel = AX.selectedRange(of: el), sel.location == r.location, sel.length == r.length {
                    EventTap.replaceBehindCaret(deleting: replacement.isEmpty ? 1 : 0, typing: replacement)
                    return true
                }
            }
            return false
        }

        if isWhole, AX.setString(el, kAXValueAttribute as String, newFull), landed() { return true }
        if AX.setSelectedRange(el, r), AX.replaceSelection(el, with: replacement), landed() { return true }
        if AX.setString(el, kAXValueAttribute as String, newFull), landed() { return true }
        if isWhole, full.count <= 4000, draft.role != "AXWebArea" {
            EventTap.replaceAllWithKeys(replacement)
            return true
        }
        return false
    }

    /// The universal route: delete back to the start of the passage with
    /// Backspace and type the replacement. Works anywhere text can be typed,
    /// as long as the caret has not moved since the words were written.
    private func replaceWithKeys(_ target: String, _ replacement: String, _ draft: HeldDraft) -> Bool {
        guard let snap = draft.typed, snap.pid == draft.pid,
              let r = snap.text.range(of: target, options: .backwards) else { return false }
        let offset = snap.text.distance(from: snap.text.startIndex, to: r.lowerBound)
        // Only text typed since the caret last moved can be reached by
        // Backspace from where the caret is now.
        guard offset >= snap.segmentStart else { return false }
        let deleteCount = snap.text.distance(from: r.lowerBound, to: snap.text.endIndex)
        let trailing = String(snap.text[r.upperBound...])
        var typing = replacement + trailing
        if replacement.isEmpty, offset > 0, typing.first == " ",
           snap.text[snap.text.index(before: r.lowerBound)] == " " {
            typing.removeFirst()
        }
        EventTap.replaceBehindCaret(deleting: deleteCount, typing: typing)
        tap.typed.replaceTail(from: offset, with: typing)
        return true
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
        held = HeldDraft(text: text, span: text, verdict: verdict, trigger: .send,
                         fieldFrame: rect, appName: nil, bundleID: nil, preview: true)
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

/// Whether AutoShield may act at all. Protection and prevention run only
/// once the person has finished onboarding in this session and the shield is
/// switched on. (Closing the window quits the app, so "open" is implied.)
enum ProtectionGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _onboarded = false

    static var onboarded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _onboarded }
        set {
            lock.lock(); _onboarded = newValue; lock.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .shieldSettingsChanged, object: nil) }
        }
    }

    /// The shield is on and setup is done.
    static var isOpen: Bool { onboarded && AppSettings.shared.sendShieldEnabled }
}

/// Apps whose focused field has shown Shield the person's real text. For
/// these, the field is the truth and the keystroke record only a fallback.
/// Apps that draw their own text (Google Docs, canvas editors) never get in,
/// so the keyboard keeps speaking for them.
enum ReadableFields {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids = Set<pid_t>()
    static func insert(_ pid: pid_t) { lock.lock(); pids.insert(pid); lock.unlock() }
    static func contains(_ pid: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(pid) }
}

enum VerdictHash {
    static func of(_ s: String) -> Int {
        var h = Hasher()
        h.combine(s.trimmingCharacters(in: .whitespacesAndNewlines))
        return h.finalize()
    }
}

extension String {
    func replacingLastOccurrence(of target: String, with replacement: String) -> String {
        guard let r = range(of: target, options: .backwards) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
