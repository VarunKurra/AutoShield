import Foundation

/// One analysis, as the monitor shows it.
public struct Trace: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID = UUID()
    public var at: Date = Date()
    public var snippet: String
    public var tier: Tier
    public var level: Level
    public var score: Double
    public var latencyMs: Double
    public var rationale: String?
    public var categories: [Category]
    public var escalated: Bool
    public var held: Bool
    public var distress: Bool
    public var source: String

    public init(id: UUID = UUID(), at: Date = Date(), snippet: String, tier: Tier,
                level: Level, score: Double, latencyMs: Double, rationale: String? = nil,
                categories: [Category] = [], escalated: Bool = false, held: Bool = false,
                distress: Bool = false, source: String) {
        self.id = id; self.at = at; self.snippet = snippet; self.tier = tier
        self.level = level; self.score = score; self.latencyMs = latencyMs
        self.rationale = rationale; self.categories = categories
        self.escalated = escalated; self.held = held; self.distress = distress
        self.source = source
    }
}

public struct CascadeResult: Sendable {
    public var verdict: Verdict
    public var trace: Trace
    public var fromCache: Bool
}

/// Routes a draft through rules, then the on-device model, then context —
/// stopping at the first tier that knows enough. Most text never leaves tier 0.
public final class Cascade: @unchecked Sendable {

    public let rules = Tier0Rules()
    public let onDevice: Tier1Classifier
    public let context: Tier2Gemini

    private let cache = VerdictCache(limit: 512)
    private let lock = NSLock()
    private var _contextEnabled: Bool

    /// Called on every completed analysis, on a background queue.
    public var onTrace: (@Sendable (Trace) -> Void)?

    public init(onDevice: Tier1Classifier = Tier1Classifier(),
                context: Tier2Gemini = Tier2Gemini(),
                contextEnabled: Bool = true) {
        self.onDevice = onDevice
        self.context = context
        self._contextEnabled = contextEnabled
    }

