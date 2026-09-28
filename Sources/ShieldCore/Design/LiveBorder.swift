import SwiftUI

/// A blue highlight that travels slowly around the window edge.
///
/// Deliberately faint. It is there to say the app is awake, and an ambient
/// effect that draws the eye away from a message someone is deciding whether
/// to send would be working against the product. One thin stroke, one slow
/// revolution, no glow.
public struct LiveBorder: ViewModifier {
    /// Off while protection is off, so the window is visibly inert.
    var active: Bool
    var radius: CGFloat

    @State private var angle: Double = 0

    public init(active: Bool, radius: CGFloat = 10) {
        self.active = active
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(sweep, lineWidth: 4.5)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(Motion.respectful(Motion.settle), value: active)
            }
            .onAppear(perform: spin)
            .onChange(of: active) { _, _ in spin() }
    }

    /// Mostly transparent, with one bright arc that is the thing travelling.
    private var sweep: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Palette.accent.opacity(0.00), location: 0.00),
                .init(color: Palette.accent.opacity(0.22), location: 0.10),
                .init(color: Palette.accentLift, location: 0.19),
                .init(color: Palette.accent.opacity(0.22), location: 0.28),
                .init(color: Palette.accent.opacity(0.00), location: 0.42),
                .init(color: Palette.accent.opacity(0.00), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(angle))
    }

    private func spin() {
        guard active, !Motion.reduceMotion else { return }
        angle = 0
        withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

public extension View {
    /// A slow blue highlight around the window edge while protection is live.
    func liveBorder(active: Bool, radius: CGFloat = 10) -> some View {
        modifier(LiveBorder(active: active, radius: radius))
    }
}
