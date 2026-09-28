import Foundation
import CryptoKit

/// The six digits that stop AutoShield being switched off by whoever it is
/// protecting.
///
/// Stored as a salted SHA-256 digest, never as the digits themselves, so
/// reading the preference file gives you nothing usable. A determined person
/// with the machine can still delete the preference and start over; this is a
/// speed bump for a teenager, not a defence against an attacker, and the
/// settings screen says so rather than implying otherwise.
public final class Passcode: ObservableObject, @unchecked Sendable {
    public static let shared = Passcode()

    private let defaults: UserDefaults
    private enum Key {
        static let digest = "shield.passcode.digest"
        static let salt = "shield.passcode.salt"
    }

    /// True once this session has proved it knows the code. Reset on quit.
    @Published public private(set) var unlocked = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let length = 6

    public var isSet: Bool {
        defaults.string(forKey: Key.digest) != nil
    }

    /// Nothing to unlock when no code was ever set.
    public var isLocked: Bool { isSet && !unlocked }

    public func set(_ code: String) {
        guard code.count == Passcode.length else { return }
        let salt = UUID().uuidString
        defaults.set(salt, forKey: Key.salt)
        defaults.set(Passcode.digest(code, salt: salt), forKey: Key.digest)
        unlocked = true
    }

    public func verify(_ code: String) -> Bool {
        guard let stored = defaults.string(forKey: Key.digest),
              let salt = defaults.string(forKey: Key.salt) else { return false }
        let ok = Passcode.digest(code, salt: salt) == stored
        if ok { unlocked = true }
        return ok
    }

    /// Re-locks without forgetting the code. Used when the window closes.
    public func lock() { unlocked = false }

    public func clear() {
        defaults.removeObject(forKey: Key.digest)
        defaults.removeObject(forKey: Key.salt)
        unlocked = false
    }

    /// The stored pair, for syncing. Never the digits.
    public var storedDigest: (digest: String, salt: String)? {
        guard let d = defaults.string(forKey: Key.digest),
              let s = defaults.string(forKey: Key.salt) else { return nil }
        return (d, s)
    }

    private static func digest(_ code: String, salt: String) -> String {
        let data = Data((salt + ":" + code).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
