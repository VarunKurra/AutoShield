import Foundation

/// Tier 2: the only tier that reads a conversation rather than a sentence.
/// Everything that makes implicit cruelty detectable lives here — and so does
/// the only place text leaves the machine.
public final class Tier2Gemini: Analyzer, @unchecked Sendable {
    public let tier: Tier = .context

    public struct Status: Sendable {
        public var hasKey: Bool
        public var model: String
        public var remainingToday: Int
        public var dailyBudget: Int
        public var lastError: String?
    }

    private let apiKey: String?
    private let model: String
    private let limiter: RateLimiter
    private let session: URLSession
    private let lock = NSLock()
    private var lastError: String?

    public init(apiKey: String? = GeminiConfig.loadAPIKey(),
                model: String = GeminiConfig.loadModel(),
                limiter: RateLimiter? = nil,
                session: URLSession? = nil) {
        self.apiKey = apiKey
        self.model = model
        let limits = GeminiConfig.loadLimits()
        self.limiter = limiter ?? RateLimiter(
            perMinute: limits.perMinute,
            perDay: limits.perDay,
            storeURL: Paths.support.appendingPathComponent("gemini-quota.json"))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: cfg)
    }

    public var isAvailable: Bool { apiKey != nil }

    public var status: Status {
        lock.lock(); let err = lastError; lock.unlock()
        return Status(hasKey: apiKey != nil,
                      model: model,
                      remainingToday: limiter.remainingToday,
                      dailyBudget: limiter.dailyBudget,
                      lastError: err)
    }

    public func analyze(_ text: String, context: [String]) async -> Verdict {
        (try? await request(text, context: context)) ?? Verdict(confidence: 0, tier: .context)
    }

    /// Throws only so the cascade can tell "no answer" from "answered clear".
    public func request(_ text: String, context: [String]) async throws -> Verdict {
        guard let apiKey else { throw GeminiError.noKey }
        guard limiter.tryAcquire() else { throw GeminiError.quotaExhausted }

        let started = DispatchTime.now()
        var released = false
        func releaseSlot() { if !released { limiter.release(); released = true } }

        do {
            var comps = URLComponents(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body(text, context: context))

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw GeminiError.transport("no response") }

            if http.statusCode == 429 {
                limiter.backOffMinute()
                note("rate limited by Google")
                throw GeminiError.quotaExhausted
            }
            guard (200..<300).contains(http.statusCode) else {
                releaseSlot()
                note("HTTP \(http.statusCode)")
                throw GeminiError.transport("HTTP \(http.statusCode)")
            }

            let verdict = try parse(data, latencyMs: elapsed(started))
            note(nil)
            return verdict
        } catch let e as GeminiError {
            if case .quotaExhausted = e {} else { releaseSlot() }
            throw e
        } catch {
            releaseSlot()
            note(error.localizedDescription)
            throw GeminiError.transport(error.localizedDescription)
        }
    }

    // MARK: Request shape

    private static let systemPrompt = """
    You are the context stage of Shield, which pauses a message the writer is about \
    to send when it would land as cruelty on the person receiving it.

    You are not a profanity filter. The earlier stages already catch explicit abuse. \
    You exist for the cruelty that uses no flagged words. Judge the DRAFT, reading \
    the CONVERSATION only as context for what the draft does.

    Weigh these forms of relational aggression:
    - exclusion: marking someone as outside the group, talking around them, \
      "nobody asked", "we all decided", conspicuous freeze-outs
    - sarcasm and mockery whose literal reading is neutral or positive
    - backhanded compliments: praise whose premise is an insult
    - veiled threats in polite vocabulary
    - coded or in-group language whose meaning is hostile to the target
    - pile-on: the draft repeating or joining a jab several people already landed, \
      where one instance would be minor and the repetition is the harm

    Do NOT flag:
    - blunt disagreement, criticism of ideas, or strong opinions about things
    - venting about a situation, or about someone not present, without cruelty
    - friendly teasing that the conversation shows is mutual and welcome
    - the writer describing their own pain, self-hatred, or hopelessness. That is \
      never held. Score it 0 for harm and set self_directed_distress true.

    score: 0.0 means harmless, 1.0 means it will clearly wound the recipient.
    rationale: one sentence, concrete, naming what the draft does. Never address \
    the writer and never moralize. Good: "three people have now repeated the same \
    line at one person inside two minutes". Bad: "this message is inappropriate".
    """

    private static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "score": ["type": "NUMBER"],
            "confidence": ["type": "NUMBER"],
            "categories": [
                "type": "ARRAY",
                "items": ["type": "STRING",
                          "enum": ["insult", "slur", "threat", "harassment", "exclusion",
                                   "sarcasm", "backhanded", "pileOn", "codedLanguage"]],
            ],
            "rationale": ["type": "STRING"],
            "self_directed_distress": ["type": "BOOLEAN"],
        ],
        "required": ["score", "confidence", "categories", "rationale", "self_directed_distress"],
        "propertyOrdering": ["score", "confidence", "categories", "rationale", "self_directed_distress"],
    ]

    private func body(_ text: String, context: [String]) -> [String: Any] {
        var prompt = ""
        if !context.isEmpty {
            prompt += "CONVERSATION (oldest first):\n"
            for line in context.suffix(12) {
                prompt += "- \(line.prefix(400))\n"
            }
            prompt += "\n"
        } else {
            prompt += "CONVERSATION: (none available)\n\n"
        }
        prompt += "DRAFT the writer is about to send:\n\(text.prefix(2000))"

        return [
            "systemInstruction": ["parts": [["text": Tier2Gemini.systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 512,
                "responseMimeType": "application/json",
                "responseSchema": Tier2Gemini.schema,
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
            ],
        ]
    }

    // MARK: Response

    private struct Payload: Decodable {
        var score: Double
        var confidence: Double
        var categories: [String]
        var rationale: String
        var self_directed_distress: Bool
    }

    private func parse(_ data: Data, latencyMs: Double) throws -> Verdict {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw GeminiError.malformed }

        let joined = parts.compactMap { $0["text"] as? String }.joined()
        guard let jsonData = joined.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: jsonData)
        else { throw GeminiError.malformed }

        let score = min(max(payload.score, 0), 1)
        let cats = payload.categories.compactMap(Category.init(rawValue:))
        return Verdict(
            level: Tier0Rules.level(for: score),
            score: payload.self_directed_distress ? 0 : score,
            confidence: min(max(payload.confidence, 0), 1),
            tier: .context,
            latencyMs: latencyMs,
            rationale: payload.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
            categories: cats,
            distress: payload.self_directed_distress ? .present : .none,
            selfDirected: payload.self_directed_distress
        )
    }

    private func note(_ message: String?) {
        lock.lock(); lastError = message; lock.unlock()
    }

    private func elapsed(_ t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000.0
    }
}

public enum GeminiError: Error, Sendable {
    case noKey
    case quotaExhausted
    case transport(String)
    case malformed
}

public enum Paths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shield", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
