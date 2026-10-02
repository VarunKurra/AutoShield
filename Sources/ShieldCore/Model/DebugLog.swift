import Foundation

/// A record of what the catch path did, so a bug report can be traced.
///
/// Always on, and never contains message text: lines carry lengths, scores,
/// app names and decisions only. Kept in ~/Library/Logs/AutoShield, rolled
/// over at 512 KB so it never grows. SHIELD_DEBUG_FILE points it elsewhere.
public enum DebugLog {
    public static let enabled = true

    private static let url: URL = {
        if let p = ProcessInfo.processInfo.environment["SHIELD_DEBUG_FILE"] { return URL(fileURLWithPath: p) }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AutoShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shield.log")
    }()
    private static let limit: UInt64 = 512 * 1024
    private static let lock = NSLock()

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private static var lastFocus = ""

    /// Focus changes every 60 ms; only the transitions are worth a line.
    public static func focus(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let l = line()
        lock.lock()
        let changed = l != lastFocus
        if changed { lastFocus = l }
        lock.unlock()
        if changed { write(l) }
    }

    public static func write(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let msg = "\(stamp.string(from: Date()))  \(line())\n"
        lock.lock(); defer { lock.unlock() }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > limit {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(msg.utf8)); try? h.close()
        } else {
            try? msg.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
