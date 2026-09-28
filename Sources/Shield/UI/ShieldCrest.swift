import SwiftUI
import ShieldCore

/// The centrepiece. Press it to arm or disarm AutoShield.
///
/// Arming runs on a hand-driven clock rather than a single `withAnimation`,
/// for two reasons. A declarative animation makes every opacity inside the
/// view inherit its duration, so the icons cross-faded over two seconds and
/// the counter looked like it started at fifty. And a fixed curve climbs too
/// evenly to read as work being done; this one varies its pace.
struct ShieldCrest: View {
    let on: Bool
    let blocked: Bool
    var action: () -> Void

    /// 0 grey, 1 armed. Drives fill, ring and counter from one number.
    @State private var progress: Double = 0
    @State private var halo: Double = 0
    @State private var driver: Timer?
    @State private var hovering = false
    @State private var pressed = false

    private let crestWidth: CGFloat = 172
    private let crestHeight: CGFloat = 207

    /// Held at the size it had when the crest was larger, so shrinking the
    /// shield opens a little air inside the ring rather than pulling it in.
    private let ringSize: CGFloat = 303
    private var canvas: CGFloat { ringSize + 46 }

    private let armDuration: Double = 2.6

    /// One source of truth for the middle, so an open lock and a closed lock
    /// can never be on screen together however fast the button is hit.
    private enum Centre { case open, counting, locked }
    private var centre: Centre {
        if progress <= 0.001 { return .open }
        if progress >= 0.999 { return .locked }
        return .counting
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                halos
                ring
                crest
                centrepiece
            }
            .frame(width: canvas, height: canvas)
            .scaleEffect(pressed ? 0.972 : (hovering ? 1.012 : 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .onHover { h in withAnimation(Motion.respectful(Motion.quick)) { hovering = h } }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(Motion.respectful(Motion.quick)) { pressed = true } } }
                .onEnded { _ in withAnimation(Motion.respectful(Motion.quick)) { pressed = false } }
        )
        .onAppear { settle(on) }
        .onChange(of: on) { _, next in animate(to: next) }
        .onDisappear { driver?.invalidate(); driver = nil }
        .accessibilityLabel(on ? "Protection on" : "Protection off")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityHint("Press to turn protection \(on ? "off" : "on")")
    }

    // MARK: Layers

    private var halos: some View {
        ZStack {
            Circle()
                .fill(Palette.accent.opacity(0.10 * halo))
                .frame(width: canvas, height: canvas)
                .scaleEffect(0.88 + 0.12 * halo)
            Circle()
                .fill(Palette.accent.opacity(0.12 * halo))
                .frame(width: ringSize + 16, height: ringSize + 16)
                .scaleEffect(0.93 + 0.07 * halo)
        }
        .blur(radius: 14)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.edge, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [Palette.accent, Palette.accentLift, Palette.accent]),
                        center: .center),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: ringSize, height: ringSize)
    }

    private var crest: some View {
        ZStack {
            ShieldShape()
                .fill(Palette.sunken)
                .overlay(ShieldShape().strokeBorder(Palette.edge, lineWidth: 1.5))

            ShieldShape()
                .fill(LinearGradient(colors: [Palette.accentLift, Palette.accent],
                                     startPoint: .top, endPoint: .bottom))
                .mask(
                    VStack(spacing: 0) {
                        Color.clear.frame(height: crestHeight * (1 - progress))
                        Rectangle()
                    }
                )
                .overlay(ShieldShape().strokeBorder(Palette.accent.opacity(progress), lineWidth: 1.5))
                .shadow(color: Palette.accent.opacity(0.32 * progress), radius: 24, y: 8)
        }
        .frame(width: crestWidth, height: crestHeight)
    }

    @ViewBuilder
    private var centrepiece: some View {
        ZStack {
            switch centre {
            case .open:
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .counting:
                PercentLabel(value: progress)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            case .locked:
                Image(systemName: "lock.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .offset(y: -8)
        // Short and local, so it never inherits the long arming timeline.
        .animation(Motion.respectful(.spring(response: 0.3, dampingFraction: 0.7)), value: centre)
    }

    // MARK: Choreography

    private func settle(_ on: Bool) {
        driver?.invalidate(); driver = nil
        progress = on ? 1 : 0
        halo = on ? 1 : 0
    }

    private func animate(to on: Bool) {
        driver?.invalidate(); driver = nil

        guard !Motion.reduceMotion else { settle(on); return }

        guard on else {
            // Disarming drains, quickly, from wherever it happens to be.
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { halo = 0 }
            withAnimation(.easeInOut(duration: 0.4)) { progress = 0 }
            return
        }

        withAnimation(.easeOut(duration: 0.2)) { halo = 0 }

        // Hand-driven so the counter is genuinely live and the pace can vary.
        // Real work is not evenly paced, and a perfectly linear bar reads as
        // decoration. This surges and eases without ever going backwards.
        let start = Date()
        let from = progress
        var wobble = Double.random(in: 0...(.pi * 2))

        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(start)
            let t = min(elapsed / armDuration, 1)

            // Ease-in-out as the spine, plus a slow sine that speeds up and
            // slows down along the way. Clamped so it is always monotonic.
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            wobble += 0.055
            let drift = sin(wobble) * 0.022 * (1 - t)
            let value = min(max(eased + drift, 0), 1)

            MainActor.assumeIsolated {
                progress = max(progress, from + (1 - from) * value)
                if t >= 1 {
                    progress = 1
                    timer.invalidate()
                    driver = nil
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.68)) { halo = 1 }
                }
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        driver = tick
    }
}

/// Text that follows the driver frame by frame.
private struct PercentLabel: View {
    var value: Double

    var body: some View {
        VStack(spacing: 0) {
            Text("\(Int((value * 100).rounded()))")
                .font(TypeScale.display(42))
                .foregroundStyle(value > 0.42 ? .white : Palette.ink)
                .monospacedDigit()
            Text("%")
                .font(TypeScale.label(12))
                .foregroundStyle(value > 0.42 ? .white.opacity(0.8) : Palette.muted)
        }
        .shadow(color: .black.opacity(value > 0.42 ? 0.16 : 0), radius: 1, y: 1)
    }
}

/// A shield outline drawn rather than borrowed, so it scales cleanly and the
/// mask has a real path to clip against.
struct ShieldShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> ShieldShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        let w = r.width, h = r.height
        let x = r.minX, y = r.minY

        p.move(to: CGPoint(x: x + w * 0.5, y: y))
        p.addLine(to: CGPoint(x: x + w, y: y + h * 0.18))
        p.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h),
                   control1: CGPoint(x: x + w, y: y + h * 0.67),
                   control2: CGPoint(x: x + w * 0.80, y: y + h * 0.93))
        p.addCurve(to: CGPoint(x: x, y: y + h * 0.18),
                   control1: CGPoint(x: x + w * 0.20, y: y + h * 0.93),
                   control2: CGPoint(x: x, y: y + h * 0.67))
        p.closeSubpath()
        return p
    }
}
