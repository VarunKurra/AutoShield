import SwiftUI
import AppKit
import ShieldCore

/// The crisis surface.
///
/// It offers and never acts. Nothing is sent anywhere, nothing is logged off
/// this machine, nothing is blocked or delayed. It appears once per message,
/// dismisses on one click, and is silent — no tone, no haptic, no alarm colour.
struct CrisisPanelView: View {
    var incoming: Bool
    var onDismiss: () -> Void

    @State private var arrived = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(incoming ? CrisisResources.incomingHeadline : CrisisResources.headline)
                    .font(TypeScale.title(15))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(CrisisResources.items) { item in
                    Button {
                        if let url = item.url { openURL(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(TypeScale.emphasis(13))
                                .foregroundStyle(Palette.accent)
                            Text(item.detail)
                                .font(TypeScale.body(12.5))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(CrisisResources.note)
                .font(TypeScale.body(11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.clear)
                .background(VisualEffect(material: .underWindowBackground, blending: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.22), lineWidth: 1)
        )
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : 5)
        .onAppear {
            if Motion.reduceMotion { arrived = true }
            else { withAnimation(Motion.settle) { arrived = true } }
        }
    }
}
