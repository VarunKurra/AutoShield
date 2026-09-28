import SwiftUI
import AppKit
import ShieldCore

/// The instrument panel: where each check landed, how long it took, and what
/// the context tier said when it fired.
///
/// Monospace lives here and nowhere else in the app, because here it genuinely
/// encodes instrumentation rather than decorating a label.
struct MonitorView: View {
    @ObservedObject var engine: ShieldEngine
    @State private var tab: Tab = .live

    enum Tab: String, CaseIterable, Identifiable {
        case live, rehearsal
        var id: String { rawValue }
        var title: String { self == .live ? "Live" : "Rehearsal" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Monitor", subtitle: subtitle) {
                HStack(spacing: 10) {
                    SegmentedChips(selection: $tab, options: Tab.allCases) { $0.title }
                    if tab == .live && !engine.traces.isEmpty {
                        IconButton(symbol: "trash", help: "Clear log") { engine.clearTraces() }
                    }
                }
            }

            ScrollView {
                VStack(spacing: 14) {
                    explainer
                    tiers
                    switch tab {
                    case .live: liveLog
                    case .rehearsal: RehearsalList(engine: engine)
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What the numbers on this page actually mean, said once, in words.
    private var explainer: some View {
        Paper(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Every message you type is checked three times over, cheapest first. Most never get past the first check.")
                    .font(TypeScale.body(13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Step(n: "1", name: "Rules",
                         detail: "Word patterns on this Mac. Instant and free.",
                         tint: Palette.calm)
                    Step(n: "2", name: "This Mac",
                         detail: "A trained model, still on your machine.",
                         tint: Palette.accent)
                    Step(n: "3", name: "Gemini",
                         detail: "Only the unclear ones, read in context.",
                         tint: Palette.severity(0.6))
                }
            }
        }
    }

    private var subtitle: String {
        let s = engine.snapshot
        guard s.analyses > 0 else { return "Nothing checked yet" }
        let pct = s.analyses > 0 ? Int(Double(s.escalations) / Double(s.analyses) * 100) : 0
        return "\(s.analyses) messages checked today · \(pct)% needed Gemini"
    }

    // MARK: Where checks land

    private var tiers: some View {
        Paper(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Which check decided")
                        .font(TypeScale.title(13.5))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(engine.contextAvailable ? Palette.calm : Palette.faint)
                            .frame(width: 5, height: 5)
                        Text(engine.contextAvailable
                             ? "\(engine.quotaRemaining)/\(engine.quotaBudget) Gemini left"
                             : "No Gemini key")
                            .font(TypeScale.mono(10))
                            .foregroundStyle(Palette.muted)
                    }
                }

                VStack(spacing: 11) {
                    TierBar(tier: .rules, label: "Rules", snapshot: engine.snapshot,
                            tint: Palette.calm)
                    TierBar(tier: .onDevice, label: "This Mac", snapshot: engine.snapshot,
                            tint: Palette.accent)
                    TierBar(tier: .context, label: "Gemini", snapshot: engine.snapshot,
                            tint: Palette.severity(0.6))
                    TierBar(tier: .cache, label: "Already seen", snapshot: engine.snapshot,
                            tint: Palette.faint)
                }
            }
        }
    }

    // MARK: Live log

