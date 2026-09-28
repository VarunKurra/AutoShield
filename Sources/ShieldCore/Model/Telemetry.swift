import Foundation

/// Plain Codable to disk. Counts only — never message text.
public struct TelemetrySnapshot: Codable, Sendable, Equatable {
    public var day: Date = Calendar.current.startOfDay(for: Date())
    public var analyses: Int = 0
    public var perTier: [Int: Int] = [:]
    public var escalations: Int = 0
    public var holds: Int = 0
    public var sentAnyway: Int = 0
    public var edited: Int = 0
    public var deleted: Int = 0
    /// Incoming messages Shield put behind glass.
    public var covered: Int = 0
    public var latencySumMs: [Int: Double] = [:]

    public init() {}

    public init(day: Date) { self.day = day }

    public func count(_ t: Tier) -> Int { perTier[t.rawValue] ?? 0 }

    public func averageLatency(_ t: Tier) -> Double {
        let n = count(t)
        guard n > 0 else { return 0 }
        return (latencySumMs[t.rawValue] ?? 0) / Double(n)
    }

    public func share(_ t: Tier) -> Double {
        guard analyses > 0 else { return 0 }
        return Double(count(t)) / Double(analyses)
    }
}

/// Small enough that a database would be a joke.
public final class TelemetryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: TelemetrySnapshot
    private let url: URL
    private var dirty = false
    private var flushTimer: DispatchSourceTimer?

    public init(url: URL = Paths.support.appendingPathComponent("telemetry.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(TelemetrySnapshot.self, from: data),
           Calendar.current.isDate(s.day, inSameDayAs: Date()) {
            snapshot = s
        } else {
            snapshot = TelemetrySnapshot()
        }
        startFlushing()
    }

    deinit { flushTimer?.cancel(); flush() }

    public var current: TelemetrySnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func record(_ trace: Trace) {
        lock.lock()
        rolloverLocked()
        snapshot.analyses += 1
        snapshot.perTier[trace.tier.rawValue, default: 0] += 1
        snapshot.latencySumMs[trace.tier.rawValue, default: 0] += trace.latencyMs
        if trace.escalated { snapshot.escalations += 1 }
        dirty = true
        lock.unlock()
    }

    public func recordHold() { bump { $0.holds += 1 } }
    public func recordSentAnyway() { bump { $0.sentAnyway += 1 } }
    public func recordEdited() { bump { $0.edited += 1 } }
    public func recordDeleted() { bump { $0.deleted += 1 } }
    public func recordCovered() { bump { $0.covered += 1 } }

    public func reset() {
        lock.lock()
        snapshot = TelemetrySnapshot()
        dirty = true
        lock.unlock()
        flush()
    }

    private func bump(_ body: (inout TelemetrySnapshot) -> Void) {
        lock.lock(); rolloverLocked(); body(&snapshot); dirty = true; lock.unlock()
    }

    private func rolloverLocked() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != snapshot.day { snapshot = TelemetrySnapshot(day: today) }
    }

    private func startFlushing() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shield.telemetry"))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        flushTimer = t
    }

    public func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let s = snapshot
        dirty = false
        lock.unlock()
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
