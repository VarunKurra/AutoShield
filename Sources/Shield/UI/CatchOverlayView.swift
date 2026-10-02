import SwiftUI
import AppKit
import ShieldCore

/// The overlay that appears when cruel text is caught, whether it was being
/// sent or only typed.
///
/// Three ways out, each one keystroke: rewrite it, take it out, or go back
/// and fix it yourself. There is no "send it anyway", because one sitting next
/// to the others turns the pause into a dare.
struct CatchOverlayView: View {
    let draft: ShieldEngine.HeldDraft
    /// Non-nil while the rewrite is in flight or has just failed.
    var rephrase: ShieldEngine.RephraseState?
    /// Bumped by the engine when a key was blocked; the panel shakes once.
    var nudge: Int = 0
    var onRephrase: () -> Void
    var onRemove: () -> Void = {}
    var onEdit: () -> Void
    /// Only offered once a rewrite has failed.
    var onSendUnchanged: (() -> Void)? = nil
    /// Drawn inside an ordinary window rather than floating over the desktop,
    /// where behind-window vibrancy has nothing to sample and turns muddy.
    var embedded: Bool = false
    /// The panel cannot guess how tall this is: a rationale can arrive later
    /// and run to three lines. So the view measures itself and says.
    var onHeight: ((CGFloat) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var arrived = false
    @State private var latch = false

    private var severity: Color { Palette.severity(draft.verdict.score) }

    private var wordPolicy: Bool {
        draft.verdict.categories.contains(.profanity) || draft.verdict.categories.contains(.explicit)
    }

    /// Swearing is not "cruel"; it is just not allowed. Say which.
    private var pipLabel: String? {
        switch draft.verdict.primaryCategory {
        case .explicit: return "Explicit"
        case .profanity: return "Language"
        default: return nil
        }
    }

    private var icon: String {
        switch draft.verdict.primaryCategory {
        case .threat, .harassment: return "exclamationmark.triangle.fill"
        case .explicit, .profanity: return "nosign"
        default: return "hand.raised.fill"
        }
    }

    private var subtitle: String {
        if failed { return "Choose how to fix it" }
        return draft.trigger == .send ? "Not sent" : "Paused while you were typing"
    }

    private var line: String {
        if draft.trigger == .typing && draft.verdict.categories.isEmpty {
            return "Hold on. This might land harder than you mean it to."
        }
        switch draft.verdict.primaryCategory {
        case .exclusion:   return "This shuts someone out."
        case .backhanded:  return "This is sharper than it looks."
        case .pileOn:      return "A few people just said the same thing."
        case .threat:      return "This reads as a threat."
        case .slur:        return "This one will really land."
        case .explicit:    return "This is explicit, so it can't go here."
        case .profanity:   return "That language isn't allowed here."
        default:           return "This might land harder than you mean it to."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: what kind of catch, and how serious, at a glance.
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(severity.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(severity)
                }
                .frame(width: 30, height: 30)
                .scaleEffect(latch ? 1 : 0.6)
                .opacity(latch ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(line)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 6)
                SeverityPip(score: draft.verdict.score, label: pipLabel)
            }

            if showQuote {
                Text(quoted)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.ink.opacity(0.05))
                    )
                    .overlay(alignment: .leading) {
                        Capsule().fill(severity.opacity(0.7)).frame(width: 2.5).padding(.vertical, 6)
                    }
            }

