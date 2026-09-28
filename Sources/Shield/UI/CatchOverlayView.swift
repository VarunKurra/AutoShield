import SwiftUI
import AppKit
import ShieldCore

/// The overlay that appears when a Return is swallowed.
///
/// Two ways out, both one keystroke. Rewrite it and send, or go back and fix
/// it yourself. There is no third button, because a "send it anyway" sitting
/// next to them turns the pause into a dare.
struct CatchOverlayView: View {
    let draft: ShieldEngine.HeldDraft
    /// Non-nil while the rewrite is in flight or has just failed.
    var rephrase: ShieldEngine.RephraseState?
    var onRephrase: () -> Void
    var onEdit: () -> Void
    /// Only offered once a rewrite has failed.
    var onSendUnchanged: (() -> Void)? = nil
    /// Drawn inside an ordinary window rather than floating over the desktop,
    /// where behind-window vibrancy has nothing to sample and turns muddy.
    var embedded: Bool = false
    /// The panel cannot guess how tall this is: a rationale can arrive later
    /// and run to three lines. So the view measures itself and says.
    var onHeight: ((CGFloat) -> Void)? = nil

    @State private var arrived = false
    @State private var latch = false

    private var severity: Color { Palette.severity(draft.verdict.score) }

    private var line: String {
        switch draft.verdict.categories.first {
        case .exclusion:   return "This shuts someone out."
        case .backhanded:  return "This is sharper than it looks."
        case .pileOn:      return "A few people just said the same thing."
        case .threat:      return "This reads as a threat."
        case .slur:        return "This one will really land."
        default:           return "This might land harder than you mean it to."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The latch: a rule in the severity colour that draws itself closed.
            Capsule()
                .fill(severity)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .scaleEffect(y: latch ? 1 : 0.15, anchor: .top)
                .opacity(latch ? 1 : 0)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Text(line)
                        .font(TypeScale.headline(16))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    SeverityPip(score: draft.verdict.score)
                }

                if let rationale = draft.verdict.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(TypeScale.body(12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .failed(let why) = rephrase {
                    Text(why)
                        .font(TypeScale.body(12))
                        .foregroundStyle(severity)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if failed, let onSendUnchanged {
                        // The rewrite did not come back. Shield has no right to
                        // keep a message it cannot help with.
                        ActionButton(title: "Send as is", shortcut: "return",
                                     symbol: "paperplane.fill", filled: true,
                                     tint: Palette.accent, busy: false,
                                     action: onSendUnchanged)
                    } else {
                        ActionButton(title: working ? "Rewriting…" : "Rewrite and send",
                                     shortcut: "return",
                                     symbol: "wand.and.sparkles",
                                     filled: true,
                                     tint: Palette.accent,
                                     busy: working,
                                     action: onRephrase)
                    }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(severity.opacity(embedded ? 0.28 : 0.22), lineWidth: 1)
        )
        .scaleEffect(arrived ? 1 : 0.965, anchor: .bottomLeading)
        .offset(y: arrived ? 0 : 7)
        .opacity(arrived ? 1 : 0)
        .onAppear {
            if Motion.reduceMotion {
                arrived = true; latch = true
            } else {
                withAnimation(Motion.arrive) { arrived = true }
                withAnimation(Motion.settle.delay(0.06)) { latch = true }
            }
        }
    }

    private var working: Bool { rephrase == .working }

    private var failed: Bool {
        if case .failed = rephrase { return true }
        return false
    }

    @ViewBuilder
    private var background: some View {
        if embedded {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.raised)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.clear)
                .background(
                    VisualEffect(material: .hudWindow, blending: .behindWindow, emphasized: true)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        }
    }

    static let width: CGFloat = 384
}

/// Three dots that fill by severity, with the word beside them. Colour alone
/// is not readable, so it never carries the meaning on its own.
private struct SeverityPip: View {
    let score: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(Palette.severityLabel(score))
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
                Text(shortcut)
                    .font(TypeScale.mono(9.5))
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
