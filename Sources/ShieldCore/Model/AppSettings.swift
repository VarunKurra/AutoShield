import Foundation
import Combine

/// Settings, backed by UserDefaults. Small enough not to need a package for it.
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.sendShield: true,
            Key.inboxShield: false,
            Key.crisisSurface: true,
            Key.contextTier: true,
            Key.sound: true,
            Key.haptics: true,
            Key.sensitivity: Sensitivity.balanced.rawValue,
            Key.onboarded: false,
            Key.shareStats: false,
        ])
    }

    private enum Key {
        static let sendShield = "shield.sendShield"
        static let inboxShield = "shield.inboxShield"
        static let crisisSurface = "shield.crisisSurface"
        static let contextTier = "shield.contextTier"
        static let sound = "shield.sound"
        static let haptics = "shield.haptics"
        static let sensitivity = "shield.sensitivity"
        static let onboarded = "shield.onboarded"
        static let shareStats = "shield.shareStats"
    }

    public var sendShieldEnabled: Bool {
        get { defaults.bool(forKey: Key.sendShield) }
        set { set(Key.sendShield, newValue) }
    }

    public var inboxShieldEnabled: Bool {
        get { defaults.bool(forKey: Key.inboxShield) }
        set { set(Key.inboxShield, newValue) }
    }

    public var crisisSurfaceEnabled: Bool {
        get { defaults.bool(forKey: Key.crisisSurface) }
        set { set(Key.crisisSurface, newValue) }
    }

    /// Off means Shield never sends anything anywhere. Tier 0 and Tier 1 only.
    public var contextTierEnabled: Bool {
        get { defaults.bool(forKey: Key.contextTier) }
        set { set(Key.contextTier, newValue) }
    }

    public var soundEnabled: Bool {
        get { defaults.bool(forKey: Key.sound) }
        set { set(Key.sound, newValue) }
    }

    public var hapticsEnabled: Bool {
        get { defaults.bool(forKey: Key.haptics) }
        set { set(Key.haptics, newValue) }
    }

    public var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: defaults.string(forKey: Key.sensitivity) ?? "") ?? .balanced }
        set { set(Key.sensitivity, newValue.rawValue) }
    }

    /// Anonymous daily totals only. Off until the person turns it on.
    public var shareStatsEnabled: Bool {
        get { defaults.bool(forKey: Key.shareStats) }
        set { set(Key.shareStats, newValue) }
    }

    /// Demo mode: start at the welcome screen on every launch rather than
    /// remembering that setup is done. Flip to false to make onboarding a
    /// once-only thing again.
    public static let alwaysShowOnboarding = true

    public var hasOnboarded: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { set(Key.onboarded, newValue) }
    }

    private func set(_ key: String, _ value: Any) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .shieldSettingsChanged, object: nil)
    }
}

public extension Notification.Name {
    static let shieldSettingsChanged = Notification.Name("shield.settingsChanged")
}
