import AppKit
import SwiftUI
import ShieldCore

/// Incoming protection: frosted glass floated over cruel text on screen,
/// tracked to its rect and peeled away only if you ask.
///
/// Two loops, both off the main thread:
///
/// - The **scan** walks the frontmost window's accessibility tree, judges
///   every run of text (alone, and joined with its siblings), and decides what
///   to cover. A large page takes a while, so it runs at its own pace.
/// - The **tracker** re-reads only the covered elements' positions, thirty
///   times a second, so covers move with the text as it scrolls instead of
///   jumping a scan later. It also notices a tab, window or app change at
///   once and pulls every cover down before the next app is drawn under it.
///
/// Honest limit: macOS gives no way to intercept another app's rendering, so
/// text exists on screen for the moment between paint and cover. Shield closes
/// that gap as far as a native app can, but it cannot make it zero.
@MainActor
final class InboxShield {

    private struct Cover {
        var panel: FloatingPanel<AnyView>
        var frame: CGRect
        var score: Double
        var textKeys: Set<Int>
        var elements: [AXUIElement]
        var container = false
        /// The element whose text was judged, and that text's key. Chat apps
        /// recycle row views as they scroll; when this element starts saying
        /// something else, the cover is no longer over what it was hiding.
        var source: AXUIElement?
        var sourceKey: Int?
        var sourceAttribute: String?
        var clip: AXUIElement?
    }

    /// Something the scan found and wants covered.
    private struct Hit {
        var key: Int
        var textKeys: Set<Int>
        var frame: CGRect
        var score: Double
        var elements: [AXUIElement]
        /// True when the cover sits on a bubble or row rather than bare
        /// text: it gets the bubble's own shape and no extra padding.
        var container = false
        var source: AXUIElement?
        var sourceKey: Int?
        var sourceAttribute: String?
        var clip: AXUIElement?
        /// The bubble could not be found this time; keep the cover where it
        /// is rather than stretch it across the row.
        var keepExisting = false
        /// Which path made the hit, for the log.
        var origin = ""
    }

    private var covers: [Int: Cover] = [:]
    private var revealed = Set<Int>()
    private var counted = Set<Int>()
    private var running = false
    private var emptyScans = 0
    private var lastPid: pid_t = 0
    private unowned let engine: ShieldEngine

    private let scanQueue = DispatchQueue(label: "shield.inbox.scan", qos: .userInitiated)
    private let trackQueue = DispatchQueue(label: "shield.inbox.track", qos: .userInteractive)
    private var trackTimer: Timer?
    private var tracking = false
    /// What the tracker last saw in front, so a change is noticed at once.
    private var frontIdentity: FrontIdentity?
    /// Bumped whenever covers are torn down, so a scan that started before
    /// the teardown cannot put stale covers back.
    private var generation = 0
    private var scanQueued = false

    /// Scores by text, so a message on screen is judged once, not every scan.
    private nonisolated let scores = ScoreCache()