    @ViewBuilder
    private var liveLog: some View {
        if engine.traces.isEmpty {
            Paper(padding: 34) {
                VStack(spacing: 6) {
                    Text("Nothing checked yet")
                        .font(TypeScale.title(14))
                        .foregroundStyle(Palette.ink)
                    Text("Type in any app. Every check lands here as it happens.")
                        .font(TypeScale.body(12.5))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            Paper(padding: 0) {
                VStack(spacing: 0) {
                    // A header row, because six unlabelled columns of numbers
                    // is a puzzle rather than an instrument.
                    HStack(spacing: 14) {
                        Text("WHEN").frame(width: 52, alignment: .leading)
                        Text("CHECKED BY").frame(width: 78, alignment: .leading)
                        Text("SPEED").frame(width: 56, alignment: .trailing)
                        Text("MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("HARM").frame(width: 46, alignment: .trailing)
                    }
                    .font(TypeScale.label(9.5))
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.sunken)

                    ForEach(Array(engine.traces.prefix(60).enumerated()), id: \.element.id) { i, trace in
                        Rectangle().fill(Palette.edge).frame(height: 1)
                        TraceRow(trace: trace)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct Step: View {
    let n: String
    let name: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(n)
                    .font(TypeScale.label(9.5))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(tint))
                Text(name)
                    .font(TypeScale.emphasis(12.5))
                    .foregroundStyle(Palette.ink)
            }
            Text(detail)
                .font(TypeScale.body(11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.sunken))
    }
}

private struct TierBar: View {
    let tier: Tier
    let label: String
    let snapshot: TelemetrySnapshot
    let tint: Color

    var body: some View {
        let share = snapshot.share(tier)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(label)
                    .font(TypeScale.emphasis(12.5))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 84, alignment: .leading)
                Text(snapshot.count(tier) == 0
                     ? "nothing yet"
                     : "\(snapshot.count(tier)) message\(snapshot.count(tier) == 1 ? "" : "s")")
                    .font(TypeScale.body(12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if snapshot.count(tier) > 0 {
                    Text("takes \(TraceRow.speed(snapshot.averageLatency(tier)))")
                        .font(TypeScale.body(11.5))
                        .foregroundStyle(Palette.faint)
                }
                Text(String(format: "%.0f%%", share * 100))
                    .font(TypeScale.emphasis(12.5))
                    .foregroundStyle(share > 0 ? Palette.ink : Palette.faint)
                    .frame(width: 40, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.sunken)
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * share))
                        .animation(Motion.respectful(Motion.settle), value: share)
                }
            }
            .frame(height: 4)
        }
    }
}

private struct TraceRow: View {
    let trace: Trace

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// "now", "12s", "4m". A live log is read in terms of how long ago, not
    /// what o'clock it was.
    private var ago: String {
        let seconds = Int(Date().timeIntervalSince(trace.at))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return TraceRow.clock.string(from: trace.at)
    }

    private var tint: Color {
        trace.score >= 0.35 ? Palette.severity(trace.score) : Palette.faint
    }

    /// Tier codes mean nothing to anyone who has not read the architecture.
    static func tierName(_ tier: Tier) -> String {
        switch tier {
        case .rules:    return "Rules"
        case .onDevice: return "This Mac"
        case .context:  return "Gemini"
        case .cache:    return "Remembered"
        }
    }

    /// Sub-millisecond numbers are noise; what matters is the order of size.
    static func speed(_ ms: Double) -> String {
        if ms < 1 { return "<1 ms" }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        return String(format: "%.1f s", ms / 1000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text(ago)
                    .font(TypeScale.mono(9.5))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 52, alignment: .leading)

                Text(TraceRow.tierName(trace.tier))
                    .font(TypeScale.emphasis(11))
                    .foregroundStyle(trace.tier == .context ? Palette.severity(0.6) : Palette.muted)
                    .frame(width: 78, alignment: .leading)

                Text(TraceRow.speed(trace.latencyMs))
                    .font(TypeScale.mono(9.5))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 56, alignment: .trailing)

                Text(trace.snippet)
                    .font(TypeScale.body(12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if trace.distress {
                    Text("resources")
                        .font(TypeScale.label(9.5))
                        .foregroundStyle(Palette.calm)
                }
                if trace.held {
                    Text("held")
                        .font(TypeScale.label(9.5))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(tint.opacity(0.15)))
                }
                Text(trace.score < 0.05 ? "none" : String(format: "%.0f%%", trace.score * 100))
                    .font(TypeScale.mono(9.5, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 46, alignment: .trailing)
            }

            if let r = trace.rationale, !r.isEmpty {
                Text(r)
                    .font(TypeScale.body(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 202)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Rehearsal

private struct RehearsalList: View {
    @ObservedObject var engine: ShieldEngine
    @State private var results: [String: Verdict] = [:]
    @State private var running: String?
    @State private var runningAll = false

    var body: some View {
        VStack(spacing: 12) {
            Paper(padding: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Fixtures.all.count) test messages")
                            .font(TypeScale.title(13.5))
                            .foregroundStyle(Palette.ink)
                        Text("Cases a word filter would miss entirely")
                            .font(TypeScale.body(11.5))
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if let passed = summary {
                        Text(passed).font(TypeScale.mono(10)).foregroundStyle(Palette.muted)
                    }
                    PrimaryButton(runningAll ? "Running…" : "Run all", symbol: "play.fill") { runAll() }
                }
            }

            Paper(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(Fixtures.all.enumerated()), id: \.element.id) { i, fixture in
                        if i > 0 { Rectangle().fill(Palette.edge).frame(height: 1) }
                        FixtureRow(fixture: fixture,
                                   verdict: results[fixture.id],
                                   running: running == fixture.id,
                                   sensitivity: engine.settings.sensitivity,
                                   run: { run(fixture) },
                                   show: { show(fixture) })
                    }
                }
            }
        }
    }

