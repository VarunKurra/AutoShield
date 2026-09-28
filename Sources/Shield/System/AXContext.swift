import AppKit
import ApplicationServices

/// Pulls the visible conversation out of the frontmost window so the context
/// tier reads a thread rather than a sentence.
///
/// Accessibility trees in browsers and Electron apps are deep and
/// inconsistent, so this walks defensively: bounded depth, bounded node count,
/// and a hard wall-clock budget. It returns whatever it found when the budget
/// runs out rather than blocking anyone.
enum AXContextReader {

    struct Message {
        var text: String
        var frame: CGRect?
    }

    static let maxDepth = 14
    static let maxNodes = 1400
    static let budget: TimeInterval = 0.12

    /// Visible message-like text, oldest first.
    static func conversation(limit: Int = 12) -> [String] {
        let messages = visibleMessages(limit: limit * 3, wantFrames: false)
        var out: [String] = []
        var seen = Set<String>()
        for m in messages {
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 500 else { continue }
            guard seen.insert(t).inserted else { continue }
            out.append(t)
        }
        return Array(out.suffix(limit))
    }

    /// Message-like nodes with their screen rects, for Inbox Shield.
    static func visibleMessages(limit: Int = 60, wantFrames: Bool = true) -> [Message] {
        guard AX.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, AX.messagingTimeout)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute as String)
            ?? AX.element(axApp, kAXMainWindowAttribute as String) else { return [] }

        var out: [Message] = []
        var nodes = 0
        let deadline = Date().addingTimeInterval(budget)

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, nodes < maxNodes, Date() < deadline else { return }
            nodes += 1

            let role = AX.string(element, kAXRoleAttribute as String) ?? ""

            // Skip the chrome that never holds a message.
            switch role {
            case "AXToolbar", "AXMenuBar", "AXMenu", "AXScrollBar", "AXSplitter",
                 "AXImage", "AXProgressIndicator", "AXTabGroup":
                return
            default: break
            }

            if role == kAXStaticTextRole as String || role == "AXTextArea" || role == "AXHeading" {
                if let v = AX.readValue(element)
                    ?? AX.string(element, kAXTitleAttribute as String),
                   !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(Message(text: v, frame: wantFrames ? AX.frame(of: element) : nil))
                }
            } else if role == "AXGroup" || role == "AXRow" || role == "AXCell" {
                // Electron chat rows often carry the whole message as a description.
                if let d = AX.string(element, kAXDescriptionAttribute as String), d.count > 12 {
                    out.append(Message(text: d, frame: wantFrames ? AX.frame(of: element) : nil))
                }
            }

            guard out.count < limit else { return }
            for child in AX.children(element) {
                walk(child, depth: depth + 1)
                if out.count >= limit || Date() >= deadline { return }
            }
        }

        walk(window, depth: 0)
        return out
    }
}
