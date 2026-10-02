import AppKit
import ApplicationServices

/// Reads the text that is visible in the frontmost window.
///
/// Used twice: Inbox Shield covers cruel messages in it, and the context tier
/// reads it as the conversation around a draft. Accessibility trees in
/// browsers and Electron apps are deep and inconsistent, so this walks
/// defensively: bounded node count, a hard wall-clock budget, and only the
/// part of the tree that is actually on screen. It returns whatever it found
/// when the budget runs out rather than blocking anyone.
///
/// Safe to call off the main thread, and meant to be: a walk can take a
/// hundred milliseconds in a large web page.
enum AXContextReader {

    /// The part of a wide element that actually holds its text.
    ///
    /// Messages, and most chat apps, expose each message as a row the width
    /// of the whole conversation; the bubble is a child somewhere inside.
    /// Covering the row blanked the whole line. This looks a few levels down
    /// for the narrower elements that are the bubble, and returns them, so
    /// the cover is drawn, and tracked, around the bubble alone.
    static func tightTarget(_ element: AXUIElement, frame: CGRect) -> (frame: CGRect, elements: [AXUIElement])? {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var text: [(AXUIElement, CGRect)] = []
        var other: [(AXUIElement, CGRect)] = []
        var visited = 0
        while !queue.isEmpty && visited < 80 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            for child in AX.children(el) {
                AXUIElementSetMessagingTimeout(child, AX.messagingTimeout)
                let role = AX.string(child, kAXRoleAttribute as String) ?? ""
                if let f = liveFrame(child), f.width >= 8, f.height >= 10,
                   f.width < frame.width * 0.85, frame.insetBy(dx: -2, dy: -2).contains(f) {
                    if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String {
                        text.append((child, f))
                    } else if role != "AXImage" && role != "AXButton" {
                        other.append((child, f))
                    }
                }
                if depth < 4 { queue.append((child, depth + 1)) }
            }
        }
        let pick = !text.isEmpty ? text : other
        guard let first = pick.first else { return nil }
        // The bubble around text that sits inside it, when there is one.
        let union = pick.dropFirst().reduce(first.1) { $0.union($1.1) }
        if let bubble = other.filter({ $0.1.contains(union) && $0.1.width < frame.width * 0.85 })
            .min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) {
            return (bubble.1, [bubble.0])
        }
        return (union, pick.map(\.0))
    }

    /// What an element says right now, from the one attribute the scan
    /// read it from. Nil when it says nothing or does not answer.
    static func liveText(_ element: AXUIElement, attribute: String) -> String? {
        guard let s = AX.string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    /// Where an element is right now, in one round trip. Nil when it is gone.
    static func liveFrame(_ element: AXUIElement) -> CGRect? {
        var values: CFArray?
        let attrs = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attrs, [], &values) == .success,
              let arr = values as? [CFTypeRef], arr.count == 2,
              CFGetTypeID(arr[0]) == AXValueGetTypeID(), CFGetTypeID(arr[1]) == AXValueGetTypeID() else { return nil }
        let pos = arr[0] as! AXValue, size = arr[1] as! AXValue
        guard AXValueGetType(pos) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &sz),
              sz.width > 0, sz.height > 0 else { return nil }
        return AX.flipToCocoa(CGRect(origin: p, size: sz))
    }


    struct Message {
        var text: String
        var frame: CGRect?
        /// Messages sharing a parent, so a sentence split across several
        /// text runs ("you are a <b>stupid</b> idiot") can be judged whole.
        var group: Int = 0
        /// The element itself, so a cover can follow it as it scrolls.
        var element: AXUIElement?
        /// Which attribute the text came from, so it can be re-read exactly.
        var attribute: String = kAXValueAttribute as String
        /// The scroll area the text lives in. Text scrolled under a toolbar
        /// or an input bar is still inside the window but not visible, and
        /// its cover must be clipped to what the scroll area shows.
        var clip: AXUIElement?
    }

    struct Scan {
        var pid: pid_t
        var bundleID: String?
        var window: AXUIElement?
        var windowFrame: CGRect?
        var messages: [Message]
        /// False when a limit stopped the walk early. What was not reached
        /// is unknown, not absent.
        var complete: Bool = true
    }

    static let maxDepth = 60
    static let maxNodes = 9000

    /// Visible message-like text, oldest first.
    static func conversation(limit: Int = 12) -> [String] {
        guard let scan = scanFrontWindow(limit: limit * 4, wantFrames: false, budget: 0.12) else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for m in scan.messages {
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 500 else { continue }
            guard seen.insert(t).inserted else { continue }
            out.append(t)
        }
        return Array(out.suffix(limit))
    }

    /// Message-like nodes with their screen rects, for Inbox Shield.
    static func visibleMessages(limit: Int = 60, wantFrames: Bool = true) -> [Message] {
        scanFrontWindow(limit: limit, wantFrames: wantFrames, budget: 0.12)?.messages ?? []
    }

    private static let attributes = [
        kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ] as CFArray

    private static let skipRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar", "AXSplitter", "AXImage",
        "AXProgressIndicator", "AXValueIndicator", "AXIncrementor", "AXSlider", "AXRuler",
        "AXSecureTextField", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
    ]

    /// Walks the frontmost window. `budget` is wall-clock seconds.
    static func scanFrontWindow(limit: Int, wantFrames: Bool, budget: TimeInterval,
                                skipping editable: AXUIElement? = nil) -> Scan? {
        guard AX.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, AX.messagingTimeout)
        AX.enableWebAccessibility(axApp, pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute as String)
            ?? AX.element(axApp, kAXMainWindowAttribute as String) else {
            return Scan(pid: app.processIdentifier, bundleID: app.bundleIdentifier, window: nil, windowFrame: nil, messages: [])
        }
        let windowFrame = AX.frame(of: window)

        var out: [Message] = []
        var nodes = 0
        var groupID = 0
        var cut = false
        let deadline = Date().addingTimeInterval(budget)

        func frame(_ pos: CFTypeRef?, _ size: CFTypeRef?) -> CGRect? {
            guard let pos, let size,
                  CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue((pos as! AXValue), .cgPoint, &p),
                  AXValueGetValue((size as! AXValue), .cgSize, &s) else { return nil }
            return AX.flipToCocoa(CGRect(origin: p, size: s))
        }

        func str(_ v: CFTypeRef?) -> String? {
            guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
            let s = (v as! CFString) as String
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }

        var bounds = windowFrame
        func walk(_ element: AXUIElement, depth: Int, group: Int, clip: AXUIElement?) {
            guard depth <= maxDepth else { return }
            guard nodes < maxNodes, out.count < limit, Date() < deadline else { cut = true; return }
            nodes += 1

            // One round trip for everything this node can tell us, rather
            // than one per attribute. This is most of the speed.
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let arr = values as? [CFTypeRef], arr.count == 7 else { return }
            func at(_ i: Int) -> CFTypeRef? {
                let v = arr[i]
                return CFGetTypeID(v) == AXValueGetTypeID() && AXValueGetType(v as! AXValue) == .axError ? nil : v
            }
            let role = str(at(0)) ?? ""
            if skipRoles.contains(role) { return }

            let rect = frame(at(5), at(6))
            // Off-screen subtrees (scrolled-away messages, hidden tabs) are
            // most of a web page's tree and none of what is on screen.
            if let rect, let wf = bounds, rect.width > 0, rect.height > 0, !rect.intersects(wf) {
                return
            }

            switch role {
            case kAXStaticTextRole as String, "AXHeading":
                let picked: (String, String)? = str(at(1)).map { ($0, kAXValueAttribute as String) }
                    ?? str(at(2)).map { ($0, kAXTitleAttribute as String) }
                    ?? str(at(3)).map { ($0, kAXDescriptionAttribute as String) }
                if let (v, attr) = picked {
                    out.append(Message(text: v, frame: wantFrames ? rect : nil, group: group,
                                       element: element, attribute: attr, clip: clip))
                }
            case kAXTextAreaRole as String:
                // Someone else's message can be a read-only text area
                // (Messages, Mail). The person's own draft is never covered.
                if let editable, CFEqual(editable, element) { return }
                var settable: DarwinBoolean = false
                let isEditable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                    && settable.boolValue
                if !isEditable, let v = str(at(1)) {
                    out.append(Message(text: v, frame: wantFrames ? rect : nil, group: group,
                                       element: element, clip: clip))
                    return
                }
                if isEditable { return }
            case kAXTextFieldRole as String, "AXSearchField", kAXComboBoxRole as String:
                // The field's own text is the person's, never covered. But
                // what hangs off it is not: Chrome's address-bar
                // suggestions, autocomplete lists and search dropdowns live
                // under the field. Skipping the whole subtree is how Google's
                // suggestions stopped being covered.
                break
            case "AXGroup", "AXRow", "AXCell", "AXLink":
                // Chat rows often carry the whole message as a description
                // (Messages, Electron apps), even a one-word one.
                if let d = str(at(3)), d.count >= 2 {
                    out.append(Message(text: d, frame: wantFrames ? rect : nil, group: group,
                                       element: element, attribute: kAXDescriptionAttribute as String, clip: clip))
                }
            default: break
            }

            guard let kidsRef = at(4), CFGetTypeID(kidsRef) == CFArrayGetTypeID(),
                  let kids = kidsRef as? [AXUIElement], !kids.isEmpty else { return }
            groupID += 1
            let myGroup = groupID
            let childClip = role == kAXScrollAreaRole as String ? element : clip
            for child in kids {
                AXUIElementSetMessagingTimeout(child, AX.messagingTimeout)
                walk(child, depth: depth + 1, group: myGroup, clip: childClip)
                if out.count >= limit || Date() >= deadline || nodes >= maxNodes { cut = true; return }
            }
        }

        AXUIElementSetMessagingTimeout(window, AX.messagingTimeout)
        walk(window, depth: 0, group: 0, clip: nil)

        // Pop-ups belong to the app but not to its main window: suggestion
        // lists, autocomplete, menus of results. They are walked too, each
        // within its own bounds.
        if let windows = AX.copyAttribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement] {
            var extra = 0
            for w in windows where !CFEqual(w, window) && extra < 4 && Date() < deadline {
                AXUIElementSetMessagingTimeout(w, AX.messagingTimeout)
                guard let f = AX.frame(of: w), let main = windowFrame,
                      f.width * f.height < main.width * main.height,
                      NSScreen.screens.contains(where: { $0.frame.intersects(f) }) else { continue }
                extra += 1
                bounds = f
                walk(w, depth: 0, group: 0, clip: nil)
            }
        }
        return Scan(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                    window: window, windowFrame: windowFrame, messages: out, complete: !cut)
    }
}
