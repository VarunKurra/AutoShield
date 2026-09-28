import Foundation

/// Everything the rule tier learned about a draft. The cascade reads more of
/// this than the `Verdict` alone carries, because the interesting decision is
/// not "is this bad" but "do I know enough to stop here".
public struct RuleReport: Sendable {
    public var verdict: Verdict
    /// 0...1. High means the surface looks innocent but the shape does not,
    /// which is precisely when the context tier earns its cost.
    public var ambiguity: Double
    /// True when nothing in the text suggests a person is being addressed at all.
    public var trivial: Bool
    public var hits: [String]
}

public struct Tier0Rules: Analyzer {
    public let tier: Tier = .rules

    public init() {}

    public func analyze(_ text: String, context: [String]) async -> Verdict {
        evaluate(text, context: context).verdict
    }

    // Sarcasm and minimisation markers. Individually meaningless, jointly loud.
    private static let sarcasmMarkers = PhraseSet([
        "actually", "for once", "finally", "wow", "oh wow", "congrats",
        "congratulations", "sure jan", "okay then", "ok then", "cool story",
        "must be nice", "good luck with that", "how original", "groundbreaking",
        "riveting", "fascinating", "shocking", "who would have guessed",
        "what a surprise", "never would have guessed", "of course you",
        "typical", "classic", "as always", "every time",
    ])

    private static let evaluativeSet: Set<String> = [
        "try", "tried", "trying", "attempt", "effort", "finally", "manage",
        "managed", "actually", "surprisingly", "somehow",
    ]

