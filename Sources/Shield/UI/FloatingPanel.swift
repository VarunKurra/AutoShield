import AppKit
import SwiftUI

/// A panel that floats over every other app and never takes focus.
///
/// Focus is the whole game: the moment Shield activates, the app underneath
/// loses its insertion point and the user has to click back into their message.
final class FloatingPanel<Content: View>: NSPanel {

    private var hosting: NSHostingView<Content>!

    init(contentRect: NSRect, acceptsMouse: Bool = true, @ViewBuilder content: () -> Content) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // Above ordinary windows and above another app's full-screen space,
        // which `.floating` is not. Shield has to work wherever the user is.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .ignoresCycle, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        ignoresMouseEvents = !acceptsMouse

        let view = NSHostingView(rootView: content())
        view.layer?.backgroundColor = .clear
        hosting = view
        contentView = view
    }

    /// Never key, never main. Keyboard control comes through the event tap.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(@ViewBuilder content: () -> Content) {
        hosting.rootView = content()
    }

    /// The height the content actually wants at this width, so a rationale of
    /// any length never clips.
    func fittedHeight(width: CGFloat) -> CGFloat {
        // Give it room first. Measuring against a one-point box makes SwiftUI
        // report the clipped height rather than the wanted one.
        let original = hosting.frame.size
        hosting.setFrameSize(NSSize(width: width, height: 2000))
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize.height
        // Put it back. Left 2000 tall, the content was laid out far below the
        // window whenever the next setFrame did not change the window's size:
        // the panel was on screen, opaque, and showed nothing. That was the
        // catch that "made the sound but never appeared".
        hosting.setFrameSize(original)
        return fitting > 1 ? fitting : hosting.intrinsicContentSize.height
    }

    /// The content always fills the window exactly, whatever happened to it.
    private func fitContent() {
        let bounds = NSRect(origin: .zero, size: contentRect(forFrameRect: frame).size)
        if hosting.frame != bounds { hosting.frame = bounds }
        hosting.needsLayout = true
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        fitContent()
    }

    /// Places the panel against a screen rect, preferring above and falling
    /// back to below when there is no room.
    func anchor(to rect: CGRect?, size: CGSize, gap: CGFloat = 10) {
        let screen = screenContaining(rect) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame

        var origin: CGPoint
        if let rect, rect.height > 0.5 {
            let above = rect.maxY + gap
            let below = rect.minY - gap - size.height
            let y = (above + size.height <= visible.maxY) ? above
                  : (below >= visible.minY ? below : min(above, visible.maxY - size.height))
            origin = CGPoint(x: rect.minX, y: y)
        } else {
            // No frame available: sit just above the Dock, centred.
            origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 96)
        }

        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func screenContaining(_ rect: CGRect?) -> NSScreen? {
        guard let rect else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    func present() {
        fitContent()
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}
