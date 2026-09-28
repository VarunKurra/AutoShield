import SwiftUI
import AppKit
import CoreText

/// Shield's visual language.
///
/// Warm paper rather than grey chrome, because this app shows up at the worst
/// moment of someone's day and cool interfaces read as institutional. Terracotta
/// carries every action; the severity ramp is the only other colour that means
/// anything, and it stays warm at the low end so a caught message never looks
/// like a system error.
public enum Palette {

    // MARK: Surfaces

    /// The page. Warm paper, so the app reads as calm rather than clinical.
    public static let surface = dynamic(light: hex(0xF4F3F0), dark: hex(0x141519))
    /// Cards and panels. Pure white in light mode: the contrast against paper
    /// is what makes content feel lifted instead of flat.
    public static let raised = dynamic(light: hex(0xFFFFFF), dark: hex(0x1D1F24))
    /// A recessed well: inputs, previews, the sidebar.
    public static let sunken = dynamic(light: hex(0xECEAE6), dark: hex(0x101114))

    // MARK: Type

    public static let ink = dynamic(light: hex(0x15171C), dark: hex(0xF2F3F5))
    public static let muted = dynamic(light: hex(0x646A75), dark: hex(0x9BA3AF))
    public static let faint = dynamic(light: hex(0x969CA6), dark: hex(0x6B7280))

    // MARK: Lines

    public static let edge = dynamic(light: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.10),
                                     dark: NSColor(white: 1, alpha: 0.10))

    // MARK: Meaning

    /// Every action Shield offers.
    public static let accent = dynamic(light: hex(0x1A6FF2), dark: hex(0x6BA6FF))
    /// A lighter partner for gradients, so a button has depth rather than fill.
    public static let accentLift = dynamic(light: hex(0x3B93FC), dark: hex(0x93C2FF))
    /// Fine, sent, allowed through.
    public static let calm = dynamic(light: hex(0x0E9C68), dark: hex(0x3DD68C))

    // The severity ramp.
    public static let sharp = dynamic(light: hex(0xE0A016), dark: hex(0xF5C24D))
    public static let harsh = dynamic(light: hex(0xEE7A24), dark: hex(0xFF9B55))
    public static let cruel = dynamic(light: hex(0xDC3B30), dark: hex(0xFF6B5E))

    /// Kept as an alias so older call sites read the same.
    public static var hold: Color { harsh }

    public static func severity(_ score: Double) -> Color {
        let s = min(max(score, 0), 1)
        if s < 0.55 { return sharp }
        if s < 0.78 { return harsh }
        return cruel
    }

    /// Plain words for the same thing. Colour never carries meaning alone.
    public static func severityLabel(_ score: Double) -> String {
        let s = min(max(score, 0), 1)
        if s < 0.55 { return "Sharp" }
        if s < 0.78 { return "Harsh" }
        return "Cruel"
    }

    // MARK: Plumbing

    public static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: Double((v >> 16) & 0xFF) / 255,
                green: Double((v >> 8) & 0xFF) / 255,
                blue: Double(v & 0xFF) / 255,
                alpha: 1)
    }
}

public enum Typeface {
    private static var registered = false