            if let rationale = draft.verdict.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let why) = rephrase {
                Label(why, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(severity)
                    .fixedSize(horizontal: false, vertical: true)
            }

                HStack(spacing: 8) {
                    if failed {
                        // Swearing and explicit language are never sent as
                        // is: the word is the problem, whatever the context.
                        if draft.trigger == .send, !wordPolicy, let onSendUnchanged {
                            // The rewrite did not come back. Shield has no right
                            // to keep a message it cannot help with.
                            ActionButton(title: "Send as is", shortcut: "⏎",
                                         symbol: "paperplane.fill", filled: true,
                                         tint: Palette.accent, busy: false,
                                         action: onSendUnchanged)
                        }
                    } else {
                        ActionButton(title: working ? "Rewriting…" : (draft.trigger == .send ? "Rewrite & send" : "Rewrite"),
                                     shortcut: "⏎",
                                     symbol: "wand.and.sparkles",
                                     filled: true,
                                     tint: Palette.accent,
                                     busy: working,
                                     action: onRephrase)
                    }
                    ActionButton(title: "Remove",
                                 shortcut: "⌘⌫",
                                 symbol: "delete.left",
                                 filled: false,
                                 tint: Palette.ink,
                                 busy: false,
                                 action: onRemove)
                    ActionButton(title: "Edit",
                                 shortcut: "esc",
                                 symbol: "pencil",
                                 filled: false,
                                 tint: Palette.ink,
                                 busy: false,
                                 action: onEdit)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
        }
        .padding(16)
        .frame(width: CatchOverlayView.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onHeight?(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in onHeight?(h) }
            }
        )
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(white: colorScheme == .dark ? 0.50 : 0.56).opacity(0.85), lineWidth: 1.5)
        )
        .scaleEffect(arrived ? 1 : 0.965, anchor: .bottomLeading)
        .offset(y: arrived ? 0 : 7)
        // Never fully transparent: if SwiftUI ever skips onAppear inside a
        // borderless panel, a held message must still have a visible panel.
        .opacity(arrived ? 1 : 0.35)
        .modifier(Shake(amount: CGFloat(nudge)))
        .animation(Motion.reduceMotion ? nil : .linear(duration: 0.32), value: nudge)
        .onAppear(perform: arrive)
        .task { if !arrived { arrive() } }
    }

    private func arrive() {
        guard !arrived else { return }
        if Motion.reduceMotion {
            arrived = true; latch = true
        } else {
            withAnimation(Motion.arrive) { arrived = true }
            withAnimation(Motion.settle.delay(0.06)) { latch = true }
        }
    }

    private var quoted: String {
        let s = draft.span.replacingOccurrences(of: "\n", with: " ")
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }

    /// The words are quoted when they are not obviously the whole message:
    /// in a document, or when caught while typing.
    private var showQuote: Bool {
        !draft.span.isEmpty
    }

    private var working: Bool { rephrase == .working }

    private var failed: Bool {
        if case .failed = rephrase { return true }
        return false
    }

    @ViewBuilder
    private var background: some View {
        if embedded {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.raised)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .background(
                    VisualEffect(material: .popover, blending: .behindWindow, emphasized: true)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        }
    }

    static let width: CGFloat = 420
}

/// One horizontal shake per nudge.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 4), y: 0))
    }
}

/// Three dots that fill by severity, with the word beside them. Colour alone
/// is not readable, so it never carries the meaning on its own.
private struct SeverityPip: View {
    let score: Double
    var label: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(label ?? Palette.severityLabel(score))
                .font(TypeScale.label(10))
                .foregroundStyle(Palette.severity(score))
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i < filled ? Palette.severity(score) : Palette.ink.opacity(0.13))
                        .frame(width: 8, height: 3)
                }
            }
        }
    }

    private var filled: Int {
        if score < 0.55 { return 1 }
        if score < 0.78 { return 2 }
        return 3
    }
}

private struct ActionButton: View {
    let title: String
    let shortcut: String
    let symbol: String
    let filled: Bool
    let tint: Color
    let busy: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false
    @State private var spin = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: busy ? "circle.dotted" : symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .rotationEffect(.degrees(busy && spin ? 360 : 0))
                    .animation(busy && !Motion.reduceMotion
                               ? .linear(duration: 1.1).repeatForever(autoreverses: false)
                               : nil, value: spin)
                Text(title)
                    .font(TypeScale.emphasis(12.5))
                    .lineLimit(1)
                    .fixedSize()
                Text(shortcut)
                    .font(TypeScale.mono(9.5))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(0.65)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill((filled ? Color.white : Palette.ink).opacity(filled ? 0.20 : 0.07))
                    )
            }
            .foregroundStyle(filled ? Color.white : Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                    .fill(filled
                          ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(hovering ? 1 : 0.94), tint],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Palette.ink.opacity(hovering ? 0.075 : 0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                    .strokeBorder(filled ? .clear : Palette.edge, lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onAppear { if busy { spin = true } }
        .onChange(of: busy) { _, b in spin = b }
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(Motion.respectful(Motion.quick)) { pressed = true } } }
                .onEnded { _ in withAnimation(Motion.respectful(Motion.quick)) { pressed = false } }
        )
    }
}
