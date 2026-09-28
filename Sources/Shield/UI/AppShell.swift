import SwiftUI
import AppKit
import ShieldCore

/// The application proper: a sidebar and a content area, one window.
///
/// Settings and the Monitor used to be separate windows, which meant opening
/// Settings was a one-way trip with no way back to anything. They are pages
/// now, and the sidebar is always there.
struct AppShell: View {
    @ObservedObject var engine: ShieldEngine
    var replayOnboarding: () -> Void

    @State private var page: Page = .protection
    @ObservedObject private var passcode = Passcode.shared

    /// Derived, never stored. A flag saying "ask for the code" can fall out of
    /// step with the page it was set for; a rule that reads the current page
    /// cannot. Settings is unreadable while this is true, by construction.
    private var mustUnlock: Bool { page == .settings && passcode.isLocked }

    enum Page: String, CaseIterable, Identifiable {
        case protection, activity, monitor, settings, crisis
        var id: String { rawValue }

        /// Crisis sits on its own at the bottom, away from the everyday pages.
        static let primary: [Page] = [.protection, .activity, .monitor, .settings]

        var title: String {
            switch self {
            case .protection: return "Protection"
            case .activity:   return "Activity"
            case .monitor:    return "Monitor"
            case .settings:   return "Settings"
            case .crisis:     return "Get help"
            }
        }

        var symbol: String {
            switch self {
            case .protection: return "shield.fill"
            case .activity:   return "list.bullet"
            case .monitor:    return "waveform"
            case .settings:   return "gearshape.fill"
            case .crisis:     return "lifepreserver"
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Palette.edge).frame(width: 1)
                // Without this the row only claims the width its content
                // wants, so the whole shell gets centred: a blank column
                // appears to the left of the sidebar and the sidebar slides
                // every time a page with a different natural width loads.
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface)

            if mustUnlock {
                PasscodeSheet(
                    mode: .unlock,
                    // Verifying flips `unlocked`, which makes `mustUnlock`
                    // false and dismisses this on its own.
                    onSubmit: { passcode.verify($0) },
                    onCancel: { page = .protection })
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.respectful(Motion.quick), value: mustUnlock)
        .onAppear {
            // Entering the app always starts locked. Setting a passcode
            // authorises the session that set it, which is exactly the session
            // that then hands the machine over, so that authority is dropped
            // here rather than relying on every setup path to remember.
            Passcode.shared.lock()
        }
    }

    /// Settings is behind the passcode; everything else is open.
    /// Deliberately not animated. Cross-fading two pages shows both at once,
    /// which reads as the next page flashing before the current one leaves.
    private func select(_ next: Page) {
        // Walking away from Settings ends the authority to be in it.
        if page == .settings, next != .settings { passcode.lock() }
        page = next
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AppMark(size: 26)
                Text("AutoShield")
                    .font(TypeScale.title(15))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 16)
            .padding(.top, 46)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Page.primary) { item in
                    NavItem(page: item,
                            selected: page == item,
                            locked: item == .settings && passcode.isLocked,
                            badge: item == .activity ? engine.events.count : 0,
                            tint: Palette.accent) {
                        select(item)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Always in the same place, always findable, never competing with
            // the everyday pages for attention.
            CrisisNavItem(selected: page == .crisis) { select(.crisis) }
                .padding(.horizontal, 10)
                .padding(.bottom, 34)
        }
        .frame(width: 196)
        .background(Palette.sunken)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        Group {
            switch page {
            case .protection:
                ProtectionPage(engine: engine, replayOnboarding: replayOnboarding)
            case .activity:
                ActivityPage(engine: engine)
            case .monitor:
                MonitorView(engine: engine)
            case .settings:
                SettingsView(engine: engine)
            case .crisis:
                CrisisPage(engine: engine)
            }
        }
        // Settings is legible only once the code is in.
        .blur(radius: mustUnlock ? 16 : 0)
        .disabled(mustUnlock)
        .animation(Motion.respectful(Motion.settle), value: mustUnlock)
    }
}

// MARK: - Sidebar pieces

private struct NavItem: View {
    let page: AppShell.Page
    let selected: Bool
    let locked: Bool
    let badge: Int
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selected ? tint : (tint == Palette.cruel ? tint.opacity(0.85) : Palette.muted))
                    .frame(width: 16)
                Text(page.title)
                    .font(TypeScale.emphasis(13))
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                Spacer(minLength: 4)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
                if badge > 0 {
                    Text("\(min(badge, 99))")
                        .font(TypeScale.mono(9.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Palette.ink.opacity(0.07)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.raised
                          : (hovering ? Palette.ink.opacity(0.045) : .clear))
                    .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 4, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
    }
}

/// Outlined rather than filled, so it reads as the one different thing in the
/// list without shouting over the pages someone uses every day.
private struct CrisisNavItem: View {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "lifepreserver")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 16)
                Text("Get help")
                    .font(TypeScale.emphasis(13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.cruel)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.cruel.opacity(selected ? 0.13 : (hovering ? 0.07 : 0.03))))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.cruel.opacity(selected ? 0.75 : 0.45),
                                  lineWidth: selected ? 1.75 : 1.25))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
    }
}

// MARK: - Shared page chrome

/// A pill group. The stock segmented control is a 2014 artefact next to
/// everything else on the page, so this is drawn instead.
struct SegmentedChips<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let active = option == selection
                Button {
                    withAnimation(Motion.respectful(Motion.quick)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(TypeScale.emphasis(12))
                        .foregroundStyle(active ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? Palette.raised : .clear)
                                .shadow(color: .black.opacity(active ? 0.07 : 0), radius: 3, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.sunken)
        )
    }
}

/// A quiet square icon button for secondary actions.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Palette.sunken : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
    }
}

/// Every page gets the same header, so they read as one application.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TypeScale.display(22))
                    .foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(TypeScale.body(12.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            trailing
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 44)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
