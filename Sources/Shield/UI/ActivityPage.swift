import SwiftUI
import ShieldCore

/// Everything Shield has done, in the words a person would use.
struct ActivityPage: View {
    @ObservedObject var engine: ShieldEngine
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, outgoing, incoming
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .outgoing: return "Outgoing"
            case .incoming: return "Incoming"
            }
        }
    }

    private var events: [ShieldEvent] {
        switch filter {
        case .all: return engine.events
        case .incoming: return engine.events.filter { $0.kind == .covered }
        case .outgoing: return engine.events.filter { $0.kind != .covered }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Activity", subtitle: subtitle) {
                HStack(spacing: 10) {
                    SegmentedChips(selection: $filter, options: Filter.allCases) { $0.title }
                    if !engine.events.isEmpty {
                        IconButton(symbol: "trash", help: "Clear activity") {
                            engine.clearHistory()
                        }
                    }
                }
            }

            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    Paper(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(events.enumerated()), id: \.element.id) { i, event in
                                if i > 0 {
                                    Rectangle().fill(Palette.edge).frame(height: 1).padding(.leading, 54)
                                }
                                EventRow(event: event)
                            }
                        }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var subtitle: String {
        let n = engine.events.count
        return n == 0 ? "Nothing yet" : (n == 1 ? "1 event" : "\(n) events")
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            TintedIcon("checkmark", tint: Palette.calm, size: 34)
            Text("Nothing to show")
                .font(TypeScale.title(14.5))
                .foregroundStyle(Palette.ink)
            Text("Anything Shield steps in on appears here.")
                .font(TypeScale.body(12.5))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

struct EventRow: View {
    let event: ShieldEvent

    private var tint: Color {
        switch event.kind {
        case .caught, .covered: return Palette.severity(event.score)
        case .rephrased, .sentAnyway: return Palette.accent
        case .edited, .deleted, .resources: return Palette.calm
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            TintedIcon(event.kind.symbol, tint: tint, size: 26).padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayText)
                    .font(TypeScale.body(13))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let rewritten = event.rewritten, !rewritten.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.accent.opacity(0.75))
                            .padding(.top, 3)
                        Text(rewritten)
                            .font(TypeScale.body(12.5))
                            .foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 7) {
                    Text(event.kind.label)
                        .font(TypeScale.label(10))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.13)))

                    if event.kind == .caught || event.kind == .covered {
                        SeverityBar(score: event.score)
                    }

                    if let reason = event.reason, !reason.isEmpty {
                        Text(reason)
                            .font(TypeScale.body(11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(event.at, style: .relative)
                .font(TypeScale.body(11))
                .foregroundStyle(Palette.faint)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// A message about someone's own pain is never quoted back at them.
    private var displayText: String {
        event.kind == .resources ? "Resources offered" : event.text
    }
}

/// Three bars that fill by severity, with the word beside them.
struct SeverityBar: View {
    let score: Double

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i < filled ? Palette.severity(score) : Palette.ink.opacity(0.12))
                        .frame(width: 9, height: 3)
                }
            }
            Text(Palette.severityLabel(score))
                .font(TypeScale.label(9.5))
                .foregroundStyle(Palette.severity(score))
        }
    }

    private var filled: Int {
        if score < 0.55 { return 1 }
        if score < 0.78 { return 2 }
        return 3
    }
}
