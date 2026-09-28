import Foundation

/// Rewrites a caught draft so it keeps the point and drops the cruelty.
///
/// This is the other half of the pause. Telling someone their message lands
/// badly is only useful if they have somewhere to go next, and most people who
/// stop to rewrite end up saying nothing at all.
public final class Rephraser: @unchecked Sendable {

    public enum Failure: Error, Sendable {
        case noKey
        case quotaExhausted
        case transport(String)
        case refused
    }

    private let apiKey: String?
    private let model: String
    private let limiter: RateLimiter
    private let session: URLSession

    public init(apiKey: String? = GeminiConfig.loadAPIKey(),
                model: String = GeminiConfig.loadModel(),
                limiter: RateLimiter? = nil) {
        self.apiKey = apiKey
        self.model = model
        let limits = GeminiConfig.loadLimits()
        self.limiter = limiter ?? RateLimiter(
            perMinute: limits.perMinute,
            perDay: limits.perDay,
            storeURL: Paths.support.appendingPathComponent("gemini-quota.json"))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 9
        cfg.timeoutIntervalForResource = 12
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public var isAvailable: Bool { apiKey != nil }

    private static let system = """
    You rewrite a message someone is about to send, keeping what they actually \
    mean and removing what would wound the person reading it.

    Rules:
    - Keep their point. If they are angry, frustrated or disagreeing, the \
      rewrite still says so. Do not turn a complaint into a compliment.
    - Keep their voice: same rough length, same register, same slang level. If \
      they write in lowercase with no punctuation, so do you.
    - Remove insults, slurs, threats, mockery, and anything aimed at who the \
      person is rather than what they did.
    - Never add an apology they did not make. Never add "I feel" therapy \
      phrasing. Never make it longer or more formal than the original.
    - Output only the rewritten message. No quotes, no preamble, no options.
    - If the message is already fine, return it unchanged.
    """

    public func rephrase(_ text: String, context: [String] = []) async throws -> String {
        guard let apiKey else { throw Failure.noKey }
        guard limiter.tryAcquire() else { throw Failure.quotaExhausted }

        var prompt = ""
        if !context.isEmpty {
            prompt += "Conversation so far:\n"
            for line in context.suffix(8) { prompt += "- \(line.prefix(300))\n" }
            prompt += "\n"
        }
        prompt += "Rewrite this message:\n\(text.prefix(2000))"

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Rephraser.system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.4,
                "maxOutputTokens": 400,
                "responseMimeType": "text/plain",
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
            ],
        ]

        var comps = URLComponents(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.transport("no response")
            }
            if http.statusCode == 429 {
                limiter.backOffMinute()
                throw Failure.quotaExhausted
            }
            guard (200..<300).contains(http.statusCode) else {
                limiter.release()
                throw Failure.transport("HTTP \(http.statusCode)")
            }
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = root["candidates"] as? [[String: Any]],
                let first = candidates.first,
                let content = first["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else { throw Failure.refused }

            var out = parts.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Models like to wrap a rewrite in quotes. The field should not get them.
            if out.count > 1, out.hasPrefix("\""), out.hasSuffix("\"") {
                out = String(out.dropFirst().dropLast())
            }
            guard !out.isEmpty else { throw Failure.refused }
            return out
        } catch let e as Failure {
            throw e
        } catch {
            limiter.release()
            throw Failure.transport(error.localizedDescription)
        }
    }
}
