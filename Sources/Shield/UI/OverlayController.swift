import AppKit
import SwiftUI
import Combine
import ShieldCore

/// Owns the floating panels and keeps them in step with the engine.
///
/// A panel that outlives the thing it points at is worse than no panel, so
/// most of this file is about noticing that the draft underneath has gone:
/// the app changed, the tab closed, the field lost focus, the text moved on.
@MainActor
final class OverlayController {

    private var catchPanel: FloatingPanel<AnyView>?
    private var crisisPanel: FloatingPanel<AnyView>?
    private var bag = Set<AnyCancellable>()
    private weak var engine: ShieldEngine?

    private var trackTimer: Timer?
    private var trackedFrame: CGRect?
    private var catchHeight: CGFloat = 110
    private var shownAt = Date.distantPast
    /// AX can blink for a frame during a window change; one miss is not proof.
    private var missCount = 0
    /// Consecutive ticks where focus sat on a different field than the one
    /// holding the draft.
    private var focusMoved = 0
    /// When the field last had a usable rectangle.
    private var lastGoodFrameAt = Date.distantPast

    func attach(to engine: ShieldEngine) {
        self.engine = engine
        DebugLog.write("overlays attached")

        engine.$held
            .removeDuplicates()
            .sink { [weak self] draft in
                DebugLog.write("held sink fired: \(draft == nil ? "nil" : "draft")")
                guard let self else { DebugLog.write("overlays deallocated"); return }
                if let draft { self.showCatch(draft) } else { self.hideCatch() }
            }
            .store(in: &bag)

        engine.$rephrase
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let draft = self.engine?.held else { return }
                self.refreshCatch(draft)
            }
            .store(in: &bag)

