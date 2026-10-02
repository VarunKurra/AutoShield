import AppKit
import ApplicationServices
import Combine
import ShieldCore

/// Live status for the two permissions Shield cannot work without.
/// Polled, because macOS gives no notification when either one flips.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false

    var allGranted: Bool { accessibility && inputMonitoring }

    /// Reading text fields and the messages around them. Accessibility alone
    /// is enough, which is why incoming protection can work when outgoing
    /// cannot.
    var canRead: Bool { accessibility }

    /// Swallowing Return before the app underneath sees it. Needs the event
    /// tap, and so needs Input Monitoring as well.
    var canCatchSends: Bool { accessibility && inputMonitoring }

    /// What is missing, in the order it matters.
    var missing: String? {
        if !accessibility && !inputMonitoring { return "Accessibility and Input Monitoring" }
        if !accessibility { return "Accessibility" }
        if !inputMonitoring { return "Input Monitoring" }
        return nil
    }

    /// Set by the engine. A running event tap is proof the permission is
    /// granted, whatever the TCC lookup says.
    var tapIsLive = false {
        didSet { if tapIsLive != oldValue { refresh() } }
    }

    private var timer: Timer?

    private init() {
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }

        // IOHIDCheckAccess reports the stored answer without prompting, but it
        // can lag a change. A live tap is proof, so either counts.
        let hid = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let granted = hid || tapIsLive
        if granted != inputMonitoring { inputMonitoring = granted }
    }

    /// Shows the system prompt once. After that macOS stays silent, so the
    /// settings deep links below are the real path.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    func requestInputMonitoring() {
        let asked = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        DebugLog.write("IOHIDRequestAccess -> \(asked)")
        openInputMonitoringSettings()
    }

    /// Puts Shield in the Input Monitoring list whether or not anyone presses
    /// a button. macOS only lists an app once it has asked, and an app that is
    /// not listed cannot be switched on, which is a dead end nobody can debug
    /// from the outside.
    func registerForInputMonitoring() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted else { return }
        let asked = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        DebugLog.write("registered for input monitoring -> \(asked)")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ s: String) {
        guard let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
