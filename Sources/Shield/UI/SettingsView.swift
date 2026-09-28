import SwiftUI
import ShieldCore

struct SettingsView: View {
    @ObservedObject var engine: ShieldEngine
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Settings", subtitle: "Everything AutoShield does, and what leaves this Mac")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                SettingsGroup("How often it steps in") {
                    Paper {
                        VStack(spacing: 0) {
                            ForEach(Array(Sensitivity.allCases.enumerated()), id: \.element) { i, level in
                                if i > 0 {
                                    Rectangle().fill(Palette.edge).frame(height: 1).padding(.leading, 40)
                                }
                                SensitivityRow(level: level,
                                               selected: settings.sensitivity == level) {
                                    settings.sensitivity = level
                                }
                            }
                        }
                    }
                }

                SettingsGroup("Protection") {
                    Paper {
                        Row(symbol: "paperplane.fill", tint: Palette.accent,
                            title: "Outgoing",
                            detail: "Catches Return on a cruel message",
                            isOn: Binding(get: { settings.sendShieldEnabled },
                                          set: { settings.sendShieldEnabled = $0 }))
                        Line()
                        Row(symbol: "eye.slash.fill", tint: Palette.calm,
                            title: "Incoming",
                            detail: "Covers a cruel message sent to you until you click it",
                            isOn: Binding(get: { settings.inboxShieldEnabled },
                                          set: { settings.inboxShieldEnabled = $0 }))
                        Line()
                        Row(symbol: "heart.fill", tint: Palette.calm,
                            title: "Crisis resources",
                            detail: "Offers 988. Never sent to anyone, never blocks you",
                            isOn: Binding(get: { settings.crisisSurfaceEnabled },
                                          set: { settings.crisisSurfaceEnabled = $0 }))
                    }
                }

                SettingsGroup("Sound and feel") {
                    Paper {
                        Row(symbol: "speaker.wave.2.fill", tint: Palette.accent,
                            title: "Catch tone",
                            detail: "A soft sound when a message is caught",
                            isOn: Binding(get: { settings.soundEnabled },
                                          set: { settings.soundEnabled = $0 }),
                            trailing: AnyView(
                                Button("Play") { Feedback.previewCatch() }
                                    .buttonStyle(.plain)
                                    .font(TypeScale.label(10.5))
                                    .foregroundStyle(Palette.accent)))
                        Line()
                        Row(symbol: "hand.tap.fill", tint: Palette.accent,
                            title: "Trackpad haptics",
                            detail: "A light tap on the trackpad",
                            isOn: Binding(get: { settings.hapticsEnabled },
                                          set: { settings.hapticsEnabled = $0 }))
                    }
                }

                SettingsGroup("Your messages") {
                    Paper {
                        Row(symbol: "sparkles", tint: Palette.accent,
                            title: "Ask Gemini on hard ones",
                            detail: engine.contextAvailable
                                ? "About 1 in 40 goes to Google. Also powers rewriting"
                                : "Add an API key to turn this on. See the README",
                            isOn: Binding(get: { settings.contextTierEnabled },
                                          set: { settings.contextTierEnabled = $0 }))
                            .disabled(!engine.contextAvailable)
                        Line()
                        Row(symbol: "chart.bar.fill", tint: Palette.calm,
                            title: "Share anonymous counts",
                            detail: "Daily totals only. No message text, no account",
                            isOn: Binding(get: { settings.shareStatsEnabled },
                                          set: { settings.shareStatsEnabled = $0 }))
                        Line()
                        VStack(alignment: .leading, spacing: 7) {
                            Fact("Everything else runs on this Mac and stays here.")
                            Fact("Message text is never written to disk.")
                            Fact("AutoShield reports to nobody. No parent view, no account.")
                            Fact("The passcode is stored as a salted hash, never as digits. It stops a switch being flipped, not someone with the machine and time.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 16) {
                    Button("Reset counts") { engine.resetTelemetry() }
                        .buttonStyle(.plain)
                        .font(TypeScale.label(10.5))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Pieces

private struct SensitivityRow: View {
    let level: Sensitivity
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected ? Palette.accent : Palette.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(level.title)
                        .font(TypeScale.title(13.5))
                        .foregroundStyle(Palette.ink)
                    Text(level.detail)
                        .font(TypeScale.body(11.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.respectful(Motion.quick), value: selected)
    }
}

/// A titled block of rows. Named for what it is rather than `Group`, which
/// shadows SwiftUI's own container and breaks any file that uses both.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(TypeScale.label(10.5))
                .foregroundStyle(Palette.faint)
            content
        }
    }
}

/// A divider between rows in a card, inset so it starts where the text does
/// rather than cutting the whole card in half.
struct Line: View {
    var body: some View {
        Rectangle()
            .fill(Palette.edge)
            .frame(height: 1)
            .padding(.leading, 54)
            .padding(.trailing, 14)
    }
}

struct Row: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var trailing: AnyView? = nil

    init(symbol: String, tint: Color, title: String, detail: String,
         isOn: Binding<Bool>, trailing: AnyView? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self._isOn = isOn
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            TintedIcon(symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TypeScale.title(13.5))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(TypeScale.body(11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let trailing { trailing }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// One short fact with a quiet marker. Easier to scan than a paragraph.
struct Fact: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(Palette.faint.opacity(0.5))
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)
            Text(text)
                .font(TypeScale.body(12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
