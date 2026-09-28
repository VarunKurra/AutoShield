import AppKit
import SwiftUI
import ShieldCore

/// Incoming protection: frosted glass floated over a cruel message that was
/// sent *to* you, tracked to its rect and peeled away only if you ask.
///
/// This is the half of Shield that protects rather than prevents. It reads the
/// visible message rows out of the frontmost window's accessibility tree,
/// scores them locally, and covers anything over the line before you have
/// finished reading the thread.
///
/// Honest limit: macOS gives no way to intercept another app's rendering, so
/// text exists on screen for the moment between paint and cover. Shield closes
/// that gap as far as a native app can (a 120 ms sweep, a synchronous local
/// score, no network on the hot path) but it cannot make it zero. Only code
/// running inside the app itself could.
@MainActor
final class InboxShield {

    /// Apps whose trees expose message rows cleanly enough to trust. Covering
    /// the wrong rectangle is worse than covering nothing, so this is a list
    /// rather than a guess.
    static let supportedBundleIDs: Set<String> = [
        "com.apple.MobileSMS",          // Messages
        "com.apple.mail",
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
    ]

    private struct Cover {
        var panel: FloatingPanel<AnyView>
        var frame: CGRect
        var score: Double
    }

    private var covers: [Int: Cover] = [:]
    private var revealed = Set<Int>()
    private var verdicts: [Int: Double] = [:]
    private var scoring = Set<Int>()
    private var timer: Timer?
    private var scrollingUntil = Date.distantPast
    private var lastFrames: [Int: CGRect] = [:]
    private unowned let engine: ShieldEngine

    init(engine: ShieldEngine) { self.engine = engine }

    func start() {
        guard timer == nil else { return }
        // 120 ms: fast enough that a message rarely sits uncovered for long,
        // slow enough that a bounded AX walk costs a fraction of a core.
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        clearAll()
    }

    var isRunning: Bool { timer != nil }

    // MARK: The sweep

    private func tick() {
        guard AppSettings.shared.inboxShieldEnabled, AX.isTrusted else { clearAll(); return }
        guard let bid = AX.frontmostBundleID(),
              InboxShield.supportedBundleIDs.contains(bid) else { clearAll(); return }
        // A held draft owns the screen; do not stack surfaces on top of it.
        guard engine.held == nil else { hideAll(); return }

        let messages = AXContextReader.visibleMessages(limit: 60, wantFrames: true)
        guard !messages.isEmpty else { clearAll(); return }

        let sensitivity = AppSettings.shared.sensitivity
        var seen = Set<Int>()
        var moved = 0

        for m in messages {
            guard let frame = m.frame, frame.width > 30, frame.height > 8 else { continue }
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4, text.count <= 600 else { continue }
            let key = Self.key(text)
            seen.insert(key)

            if let old = lastFrames[key], abs(old.minY - frame.minY) > 3 { moved += 1 }
            lastFrames[key] = frame

            guard !revealed.contains(key) else { continue }

            // Score once per distinct message, then remember it.
            guard let score = verdicts[key] else {
                scoreIfNeeded(key: key, text: text)
                continue
            }
            guard score >= sensitivity.holdThreshold else { continue }
            place(key: key, frame: frame, score: score)
        }

        // Scrolling: a flickering overlay is worse than none, so everything
        // hides until the list settles, then re-resolves.
        if moved >= 2 {
            scrollingUntil = Date().addingTimeInterval(0.15)
            hideAll()
            return
        }
        if Date() < scrollingUntil { return }

        for key in covers.keys where !seen.contains(key) { remove(key) }
        for (key, cover) in covers where cover.panel.isVisible == false {
            cover.panel.orderFrontRegardless()
        }
    }

