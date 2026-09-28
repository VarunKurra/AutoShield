import Foundation
import CoreML
import NaturalLanguage

/// Tier 1: a Core ML text classifier trained by `ShieldTrainer`, loaded through
/// `NLModel`. Local, free, single-digit milliseconds, nothing leaves the machine.
///
/// When the model is missing the tier degrades to a small lexical fallback
/// rather than failing, so the app is always runnable.
public final class Tier1Classifier: Analyzer, @unchecked Sendable {
    public let tier: Tier = .onDevice

    private let model: NLModel?
    private let lock = NSLock()
    public let isModelLoaded: Bool
    public let modelDescription: String

    public init(modelURL: URL? = Tier1Classifier.bundledModelURL()) {
        if let url = modelURL, let ml = try? MLModel(contentsOf: url), let nl = try? NLModel(mlModel: ml) {
            self.model = nl
            self.isModelLoaded = true
            self.modelDescription = url.deletingPathExtension().lastPathComponent
        } else {
            self.model = nil
            self.isModelLoaded = false
            self.modelDescription = "lexical fallback"
        }
    }

    public static func bundledModelURL() -> URL? {
        ShieldResources.url("ShieldTier1", "mlmodelc")
    }

    public func analyze(_ text: String, context: [String]) async -> Verdict {
        score(text)
    }

    /// Synchronous because it is genuinely fast and the cascade already runs
    /// off the main thread.
    public func score(_ text: String) -> Verdict {
        let started = DispatchTime.now()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Verdict(confidence: 1, tier: .onDevice, latencyMs: elapsed(started))
        }

        let probability: Double
        var source = "model"
        if let model {
            lock.lock()
            let hypotheses = model.predictedLabelHypotheses(for: normalizedInput(trimmed), maximumCount: 3)
            lock.unlock()
            probability = (hypotheses["harmful"] ?? 0)
        } else {
            source = "fallback"
            probability = Tier1Classifier.lexicalFallback(trimmed)
        }

        // Confidence is distance from the fence, not the probability itself.
        let confidence = min(1.0, abs(probability - 0.5) * 2.0)
        var v = Verdict(
            level: Tier0Rules.level(for: probability),
            score: probability,
            confidence: confidence,
            tier: .onDevice,
            latencyMs: elapsed(started),
            rationale: nil,
            categories: probability >= 0.5 ? [.insult] : []
        )
        if source == "fallback" { v.confidence = min(v.confidence, 0.5) }
        return v
    }

    /// The trainer sees normalized text, so inference must too.
    private func normalizedInput(_ s: String) -> String {
        Normalizer.normalize(s).plain
    }

    /// A deliberately small stand-in so a fresh checkout runs before training.
    static func lexicalFallback(_ text: String) -> Double {
        let n = Normalizer.normalize(text)
        let second = n.hasAnyWord(Lexicon.secondPerson)
        var s = 0.0
        s += 0.30 * Double(min(Lexicon.degradingWords.filter { n.hasWord($0) }.count, 3))
        s += 0.18 * Double(min(Lexicon.profanityWords.filter { n.hasWord($0) }.count, 3))
        s += 0.45 * Double(min(Lexicon.slurWords.filter { n.hasWord($0) }.count, 2))
        if second { s *= 1.5 } else { s *= 0.6 }
        return min(s, 0.99)
    }

    private func elapsed(_ t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000.0
    }
}
