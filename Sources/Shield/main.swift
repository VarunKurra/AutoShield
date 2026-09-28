import AppKit
import ShieldCore

// Shield runs as an accessory app: no Dock icon, no window until one is asked
// for. The lifecycle is AppKit's rather than SwiftUI's, because a menu bar app
// needs precise control over its activation policy and its status item, and
// SwiftUI's App scenes fight both.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // NSApplication does not retain its delegate.
    objc_setAssociatedObject(app, "shield.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
