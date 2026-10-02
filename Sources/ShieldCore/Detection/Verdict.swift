import Foundation

/// How much outward-directed harm a draft carries.
/// Deliberately not named after enforcement language: Shield holds, it does not judge.
public enum Level: Int, Codable, Sendable, CaseIterable, Comparable {
    case clear = 0
    case borderline = 1
    case harmful = 2

    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .clear: return "clear"
        case .borderline: return "borderline"
        case .harmful: return "harmful"
        }
    }
}

/// Which stage of the cascade produced a verdict.
public enum Tier: Int, Codable, Sendable, CaseIterable {
    case cache = -1
    case rules = 0
    case onDevice = 1
    case context = 2

    public var shortName: String {
        switch self {
        case .cache: return "CACHE"
        case .rules: return "T0"
        case .onDevice: return "T1"
        case .context: return "T2"
        }
    }

    public var displayName: String {
        switch self {
        case .cache: return "Cache"
        case .rules: return "Rules"
        case .onDevice: return "On-device"
        case .context: return "Context"
        }
    }
}

/// The kinds of harm Shield names. Used for the monitor and for prompt design,
/// never shown to the person as an accusation.
public enum Category: String, Codable, Sendable, CaseIterable {
    case insult
    case slur
    case threat
    case harassment
    case exclusion
    case sarcasm
    case backhanded
    case pileOn
    case codedLanguage
    /// Swearing, judged by word rather than by aim. See `Lexicon`.
    case profanity
    /// Sexual or explicit language. Blocked at every sensitivity.
    case explicit

    public var display: String {
        switch self {
        case .insult: return "insult"
        case .slur: return "slur"
        case .threat: return "veiled threat"
        case .harassment: return "harassment"
        case .exclusion: return "exclusion"
        case .sarcasm: return "sarcasm"
        case .backhanded: return "backhanded"
        case .pileOn: return "pile-on"
        case .codedLanguage: return "coded language"
        case .profanity: return "swearing"
        case .explicit: return "explicit"
        }
    }
}

/// Distress runs on its own path. It never feeds the hold decision.
public enum Distress: Int, Codable, Sendable {
    case none = 0
    case present = 1
}

public struct Verdict: Codable, Sendable, Equatable {
    public var level: Level
    /// 0...1 estimate of outward-directed harm.
    public var score: Double
    public var confidence: Double
    public var tier: Tier
    public var latencyMs: Double
    public var rationale: String?
    public var categories: [Category]
    /// Set on its own path; see `CrisisRouter`. Never raises `level`.
    public var distress: Distress
    /// True when the harmful language points at the writer rather than another person.
    public var selfDirected: Bool
    /// The on-device transformer thinks this attacks someone but the rules
    /// found nothing. Not held on that alone: the context tier reads it first,
    /// because the transformer cannot tell teasing between friends from the
    /// real thing. In memory only.
    public var pendingReview: Bool = false
    /// The transformer's probability, kept for the offline fallback.
    public var modelScore: Double = 0

    private enum CodingKeys: String, CodingKey {
        case level, score, confidence, tier, latencyMs, rationale, categories, distress, selfDirected
    }

    public init(level: Level = .clear,
                score: Double = 0,
                confidence: Double = 1,
                tier: Tier = .rules,
                latencyMs: Double = 0,
                rationale: String? = nil,
                categories: [Category] = [],
                distress: Distress = .none,
                selfDirected: Bool = false) {
        self.level = level
        self.score = score
        self.confidence = confidence
        self.tier = tier
        self.latencyMs = latencyMs
        self.rationale = rationale
        self.categories = categories
        self.distress = distress
        self.selfDirected = selfDirected
    }

    public static let clear = Verdict()

    /// The most serious thing the verdict found, for one-line explanations.
    /// Categories are stored sorted by name, so "first" would be alphabetical.
    public var primaryCategory: Category? {
        let order: [Category] = [.threat, .harassment, .slur, .explicit, .insult, .exclusion,
                                 .pileOn, .backhanded, .sarcasm, .codedLanguage, .profanity]
        return order.first { categories.contains($0) }
    }
}

/// One interface, three tiers. Tiers swap without touching UI code.
public protocol Analyzer: Sendable {
    var tier: Tier { get }
    func analyze(_ text: String, context: [String]) async -> Verdict
}

public enum Sensitivity: String, Codable, Sendable, CaseIterable, Identifiable {
    case light
    case balanced
    case attentive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .attentive: return "Attentive"
        }
    }

    public var detail: String {
        switch self {
        case .light: return "Clearly cruel"
        case .balanced: return "Cruel and pointed"
        case .attentive: return "Sarcasm too"
        }
    }

    /// Score at or above which a draft is held.
    public var holdThreshold: Double {
        switch self {
        case .light: return 0.80
        case .balanced: return 0.62
        case .attentive: return 0.45
        }
    }

    /// Minimum level that can ever be held.
    public var minimumLevel: Level {
        switch self {
        case .light: return .harmful
        // Balanced holds from 0.62, which is borderline territory. Requiring
        // harmful here silently raised its real threshold to 0.70.
        case .balanced: return .borderline
        case .attentive: return .borderline
        }
    }
}
