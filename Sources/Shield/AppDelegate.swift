import AppKit
import SwiftUI
import Combine
import ShieldCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlays = OverlayController()
    private var inbox: InboxShield?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Typeface.register()
        Feedback.prepare()

        let engine = ShieldEngine.shared
        overlays.attach(to: engine)
        engine.start()

        statusItem = StatusItemController(engine: engine, permissions: .shared)

        // Ask once at launch so Shield always appears in the Input Monitoring
        // list, even before anyone opens the setup screen.
        Permissions.shared.registerForInputMonitoring()

        inbox = InboxShield(engine: engine)
        if AppSettings.shared.inboxShieldEnabled { inbox?.start() }

        NotificationCenter.default.addObserver(
            forName: .shieldSettingsChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if AppSettings.shared.inboxShieldEnabled { self.inbox?.start() }
                else { self.inbox?.stop() }
            }

        // `open Shield.app --args --monitor` goes straight to the instrument
        // panel, which is how a demo should start.
        let args = CommandLine.arguments
        if let requested = ["monitor", "settings"].first(where: { args.contains("--\($0)") }),
           let kind = Windows.Kind(rawValue: requested) {
            Windows.shared.show(kind)
        } else {
            // One window. RootView decides which screen is inside it.
            Windows.shared.show(.main)
        }
    }

    /// Opening Shield again from the Dock, Spotlight or Finder brings the
    /// home window back rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Windows.shared.show(.main)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShieldEngine.shared.stop()
        ShieldEngine.shared.telemetry.flush()
    }
}

/// The menu bar item and the panel behind it.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()
    private let engine: ShieldEngine
    private let permissions: Permissions

    init(engine: ShieldEngine, permissions: Permissions) {
        self.engine = engine
        self.permissions = permissions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "AutoShield"
        refreshSymbol()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(engine: engine, permissions: permissions))

        engine.$held.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSymbol() }
        }.store(in: &bag)
        engine.$status.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSymbol() }
        }.store(in: &bag)
        permissions.$accessibility.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSymbol() }
        }.store(in: &bag)
        permissions.$inputMonitoring.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSymbol() }
        }.store(in: &bag)
    }

    /// The glyph is the only always-visible piece of Shield, so it carries the
    /// whole state: watching, holding, or not able to.
    private func refreshSymbol() {
        let name: String
        if engine.held != nil { name = "shield.lefthalf.filled" }
        else if permissions.allGranted && engine.status.running { name = "shield" }
        else { name = "shield.slash" }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AutoShield")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        item.button?.image = image
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentViewController = NSHostingController(
                rootView: MenuBarView(engine: engine, permissions: permissions))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {}
}
