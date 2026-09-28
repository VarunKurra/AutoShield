import SwiftUI
import AppKit
import ShieldCore

/// Shield's one window.
///
/// Welcome, then permissions, then home, in that order and only that order.
/// An earlier build used a separate window for setup, which meant home could
/// send you back to setup and setup could send you back to home. One window
/// holding one screen at a time cannot loop.
struct RootView: View {
    @ObservedObject var engine: ShieldEngine
    @ObservedObject private var settings = AppSettings.shared

    enum Screen { case welcome, permissions, passcode, home }

    @State private var screen: Screen

    init(engine: ShieldEngine) {
        self.engine = engine
        let straightToHome = AppSettings.shared.hasOnboarded
            && !AppSettings.alwaysShowOnboarding
        _screen = State(initialValue: straightToHome ? .home : .welcome)
    }

    var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            switch screen {
            case .welcome:
                WelcomeScreen { go(.permissions) }
                    .transition(.opacity)
            case .permissions:
                PermissionsScreen { go(.passcode) }
                    .transition(.opacity)
            case .passcode:
                PasscodeSetupScreen {
                    AppSettings.shared.hasOnboarded = true
                    // Setting a code does not leave the session authorised, or
                    // the first thing it guards could be switched off without
                    // ever being asked for.
                    Passcode.shared.lock()
                    go(.home)
                }
                .transition(.opacity)
            case .home:
                AppShell(engine: engine, replayOnboarding: { go(.permissions) })
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .liveBorder(active: borderLive)
        .ignoresSafeArea()
    }

    /// The border tracks the thing it signifies: on when AutoShield is
    /// actually watching, off otherwise.
    private var borderLive: Bool {
        screen == .home && settings.sendShieldEnabled && Permissions.shared.allGranted
    }

    private func go(_ next: Screen) {
        withAnimation(Motion.respectful(Motion.settle)) { screen = next }
        Windows.shared.resizeMain(for: next)
    }
}

// MARK: - Welcome

/// One mark, one sentence, one button. Nothing to read and nothing to decide.
private struct WelcomeScreen: View {
    var onStart: () -> Void
    @State private var arrived = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                AppMark(size: 84)
                    .scaleEffect(arrived ? 1 : 0.9)
                    .opacity(arrived ? 1 : 0)

                VStack(spacing: 7) {
                    Text("AutoShield")
                        .font(TypeScale.display(30))
                        .foregroundStyle(Palette.ink)
                    Text("Catches a cruel message before it sends,\nand covers one sent to you.")
                        .font(TypeScale.body(14))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived ? 0 : 6)
            }

            Spacer()

            PrimaryButton("Get started", wide: true, action: onStart)
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
                .opacity(arrived ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if Motion.reduceMotion { arrived = true }
            else { withAnimation(Motion.settle.delay(0.05)) { arrived = true } }
        }
    }
}

// MARK: - Passcode setup

/// The third step: six digits a supervisor chooses, so protection cannot be
/// switched off by the person it is protecting.
private struct PasscodeSetupScreen: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            PasscodeView(mode: .create, onSubmit: submit)

            Spacer(minLength: 16)

            Button("Skip for now", action: onDone)
                .buttonStyle(.plain)
                .font(TypeScale.emphasis(12.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit(_ code: String) -> Bool {
        Passcode.shared.set(code)
        onDone()
        return true
    }
}

// MARK: - Permissions

/// Both permissions on one screen, each with its own switch-on button and a
/// live status. Nothing is gated: Continue always works.
private struct PermissionsScreen: View {
    var onContinue: () -> Void
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Two permissions")
                    .font(TypeScale.display(25))
                    .foregroundStyle(Palette.ink)
                Text("AutoShield needs both to work.")
                    .font(TypeScale.body(13.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.top, 52)
            .padding(.bottom, 20)

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Reads what you type",
                    symbol: "text.cursor",
                    granted: permissions.accessibility,
                    action: { permissions.requestAccessibility() })

                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Catches Return before it sends",
                    symbol: "keyboard.fill",
                    granted: permissions.inputMonitoring,
                    action: { permissions.requestInputMonitoring() })
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 16)

            PrimaryButton(permissions.allGranted ? "Start Shield" : "Continue",
                          wide: true, action: onContinue)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.respectful(Motion.settle), value: permissions.allGranted)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        Paper(padding: 15) {
            HStack(spacing: 13) {
                TintedIcon(symbol, tint: granted ? Palette.calm : Palette.accent, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TypeScale.title(14))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(TypeScale.body(12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.calm)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Turn on", action: action)
                        .buttonStyle(.plain)
                        .font(TypeScale.emphasis(12.5))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Palette.accent.opacity(0.11)))
                }
            }
        }
        .animation(Motion.respectful(Motion.settle), value: granted)
    }
}
