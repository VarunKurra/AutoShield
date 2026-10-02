import AppKit
import SwiftUI
import ShieldCore

/// Windows are built in AppKit rather than as SwiftUI scenes.
///
/// A menu bar app has no Dock icon and no activation policy of its own, and
/// SwiftUI's `Window` scenes fight that. Owning the NSWindows directly makes
/// opening, reusing and closing them predictable.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()

    enum Kind: String { case main }

    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind) {
        DebugLog.write("show(\(kind.rawValue))")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = windows[kind] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let engine = ShieldEngine.shared
        let root: AnyView
        let title: String
        let resizable: Bool

        switch kind {
        case .main:
            root = AnyView(RootView(engine: engine))
            title = "AutoShield"
            resizable = true
        }

        var mask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { mask.insert(.resizable); mask.insert(.miniaturizable) }

        let window = NSWindow(contentRect: defaultRect(kind),
                              styleMask: mask,
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar deepens the titlebar, which is what gives
        // the traffic lights their inset. Setting their frames by hand works
        // until the first resize; this survives.
        let bar = NSToolbar(identifier: "shield.titlebar")
        bar.showsBaselineSeparator = false
        window.toolbar = bar
        window.toolbarStyle = .unified
        // The main window carries its own header, so the chrome stays bare.
        window.titleVisibility = kind == .main ? .hidden : .visible
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: root)
        // The live border draws on the very edge of the content, so the
        // content view must not be clipped short of the window's corners.
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        // Without this the SwiftUI content dictates the window size, and a
        // screen that asks for infinite height gets it.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.center()
        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
        DebugLog.write("window \(kind.rawValue) frame=\(window.frame) visible=\(window.isVisible)")
    }

    func close(_ kind: Kind) {
        windows[kind]?.close()
    }

    /// Setup is a fixed-size card. The app proper is resizable.
    func setResizable(_ resizable: Bool) {
        guard let window = windows[.main] else { return }
        if resizable { window.styleMask.insert([.resizable, .miniaturizable]) }
        else { window.styleMask.remove([.resizable, .miniaturizable]) }
    }

    /// The main window grows a little once setup is behind you. Animated, so
    /// the step change reads as one screen becoming the next.
    func resizeMain(for screen: RootView.Screen) {
        guard let window = windows[.main] else { return }
        let size: CGSize
        switch screen {
        case .welcome:     size = CGSize(width: 460, height: 520)
        case .permissions: size = CGSize(width: 460, height: 540)
        case .passcode:    size = CGSize(width: 460, height: 560)
        case .home:        size = CGSize(width: 900, height: 640)
        }
        var frame = window.frame
        guard abs(frame.width - size.width) > 1 || abs(frame.height - size.height) > 1 else { return }
        frame.origin.y -= (size.height - frame.height)
        frame.origin.x -= (size.width - frame.width) / 2
        frame.size = size
        // Never taller than the screen it is on.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.size.height, visible.height - 20)
            frame.size.width = min(frame.size.width, visible.width - 20)
            frame.origin.y = max(frame.origin.y, visible.minY + 10)
            frame.origin.x = min(max(frame.origin.x, visible.minX + 10),
                                 visible.maxX - frame.size.width - 10)
        }
        setResizable(screen == .home)
        window.setFrame(frame, display: true, animate: !Motion.reduceMotion)
        DebugLog.write("resize -> \(screen) frame=\(frame) contentFits=\(window.contentView?.fittingSize ?? .zero)")
    }

    private func defaultRect(_ kind: Kind) -> NSRect {
        switch kind {
        case .main:
            let startsAtHome = AppSettings.shared.hasOnboarded
                && !AppSettings.alwaysShowOnboarding
            return startsAtHome ? NSRect(x: 0, y: 0, width: 900, height: 640)
                                : NSRect(x: 0, y: 0, width: 460, height: 520)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
        // Closing the window ends the session's authority. Reopening asks again.
        Passcode.shared.lock()
        // The red button quits AutoShield outright: protection runs only
        // while the app is open. Explicit, because covers on screen are
        // windows too and would otherwise keep the app alive.
        if windows.isEmpty {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        // Back to a menu bar app once nothing is on screen.
        DispatchQueue.main.async {
            if self.windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