    /// Scores off the hot path. Rules are synchronous and sub-millisecond, so
    /// the common case never waits; only genuinely uncertain text goes async.
    private func scoreIfNeeded(key: Int, text: String) {
        let report = engine.cascade.rules.evaluate(text, context: [])

        // Someone else's message about their own pain is not covered. It is
        // offered resources, quietly, and left alone.
        if report.verdict.selfDirected || report.verdict.distress == .present {
            verdicts[key] = 0
            if AppSettings.shared.crisisSurfaceEnabled,
               let offer = engine.crisis.consider(report.verdict, text: text, incoming: true) {
                engine.offerCrisis(incoming: offer.incoming, near: lastFrames[key])
            }
            return
        }

        if report.verdict.score >= 0.7 || report.trivial {
            verdicts[key] = report.verdict.score
            return
        }

        guard !scoring.contains(key) else { return }
        scoring.insert(key)
        let sensitivity = AppSettings.shared.sensitivity
        Task { [weak self] in
            guard let self else { return }
            let result = await self.engine.cascade.analyze(text, context: [], allowContext: false)
            await MainActor.run {
                self.scoring.remove(key)
                self.verdicts[key] = result.verdict.score
                _ = sensitivity
            }
        }
    }

    // MARK: Covers

    private func place(key: Int, frame: CGRect, score: Double) {
        if var existing = covers[key] {
            if existing.frame != frame {
                existing.panel.setFrame(frame, display: true)
                existing.frame = frame
                covers[key] = existing
            }
            if !existing.panel.isVisible { existing.panel.present() }
            return
        }

        let view = AnyView(CoverView(score: score, onReveal: { [weak self] in self?.reveal(key) }))
        let panel = FloatingPanel(contentRect: frame) { view }
        panel.setFrame(frame, display: false)
        panel.present()
        covers[key] = Cover(panel: panel, frame: frame, score: score)

        engine.telemetry.recordCovered()
        engine.record(.covered, text: "A message here was covered",
                      reason: Palette.severityLabel(score) + " language",
                      app: NSWorkspace.shared.frontmostApplication?.localizedName,
                      score: score)
        engine.refreshSnapshot()
    }

    private func reveal(_ key: Int) {
        revealed.insert(key)
        Feedback.revealHappened()
        guard let cover = covers[key] else { return }
        // The view dissolves itself; the panel leaves once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            cover.panel.dismiss()
            self?.covers[key] = nil
        }
    }

    private func remove(_ key: Int) {
        covers[key]?.panel.dismiss()
        covers[key] = nil
    }

    private func hideAll() {
        for c in covers.values where c.panel.isVisible { c.panel.orderOut(nil) }
    }

    private func clearAll() {
        for c in covers.values { c.panel.dismiss() }
        covers.removeAll()
        lastFrames.removeAll()
    }

    private static func key(_ text: String) -> Int {
        Normalizer.normalize(text).squashed.hashValue
    }
}

/// The frosted pane itself.
///
/// Clicking it dissolves the blur rather than switching it off: the reveal is
/// the second place Shield spends its boldness.
private struct CoverView: View {
    let score: Double
    var onReveal: () -> Void

    @State private var revealing = false
    @State private var hovering = false

    private var tint: Color { Palette.severity(score) }

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI, blending: .behindWindow, emphasized: true)
            Rectangle().fill(Palette.surface.opacity(0.42))
            Rectangle().fill(tint.opacity(0.07))

            HStack(spacing: 6) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("\(Palette.severityLabel(score)) message")
                    .font(TypeScale.label(10.5))
                Text("Click to read")
                    .font(TypeScale.body(11))
                    .foregroundStyle(Palette.muted)
            }
            .foregroundStyle(tint)
            .opacity(revealing ? 0 : (hovering ? 1 : 0.85))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(hovering ? 0.35 : 0.18), lineWidth: 1)
        )
        .opacity(revealing ? 0 : 1)
        .scaleEffect(revealing ? 1.03 : 1)
        .blur(radius: revealing ? 7 : 0)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
        .onTapGesture {
            guard !revealing else { return }
            if Motion.reduceMotion { revealing = true }
            else { withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) { revealing = true } }
            onReveal()
        }
    }
}
