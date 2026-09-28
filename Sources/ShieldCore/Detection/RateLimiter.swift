import Foundation

/// Respects the free tier's per-minute and per-day caps locally, so quota is
/// never discovered by a 429 in the middle of a demo.
public final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var minuteStamps: [Date] = []
    private var dayCount: Int = 0
    private var dayStamp: Date
    private let perMinute: Int
    private let perDay: Int
    private let storeURL: URL

    private struct Persisted: Codable { var day: Date; var count: Int }

    public init(perMinute: Int, perDay: Int, storeURL: URL) {
        self.perMinute = perMinute
        self.perDay = perDay
        self.storeURL = storeURL
        self.dayStamp = Calendar.current.startOfDay(for: Date())
        if let data = try? Data(contentsOf: storeURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data),
           Calendar.current.isDate(p.day, inSameDayAs: Date()) {
            self.dayCount = p.count
            self.dayStamp = p.day
        }
    }

    public var remainingToday: Int {
        lock.lock(); defer { lock.unlock() }
        rolloverLocked()
        return max(0, perDay - dayCount)
    }

    public var dailyBudget: Int { perDay }

    public var remainingThisMinute: Int {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return max(0, perMinute - minuteStamps.count)
    }

    /// Takes a slot if one is free. Returns false rather than waiting; the
    /// caller falls back to the cheaper tier immediately.
    public func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        rolloverLocked()
        pruneLocked()
        guard dayCount < perDay, minuteStamps.count < perMinute else { return false }
        dayCount += 1
        minuteStamps.append(Date())
        persistLocked()
        return true
    }

    /// Hands a slot back when a request never went out.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        if dayCount > 0 { dayCount -= 1 }
        if !minuteStamps.isEmpty { minuteStamps.removeLast() }
        persistLocked()
    }

    /// Called when Google itself says no. Burns the rest of the minute.
    public func backOffMinute() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        minuteStamps = Array(repeating: now, count: perMinute)
    }

    public func resetDay() {
        lock.lock(); defer { lock.unlock() }
        dayCount = 0
        dayStamp = Calendar.current.startOfDay(for: Date())
        persistLocked()
    }

    private func pruneLocked() {
        let cutoff = Date().addingTimeInterval(-60)
        minuteStamps.removeAll { $0 < cutoff }
    }

    private func rolloverLocked() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != dayStamp {
            dayStamp = today
            dayCount = 0
            persistLocked()
        }
    }

    private func persistLocked() {
        let p = Persisted(day: dayStamp, count: dayCount)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
