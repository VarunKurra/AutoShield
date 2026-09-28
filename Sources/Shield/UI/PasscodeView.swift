import SwiftUI
import AppKit
import ShieldCore

/// Six digits, six wells.
///
/// Used three ways: choosing a code during setup, confirming it, and unlocking
/// later. The entry itself is a hidden field behind the wells, so typing,
/// deleting and pasting all behave the way the system expects while the wells
/// stay purely visual.
struct PasscodeView: View {
    enum Mode {
        case create, unlock

        var title: String {
            switch self {
            case .create: return "6-digit passcode"
            case .unlock: return "Enter passcode"
            }
        }

        var detail: String {
            switch self {
            case .create: return "Needed to turn AutoShield off or open Settings."
            case .unlock: return "Required to change protection."
            }
        }
    }

    let mode: Mode
    /// Returns true when the code was accepted. Returning false shakes.
    let onSubmit: (String) -> Bool
    var onCancel: (() -> Void)? = nil

    @State private var code = ""
    @State private var shake: CGFloat = 0
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 9) {
                TintedIcon(mode == .unlock ? "lock.fill" : "lock.shield.fill",
                           tint: wrong ? Palette.severity(0.9) : Palette.accent, size: 46)
                    .animation(Motion.respectful(Motion.quick), value: wrong)

                Text(mode.title)
                    .font(TypeScale.display(21))
                    .foregroundStyle(Palette.ink)
                Text(wrong ? "That is not it. Try again." : mode.detail)
                    .font(TypeScale.body(12.5))
                    .foregroundStyle(wrong ? Palette.severity(0.9) : Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            wells
                .modifier(Shake(travel: shake))

            // Choosing a code confirms with a button rather than by typing it
            // twice. Retyping is friction that catches almost nothing when the
            // digits are visible on screen.
            if mode == .create {
                PrimaryButton("Confirm passcode", symbol: "checkmark", wide: true) {
                    submit()
                }
                .opacity(complete ? 1 : 0.35)
                .disabled(!complete)
                .animation(Motion.respectful(Motion.quick), value: complete)
            }

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(TypeScale.emphasis(12.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 32)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.raised)
                .shadow(color: .black.opacity(0.16), radius: 30, y: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1))
        .onAppear { focused = true }
    }

    // MARK: Wells

    private var wells: some View {
        ZStack {
            // The real field, invisible but focused, so the system handles
            // keyboard, delete and paste for us.
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($focused)
                .opacity(0.001)
                .frame(width: 1, height: 1)
                .onChange(of: code) { _, next in handle(next) }
                .onSubmit { submit() }

            HStack(spacing: 9) {
                ForEach(0..<Passcode.length, id: \.self) { i in
                    Well(digit: i < code.count ? Array(code)[i] : nil,
                         caret: i == code.count && focused,
                         // Digits are shown while choosing, because a code you
                         // cannot read is a code you mistype twice and give up
                         // on. Unlocking hides them, since by then someone is
                         // usually watching over a shoulder.
                         reveal: mode != .unlock,
                         wrong: wrong)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
    }

    private var complete: Bool { code.count == Passcode.length }

    private func handle(_ next: String) {
        let digits = String(next.filter(\.isNumber).prefix(Passcode.length))
        if digits != next { code = digits; return }
        if wrong && !digits.isEmpty {
            withAnimation(Motion.respectful(Motion.quick)) { wrong = false }
        }
        // Unlocking submits the moment it is complete; choosing waits for the
        // button, so a mistyped digit can still be deleted.
        guard mode == .unlock, digits.count == Passcode.length else { return }
        submit()
    }

    private func submit() {
        guard complete else { return }
        if onSubmit(code) {
            code = ""
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.32)) { shake += 1 }
            withAnimation(Motion.respectful(Motion.quick)) { wrong = true }
            NSSound.beep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { code = "" }
        }
    }
}

private struct Well: View {
    let digit: Character?
    let caret: Bool
    let reveal: Bool
    let wrong: Bool

    @State private var blink = false

    private var filled: Bool { digit != nil }
    private var tint: Color { wrong ? Palette.severity(0.9) : Palette.accent }

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(caret ? Palette.raised : Palette.sunken)
            .frame(width: 46, height: 58)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(caret ? tint : (filled ? tint.opacity(0.40) : Palette.edge),
                                  lineWidth: caret ? 1.75 : 1))
            .overlay(alignment: .center) { mark }
            .overlay(alignment: .bottom) { rule }
            .shadow(color: tint.opacity(caret ? 0.20 : 0), radius: 7, y: 2)
            .animation(Motion.respectful(Motion.quick), value: filled)
            .animation(Motion.respectful(Motion.quick), value: caret)
    }

    /// The digit, or a dot when the code is hidden.
    @ViewBuilder
    private var mark: some View {
        if let digit, reveal {
            Text(String(digit))
                .font(TypeScale.display(24))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .id(digit)
        } else if filled {
            Circle().fill(tint).frame(width: 11, height: 11)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    /// A caret that sits where the digit will land: solid once typed, blinking
    /// while the well is waiting for one.
    @ViewBuilder
    private var rule: some View {
        Capsule()
            .fill(filled ? tint.opacity(0.55) : tint)
            .frame(width: 18, height: 2.5)
            .opacity(caret ? (blink ? 0.15 : 1) : (filled ? 1 : 0))
            .padding(.bottom, 9)
            .onAppear {
                guard caret, !Motion.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.58).repeatForever(autoreverses: true)) {
                    blink = true
                }
            }
            .onChange(of: caret) { _, active in
                blink = false
                guard active, !Motion.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.58).repeatForever(autoreverses: true)) {
                    blink = true
                }
            }
    }
}

/// A horizontal shake, driven by an incrementing counter so repeated failures
/// each get their own shake.
private struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let amount = sin(travel * .pi * 6) * 9
        return ProjectionTransform(CGAffineTransform(translationX: amount, y: 0))
    }
}

/// Dims whatever is behind it and centres a passcode prompt.
struct PasscodeSheet: View {
    let mode: PasscodeView.Mode
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void

    @State private var arrived = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(arrived ? 0.28 : 0))
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            PasscodeView(mode: mode, onSubmit: onSubmit, onCancel: onCancel)
                .scaleEffect(arrived ? 1 : 0.94)
                .opacity(arrived ? 1 : 0)
        }
        .onAppear {
            if Motion.reduceMotion { arrived = true }
            else { withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { arrived = true } }
        }
    }
}
