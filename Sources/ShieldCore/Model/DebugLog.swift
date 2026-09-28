import Foundation

/// Instrumentation for the catch path, written to a file rather than stdout,
/// because Shield is a GUI process with nowhere to print. Off unless
/// SHIELD_DEBUG is set in the environment.
public enum DebugLog {
    /// Environment variable, or the presence of a marker file. The marker is
    /// how you turn logging on for a normally launched .app, which inherits no
    /// environment from a shell.
    public static let enabled =
        ProcessInfo.processInfo.environment["SHIELD_DEBUG"] != nil
        || FileManager.default.fileExists(atPath: "/tmp/shield-debug-on")

    private static let url = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["SHIELD_DEBUG_FILE"] ?? "/tmp/shield-debug.log")
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
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(msg.utf8)); try? h.close()
        } else {
            try? msg.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