    init(engine: ShieldEngine) {
        self.engine = engine
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Down before the next app is drawn under them.
                    self?.clearAll()
                    self?.scanSoon()
                }
            }
    }

    func start() {
        guard !running else { return }
        running = true
        scheduleScan(after: 0.05)
        startTracking()
    }

    func stop() {
        running = false
        trackTimer?.invalidate(); trackTimer = nil
        clearAll()
    }

    var isRunning: Bool { running }

    // MARK: The scan

    private func scanSoon() {
        guard running, !scanQueued else { return }
        scheduleScan(after: 0.02)
    }

    private func scheduleScan(after delay: TimeInterval) {
        guard running else { return }
        scanQueued = true
        let cascade = engine.cascade
        let scores = self.scores
        let revealedNow = revealed
        let editable = engine.heldElement
        let gen = generation
        scanQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            let started = Date()
            let result = InboxShield.scan(cascade: cascade, scores: scores, revealed: revealedNow,
                                          editable: editable ?? AX.focusedField()?.element)
            let took = Date().timeIntervalSince(started)
            Task { @MainActor in
                guard let self, self.running else { return }
                self.scanQueued = false
                if gen == self.generation { self.apply(result) }
                // Pace to the app: a page that takes 300 ms to walk is
                // scanned less often than one that takes 10. The tracker
                // keeps covers in place between scans either way.
                self.scheduleScan(after: max(0.15, min(0.8, took * 1.2)))
            }
        }
    }

    private struct ScanResult {
        /// The person's own text field, when it sits at the foot of the
        /// window: covers are clipped above it, never drawn over it.
        var compose: AXUIElement? = nil
        var pid: pid_t
        var skipped: Bool
        var complete: Bool
        var hits: [Hit]
        var offers: [CGRect?]
        var sawText: Bool
    }

    private nonisolated static func scan(cascade: Cascade, scores: ScoreCache,
                                         revealed: Set<Int>, editable: AXUIElement?) -> ScanResult {
        let settings = AppSettings.shared
        let skipped = ScanResult(pid: 0, skipped: true, complete: true, hits: [], offers: [], sawText: false)
        // The shield switch is the master switch: off means nothing is
        // covered either, and nothing happens before setup is finished.
        guard ProtectionGate.isOpen, settings.inboxShieldEnabled, AX.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication else { return skipped }
        if let bid = app.bundleIdentifier, Lexicon.excludedBundleIDs.contains(bid) {
            return ScanResult(pid: app.processIdentifier, skipped: true, complete: true, hits: [], offers: [], sawText: false)
        }
        guard let scan = AXContextReader.scanFrontWindow(limit: 900, wantFrames: true,
                                                         budget: 0.9, skipping: editable) else { return skipped }

        let sensitivity = settings.sensitivity
        var raw: [Hit] = []
        var offers: [CGRect?] = []

        // New text costs a model pass. A page full of it is judged over a few
        // scans rather than stalling one; text already judged is free.
        var fresh = 0
        var deferred = false
        func judge(_ text: String) -> (cover: Bool, score: Double, offer: Bool)? {
            let key = InboxShield.textKey(text)
            if let cached = scores.get(key) { return cached }
            fresh += 1
            if fresh > 80 { deferred = true; return nil }
            let v = cascade.localVerdict(text).verdict
            // Someone else's message about their own pain is not covered. It
            // is offered resources, quietly, and left alone.
            let offer = v.selfDirected && v.distress == .present
            // Incoming text is not sent to the context tier (that would be
            // every message on screen), so a transformer-only verdict covers
            // when the transformer is all but certain. A cover is one click
            // to undo; a hold is not.
            let cover = !v.selfDirected && (HoldPolicy.shouldHold(v, sensitivity: sensitivity)
                || (v.pendingReview && v.modelScore >= 0.98 && sensitivity != .light))
            // Offered once per message: the cache remembers it as handled.
            scores.set(key, (cover, v.score, false))
            return (cover, v.score, offer)
        }

        func add(_ text: String, _ frame: CGRect, _ score: Double, _ elements: [AXUIElement],
                 attribute: String? = nil, clipTo clipElement: AXUIElement? = nil, origin: String = "run") {
            let tk = InboxShield.textKey(text)
            guard !revealed.contains(tk) else { return }
            var frame = frame
            var elements = elements
            var container = false
            var keepExisting = false
            var bubbleExpected = false
            let source = elements.count == 1 ? elements[0] : nil
            // A row as wide as the conversation is not the message; the
            // bubble inside it is.
            // Only a chat row (a container that carries its message as a
            // description) has a bubble inside it to find. Ordinary text, a
            // search suggestion or a paragraph, is already its own shape.
            if let wf = scan.windowFrame, frame.width > wf.width * 0.5, elements.count == 1,
               attribute == kAXDescriptionAttribute as String {
                bubbleExpected = true
                if let tight = AXContextReader.tightTarget(elements[0], frame: frame) {
                    frame = tight.frame
                    elements = tight.elements
                    container = true
                } else {
                    // The bubble did not answer in time (mid-scroll, usually).
                    // Never stretch a cover across the conversation: keep the
                    // one already there, and look again next scan.
                    keepExisting = true
                    deferred = true
                }
            }
            var clipped = frame
            if let wf = scan.windowFrame { clipped = frame.intersection(wf) }
            let area = clipElement.flatMap { AXContextReader.liveFrame($0) }
            if let cf = area { clipped = clipped.intersection(cf) }
            // A single message is never as wide as the conversation. If this
            // one is, Shield is looking at a row, not a bubble: wait for a
            // scan that finds the bubble rather than draw a band across.
            if bubbleExpected, InboxShield.tooWide(clipped, area: area ?? scan.windowFrame) {
                keepExisting = true
                deferred = true
            }
            guard !clipped.isNull, clipped.width > 6, clipped.height > 6 else { return }
            raw.append(Hit(key: 0, textKeys: [tk], frame: clipped, score: score, elements: elements,
                           container: container, source: attribute == nil ? nil : source, sourceKey: tk,
                           sourceAttribute: attribute, clip: clipElement, keepExisting: keepExisting,
                           origin: "\(origin) expected=\(bubbleExpected) tight=\(container) els=\(elements.count)"))
        }

        // Individual text runs first.
        var coveredGroups = Set<Int>()
        var byGroup: [Int: [AXContextReader.Message]] = [:]
        for m in scan.messages {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, text.count <= 2000 else { continue }
            byGroup[m.group, default: []].append(m)
            // Chat apps describe a row as "Sender, message, 12:21 AM". The
            // message is judged on its own too, or "pathetic" reads as
            // "Rishi Dasaraju pathetic 12 21 am" and is aimed at nobody.
            var candidates = [text]
            // Labels an app adds for screen readers are not part of what
            // the person reads: Chrome's suggestions say "stupid search
            // suggestion", which reads as aimed at no one.
            let stripped = InboxShield.stripLabels(text)
            if stripped != text, stripped.count >= 2 { candidates.append(stripped) }
            if text.contains(", ") {
                candidates += text.components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 2 }
            }
            var best: (cover: Bool, score: Double, offer: Bool)?
            for c in candidates {
                guard let j = judge(c) else { continue }
                if j.offer { offers.append(m.frame) }
                if j.cover && j.score >= (best?.score ?? 0) { best = j }
            }
            if let j = best, let f = m.frame {
                add(text, f, j.score, m.element.map { [$0] } ?? [], attribute: m.attribute, clipTo: m.clip)
                coveredGroups.insert(m.group)
            }
        }

        // Then each group of sibling runs read as one sentence, for the
        // message split across links, mentions and bold.
        for (group, parts) in byGroup where parts.count >= 2 && !coveredGroups.contains(group) {
            // Joining is for one sentence split into runs (a link, a bold
            // word). A part as wide as the window is a whole chat row, which
            // is judged, and bubble-measured, on its own above; joined, it
            // drew a band across the conversation.
            if let wf = scan.windowFrame,
               parts.contains(where: { ($0.frame?.width ?? 0) > wf.width * 0.5 }) { continue }
            let joined = parts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            guard joined.count <= 2000, let j = judge(joined), j.cover else { continue }
            let frames = parts.compactMap(\.frame)
            guard let first = frames.first else { continue }
            let union = frames.dropFirst().reduce(first) { $0.union($1) }
            // A "group" the size of the window is a layout container, not a
            // message. Covering it would black out the app.
            if let wf = scan.windowFrame, union.width * union.height > wf.width * wf.height * 0.35 { continue }
            add(joined, union, j.score, parts.compactMap(\.element), clipTo: parts.first?.clip, origin: "group")
        }

        // Padding goes on after merging, so neighbouring bubbles stay
        // separate covers instead of fusing into one block.
        var padded = InboxShield.merge(raw).map { h -> Hit in
            var h = h
            h.frame = InboxShield.pad(h.frame, in: scan.windowFrame, container: h.container)
            return h
        }
        let separated = InboxShield.separate(Dictionary(uniqueKeysWithValues: padded.enumerated().map { ($0.offset, $0.element.frame) }))
        for i in padded.indices { if let f = separated[i] { padded[i].frame = f } }
        return ScanResult(compose: editable, pid: scan.pid, skipped: false, complete: scan.complete && !deferred,
                          hits: padded, offers: offers, sawText: !scan.messages.isEmpty)
    }

    /// One cover per patch of screen. Covers that touch become one, so a
    /// message caught both whole and in parts is covered once, cleanly.
    private nonisolated static func merge(_ hits: [Hit]) -> [Hit] {
        // A row still waiting for its bubble has no real shape yet. It never
        // merges (merged with the message's actual text, its width became
        // the cover's), and where real text already covers it, it is dropped.
        let waiting = hits.filter(\.keepExisting)
        let real = hits.filter { !$0.keepExisting }
        var out: [Hit] = []
        for h in real.sorted(by: { $0.frame.minY > $1.frame.minY || ($0.frame.minY == $1.frame.minY && $0.frame.minX < $1.frame.minX) }) {
            var merged = h
            var changed = true
            while changed {
                changed = false
                for (i, o) in out.enumerated() where InboxShield.overlaps(o.frame, merged.frame) {
                    merged.frame = merged.frame.union(o.frame)
                    merged.score = max(merged.score, o.score)
                    merged.textKeys.formUnion(o.textKeys)
                    merged.elements += o.elements
                    merged.container = merged.container || o.container
                    merged.source = nil
                    merged.sourceKey = nil
                    merged.sourceAttribute = nil
                    merged.keepExisting = merged.keepExisting && o.keepExisting
                    merged.origin = "merged(\(merged.origin) + \(o.origin))"
                    out.remove(at: i)
                    changed = true
                    break
                }
            }
            out.append(merged)
        }
        for w in waiting where !out.contains(where: { $0.frame.intersects(w.frame) || !$0.textKeys.isDisjoint(with: w.textKeys) }) {
            out.append(w)
        }
        // Stable identity: the same texts in the same order on screen.
        var seen: [Int: Int] = [:]
        return out.map { h in
            var h = h
            var hasher = Hasher()
            hasher.combine(h.textKeys.sorted())
            let base = hasher.finalize()
            let n = seen[base, default: 0]
            seen[base] = n + 1
            var k = Hasher(); k.combine(base); k.combine(n)
            h.key = k.finalize()
            return h
        }
    }

    private var lastScanSummary = ""

    private func apply(_ result: ScanResult) {
        let summary = "scan pid=\(result.pid) skipped=\(result.skipped) complete=\(result.complete) texts=\(result.sawText) hits=\(result.hits.count) waiting=\(result.hits.filter(\.keepExisting).count) covers=\(covers.count) stale=\(staleKeys.count)"
        if summary != lastScanSummary { lastScanSummary = summary; DebugLog.write(summary) }
        guard ProtectionGate.isOpen, AppSettings.shared.inboxShieldEnabled, !result.skipped else { clearAll(); return }
        // Covers stay up while a draft is held: the catch panel sits above
        // them, and protection never pauses because prevention fired.

        if result.pid != lastPid {
            clearAll()
            lastPid = result.pid
        }
        compose = result.compose

        // One empty scan is a repaint, not proof the messages are gone.
        if !result.sawText {
            emptyScans += 1
            if emptyScans >= 3 { clearAll() }
            return
        }
        emptyScans = 0

        var seen = Set<Int>()
        for hit in result.hits where revealed.isDisjoint(with: hit.textKeys) {
            seen.insert(hit.key)
            place(hit)
        }
        // A scan cut short by its budget saw only part of the window. Covers
        // it did not reach stay up; the tracker removes them if their text
        // is really gone.
        if result.complete {
            for key in covers.keys where !seen.contains(key) { remove(key) }
        }

        if AppSettings.shared.crisisSurfaceEnabled, let frame = result.offers.first {
            engine.offerCrisis(incoming: true, near: frame)
        }
    }

    // MARK: The tracker

    private struct FrontIdentity: Equatable {
        var pid: pid_t
        var windowTitle: String?
        var windowFrame: CGRect?
    }

    private func startTracking() {
        trackTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func trackTick() {
        guard running, !tracking else { return }
        tracking = true
        let snapshot = covers.mapValues { $0.elements }
        let containers = covers.mapValues { $0.container }
        let clips = covers.compactMapValues { $0.clip }
        let composeElement = compose
        let sources = covers.compactMapValues { c -> (AXUIElement, Int, String)? in
            guard let s = c.source, let k = c.sourceKey, let a = c.sourceAttribute else { return nil }
            return (s, k, a)
        }
        let gen = generation
        trackQueue.async { [weak self] in
            let front = InboxShield.currentFront()
            var frames: [Int: CGRect?] = [:]
            var recycled = Set<Int>()
            for (key, elements) in snapshot where !elements.isEmpty {
                // Still the same message? A recycled row says something else.
                if let (src, expected, attr) = sources[key],
                   let text = AXContextReader.liveText(src, attribute: attr),
                   InboxShield.textKey(text) != expected {
                    recycled.insert(key); continue
                }
                let live = elements.compactMap { AXContextReader.liveFrame($0) }
                frames[key] = live.isEmpty ? nil : live.dropFirst().reduce(live[0]) { $0.union($1) }
            }
            // Each scroll area's visible rect, read once per tick.
            var clipFrames: [Int: CGRect] = [:]
            var seenClips: [(AXUIElement, CGRect?)] = []
            for (key, ce) in clips {
                let cached = seenClips.first { CFEqual($0.0, ce) }
                let f = cached != nil ? cached!.1 : AXContextReader.liveFrame(ce)
                if cached == nil { seenClips.append((ce, f)) }
                if let f { clipFrames[key] = f }
            }
            let composeFrame = composeElement.flatMap { AXContextReader.liveFrame($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tracking = false
                guard gen == self.generation else { return }
                self.composeFrame = composeFrame
                self.applyRecycled(recycled)
                self.applyTracking(front: front, frames: frames, containers: containers, clips: clipFrames)
            }
        }
    }

    private nonisolated static func currentFront() -> FrontIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, AX.messagingTimeout)
        let win = AX.element(axApp, kAXFocusedWindowAttribute as String)
        return FrontIdentity(pid: app.processIdentifier,
                             windowTitle: win.flatMap { AX.string($0, kAXTitleAttribute as String) },
                             windowFrame: win.flatMap { AX.frame(of: $0) })
    }

    /// The person's text field in the front window; see `ScanResult.compose`.
    private var compose: AXUIElement?
    private var composeFrame: CGRect?

    /// Clips a cover so it never sits on the input bar at the foot of a
    /// chat. Chat apps scroll messages underneath that bar.
    nonisolated static func clipAboveCompose(_ rect: CGRect, compose: CGRect?, window: CGRect?) -> CGRect {
        guard let c = compose, let w = window, c.midY < w.minY + w.height * 0.35 else { return rect }
        let floor = c.maxY + 8
        guard rect.minY < floor, rect.maxX > c.minX - 60, rect.minX < c.maxX + 60 else { return rect }
        let top = rect.maxY
        guard top > floor else { return .null }
        return CGRect(x: rect.minX, y: floor, width: rect.width, height: top - floor)
    }

    /// Covers whose row now shows a different message. Hidden at once, then
    /// handed new elements by the next scan.
    private var staleKeys = Set<Int>()

    private func applyRecycled(_ keys: Set<Int>) {
        guard !keys.isEmpty else { return }
        for k in keys {
            guard let c = covers[k] else { continue }
            if c.panel.isVisible { c.panel.orderOut(nil) }
            staleKeys.insert(k)
        }
        scanSoon()
    }

    private func applyTracking(front: FrontIdentity?, frames: [Int: CGRect?], containers: [Int: Bool],
                               clips: [Int: CGRect] = [:]) {
        // A new tab, window or app: everything comes down now, and a fresh
        // scan decides what goes back up.
        if let front, let last = frontIdentity,
           front.pid != last.pid || front.windowTitle != last.windowTitle {
            frontIdentity = front
            clearAll()
            scanSoon()
            return
        }
        frontIdentity = front

        // Every cover's new rect, then neighbours separated, then applied.
        var next: [Int: CGRect] = [:]
        var tooWide = Set<Int>()
        for (key, frame) in frames {
            guard let cover = covers[key], !staleKeys.contains(key) else { continue }
            guard let frame else {
                // The text is gone: a closed tab, a deleted message.
                remove(key)
                continue
            }
            var rect = InboxShield.pad(frame, in: nil, container: containers[key] ?? false)
            if let wf = front?.windowFrame { rect = rect.intersection(wf) }
            if let cf = clips[key] { rect = rect.intersection(cf) }
            if !rect.isNull { rect = InboxShield.clipAboveCompose(rect, compose: composeFrame, window: front?.windowFrame) }
            // A bubble cover that suddenly spans the conversation is tracking
            // a row now. Hide it and let a scan re-measure.
            if cover.container, !rect.isNull, InboxShield.tooWide(rect, area: clips[key] ?? front?.windowFrame) {
                tooWide.insert(key)
                continue
            }
            if rect.isNull || rect.width < 6 || rect.height < 6 {
                // Scrolled out of view. Hidden, not forgotten.
                if cover.panel.isVisible { cover.panel.orderOut(nil) }
                continue
            }
            next[key] = rect
        }
        if !tooWide.isEmpty { applyRecycled(tooWide) }
        for (key, rect) in InboxShield.separate(next) {
            guard var cover = covers[key] else { continue }
            if !cover.panel.isVisible { cover.panel.orderFrontRegardless() }
            if abs(rect.minX - cover.frame.minX) > 0.5 || abs(rect.minY - cover.frame.minY) > 0.5
                || abs(rect.width - cover.frame.width) > 0.5 || abs(rect.height - cover.frame.height) > 0.5 {
                cover.panel.setFrame(rect, display: true)
                cover.frame = rect
                covers[key] = cover
            }
        }
    }

    // MARK: Covers

    private func place(_ hit: Hit) {
        if var existing = covers[hit.key] {
            // One owner for a cover's shape: the tracker. A scan only
            // re-targets a cover whose elements have gone quiet, so the two
            // can never take turns pulling it into different shapes.
            if !hit.keepExisting && (existing.elements.isEmpty || staleKeys.contains(hit.key)) {
                existing.elements = hit.elements
                existing.source = hit.source
                existing.sourceKey = hit.sourceKey
                existing.sourceAttribute = hit.sourceAttribute
                existing.clip = hit.clip
                existing.container = hit.container
                existing.panel.setFrame(hit.frame, display: true)
                existing.frame = hit.frame
                staleKeys.remove(hit.key)
            }
            covers[hit.key] = existing
            if !existing.panel.isVisible && !staleKeys.contains(hit.key) { existing.panel.present() }
            return
        }
        // No bubble found and nothing on screen yet: wait for a scan that
        // finds it rather than draw a cover across the whole row.
        guard !hit.keepExisting else { return }

        if let wf = frontIdentity?.windowFrame, hit.frame.width > wf.width * 0.6 {
            DebugLog.write("wide cover placed w=\(Int(hit.frame.width)) origin=\(hit.origin) merged=\(hit.textKeys.count)")
        }
        let keys = hit.textKeys
        let view = AnyView(CoverView(score: hit.score, container: hit.container,
                                     onReveal: { [weak self] in self?.reveal(keys) }))
        let panel = FloatingPanel(contentRect: hit.frame) { view }
        panel.hasShadow = false
        panel.setFrame(hit.frame, display: false)
        panel.present()
        covers[hit.key] = Cover(panel: panel, frame: hit.frame, score: hit.score,
                                textKeys: keys, elements: hit.elements, container: hit.container,
                                source: hit.source, sourceKey: hit.sourceKey, sourceAttribute: hit.sourceAttribute,
                                clip: hit.clip)

        guard counted.insert(hit.key).inserted else { return }
        if counted.count > 2000 { counted.removeAll() }
        engine.telemetry.recordCovered()
        engine.record(.covered, text: "A message here was covered",
                      reason: Palette.severityLabel(hit.score) + " language",
                      app: NSWorkspace.shared.frontmostApplication?.localizedName,
                      score: hit.score)
        engine.refreshSnapshot()
    }

    private func reveal(_ keys: Set<Int>) {
        revealed.formUnion(keys)
        Feedback.revealHappened()
        let affected = covers.filter { !$0.value.textKeys.isDisjoint(with: keys) }.map(\.key)
        // The view dissolves itself; the panel leaves once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            for k in affected { self?.remove(k) }
        }
    }

    private func remove(_ key: Int) {
        covers[key]?.panel.dismiss()
        covers[key] = nil
        staleKeys.remove(key)
    }

    private func hideAll() {
        for c in covers.values where c.panel.isVisible { c.panel.orderOut(nil) }
    }

    private func clearAll() {
        generation &+= 1
        for c in covers.values { c.panel.dismiss() }
        covers.removeAll()
        staleKeys.removeAll()
        emptyScans = 0
    }

    nonisolated static let labelSuffixes = [
        ", search suggestion", " search suggestion", " - google search", ", google search",
        ", suggestion", " suggestion", ", link", ", button", ", heading", ", visited link",
    ]

    nonisolated static func stripLabels(_ text: String) -> String {
        var t = text
        var changed = true
        while changed {
            changed = false
            for suffix in labelSuffixes where t.lowercased().hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return t
    }

    /// Wider than any one message could be: most of the scroll area's width.
    nonisolated static func tooWide(_ r: CGRect, area: CGRect?) -> Bool {
        guard let a = area, a.width > 300 else { return false }
        return r.width > a.width * 0.88
    }

    /// Padding never makes neighbours overlap: where two padded covers
    /// meet, the overlap is split down the middle.
    nonisolated static func separate(_ rects: [Int: CGRect]) -> [Int: CGRect] {
        var out = rects
        let keys = Array(rects.keys)
        for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                guard var a = out[keys[i]], var b = out[keys[j]] else { continue }
                let inter = a.intersection(b)
                guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
                if inter.height <= inter.width {
                    // Stacked: split vertically.
                    let mid = inter.midY
                    if a.midY > b.midY {
                        a = CGRect(x: a.minX, y: mid + 1, width: a.width, height: a.maxY - mid - 1)
                        b = CGRect(x: b.minX, y: b.minY, width: b.width, height: mid - 1 - b.minY)
                    } else {
                        b = CGRect(x: b.minX, y: mid + 1, width: b.width, height: b.maxY - mid - 1)
                        a = CGRect(x: a.minX, y: a.minY, width: a.width, height: mid - 1 - a.minY)
                    }
                } else {
                    // Side by side: split horizontally.
                    let mid = inter.midX
                    if a.midX < b.midX {
                        a = CGRect(x: a.minX, y: a.minY, width: mid - 1 - a.minX, height: a.height)
                        b = CGRect(x: mid + 1, y: b.minY, width: b.maxX - mid - 1, height: b.height)
                    } else {
                        b = CGRect(x: b.minX, y: b.minY, width: mid - 1 - b.minX, height: b.height)
                        a = CGRect(x: mid + 1, y: a.minY, width: a.maxX - mid - 1, height: a.height)
                    }
                }
                if a.width > 4, a.height > 4 { out[keys[i]] = a }
                if b.width > 4, b.height > 4 { out[keys[j]] = b }
            }
        }
        return out
    }

    /// Covers merge only when they truly overlap, not when they merely
    /// touch: neighbouring rows in a list stay separate covers.
    nonisolated static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && (i.width * i.height) / smaller > 0.25
    }

    /// Breathing room around the text, so a cover reads as a shape of its
    /// own rather than a box drawn tight on the letters.
    nonisolated static func pad(_ r: CGRect, in window: CGRect?, container: Bool = false) -> CGRect {
        // A bubble already has its own margin; bare text needs some.
        let dx = container ? 1 : min(8, max(4, r.height * 0.3))
        let dy = container ? 1 : min(4, max(2, r.height * 0.12))
        var out = r.insetBy(dx: -dx, dy: -dy)
        if let window { out = out.intersection(window) }
        return out.isNull ? r : out
    }

    nonisolated static func textKey(_ text: String) -> Int {
        Normalizer.normalize(text).squashed.hashValue
    }
}