    /// Bundled rather than assumed. Falls back to the system face silently.
    public static func register() {
        guard !registered else { return }
        registered = true
        let names = ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold",
                     "GeistMono-Regular", "GeistMono-Medium"]
        for name in names {
            guard let url = ShieldResources.url(name, "otf")
                ?? ShieldResources.url(name, "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// One family, one scale.
///
/// Geist throughout. An earlier pass used a serif for headings; it read as
/// decorative rather than clear, which is the opposite of what this app needs.
/// Monospace appears in exactly one place, the Monitor, where it encodes
/// instrumentation.
public enum TypeScale {
    public static func display(_ size: CGFloat = 25) -> Font { sans(size, .semibold, tracking: -0.5) }
    public static func headline(_ size: CGFloat = 17) -> Font { sans(size, .semibold, tracking: -0.3) }
    public static func title(_ size: CGFloat = 14) -> Font { sans(size, .semibold, tracking: -0.15) }
    public static func body(_ size: CGFloat = 13) -> Font { sans(size, .regular, tracking: 0) }
    public static func emphasis(_ size: CGFloat = 13) -> Font { sans(size, .medium, tracking: 0) }
    public static func label(_ size: CGFloat = 11) -> Font { sans(size, .medium, tracking: 0.35) }
    /// Kept so older call sites read the same.
    public static func serifBody(_ size: CGFloat = 14) -> Font { body(size) }

    public static func mono(_ size: CGFloat = 11, weight: NSFont.Weight = .regular) -> Font {
        if let f = NSFont(name: weight == .medium ? "GeistMono-Medium" : "GeistMono-Regular", size: size) {
            return Font(f as CTFont)
        }
        return .system(size: size, weight: weight == .medium ? .medium : .regular, design: .monospaced)
    }

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight, tracking: CGFloat) -> Font {
        let name: String
        switch weight {
        case .bold: name = "Geist-Bold"
        case .semibold: name = "Geist-SemiBold"
        case .medium: name = "Geist-Medium"
        default: name = "Geist-Regular"
        }
        if let f = NSFont(name: name, size: size) { return Font(f as CTFont) }
        return .system(size: size, weight: swiftUIWeight(weight))
    }

    private static func swiftUIWeight(_ w: NSFont.Weight) -> Font.Weight {
        switch w {
        case .bold, .heavy: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        default: return .regular
        }
    }
}

public enum Metrics {
    public static let gutter: CGFloat = 20
    public static let rowGap: CGFloat = 10
    public static let sectionGap: CGFloat = 26
    public static let radius: CGFloat = 14
    public static let smallRadius: CGFloat = 9
}

public enum Motion {
    public static let arrive = SwiftUI.Animation.spring(response: 0.34, dampingFraction: 0.72)
    public static let settle = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.86)
    public static let quick = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.9)

    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Every animation goes through here so Reduce Motion is honoured once.
    public static func respectful(_ a: SwiftUI.Animation) -> SwiftUI.Animation? {
        reduceMotion ? nil : a
    }
}

// MARK: - Components

/// A tinted tile holding an SF Symbol: saturated gradient, white glyph.
public struct TintedIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    public init(_ symbol: String, tint: Color, size: CGFloat = 28) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.88), tint],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 0.8)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.14), radius: 0.5, y: 0.5)
            )
            .shadow(color: tint.opacity(0.30), radius: size * 0.16, y: size * 0.07)
    }
}

/// The one button on screen the person is meant to press.
public struct PrimaryButton: View {
    let title: String
    let symbol: String?
    let tint: Color
    let wide: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    public init(_ title: String, symbol: String? = nil, tint: Color = Palette.accent,
                wide: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.wide = wide
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(TypeScale.emphasis(13.5))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: wide ? .infinity : nil)
            .padding(.horizontal, wide ? 0 : 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint == Palette.accent ? Palette.accentLift : tint.opacity(0.92), tint],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: tint.opacity(hovering ? 0.42 : 0.30),
                            radius: pressed ? 2 : 10, y: pressed ? 1 : 4)
            )
            .scaleEffect(pressed ? 0.985 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(Motion.respectful(Motion.quick)) { pressed = true } } }
                .onEnded { _ in withAnimation(Motion.respectful(Motion.quick)) { pressed = false } }
        )
    }
}

/// The card everything sits in: paper, hairline, one soft shadow.
public struct Paper<Content: View>: View {
    var padding: CGFloat
    var radius: CGFloat
    @ViewBuilder var content: Content

    public init(padding: CGFloat = 0, radius: CGFloat = Metrics.radius,
                @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.raised)
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.edge, lineWidth: 1)
            )
    }
}

public struct VisualEffect: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blending: NSVisualEffectView.BlendingMode
    public var emphasized: Bool

    public init(material: NSVisualEffectView.Material = .popover,
                blending: NSVisualEffectView.BlendingMode = .behindWindow,
                emphasized: Bool = false) {
        self.material = material
        self.blending = blending
        self.emphasized = emphasized
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }

    public func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
    }
}

public extension View {
    func shieldCard(radius: CGFloat = Metrics.radius) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1)
        )
    }
}