        engine.$nudge
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let draft = self.engine?.held else { return }
                self.refreshCatch(draft)
            }
            .store(in: &bag)

        engine.$crisisOffer
            .removeDuplicates()
            .sink { [weak self] offer in
                guard let self else { return }
                if let offer { self.showCrisis(offer) } else { self.hideCrisis() }
            }
            .store(in: &bag)

        // Switching apps abandons the draft. Both panels belong to the app
        // that was in front when they appeared.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.frontmostChanged(to: app?.bundleIdentifier)
                }
            }
    }

    // MARK: Catch

    private func catchView(_ draft: ShieldEngine.HeldDraft) -> AnyView {
        AnyView(
            CatchOverlayView(
                draft: draft,
                rephrase: engine?.rephrase,
                nudge: engine?.nudge ?? 0,
                onRephrase: { [weak self] in self?.engine?.rephraseAndSend() },
                onRemove: { [weak self] in self?.engine?.deleteDraft() },
                onEdit: { [weak self] in self?.engine?.editDraft() },
                onSendUnchanged: { [weak self] in self?.engine?.sendUnchanged() },
                onHeight: { [weak self] h in self?.catchHeightChanged(h) })
        )
    }

    private func showCatch(_ draft: ShieldEngine.HeldDraft) {
        DebugLog.write("showCatch entered")
        let width = CatchOverlayView.width

        // A fresh panel for every catch. Reusing one meant SwiftUI kept the
        // previous catch's state, and after the first dismissal the panel
        // could come back invisible while the keyboard stayed held — the
        // "it only works the first time" bug.
        catchPanel?.orderOut(nil)
        catchPanel = FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: catchHeight)) {
            catchView(draft)
        }
        // Above Inbox Shield's covers, which stay up while a draft is held.
        catchPanel?.level = .popUpMenu

        trackedFrame = draft.fieldFrame
        shownAt = Date()
        lastGoodFrameAt = Date()
        missCount = 0
        focusMoved = 0

        // Measure once up front so the first frame is already the right size,
        // then let the view correct it through onHeight.
        if let measured = catchPanel?.fittedHeight(width: width), measured > 40 {
            catchHeight = measured
        }
        catchPanel?.anchor(to: draft.fieldFrame, size: CGSize(width: width, height: catchHeight))
        catchPanel?.present()
        ensureVisible()
        // And once more after the arrival animation, in case a space switch
        // or a full-screen app swallowed the first order-front.
        let id = draft.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.engine?.held?.id == id else { return }
            self.ensureVisible()
        }
        let screenName = catchPanel?.screen?.localizedName ?? "none"
        let frontWindow = NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "?")" } ?? "?"
        DebugLog.write("showCatch h=\(catchHeight) anchor=\(String(describing: draft.fieldFrame)) frame=\(catchPanel?.frame ?? .zero) visible=\(catchPanel?.isVisible ?? false) screen=\(screenName) activeSpace=\(catchPanel?.isOnActiveSpace ?? false) front=\(frontWindow)")
        startTracking()
    }

    /// A hold with no visible panel is a message that can never be sent, so
    /// verify the panel actually landed on a screen and recover if it did not.
    private func ensureVisible() {
        guard let panel = catchPanel else { return }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen {
            DebugLog.write("panel off screen at \(panel.frame), recentering")
            panel.anchor(to: nil, size: CGSize(width: CatchOverlayView.width, height: catchHeight))
        }
        if !panel.isVisible || !onScreen { panel.orderFrontRegardless() }
    }

    /// SwiftUI reporting its real height, including a rationale that arrived
    /// after the panel was already on screen.
    private func catchHeightChanged(_ height: CGFloat) {
        let h = height.rounded(.up)
        guard h > 40 else { return }
        guard abs(h - catchHeight) > 0.5 else { return }
        catchHeight = h
        DebugLog.write("reported height=\(h)")
        guard let panel = catchPanel, panel.isVisible else { return }
        panel.anchor(to: trackedFrame,
                     size: CGSize(width: CatchOverlayView.width, height: h))
    }

    /// Re-renders the panel in place, without re-anchoring or replaying the
    /// arrival animation.
    private func refreshCatch(_ draft: ShieldEngine.HeldDraft) {
        guard let panel = catchPanel, panel.isVisible else { return }
        panel.update { catchView(draft) }
    }

    private func hideCatch() {
        stopTracking()
        catchPanel?.dismiss()
        catchPanel = nil
    }

    // MARK: Crisis

    private func showCrisis(_ offer: ShieldEngine.CrisisOffer) {
        let size = CGSize(width: 320, height: 208)
        let view = AnyView(
            CrisisPanelView(incoming: offer.incoming,
                            onDismiss: { [weak self] in self?.engine?.dismissCrisis() })
        )
        if crisisPanel == nil {
            crisisPanel = FloatingPanel(contentRect: CGRect(origin: .zero, size: size)) { view }
        } else {
            crisisPanel?.update { view }
        }
        // Sits beside a held draft rather than on top of it; the two surfaces
        // are allowed to coexist and never replace one another.
        var anchor = offer.anchor
        if engine?.held != nil, let a = anchor {
            anchor = CGRect(x: a.minX + CatchOverlayView.width + 14, y: a.minY,
                            width: a.width, height: a.height)
        }
        let fitted = CGSize(width: size.width,
                            height: crisisPanel?.fittedHeight(width: size.width) ?? size.height)
        crisisPanel?.anchor(to: anchor, size: fitted)
        crisisPanel?.present()
    }

    private func hideCrisis() {
        crisisPanel?.dismiss()
    }

    // MARK: Staying attached to the draft

    private func startTracking() {
        stopTracking()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retrack() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
    }

    private func frontmostChanged(to bundleID: String?) {
        guard let engine else { return }
        // Hide first, decide second: the panel must not sit over the next
        // app for even a frame.
        if let draft = engine.held, !draft.preview, draft.bundleID != bundleID {
            catchPanel?.orderOut(nil)
        }
        if let draft = engine.held, !draft.preview, draft.bundleID != bundleID {
            engine.dismissHold()
        }
        // Resources are about the message on screen, so they go too.
        if engine.crisisOffer != nil { engine.dismissCrisis() }
    }

    /// What one tracking pass found, computed off the main thread.
    private enum TrackResult {
        case keep(frame: CGRect?)
        case dismiss(String, edit: Bool)
    }
    private let trackQueue = DispatchQueue(label: "shield.overlay.track", qos: .userInteractive)
    private var tracking = false

    /// Runs at 30 Hz while a draft is held. Re-anchors when the window moves,
    /// and lets go when the thing it was pointing at is gone.
    ///
    /// The Accessibility reads happen on a background queue: done on main,
    /// they stalled the whole UI while scrolling. Main only moves the panel.
    private func retrack() {
        guard let engine, let draft = engine.held else { stopTracking(); return }
        guard !draft.preview, let panel = catchPanel else { return }
        // Whatever else happens, a held draft always has its panel on screen.
        if !panel.isVisible { panel.orderFrontRegardless() }
        guard !tracking else { return }

        // Switching apps is checked here, on main, every tick: it must close
        // the panel at once, not one background round trip later.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == draft.pid || front?.bundleIdentifier == draft.bundleID else {
            DebugLog.write("dismiss: app switched")
            engine.editDraft(); return
        }
        guard let element = engine.heldElement else { return }

        tracking = true
        let settling = Date().timeIntervalSince(shownAt) < 0.5
        let span = draft.span.trimmingCharacters(in: .whitespacesAndNewlines)
        let checkText = draft.source != .typed
        trackQueue.async { [weak self] in
            let result = OverlayController.track(element: element, span: span, checkText: checkText, settling: settling)
            DispatchQueue.main.async {
                guard let self else { return }
                self.tracking = false
                guard let engine = self.engine, let current = engine.held, current.id == draft.id else { return }
                self.apply(result, settling: settling)
            }
        }
    }

    private nonisolated static func track(element: AXUIElement, span: String, checkText: Bool, settling: Bool) -> TrackResult {
        // Focus moving to a *different* field is the reliable signal that the
        // draft has been left behind. Focus going to nil is not, because web
        // views do that constantly, and Chromium hands out a fresh element
        // for the same field now and then, so the text is compared as well.
        if let focused = AX.focusedField(), !CFEqual(focused.element, element) {
            let sameText = !span.isEmpty && focused.value.contains(span)
            if !sameText { return .dismiss("focus moved to \(focused.role)", edit: true) }
        }
        guard AX.isAlive(element) else { return .dismiss("element gone", edit: true) }
        if checkText {
            let current = AX.readValue(element) ?? ""
            if !span.isEmpty && !current.contains(span) {
                return .dismiss("text gone, field now \(current.count) chars", edit: false)
            }
        }
        return .keep(frame: AX.caretFrameChecked(of: element))
    }

    private func apply(_ result: TrackResult, settling: Bool) {
        guard let engine, let panel = catchPanel else { return }
        switch result {
        case .dismiss(let why, let edit):
            // AX is often still settling in the first half second; one miss
            // means nothing, a few in a row mean it is really gone.
            if settling { return }
            missCount += 1
            guard missCount >= 4 else { return }
            DebugLog.write("dismiss: \(why)")
            if edit { engine.editDraft() } else { engine.dismissHold() }
        case .keep(let frame):
            missCount = 0
            guard let frame, frame.height > 0.5 else { return }
            lastGoodFrameAt = Date()
            guard let last = trackedFrame else { trackedFrame = frame; return }
            // Ignore sub-pixel noise; a jittering overlay is worse than a still one.
            guard abs(frame.minX - last.minX) > 1.5 || abs(frame.minY - last.minY) > 1.5 else { return }
            trackedFrame = frame
            panel.anchor(to: frame, size: CGSize(width: CatchOverlayView.width, height: catchHeight))
        }
    }
}
