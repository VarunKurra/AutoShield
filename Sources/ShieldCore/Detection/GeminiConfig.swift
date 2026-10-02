import Foundation

/// Where the Gemini key comes from, and the one place the model name lives.
public enum GeminiConfig {

    /// Swap this to change models. Verified against ai.google.dev/gemini-api/docs/models
    /// on 2026-09-23; `gemini-3.5-flash-lite` is the newer sibling if you want it.
    public static let defaultModel = "gemini-3.1-flash-lite"

    /// Free-tier shape as published for Flash-Lite. Both are conservative on
    /// purpose: running out mid-demo has to degrade, never error.
    /// Google's free tier cuts off well before 28 a minute and answers 429,
    /// which the old default hit in ordinary use. Staying under it keeps the
    /// context tier answering.
    public static let defaultRequestsPerMinute = 12
    public static let defaultRequestsPerDay = 480

    public static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shield/config.json")
    }

    public struct FileConfig: Decodable {
        public var geminiAPIKey: String?
        public var model: String?
        public var requestsPerMinute: Int?
        public var requestsPerDay: Int?
        public var supabaseURL: String?
        public var supabaseAnonKey: String?
    }

    /// Environment first, then `~/.config/shield/config.json`. Never the repo.
    public static func loadAPIKey() -> String? {
        for name in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "SHIELD_GEMINI_API_KEY"] {
            if let v = ProcessInfo.processInfo.environment[name],
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fileConfig()?.geminiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static func fileConfig() -> FileConfig? {
        guard let data = try? Data(contentsOf: configFileURL) else { return nil }
        return try? JSONDecoder().decode(FileConfig.self, from: data)
    }

    public static func loadModel() -> String {
        ProcessInfo.processInfo.environment["SHIELD_GEMINI_MODEL"]?.nilIfEmpty
            ?? fileConfig()?.model?.nilIfEmpty
            ?? defaultModel
    }

    public static func loadLimits() -> (perMinute: Int, perDay: Int) {
        let c = fileConfig()
        return (c?.requestsPerMinute ?? defaultRequestsPerMinute,
                c?.requestsPerDay ?? defaultRequestsPerDay)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
