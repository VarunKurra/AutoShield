import SwiftUI
import AppKit
import ShieldCore

/// The page you land on. One control, and it is the whole product.
struct ProtectionPage: View {
    @ObservedObject var engine: ShieldEngine
    var replayOnboarding: () -> Void

    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var passcode = Passcode.shared
    @State private var askingToDisable = false

    private var on: Bool { settings.sendShieldEnabled && permissions.canCatchSends }

    var body: some View {
        ZStack {
            page
            if askingToDisable {
                PasscodeSheet(
                    mode: .unlock,
                    onSubmit: { code in
                        guard passcode.verify(code) else { return false }
                        settings.sendShieldEnabled = false
                        askingToDisable = false
                        return true
                    },
                    onCancel: { askingToDisable = false })
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(Motion.respectful(Motion.quick), value: askingToDisable)
    }

    private var page: some View {
        VStack(spacing: 0) {
            if !permissions.allGranted { setupBanner }

            Spacer(minLength: 24)

            ShieldCrest(on: on, blocked: !permissions.canCatchSends) {
                if settings.sendShieldEnabled && passcode.isLocked {
                    // Switching protection off is the one thing the person
                    // being protected must not be able to do alone.
                    askingToDisable = true
                } else {
                    settings.sendShieldEnabled.toggle()
                }
            }

            VStack(spacing: 5) {
                Text(headline)
                    .font(TypeScale.display(23))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.opacity)
                Text(statusLine)
                    .font(TypeScale.body(13))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.top, 14)
            .animation(Motion.respectful(Motion.settle), value: on)

            Spacer(minLength: 26)

            stats
                .frame(maxWidth: 620)
                .padding(.horizontal, 26)
                .padding(.bottom, 28)
        }
    }

    private var headline: String {
        if !permissions.canCatchSends {
            return permissions.canRead ? "Half protected" : "Not watching yet"
        }
        return on ? "Protected" : "Protection is off"
    }

    private var statusLine: String {
        if !permissions.canCatchSends {
            return permissions.canRead
                ? "Incoming works. Outgoing needs Input Monitoring."
                : "Both permissions are still off"
        }
        if !on { return "Press the shield to turn it on" }
        if let app = engine.status.watching { return "Watching \(app)" }
        if let reason = engine.status.suspendedReason { return reason }
        return "Watching everything you type"
    }

    // MARK: Setup banner

    private var setupBanner: some View {
        Button(action: replayOnboarding) {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                Text(bannerText)
                    .font(TypeScale.emphasis(12.5))
                Spacer()
                Text("Fix it").font(TypeScale.emphasis(12.5))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Palette.severity(0.7))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Palette.severity(0.7).opacity(0.10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Names the permission that is actually missing, and what still works
    /// without it. "Cannot see anything" was wrong whenever Accessibility was
    /// on by itself.
    private var bannerText: String {
        guard let missing = permissions.missing else { return "" }
        if permissions.canRead {
            return "Outgoing is off. \(missing) is not granted."
        }
        return "AutoShield cannot see anything. \(missing) not granted."
    }

    // MARK: Today

    private var stats: some View {
        Paper(padding: 0) {
            HStack(spacing: 0) {
                Stat(value: engine.snapshot.holds, label: "caught", tint: Palette.severity(0.8))
                Divider().frame(height: 32).overlay(Palette.edge)
                Stat(value: engine.snapshot.edited, label: "rewritten", tint: Palette.accent)
                Divider().frame(height: 32).overlay(Palette.edge)
                Stat(value: engine.snapshot.covered, label: "covered", tint: Palette.calm)
                Divider().frame(height: 32).overlay(Palette.edge)
                Stat(value: engine.snapshot.analyses, label: "checked", tint: Palette.muted)
            }
            .padding(.vertical, 15)
        }
    }
}

private struct Stat: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(TypeScale.display(19))
                .foregroundStyle(value == 0 ? Palette.faint : tint)
                .contentTransition(.numericText())
            Text(label).font(TypeScale.body(11.5)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.respectful(Motion.settle), value: value)
    }
}

/// A little keyboard key, used wherever a shortcut is named.
struct KeyCap: View {
    let label: String
    var tint: Color = Palette.faint

    init(_ label: String, tint: Color = Palette.faint) {
        self.label = label; self.tint = tint
    }

    var body: some View {
        Text(label)
            .font(TypeScale.mono(9.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// Quits and comes back. Menu bar recovery path when macOS withholds the tap.
enum Relauncher {
    static func restart() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
