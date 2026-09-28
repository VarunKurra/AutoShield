import SwiftUI
import AppKit
import ShieldCore

/// The page for the worst night.
///
/// Built for the person who is humiliated and panicking at 11pm, not only for
/// the person in acute danger. The crisis lines stay at the top and never move,
/// but most of this page is about the next practical step: keep the evidence,
/// report it, and find the first sentence to say out loud.
struct CrisisPage: View {
    @ObservedObject var engine: ShieldEngine
    @State private var exported: URL?
    @State private var copiedScript: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Get help", subtitle: "Four steps, in order")

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rightNow
                    saveWhatHappened
                    reportIt
                    tellSomeone
                    schoolsNote
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 1. Right now

    private var rightNow: some View {
        Section(number: "1", title: "Right now", tint: Palette.cruel) {
            VStack(spacing: 9) {
                HelpLine(title: "Call or text 988",
                         subtitle: "Suicide and Crisis Lifeline",
                         symbol: "phone.fill",
                         tint: Palette.cruel,
                         url: URL(string: "tel:988"))

                HelpLine(title: "Text HOME to 741741",
                         subtitle: "Crisis Text Line, if talking is too much",
                         symbol: "message.fill",
                         tint: Palette.cruel,
                         url: URL(string: "sms:741741&body=HOME"))

                HelpLine(title: "The Trevor Project",
                         subtitle: "1-866-488-7386, for LGBTQ+ young people",
                         symbol: "heart.fill",
                         tint: Palette.cruel,
                         url: URL(string: "https://www.thetrevorproject.org/get-help/"))
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.calm)
                    .padding(.top, 1)
                Text("Calling 988 does not automatically send police.")
                    .font(TypeScale.body(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    // MARK: 2. Save what happened

    private var saveWhatHappened: some View {
        Section(number: "2", title: "Save what happened", tint: Palette.accent) {
            Text("Schools and platforms rarely act on screenshots. AutoShield already has a dated record.")
                .font(TypeScale.body(12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                PrimaryButton("Export a timestamped record", symbol: "square.and.arrow.down") {
                    export()
                }
                .disabled(engine.events.isEmpty)
                .opacity(engine.events.isEmpty ? 0.45 : 1)

                if let exported {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([exported])
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Saved. Show it")
                        }
                        .font(TypeScale.emphasis(12.5))
                        .foregroundStyle(Palette.calm)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(engine.events.isEmpty
                 ? "Nothing recorded yet."
                 : "\(engine.events.count) event\(engine.events.count == 1 ? "" : "s") recorded this session.")
                .font(TypeScale.body(11.5))
                .foregroundStyle(Palette.faint)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AutoShield-record-\(Self.fileStamp.string(from: Date())).md"
        panel.allowedContentTypes = [.plainText]
        panel.message = "A dated record of what AutoShield saw."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Self.record(engine.events).write(to: url, atomically: true, encoding: .utf8)
        exported = url
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f
    }()

    private static let rowStamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()

    /// Plain Markdown, so it opens anywhere and reads as a document rather
    /// than a data dump. Whoever receives it should not need this app.
    static func record(_ events: [ShieldEvent]) -> String {
        var out = "# Record of online harassment\n\n"
        out += "Generated by AutoShield on \(rowStamp.string(from: Date())).\n\n"
        out += "Each entry is a message AutoShield identified, with the time it was seen "
        out += "and how severely it scored. Entries are in reverse order, newest first.\n\n"
        out += "---\n\n"

        for event in events {
            out += "### \(rowStamp.string(from: event.at))\n\n"
            out += "- **What happened:** \(event.kind.label)\n"
            if event.score > 0 {
                out += "- **Severity:** \(Palette.severityLabel(event.score)) "
                out += "(\(Int(event.score * 100))%)\n"
            }
            if let app = event.app { out += "- **Where:** \(app)\n" }
            if let reason = event.reason, !reason.isEmpty {
                out += "- **Why it was flagged:** \(reason)\n"
            }
            if event.kind != .resources {
                out += "- **Message:** \(event.text)\n"
            }
            if let rewritten = event.rewritten, !rewritten.isEmpty {
                out += "- **Rewritten to:** \(rewritten)\n"
            }
            out += "\n"
        }

        out += "---\n\n"
        out += "This record was produced automatically. The times are from this "
        out += "computer's clock. Nothing has been edited.\n"
        return out
    }

    // MARK: 3. Report it

    private var reportIt: some View {
        Section(number: "3", title: "Report it", tint: Palette.harsh) {
            Text("Straight to each platform\u{2019}s report form.")
                .font(TypeScale.body(12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 9) {
                ReportLink(platform: "Instagram",
                           what: "Anonymous. They are not told who reported.",
                           url: "https://help.instagram.com/192435014247952")
                ReportLink(platform: "Snapchat",
                           what: "Usually reviewed within a day.",
                           url: "https://help.snapchat.com/hc/en-us/articles/7012399221652")
                ReportLink(platform: "Discord",
                           what: "Right-click the message, Copy Message Link, first.",
                           url: "https://support.discord.com/hc/en-us/requests/new")
                ReportLink(platform: "TikTok",
                           what: "This form takes your exported record.",
                           url: "https://www.tiktok.com/legal/report/feedback")
                ReportLink(platform: "iMessage",
                           what: "Report and block, not just block.",
                           url: "https://support.apple.com/en-us/102322")
            }
        }
    }

    // MARK: 4. Tell someone

    private static let scripts: [(who: String, text: String)] = [
        ("A parent",
         "Something's been happening online and I don't know how to handle it. Can I show you?"),
        ("A school counselor",
         "I'm being targeted online by someone from school and it's affecting me. I have a record of it. Can we talk?"),
        ("A friend",
         "Something's going on and I don't really want to explain it all right now. Can you just be around today?"),
    ]

    private var tellSomeone: some View {
        Section(number: "4", title: "Tell someone", tint: Palette.calm) {
            Text("Copy one and send it.")
                .font(TypeScale.body(12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 9) {
                ForEach(Self.scripts, id: \.who) { script in
                    ScriptCard(who: script.who,
                               text: script.text,
                               copied: copiedScript == script.who) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(script.text, forType: .string)
                        withAnimation(Motion.respectful(Motion.quick)) { copiedScript = script.who }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation(Motion.respectful(Motion.quick)) {
                                if copiedScript == script.who { copiedScript = nil }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Footnote

    private var schoolsNote: some View {
        Paper(padding: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("What a school has to do")
                    .font(TypeScale.title(13.5))
                    .foregroundStyle(Palette.ink)
                Text("Most US states require schools to investigate bullying reports, including things that happened off campus. If it involves race, sex, disability, religion or national origin, federal law applies and they have to respond.\n\nYou can ask in writing and ask what was done.")
                    .font(TypeScale.body(12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2.5)
            }
        }
    }
}

// MARK: - Pieces

private struct Section<Content: View>: View {
    let number: String
    let title: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        Paper(padding: 18) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Text(number)
                        .font(TypeScale.label(10.5))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(tint))
                    Text(title)
                        .font(TypeScale.title(15))
                        .foregroundStyle(Palette.ink)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HelpLine: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let url: URL?

    @State private var hovering = false

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 12) {
                TintedIcon(symbol, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(TypeScale.title(14))
                        .foregroundStyle(Palette.ink)
                    Text(subtitle)
                        .font(TypeScale.body(12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? tint : Palette.faint)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hovering ? tint.opacity(0.09) : Palette.sunken))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.35) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
    }
}

private struct ReportLink: View {
    let platform: String
    let what: String
    let url: String

    @State private var hovering = false

    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(platform)
                    .font(TypeScale.emphasis(12.5))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 78, alignment: .leading)
                Text(what)
                    .font(TypeScale.body(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hovering ? Palette.accent : Palette.faint)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.accent.opacity(0.07) : Palette.sunken))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
    }
}

private struct ScriptCard: View {
    let who: String
    let text: String
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(who)
                    .font(TypeScale.label(10))
                    .foregroundStyle(Palette.faint)
                Text("\u{201C}\(text)\u{201D}")
                    .font(TypeScale.body(13))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                        .font(TypeScale.label(10.5))
                }
                .foregroundStyle(copied ? Palette.calm : Palette.accent)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill((copied ? Palette.calm : Palette.accent).opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.sunken))
    }
}