/// Verdicts for on-screen text, keyed by content.
private final class ScoreCache: @unchecked Sendable {
    typealias Entry = (cover: Bool, score: Double, offer: Bool)
    private var store: [Int: Entry] = [:]
    private let lock = NSLock()

    func get(_ k: Int) -> Entry? { lock.lock(); defer { lock.unlock() }; return store[k] }
    func set(_ k: Int, _ v: Entry) {
        lock.lock()
        if store.count > 5000 { store.removeAll(keepingCapacity: true) }
        store[k] = v
        lock.unlock()
    }
}

/// A true blur of whatever is behind the window, with no tint of its own.
///
/// Built on the window server's backdrop layer, the one Apple's own blur
/// views use underneath, so the radius is ours to choose and the glass can
/// be perfectly clear. Radius 5 was measured on this machine: text becomes
/// unreadable while its shape stays (radius 6 at 1/4 scale). Falls back to the standard material if
/// the layer is ever unavailable.
struct BackdropBlur: NSViewRepresentable {
    var radius: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        if let layer = BackdropBlur.makeLayer(radius: radius) {
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = .hudWindow
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.autoresizingMask = [.width, .height]
            view.addSubview(fallback)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func makeLayer(radius: Double) -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue("gaussianBlur", forKey: "name")
        let layer = cls.init()
        // Configured the way NSVisualEffectView configures its own backdrop
        // (read from a live one): sampled at reduced scale, which is what
        // makes a large radius behave, and in the window-server group that
        // captures what is behind the window.
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(0.25, forKey: "scale")
        layer.setValue(0, forKey: "bleedAmount")
        layer.setValue("NSCGSWindowBehindWindowCaptureBackdropGroup", forKey: "groupName")
        layer.filters = [filter]
        return layer
    }
}

