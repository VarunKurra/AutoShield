import AppKit
import ApplicationServices

/// A thin, timeout-guarded wrapper over the Accessibility C API.
///
/// Every call here can talk to a hostile or hung application, so nothing is
/// allowed to block without a deadline.
enum AX {

    /// Anything slower than this is a wedged app, not a slow one.
    static let messagingTimeout: Float = 0.25

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Attributes

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let v = copyAttribute(element, attribute) else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() { return (v as! CFString) as String }
        return nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let v = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let v = copyAttribute(element, kAXChildrenAttribute as String),
              CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! CFArray) as? [AXUIElement] ?? []
    }

    @discardableResult
    static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef) == .success
    }

    // MARK: Geometry

    /// Screen rect in Cocoa coordinates (origin bottom-left of the main screen).
    /// The AX API reports top-left origin, so this flips.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let posRef = copyAttribute(element, kAXPositionAttribute as String),
            let sizeRef = copyAttribute(element, kAXSizeAttribute as String),
            CFGetTypeID(posRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((posRef as! AXValue), .cgPoint, &point),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }

        return flipToCocoa(CGRect(origin: point, size: size))
    }

    /// AX and Quartz share a top-left origin anchored on the *primary* screen.
    static func flipToCocoa(_ r: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first else { return r }
        let maxY = primary.frame.maxY
        return CGRect(x: r.origin.x, y: maxY - r.origin.y - r.size.height,
                      width: r.size.width, height: r.size.height)
    }

    // MARK: Focus

    struct FocusedField {
        var element: AXUIElement
        var value: String
        var role: String
        var bundleID: String?
        var appName: String?
        var isSecure: Bool
    }

    static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    /// The text field the user is typing in right now, in whatever app owns
    /// the keyboard. Returns nil rather than guessing.
    static func focusedField() -> FocusedField? {
        guard isTrusted else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        enableWebAccessibility(axApp, pid: app.processIdentifier)

        guard let focused = element(axApp, kAXFocusedUIElementAttribute as String) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = string(focused, kAXRoleAttribute as String) ?? ""
        let secure = role == "AXSecureTextField"

        // Some editors expose the text on the focused element; web views often
        // put it one level down on the contenteditable body.
        let value = readValue(focused) ?? ""

        let editable = editableRoles.contains(role)
            || (bool(focused, "AXEditable") ?? false)
            || (role == "AXWebArea" && !value.isEmpty)
            || (role == "AXGroup" && (bool(focused, "AXEditable") ?? false))

        guard editable || secure else { return nil }

        return FocusedField(element: focused,
                            value: value,
                            role: role,
                            bundleID: app.bundleIdentifier,
                            appName: app.localizedName,
                            isSecure: secure)
    }

    /// Reads AXValue, falling back to the selected-text container some
    /// Electron apps use instead.
    static func readValue(_ element: AXUIElement) -> String? {
        if let s = string(element, kAXValueAttribute as String) { return s }
        if let s = string(element, "AXSelectedText"), !s.isEmpty { return s }
        return nil
    }

    /// Clears a field. Tries AX first because it is instantaneous and silent;
    /// the caller falls back to synthetic keys when this returns false.
    static func clear(_ element: AXUIElement) -> Bool {
        if setString(element, kAXValueAttribute as String, "") {
            // Some Electron fields accept the write but keep the old value.
            let after = readValue(element) ?? ""
            return after.isEmpty
        }
        return false
    }

    /// Chrome, Electron and anything else built on Blink only construct their
    /// accessibility tree when a client asks for it. Without this, the entire
    /// web page is invisible: no text fields, no messages, nothing. Asking is
    /// one attribute write, and it is what every screen reader does.
    private static var webAccessibilityAsked = Set<pid_t>()
    private static let webLock = NSLock()

    static func enableWebAccessibility(_ axApp: AXUIElement, pid: pid_t) {
        webLock.lock()
        let alreadyAsked = webAccessibilityAsked.contains(pid)
        if !alreadyAsked { webAccessibilityAsked.insert(pid) }
        webLock.unlock()
        guard !alreadyAsked else { return }

        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Blink apps that ignore the manual flag respond to this one instead.
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Drops the cache when an app quits, so a relaunch is asked again.
    static func forgetWebAccessibility(pid: pid_t) {
        webLock.lock(); webAccessibilityAsked.remove(pid); webLock.unlock()
    }

    /// Where the insertion point actually is, so an overlay can sit under the
    /// caret rather than under a 400-point-tall compose area.
    static func caretFrame(of element: AXUIElement) -> CGRect? {
        guard let rangeRef = copyAttribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue((rangeRef as! AXValue), .cfRange, &range) else { return nil }

        var bounds: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRef, &bounds)
        guard err == .success, let b = bounds,
              CFGetTypeID(b) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue((b as! AXValue), .cgRect, &rect), rect.height > 0 else { return nil }
        // An insertion point is legitimately zero-wide. Give it a nominal
        // width so downstream geometry checks do not throw it away.
        rect.size.width = max(rect.size.width, 1)
        return flipToCocoa(rect)
    }

    /// True when the element still exists. A closed tab or a torn-down view
    /// answers nothing at all.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return err != .invalidUIElement && err != .cannotComplete && err != .notImplemented
    }

    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