    public func evaluate(_ text: String, context: [String] = []) -> RuleReport {
        let started = DispatchTime.now()
        let n = Normalizer.normalize(text)

        guard !n.plain.isEmpty else {
            return RuleReport(verdict: Verdict(confidence: 1, tier: .rules, latencyMs: elapsed(started)),
                              ambiguity: 0, trivial: true, hits: [])
        }

        var score = 0.0
        var categories = Set<Category>()
        var hits: [String] = []
        var confidence = 0.45

        let second = n.hasAnyWord(Lexicon.secondPersonSet)
        let first = n.hasAnyWord(Lexicon.firstPersonSet)
        let quoting = Lexicon.negatorSet.anyMatch(in: n)

        // --- Distress runs first and on its own wire. -------------------------
        let selfHarm = Lexicon.selfHarm.matches(in: n)
        let softDistress = Lexicon.distress.matches(in: n)
        let distressPresent = !selfHarm.isEmpty || !softDistress.isEmpty
        // Distress only counts as the writer's own when they are talking about
        // themselves and not aiming anything at someone else.
        let selfDirected = distressPresent && first && !second

        // --- Telling someone to die. -----------------------------------------
        let lethal = Lexicon.lethal.matches(in: n)
        if !lethal.isEmpty {
            score = max(score, 0.97)
            categories.insert(.harassment)
            categories.insert(.threat)
            confidence = 0.97
            hits.append(contentsOf: lethal.map { "lethal:\($0)" })
        }

        // --- Slurs. -----------------------------------------------------------
        let slurs = n.words(in: Lexicon.slurSet)
        if !slurs.isEmpty {
            score = max(score, second ? 0.94 : 0.86)
            categories.insert(.slur)
            confidence = max(confidence, 0.94)
            hits.append(contentsOf: slurs.map { "slur:\($0)" })
        }

        // --- Threats. ---------------------------------------------------------
        let threats = Lexicon.threats.matches(in: n)
        if !threats.isEmpty {
            score = max(score, second ? 0.86 : 0.72)
            categories.insert(.threat)
            confidence = max(confidence, 0.85)
            hits.append(contentsOf: threats.map { "threat:\($0)" })
        }

        // --- Profanity aimed at a person. -------------------------------------
        let aimed = Lexicon.aimedProfanity.matches(in: n)
        if !aimed.isEmpty {
            score = max(score, 0.80)
            categories.insert(.insult)
            confidence = max(confidence, 0.88)
            hits.append(contentsOf: aimed.map { "aimed:\($0)" })
        }

        // --- Degradation. Vocabulary matters far less than aim. ----------------
        //
        // A harsh word sharing a sentence with "you" is not the same as a
        // harsh word pointed at you. Requiring proximity is what separates
        // "you are an idiot" from "you should see this idiotic bug", and
        // scoring on mere presence is what made Shield stop ordinary
        // complaints about software, weather and homework.
        //
        // Aim is judged once per sentence, not once per word: "you are a
        // worthless pathetic loser" is a single predicate, and only the first
        // adjective sits next to the pronoun. Scoring each word separately
        // made a pile of insults read weaker than one.
        let degrading = n.words(in: Lexicon.degradingSet)
        let aimedDegrading = degrading.contains(where: { n.isAimed($0) }) ? degrading : []
        if !aimedDegrading.isEmpty {
            let base = 0.30 + 0.12 * Double(min(aimedDegrading.count - 1, 3))
            score = max(score, min(base * 2.1, 0.90))
            categories.insert(.insult)
            confidence = max(confidence, 0.80)
            hits.append(contentsOf: aimedDegrading.map { "degrade:\($0)" })
        } else if !degrading.isEmpty {
            // Present but not pointed at anyone. Worth noticing, not holding.
            score = max(score, 0.18)
            hits.append(contentsOf: degrading.map { "degrade-unaimed:\($0)" })
        }

        let profanity = n.words(in: Lexicon.profanitySet)
        let aimedProfanityWords = profanity.contains(where: { n.isAimed($0, window: 2) })
            ? profanity : []
        if !aimedProfanityWords.isEmpty {
            let base = 0.20 + 0.09 * Double(min(aimedProfanityWords.count - 1, 3))
            score = max(score, min(base * 2.2, 0.78))
            categories.insert(.insult)
            confidence = max(confidence, 0.62)
            hits.append(contentsOf: aimedProfanityWords.map { "profanity:\($0)" })
        } else if !profanity.isEmpty {
            // Swearing is not cruelty. Most of it is punctuation.
            score = max(score, 0.12)
            hits.append(contentsOf: profanity.map { "profanity-unaimed:\($0)" })
        }

        // --- Relational aggression. -------------------------------------------
        let exclusion = Lexicon.exclusion.matches(in: n)
        if !exclusion.isEmpty {
            let base = 0.52 + 0.09 * Double(min(exclusion.count - 1, 2))
            score = max(score, min(base + (second ? 0.08 : 0), 0.80))
            categories.insert(.exclusion)
            confidence = max(confidence, 0.58)
            hits.append(contentsOf: exclusion.map { "exclusion:\($0)" })
        }

        let backhanded = Lexicon.backhanded.matches(in: n)
        if !backhanded.isEmpty {
            score = max(score, min(0.40 + 0.10 * Double(min(backhanded.count - 1, 2)), 0.66))
            categories.insert(.backhanded)
            hits.append(contentsOf: backhanded.map { "backhanded:\($0)" })
        }

        let mockery = Lexicon.mockery.matches(in: n)
        if !mockery.isEmpty {
            score = max(score, min(0.28 + 0.08 * Double(min(mockery.count - 1, 3)), 0.58))
            categories.insert(.sarcasm)
            hits.append(contentsOf: mockery.map { "mockery:\($0)" })
        }

        // --- Pile-on: the same jab arriving from several directions. -----------
        if let pile = pileOnBoost(text: n, context: context) {
            score = max(score, pile)
            categories.insert(.pileOn)
            confidence = max(confidence, 0.70)
            hits.append("pile-on:context")
        }

        // --- Quoting and refusing pull the score back down. --------------------
        if quoting && score > 0 {
            score *= 0.35
            confidence = min(confidence, 0.45)
            hits.append("quoted")
        }

        // --- Ambiguity: the reason the context tier exists. --------------------
        var ambiguity = 0.0
        if score < 0.85 {
            let sarcasmCount = Tier0Rules.sarcasmMarkers.count(in: n)
            let evaluativeCount = n.words(in: Tier0Rules.evaluativeSet).count
            if second { ambiguity += 0.22 }
            if sarcasmCount > 0 { ambiguity += min(0.30, 0.16 * Double(sarcasmCount)) }
            if evaluativeCount > 0 { ambiguity += min(0.22, 0.12 * Double(evaluativeCount)) }
            if !backhanded.isEmpty { ambiguity += 0.30 }
            if !exclusion.isEmpty { ambiguity += 0.18 }
            if !mockery.isEmpty { ambiguity += 0.18 }
            if context.count >= 2 { ambiguity += 0.12 }
            if n.plain.hasSuffix("...") || n.plain.contains(" lol") { ambiguity += 0.10 }
            ambiguity = min(ambiguity, 1.0)
        }

        let trivial = hits.isEmpty && !second && ambiguity < 0.15 && n.tokens.count <= 40

        var verdict = Verdict(
            level: Tier0Rules.level(for: score),
            score: score,
            confidence: confidence,
            tier: .rules,
            latencyMs: elapsed(started),
            rationale: nil,
            categories: categories.sorted { $0.rawValue < $1.rawValue },
            distress: distressPresent ? .present : .none,
            selfDirected: selfDirected
        )

        // Someone describing their own pain is never held. This is enforced
        // again in the cascade and once more in HoldPolicy; three locks, on purpose.
        if selfDirected && categories.isDisjoint(with: [.threat, .slur]) {
            verdict.score = min(verdict.score, 0.15)
            verdict.level = .clear
            verdict.confidence = 0.9
            hits.append("self-directed")
        }

        if !selfHarm.isEmpty { hits.append(contentsOf: selfHarm.prefix(2).map { "distress:\($0)" }) }
        else if !softDistress.isEmpty { hits.append(contentsOf: softDistress.prefix(2).map { "distress:\($0)" }) }

        return RuleReport(verdict: verdict, ambiguity: ambiguity, trivial: trivial, hits: hits)
    }

    /// Three people landing on the same line inside one short window reads very
    /// differently from one person saying it once.
    private func pileOnBoost(text: Normalized, context: [String]) -> Double? {
        guard context.count >= 2 else { return nil }
        let draftTokens = Set(text.tokens.filter { $0.count > 2 })
        guard !draftTokens.isEmpty else { return nil }

        var echoes = 0
        for msg in context.suffix(6) {
            let t = Set(Normalizer.normalize(msg).tokens.filter { $0.count > 2 })
            guard !t.isEmpty else { continue }
            let overlap = Double(draftTokens.intersection(t).count)
            let jaccard = overlap / Double(draftTokens.union(t).count)
            if jaccard >= 0.45 { echoes += 1 }
        }
        guard echoes >= 2 else { return nil }
        return min(0.58 + 0.10 * Double(echoes), 0.82)
    }

    static func level(for score: Double) -> Level {
        if score >= 0.70 { return .harmful }
        if score >= 0.35 { return .borderline }
        return .clear
    }

    private func elapsed(_ t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000.0
    }
}
