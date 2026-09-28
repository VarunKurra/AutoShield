import SwiftUI
import AppKit
import ShieldCore

struct MenuBarView: View {
    @ObservedObject var engine: ShieldEngine
    @ObservedObject var permissions: Permissions
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(TypeScale.title(14))
                    .foregroundStyle(Palette.ink)
                Text(subline)
                    .font(TypeScale.body(12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !permissions.allGranted {
                Button { Windows.shared.show(.main) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.hold).frame(width: 5, height: 5)
                        Text(permissions.accessibility ? "Input Monitoring is off" : "Accessibility is off")
                            .font(TypeScale.emphasis(12.5))
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text("Fix")
                            .font(TypeScale.label())
                            .foregroundStyle(Palette.accent)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                        .fill(Palette.hold.opacity(0.10)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(Palette.edge)

            VStack(spacing: 9) {
                MenuToggle("Send Shield",
                           isOn: Binding(get: { settings.sendShieldEnabled },
                                         set: { settings.sendShieldEnabled = $0 }))
                MenuToggle("Inbox Shield",
                           isOn: Binding(get: { settings.inboxShieldEnabled },
                                         set: { settings.inboxShieldEnabled = $0 }))
            }

            HStack(spacing: 6) {
                ForEach(Sensitivity.allCases) { level in
                    Button { settings.sensitivity = level } label: {
                        Text(level.title)
                            .font(TypeScale.label(11.5))
                            .foregroundStyle(settings.sensitivity == level ? Palette.ink : Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Palette.ink.opacity(settings.sensitivity == level ? 0.08 : 0.025)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().overlay(Palette.edge)

            VStack(spacing: 2) {
                MenuRow("Open AutoShield", detail: "\(engine.snapshot.analyses) checked today") { Windows.shared.show(.main) }
                
                if !engine.status.tapLive && permissions.allGranted {
                    // Only offered when macOS is withholding the keyboard,
                    // which is the one case a relaunch actually fixes.
                    MenuRow("Restart Shield", detail: nil) { Relauncher.restart() }
                }
                MenuRow("Quit", detail: nil) { NSApp.terminate(nil) }
            }
        }
        .padding(15)
        .frame(width: 290)
    }

    private var headline: String {
        if engine.held != nil { return "Message caught" }
        if !permissions.allGranted { return "Needs permission" }
        if !settings.sendShieldEnabled { return "Send Shield is off" }
        return "Watching"
    }

    private var subline: String {
        if let reason = engine.status.suspendedReason { return reason }
        if let app = engine.status.watching { return "Reading \(app)" }
        if permissions.allGranted { return "No text field in focus" }
        return "Turn both on to start"
    }
}

private struct MenuToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }

    var body: some View {
        HStack {
            Text(title)
                .font(TypeScale.body(13))
                .foregroundStyle(Palette.ink)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct MenuRow: View {
    let title: String
    let detail: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, detail: String?, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(TypeScale.body(13))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(TypeScale.mono(10))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Palette.ink.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
