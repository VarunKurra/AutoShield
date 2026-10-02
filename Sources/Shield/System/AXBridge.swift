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
        var pid: pid_t = 0
        /// Insertion point, in UTF-16 units, when the field reports one.
        var caret: Int?
        /// True for text inside a web view or Electron app, where writing
        /// AXValue often changes the screen without telling the page.
        var isWeb: Bool = false
    }

    static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, messagingTimeout)
        return e
    }()

    /// The text field the user is typing in right now, in whatever app owns
    /// the keyboard. Returns nil rather than guessing.
    static func focusedField() -> FocusedField? {
        guard isTrusted else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        enableWebAccessibility(axApp, pid: app.processIdentifier, bundleID: app.bundleIdentifier)

        // The system-wide element answers for apps whose own focus attribute
        // lags (several Electron builds), but it can point at another process
        // mid-switch, so its owner is checked.
        var focused: AXUIElement?
        if let e = element(systemWide, kAXFocusedUIElementAttribute as String) {
            var pid: pid_t = 0
            if AXUIElementGetPid(e, &pid) == .success, pid == app.processIdentifier { focused = e }
        }
        if focused == nil { focused = element(axApp, kAXFocusedUIElementAttribute as String) }
        guard let focused else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = string(focused, kAXRoleAttribute as String) ?? ""
        let subrole = string(focused, kAXSubroleAttribute as String) ?? ""
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"

        // Only a field the person can type into. A text role is not enough:
        // a message bubble someone else sent, or a web page clicked to
        // select and copy from, also report text roles, and treating them as
        // the person's own writing made Shield block a copy of someone
        // else's words.
        var settable: DarwinBoolean = false
        let valueSettable = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        let editableFlag = bool(focused, "AXEditable") ?? false
        let editable = (editableRoles.contains(role) && (valueSettable || editableFlag))
            || (role != "AXWebArea" && editableFlag)
            || (role != "AXWebArea" && valueSettable && role != kAXStaticTextRole as String)

        guard editable || secure else { return nil }
        let value = secure ? "" : (readValue(focused) ?? "")

        let isWeb = copyAttribute(focused, "AXDOMIdentifier") != nil
            || copyAttribute(focused, "AXDOMClassList") != nil
            || role == "AXWebArea"

        return FocusedField(element: focused,
                            value: value,
                            role: role,
                            bundleID: app.bundleIdentifier,
                            appName: app.localizedName,
                            isSecure: secure,
                            pid: app.processIdentifier,
                            caret: selectedRange(of: focused)?.location,
                            isWeb: isWeb)
    }

    /// The field's text. AXValue where the field offers it; otherwise asked
    /// for by character range, which is how WebKit and Chromium expose some
    /// contenteditable editors. Never the selection: reading AXSelectedText as
    /// the value made Shield judge whatever happened to be highlighted.
    static func readValue(_ element: AXUIElement) -> String? {
        if let s = string(element, kAXValueAttribute as String) { return s }
        guard let countRef = copyAttribute(element, kAXNumberOfCharactersAttribute as String),
              let count = (countRef as? NSNumber)?.intValue, count > 0 else { return nil }
        var range = CFRange(location: 0, length: min(count, 20_000))
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &out)
        guard err == .success, let out, CFGetTypeID(out) == CFStringGetTypeID() else { return nil }
        return (out as! CFString) as String
    }

    /// The selected range in UTF-16 units. A caret is a zero-length range.
    static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let ref = copyAttribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue((ref as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    static func setSelectedRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var r = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Replaces the current selection, the way typing over it would.
    static func replaceSelection(_ element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
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

    /// Chromium browsers honour AXEnhancedUserInterface. Setting it on every
    /// app is what screen readers avoid, because some native apps change how
    /// their windows animate when it is on.
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    static func enableWebAccessibility(_ axApp: AXUIElement, pid: pid_t, bundleID: String? = nil) {
        webLock.lock()
        let alreadyAsked = webAccessibilityAsked.contains(pid)
        if !alreadyAsked { webAccessibilityAsked.insert(pid) }
        webLock.unlock()
        guard !alreadyAsked else { return }

        // Electron and Chromium build their tree when asked this way.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleID, chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Drops the cache when an app quits, so a relaunch is asked again.
    static func forgetWebAccessibility(pid: pid_t) {
        webLock.lock(); webAccessibilityAsked.remove(pid); webLock.unlock()
    }

    /// Where the insertion point actually is, so an overlay can sit under the
    /// caret rather than under a 400-point-tall compose area.
    /// The caret, but only if it lies where the field is. Some apps
    /// (Messages among them) report the caret in the wrong coordinate space,
    /// which put the catch panel on the other display; the field's own frame
    /// is always right, so the caret has to agree with it.
    static func caretFrameChecked(of element: AXUIElement) -> CGRect? {
        let field = frame(of: element)
        guard let caret = caretFrame(of: element) else { return field }
        guard let field else { return caret }
        return field.insetBy(dx: -40, dy: -40).contains(CGPoint(x: caret.midX, y: caret.midY)) ? caret : field
    }

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
