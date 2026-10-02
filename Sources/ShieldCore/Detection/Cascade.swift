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

    /// Scores at or above this at tier 0 need nobody else's opinion.
    private static let rulesDecisive = 0.85
    /// The band where the local tiers are not convincing either way.
    private static let uncertainLow = 0.30
    private static let uncertainHigh = 0.80
    /// How odd the shape has to look before context is worth a request.
    private static let ambiguityGate = 0.42
    /// Model confidence that counts as a strong opinion.
    private static let modelStrong = 0.90

    /// The verdict without the network: rules, with the on-device model as a
    /// second opinion. Synchronous and around a millisecond, so it is safe on
    /// the keystroke path, and it is what the live catch and the Return key
    /// decide on.
    ///
    /// The model never holds a message on its own. It was trained on public
    /// corpora that do not sound like a group chat, and on its own it reads
    /// "you have to try this ramen" as an attack. It may only push a score the
    /// rules already found borderline over the line, and flag addressed text
    /// for the context tier.
    public func localVerdict(_ text: String, context ctx: [String] = []) -> (verdict: Verdict, report: RuleReport, model: Double) {
        let report = rules.evaluate(text, context: ctx)
        var verdict = report.verdict
        if verdict.selfDirected || report.trivial || verdict.score >= Cascade.rulesDecisive {
            return (verdict, report, 0)
        }
        let m = onDevice.score(text)
        verdict.modelScore = m.score
        let affectionate = report.hits.contains("affectionate")
        let quoted = report.hits.contains("quoted")
        // "shut up" is as often delight as dismissal; the model cannot tell.
        let weakOnly = report.hits.allSatisfy { $0 == "phrase:shut up" || $0.hasPrefix("profanity:") }
        // The old bag-of-words model may push a borderline score over the
        // line. The transformer is too sure of itself on teasing for that;
        // its borderline cases go to review below instead.
        if !onDevice.isTransformer, !affectionate, !quoted, !weakOnly, report.addressed,
           verdict.score >= 0.35, verdict.score < 0.66, m.score >= Cascade.modelStrong {
            verdict.score = 0.66
            verdict.tier = .onDevice
            verdict.confidence = max(verdict.confidence, m.confidence)
            if verdict.categories.isEmpty { verdict.categories = [.insult] }
        } else {
            verdict.confidence = max(verdict.confidence, m.confidence * 0.8)
        }
        // The rules missed it and the transformer is sure. Ask the context
        // tier; if there is no context tier to ask, trust the transformer.
        if !affectionate, !quoted, report.addressed, verdict.score < 0.62,
           m.score >= Cascade.modelStrong, onDevice.isTransformer {
            if contextReachable {
                verdict.pendingReview = true
            } else {
                Cascade.applyOfflineFallback(&verdict)
            }
        }
        verdict.level = Tier0Rules.level(for: verdict.score)
        verdict.latencyMs = report.verdict.latencyMs + m.latencyMs
        return (verdict, report, m.score)
    }

    /// True when a context-tier request could be made right now.
    public var contextReachable: Bool {
        contextEnabled && context.isAvailable && context.status.remainingToday > 0
    }

    /// With no context tier to ask, a transformer this sure holds on its own
    /// at Attentive only. Alone it cannot tell "you guys are crazy" from an
    /// attack (it scores both near 1.0), so Light and Balanced wait for a
    /// second opinion that is not coming, and let the message go.
    public static func applyOfflineFallback(_ v: inout Verdict) {
        v.pendingReview = false
        guard v.modelScore >= 0.98 else { return }
        v.score = max(v.score, 0.5)
        v.tier = .onDevice
        if v.categories.isEmpty { v.categories = [.insult] }
        v.level = Tier0Rules.level(for: v.score)
    }

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

        let (verdict, report, model) = localVerdict(text, context: ctx)

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

        // A banned word is a banned word; there is nothing for context to add.
        let wordPolicy = verdict.categories.contains(.profanity) || verdict.categories.contains(.explicit)
        let uncertain = !wordPolicy && verdict.score > Cascade.uncertainLow && verdict.score < Cascade.uncertainHigh
        let shapeOdd = report.ambiguity >= Cascade.ambiguityGate
        let modelSuspects = verdict.pendingReview || (report.addressed && model >= Cascade.modelStrong)
        let wantsContext = allowContext && contextEnabled && self.context.isAvailable
            && (uncertain || shapeOdd || modelSuspects)

        guard wantsContext else {
            var verdict = verdict
            // Not reviewed this time (context not allowed on this pass): do
            // not cache a verdict that is still waiting for review.
            if verdict.pendingReview && allowContext { Cascade.applyOfflineFallback(&verdict) }
            if !verdict.pendingReview { cache.set(key, verdict) }
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
            // Quota gone, offline, malformed — keep the local verdict, and if
            // it was waiting on review, let the transformer decide.
            var verdict = verdict
            if verdict.pendingReview { Cascade.applyOfflineFallback(&verdict) }
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

    /// Context wins, because it is the only tier that read the conversation.
    private func merge(context c: Verdict, fallback f: Verdict) -> Verdict {
        var out = c
        out.tier = .context
        out.categories = c.categories.isEmpty ? f.categories : c.categories
        // Explicit abuse the rules already caught cannot be talked down.
        if f.score >= 0.85 { out.score = max(out.score, f.score) }
        // Nor can a word the policy bans: swearing and explicit language are
        // judged by the word, and no reading of the conversation changes that.
        if f.categories.contains(.profanity) || f.categories.contains(.explicit) {
            out.score = max(out.score, f.score)
            out.categories = Array(Set(out.categories).union(f.categories)).sorted { $0.rawValue < $1.rawValue }
        }
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
