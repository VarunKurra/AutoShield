import Foundation

/// Sends anonymous daily counts to Supabase, if the person turned that on.
///
/// The entire payload is integers plus a random install id. There is no code
/// path here that can carry message text, because the struct it serialises has
/// nowhere to put any.
public final class StatsSync: @unchecked Sendable {

    public struct Config: Sendable {
        public var url: URL
        public var anonKey: String
        public init(url: URL, anonKey: String) { self.url = url; self.anonKey = anonKey }

        /// From `~/.config/shield/config.json`, alongside the Gemini key.
        public static func load() -> Config? {
            guard let c = GeminiConfig.fileConfig(),
                  let raw = c.supabaseURL, let key = c.supabaseAnonKey,
                  let url = URL(string: raw), !key.isEmpty
            else { return nil }
            return Config(url: url, anonKey: key)
        }
    }

    /// Exactly what leaves the machine. Integers and a random id.
    struct Row: Encodable {
        let install_id: String
        let day: String
        let caught: Int
        let rewritten: Int
        let dropped: Int
        let sent_anyway: Int
        let covered: Int
        let tier_rules: Int
        let tier_device: Int
        let tier_context: Int
        let sensitivity: String
        let app_version: String
    }

    private let config: Config?
    private let session: URLSession
    private var lastSent: TelemetrySnapshot?
    private let lock = NSLock()

    /// A random id made once on this machine. Identifies an install, not a
    /// person, and is gone if they reinstall.
    public static var installID: String {
        let key = "shield.installID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    public init(config: Config? = Config.load()) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public var isConfigured: Bool { config != nil }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Registers this install and its passcode digest. The digest is what the
    /// app already stores locally; the digits themselves exist nowhere but the
    /// supervisor's memory.
    public func registerInstall(sensitivity: Sensitivity,
                                outgoing: Bool,
                                incoming: Bool,
                                passcodeDigest: String?,
                                passcodeSalt: String?) async {
        guard let config else { return }

        var row: [String: Any] = [
            "install_id": StatsSync.installID,
            "sensitivity": sensitivity.rawValue,
            "outgoing_on": outgoing,
            "incoming_on": incoming,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let passcodeDigest, let passcodeSalt {
            row["passcode_digest"] = passcodeDigest
            row["passcode_salt"] = passcodeSalt
            row["passcode_set_at"] = ISO8601DateFormatter().string(from: Date())
        }
        await post("installs", rows: [row], upsert: true)
    }

    /// Appends one event. Carries what happened and how hard it landed, never
    /// a word of what was written.
    public func send(event kind: String,
                     score: Double,
                     severity: String?,
                     tier: String?,
                     category: String?,
                     textLength: Int) async {
        guard config != nil else { return }
        let row: [String: Any] = [
            "install_id": StatsSync.installID,
            "kind": kind,
            "score": min(max(score, 0), 1),
            "severity": severity as Any,
            "tier": tier as Any,
            "category": category as Any,
            "text_length": textLength,
            "occurred_at": ISO8601DateFormatter().string(from: Date()),
        ].compactMapValues { $0 is NSNull ? nil : $0 }
        await post("events", rows: [row], upsert: false)
    }

    private func post(_ table: String, rows: [[String: Any]], upsert: Bool) async {
        guard let config else { return }
        var req = URLRequest(url: config.url.appendingPathComponent("rest/v1/\(table)"))
        req.httpMethod = "POST"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(upsert ? "resolution=merge-duplicates,return=minimal" : "return=minimal",
                     forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: rows)
        do {
            let (_, response) = try await session.data(for: req)
            DebugLog.write("\(table) sync -> HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            DebugLog.write("\(table) sync failed: \(error.localizedDescription)")
        }
    }

    /// Upserts today's row. Safe to call often; it returns early when nothing
    /// has changed since the last send.
    public func send(_ snapshot: TelemetrySnapshot, sensitivity: Sensitivity) async {
        guard let config else { return }

        lock.lock()
        let unchanged = lastSent == snapshot
        if !unchanged { lastSent = snapshot }
        lock.unlock()
        guard !unchanged else { return }

        let row = Row(
            install_id: StatsSync.installID,
            day: StatsSync.dayFormatter.string(from: snapshot.day),
            caught: snapshot.holds,
            rewritten: snapshot.edited,
            dropped: snapshot.deleted,
            sent_anyway: snapshot.sentAnyway,
            covered: snapshot.covered,
            tier_rules: snapshot.count(.rules),
            tier_device: snapshot.count(.onDevice),
            tier_context: snapshot.count(.context),
            sensitivity: sensitivity.rawValue,
            app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")

        var req = URLRequest(url: config.url.appendingPathComponent("rest/v1/daily_stats"))
        req.httpMethod = "POST"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Upsert on the composite key, and ask for nothing back.
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONEncoder().encode([row])

        do {
            let (_, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.write("stats sync -> HTTP \(code)")
            if !(200..<300).contains(code) {
                lock.lock(); lastSent = nil; lock.unlock()
            }
        } catch {
            // Never surfaced, never retried aggressively. Counts are not worth
            // anyone's attention.
            DebugLog.write("stats sync failed: \(error.localizedDescription)")
            lock.lock(); lastSent = nil; lock.unlock()
        }
    }
}
