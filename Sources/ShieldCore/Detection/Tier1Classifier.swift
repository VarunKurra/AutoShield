import Foundation
import CoreML
import NaturalLanguage

/// Tier 1: on-device machine learning. Local, free, nothing leaves the machine.
///
/// Prefers the transformer (`ShieldTier1T`, a BERT fine-tuned by
/// `Tools/finetune_tier1.py` to recognise cruelty aimed at a person, running on
/// the Neural Engine). Falls back to the older bag-of-words classifier
/// (`ShieldTier1`), and then to a small lexical stand-in, so the app always runs.
public final class Tier1Classifier: Analyzer, @unchecked Sendable {
    public let tier: Tier = .onDevice

    private let model: NLModel?
    private var transformer: MLModel?
    private var tokenizer: WordPiece?
    private let lock = NSLock()
    public let isModelLoaded: Bool
    /// True once the transformer, not the fallback, is answering. The
    /// transformer can take several seconds to load the first time (Core ML
    /// compiles it for the Neural Engine), so the app loads it in the
    /// background and uses the fallback until then.
    public var isTransformer: Bool { lock.lock(); defer { lock.unlock() }; return transformer != nil }
    public var modelDescription: String { isTransformer ? "transformer" : fallbackDescription }
    private let fallbackDescription: String

    static let sequenceLength = 64

    /// `background: true` returns at once and loads the transformer off the
    /// calling thread. Tools that need it immediately leave it false.
    public init(modelURL: URL? = Tier1Classifier.bundledModelURL(),
                transformerURL: URL? = Tier1Classifier.bundledTransformerURL(),
                vocabURL: URL? = ShieldResources.url("ShieldTier1T.vocab", "txt"),
                background: Bool = false) {
        if let url = modelURL, let ml = try? MLModel(contentsOf: url), let nl = try? NLModel(mlModel: ml) {
            self.model = nl
            self.isModelLoaded = true
            self.fallbackDescription = url.deletingPathExtension().lastPathComponent
        } else {
            self.model = nil
            self.isModelLoaded = transformerURL != nil
            self.fallbackDescription = "lexical fallback"
        }
        guard let t = transformerURL, let v = vocabURL else { return }
        let load = { [weak self] in
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            guard let ml = try? MLModel(contentsOf: t, configuration: cfg), let tok = WordPiece(vocabURL: v) else { return }
            // One throwaway prediction pays the first-run cost here, not on
            // someone's keystroke.
            guard let self else { return }
            self.lock.lock()
            self.transformer = ml
            self.tokenizer = tok
            self.lock.unlock()
            _ = self.score("warm up")
        }
        if background {
            DispatchQueue.global(qos: .utility).async(execute: load)
        } else {
            load()
        }
    }

    public static func bundledModelURL() -> URL? {
        ShieldResources.url("ShieldTier1", "mlmodelc")
    }

    public static func bundledTransformerURL() -> URL? {
        ShieldResources.url("ShieldTier1T", "mlmodelc")
    }

    /// The transformer's raw probability, for tools that check parity.
    public func transformerProbability(ids: [Int32], mask: [Int32]) -> Double? {
        guard let transformer = currentTransformer() else { return nil }
        let n = Tier1Classifier.sequenceLength
        guard let idArr = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32),
              let maskArr = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32) else { return nil }
        for i in 0..<n {
            idArr[i] = NSNumber(value: ids[i])
            maskArr[i] = NSNumber(value: mask[i])
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idArr),
            "attention_mask": MLFeatureValue(multiArray: maskArr)]),
              let out = try? transformer.prediction(from: input),
              let harm = out.featureValue(for: "harm")?.multiArrayValue else { return nil }
        return harm[0].doubleValue
    }

    public func encode(_ text: String) -> (ids: [Int32], mask: [Int32])? {
        currentTokenizer()?.encode(text, length: Tier1Classifier.sequenceLength)
    }

    private func currentTransformer() -> MLModel? { lock.lock(); defer { lock.unlock() }; return transformer }
    private func currentTokenizer() -> WordPiece? { lock.lock(); defer { lock.unlock() }; return tokenizer }

    /// Core ML predictions are run one at a time.
    private let predictLock = NSLock()

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
        if let tokenizer = currentTokenizer() {
            // The transformer reads the text as written; its tokenizer does
            // its own lowercasing, and normalising first would erase the
            // casing and punctuation it learned from.
            let (ids, mask) = tokenizer.encode(trimmed, length: Tier1Classifier.sequenceLength)
            predictLock.lock()
            var p = transformerProbability(ids: ids, mask: mask)
            // Disguised spelling ("l0ser", "f*ck") reads as noise to the
            // model, so the de-disguised text gets a second look.
            let disguised = trimmed.contains { "*#%@$0134578".contains($0) }
            let plain = disguised ? Normalizer.normalize(trimmed).plain : ""
            if disguised, plain != trimmed.lowercased(), let current = p {
                let (ids2, mask2) = tokenizer.encode(plain, length: Tier1Classifier.sequenceLength)
                if let p2 = transformerProbability(ids: ids2, mask: mask2) { p = max(current, p2) }
            }
            predictLock.unlock()
            probability = p ?? 0
            source = p == nil ? "fallback" : "transformer"
        } else if let model {
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