/// The cover.
///
/// At rest: blurred text under a soft grey, with a "Hidden" label when there
/// is room. On hover: the grey and the label fade away, leaving clear glass
/// over still-blurred text inside the same grey outline, so the shape of the
/// message shows without it being readable. Click reveals.
struct CoverView: View {
    let score: Double
    var container: Bool = false
    var onReveal: () -> Void

    @State private var revealing = false
    @State var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var tint: Color { Palette.severity(score) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let radius = min(container ? 18 : 10, h / 2)
            ZStack {
                // Two blurs, crossfaded: heavy at rest, lighter on hover.
                // Both measured unreadable; the lighter one keeps the shape
                // of the words visible through clear glass.
                // The light blur is always fully there underneath, so no
                // frame of the fade ever lets sharp text through; only the
                // heavy blur on top fades.
                BackdropBlur(radius: 6)
                BackdropBlur(radius: 10).opacity(hovering ? 0 : 1)
                Rectangle().fill(grey.opacity(hovering ? 0 : 0.62))
                label(width: w, height: h)
                    .opacity(hovering || revealing ? 0 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(outline, lineWidth: 1.5)
            )
        }
        .opacity(revealing ? 0 : 1)
        .scaleEffect(revealing ? 1.02 : 1)
        .contentShape(Rectangle())
        .help("Hidden by AutoShield. Click to show")
        .onHover { h in
            if Motion.reduceMotion { hovering = h }
            else { withAnimation(.easeInOut(duration: 0.2)) { hovering = h } }
        }
        .onTapGesture {
            guard !revealing else { return }
            if Motion.reduceMotion { revealing = true }
            else { withAnimation(.easeOut(duration: 0.28)) { revealing = true } }
            onReveal()
        }
    }

    private var grey: Color {
        scheme == .dark ? Color(white: 0.24) : Color(white: 0.86)
    }

    private var outline: Color {
        scheme == .dark ? Color(white: 0.50) : Color(white: 0.56)
    }

    private var ink: Color {
        scheme == .dark ? Color.white.opacity(0.88) : Color.black.opacity(0.70)
    }

    @ViewBuilder
    private func label(width w: CGFloat, height h: CGFloat) -> some View {
        let size = min(max(h * 0.38, 10), 13)
        if w >= 170 && h >= 22 {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.85))
                Text("Hidden")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(ink)
                Text("· Click to show")
                    .font(.system(size: size))
                    .foregroundStyle(ink.opacity(0.6))
            }
            .lineLimit(1)
            .fixedSize()
        } else if w >= 96 && h >= 18 {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.85))
                Text("Hidden")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(ink)
            }
            .lineLimit(1)
            .fixedSize()
        } else if w >= 22 && h >= 12 {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: min(h * 0.5, 12), weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
        }
    }
}