    private var summary: String? {
        guard !results.isEmpty else { return nil }
        let s = engine.settings.sensitivity
        let done = Fixtures.all.filter { results[$0.id] != nil }
        let ok = done.filter { Fixtures.expectationMet($0, verdict: results[$0.id]!, sensitivity: s) }
        return "\(ok.count)/\(done.count) correct"
    }

    private func run(_ fixture: Fixture) {
        running = fixture.id
        Task {
            results[fixture.id] = await engine.replay(fixture)
            running = nil
        }
    }

    /// Shows the catch exactly as it arrives in the wild.
    private func show(_ fixture: Fixture) {
        guard let v = results[fixture.id],
              HoldPolicy.shouldHold(v, sensitivity: engine.settings.sensitivity) else { return }
        let anchor = NSApp.keyWindow.map {
            CGRect(x: $0.frame.midX - CatchOverlayView.width / 2,
                   y: $0.frame.minY + 40, width: CatchOverlayView.width, height: 1)
        }
        engine.previewHold(fixture.draft, verdict: v, near: anchor)
    }

    private func runAll() {
        runningAll = true
        Task {
            for fixture in Fixtures.all {
                running = fixture.id
                results[fixture.id] = await engine.replay(fixture)
            }
            running = nil
            runningAll = false
        }
    }
}

private struct FixtureRow: View {
    let fixture: Fixture
    let verdict: Verdict?
    let running: Bool
    let sensitivity: Sensitivity
    let run: () -> Void
    let show: () -> Void

    private var held: Bool {
        guard let v = verdict else { return false }
        return HoldPolicy.shouldHold(v, sensitivity: sensitivity)
    }

    private var met: Bool {
        guard let v = verdict else { return false }
        return Fixtures.expectationMet(fixture, verdict: v, sensitivity: sensitivity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(fixture.title)
                    .font(TypeScale.emphasis(13))
                    .foregroundStyle(Palette.ink)
                Text(expectation)
                    .font(TypeScale.label(9.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Palette.sunken))

                Spacer()

                if let v = verdict {
                    Text(v.tier.shortName)
                        .font(TypeScale.mono(10, weight: .medium))
                        .foregroundStyle(v.tier == .context ? Palette.severity(0.6) : Palette.faint)
                    Text(String(format: "%.2f", v.score))
                        .font(TypeScale.mono(10)).foregroundStyle(Palette.muted)
                    Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(met ? Palette.calm : Palette.severity(0.8))
                }

                if held {
                    Button("Show", action: show)
                        .buttonStyle(.plain)
                        .font(TypeScale.label(10.5))
                        .foregroundStyle(Palette.severity(0.8))
                }
                Button(running ? "…" : "Run", action: run)
                    .buttonStyle(.plain)
                    .font(TypeScale.label(10.5))
                    .foregroundStyle(Palette.accent)
                    .disabled(running)
            }

            Text(fixture.draft)
                .font(TypeScale.body(12.5))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let r = verdict?.rationale, !r.isEmpty {
                Text(r)
                    .font(TypeScale.body(12))
                    .foregroundStyle(Palette.severity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(fixture.note)
                    .font(TypeScale.body(11.5))
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var expectation: String {
        switch fixture.expect {
        case "hold": return "catch"
        case "pass": return "let through"
        case "offer": return "offer help"
        default: return fixture.expect
        }
    }
}