    public var contextEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _contextEnabled }
        set { lock.lock(); _contextEnabled = newValue; lock.unlock() }
    }

    /// Scores below this at tier 0 with nothing else interesting stop there.
    private static let rulesDecisive = 0.85
    /// The band where neither cheap tier is convincing.
    private static let uncertainLow = 0.28
    private static let uncertainHigh = 0.74
    /// How odd the shape has to look before context is worth a request.
    private static let ambiguityGate = 0.42

    public func analyze(_ text: String,
                        context ctx: [String] = [],
                        allowContext: Bool = true) async -> CascadeResult {
        let key = VerdictCache.key(text, ctx)
        if let cached = cache.get(key) {
            var v = cached
            let t = v.tier
            v.tier = .cache
            return CascadeResult(verdict: v,
                                 trace: trace(text, v, escalated: false, source: "cached \(t.shortName)"),
                                 fromCache: true)
        }

        let report = rules.evaluate(text, context: ctx)
        var verdict = report.verdict

        // Someone talking about their own pain leaves here, always clear.
        if verdict.selfDirected {
            cache.set(key, verdict)
            return CascadeResult(verdict: verdict,
                                 trace: trace(text, verdict, escalated: false, source: "T0 self-directed"),
                                 fromCache: false)
        }

        if verdict.score >= Cascade.rulesDecisive || report.trivial {
            cache.set(key, verdict)
            let src = report.trivial ? "T0 clear" : "T0 decisive"
            return CascadeResult(verdict: verdict,
                                 trace: trace(text, verdict, escalated: false, source: src),
                                 fromCache: false)
        }

        // Tier 1.
        let t1 = onDevice.score(text)
        verdict = merge(rules: verdict, model: t1)

        let uncertain = verdict.score > Cascade.uncertainLow && verdict.score < Cascade.uncertainHigh
        let shapeOdd = report.ambiguity >= Cascade.ambiguityGate
        let wantsContext = allowContext && contextEnabled && self.context.isAvailable && (uncertain || shapeOdd)

        guard wantsContext else {
            cache.set(key, verdict)
            return CascadeResult(verdict: verdict,
                                 trace: trace(text, verdict, escalated: false, source: "T1 \(onDevice.isModelLoaded ? "model" : "fallback")"),
                                 fromCache: false)
        }

        // Tier 2. Any failure here is silent by design.
        do {
            let t2 = try await self.context.request(text, context: ctx)
            let merged = merge(context: t2, fallback: verdict)
            cache.set(key, merged)
            return CascadeResult(verdict: merged,
                                 trace: trace(text, merged, escalated: true, source: "T2 \(self.context.status.model)"),
                                 fromCache: false)
        } catch {
            // Quota gone, offline, malformed — keep the optimistic verdict.
            cache.set(key, verdict)
            let reason: String
            switch error {
            case GeminiError.quotaExhausted: reason = "T1 (quota spent)"
            case GeminiError.noKey: reason = "T1 (no key)"
            default: reason = "T1 (context unavailable)"
            }
            return CascadeResult(verdict: verdict,
                                 trace: trace(text, verdict, escalated: false, source: reason),
                                 fromCache: false)
        }
    }

    /// Rules never get overruled downward by the model; the model can only
    /// raise a score the rules were unsure about.
    private func merge(rules r: Verdict, model m: Verdict) -> Verdict {
        var out = r
        if m.score > r.score {
            out.score = min(m.score, 0.88)
            out.tier = .onDevice
            out.confidence = max(r.confidence, m.confidence)
            out.categories = Array(Set(r.categories).union(m.categories)).sorted { $0.rawValue < $1.rawValue }
        } else {
            out.confidence = max(r.confidence, m.confidence * 0.8)
            out.tier = r.score > 0 ? .rules : .onDevice
        }
        out.level = Tier0Rules.level(for: out.score)
        out.latencyMs = r.latencyMs + m.latencyMs
        return out
    }

    /// Context wins, because it is the only tier that read the conversation.
    private func merge(context c: Verdict, fallback f: Verdict) -> Verdict {
        var out = c
        out.tier = .context
        out.categories = c.categories.isEmpty ? f.categories : c.categories
        // Explicit abuse the rules already caught cannot be talked down.
        if f.score >= 0.85 { out.score = max(out.score, f.score) }
        out.level = Tier0Rules.level(for: out.score)
        out.latencyMs = f.latencyMs + c.latencyMs
        return out
    }

    private func trace(_ text: String, _ v: Verdict, escalated: Bool, source: String) -> Trace {
        let t = Trace(snippet: String(text.prefix(140)),
                      tier: v.tier,
                      level: v.level,
                      score: v.score,
                      latencyMs: v.latencyMs,
                      rationale: v.rationale,
                      categories: v.categories,
                      escalated: escalated,
                      held: false,
                      distress: v.distress == .present,
                      source: source)
        onTrace?(t)
        return t
    }

    public func clearCache() { cache.removeAll() }
}

/// Content-addressed so the Return handler is a dictionary lookup.
final class VerdictCache: @unchecked Sendable {
    private var store: [Int: Verdict] = [:]
    private var order: [Int] = []
    private let limit: Int
    private let lock = NSLock()

    init(limit: Int) { self.limit = limit }

    static func key(_ text: String, _ context: [String]) -> Int {
        var h = Hasher()
        h.combine(text)
        for c in context.suffix(12) { h.combine(c) }
        return h.finalize()
    }

    func get(_ k: Int) -> Verdict? {
        lock.lock(); defer { lock.unlock() }
        return store[k]
    }

    func set(_ k: Int, _ v: Verdict) {
        lock.lock(); defer { lock.unlock() }
        if store[k] == nil {
            order.append(k)
            if order.count > limit {
                let drop = order.removeFirst()
                store.removeValue(forKey: drop)
            }
        }
        store[k] = v
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(); order.removeAll()
    }
}
