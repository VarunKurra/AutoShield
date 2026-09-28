import SwiftUI
import AppKit

/// The app's own mark, used wherever AutoShield refers to itself.
///
/// A bundled image rather than an SF Symbol in a tinted tile, so the icon in
/// the sidebar is the same artwork as the icon in the Dock.
public struct AppMark: View {
    var size: CGFloat
    var dimmed: Bool

    public init(size: CGFloat = 28, dimmed: Bool = false) {
        self.size = size
        self.dimmed = dimmed
    }

    public var body: some View {
        Group {
            if let image = AppMark.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // The bundle is missing its resources; still show something.
                TintedIcon("shield.fill", tint: Palette.accent, size: size)
            }
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.45 : 1)
        .shadow(color: .black.opacity(dimmed ? 0 : 0.14), radius: size * 0.10, y: size * 0.045)
    }

    static let image: NSImage? = {
        guard let url = ShieldResources.url("AppMark", "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
