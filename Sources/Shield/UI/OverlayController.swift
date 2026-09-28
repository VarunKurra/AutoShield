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

    private func showCatch(_ draft: ShieldEngine.HeldDraft) {
        DebugLog.write("showCatch entered")
        let width = CatchOverlayView.width
        let view = AnyView(
            CatchOverlayView(
                draft: draft,
                rephrase: engine?.rephrase,
                onRephrase: { [weak self] in self?.engine?.rephraseAndSend() },
                onEdit: { [weak self] in self?.engine?.editDraft() },
                onSendUnchanged: { [weak self] in self?.engine?.sendUnchanged() },
                onHeight: { [weak self] h in self?.catchHeightChanged(h) })
        )

        if catchPanel == nil {
            catchPanel = FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: catchHeight)) { view }
            DebugLog.write("panel created")
        } else {
            catchPanel?.update { view }
            DebugLog.write("panel updated")
        }

        trackedFrame = draft.fieldFrame
        shownAt = Date()
        lastGoodFrameAt = Date()
        missCount = 0
        focusMoved = 0
        focusMoved = 0

        // Measure once up front so the first frame is already the right size,
        // then let the view correct it through onHeight.
        if let measured = catchPanel?.fittedHeight(width: width), measured > 40 {
            catchHeight = measured
        }
        catchPanel?.anchor(to: draft.fieldFrame, size: CGSize(width: width, height: catchHeight))
        catchPanel?.present()

        // A hold with no visible panel is a message that can never be sent, so
        // verify the panel actually landed somewhere on a screen and recover
        // by centring it if it did not.
        if let panel = catchPanel {
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
            if !panel.isVisible || !onScreen {
                DebugLog.write("panel off screen at \(panel.frame), recentering")
                panel.anchor(to: nil, size: CGSize(width: width, height: catchHeight))
                panel.orderFrontRegardless()
            }
        }
        DebugLog.write("showCatch h=\(catchHeight) anchor=\(String(describing: draft.fieldFrame)) frame=\(catchPanel?.frame ?? .zero) visible=\(catchPanel?.isVisible ?? false) level=\(catchPanel?.level.rawValue ?? -1)")
        startTracking()
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
        panel.update {
            AnyView(CatchOverlayView(
                draft: draft,
                rephrase: engine?.rephrase,
                onRephrase: { [weak self] in self?.engine?.rephraseAndSend() },
                onEdit: { [weak self] in self?.engine?.editDraft() },
                onSendUnchanged: { [weak self] in self?.engine?.sendUnchanged() },
                onHeight: { [weak self] h in self?.catchHeightChanged(h) }))
        }
    }

    private func hideCatch() {
        stopTracking()
        catchPanel?.dismiss()
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
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
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
        if let draft = engine.held, !draft.preview, draft.bundleID != bundleID {
            engine.dismissHold()
        }
        // Resources are about the message on screen, so they go too.
        if engine.crisisOffer != nil { engine.dismissCrisis() }
    }

    /// Runs at 20 Hz while a draft is held. Re-anchors when the window moves,
    /// and lets go when the thing it was pointing at is gone.
    ///
    /// It watches the held element directly rather than re-resolving focus,
    /// because focus in a web view blinks out constantly: Chrome drops the
    /// focused element for a frame whenever the page repaints, and a tracker
    /// built on focus dismisses itself within 150 ms of every catch.
    private func retrack() {
        guard let engine, let draft = engine.held else { stopTracking(); return }
        guard !draft.preview else { return }
        guard let panel = catchPanel else { return }

        // The first quarter second belongs to the catch animation; AX is often
        // still settling there and a miss means nothing.
        let settling = Date().timeIntervalSince(shownAt) < 0.25

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == draft.bundleID else {
            DebugLog.write("dismiss: app switched")
            engine.dismissHold(); return
        }

        guard let element = engine.heldElement else { engine.dismissHold(); return }

        // Focus moving to a *different* field is the reliable signal that the
        // draft has been left behind: a new tab, another input, a different
        // window. Focus going to nil is not, because web views do that
        // constantly, so nil is ignored here entirely.
        if let focused = AX.focusedField(), !CFEqual(focused.element, element) {
            if settling { return }
            focusMoved += 1
            if focusMoved >= 2 {
                DebugLog.write("dismiss: focus moved to \(focused.role)")
                engine.dismissHold()
            }
            return
        }
        focusMoved = 0

        // A closed tab or a torn-down view stops answering entirely.
        guard AX.isAlive(element) else {
            if settling { return }
            missCount += 1
            if missCount >= 3 { DebugLog.write("dismiss: element gone"); engine.dismissHold() }
            return
        }

        // The draft was replaced. Compared by containment, not equality,
        // because autocorrect and trailing newlines change the string without
        // changing the message.
        let current = (AX.readValue(element) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let holdText = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !current.contains(holdText) && !holdText.contains(current) {
            if settling { return }
            missCount += 1
            if missCount >= 3 {
                DebugLog.write("dismiss: text replaced now=\(current.prefix(40))")
                engine.dismissHold()
            }
            return
        }
        if current.isEmpty && !holdText.isEmpty {
            if settling { return }
            missCount += 1
            if missCount >= 4 { DebugLog.write("dismiss: field emptied"); engine.dismissHold() }
            return
        }

        missCount = 0

        let frame = AX.caretFrame(of: element) ?? AX.frame(of: element)
        guard let frame, frame.height > 0.5 else {
            // Minimised, scrolled away, or on another space. Hide it, but do
            // not hold the keyboard hostage if it never comes back.
            if panel.isVisible { panel.orderOut(nil) }
            if Date().timeIntervalSince(lastGoodFrameAt) > 2.0 {
                DebugLog.write("dismiss: no frame for 2s")
                engine.dismissHold()
            }
            return
        }
        lastGoodFrameAt = Date()
        if !panel.isVisible { panel.orderFrontRegardless() }

        guard let last = trackedFrame else { trackedFrame = frame; return }
        // Ignore sub-pixel noise; a jittering overlay is worse than a still one.
        guard abs(frame.minX - last.minX) > 1.5 || abs(frame.minY - last.minY) > 1.5 else { return }
        trackedFrame = frame
        panel.anchor(to: frame, size: CGSize(width: CatchOverlayView.width, height: catchHeight))
    }
}
