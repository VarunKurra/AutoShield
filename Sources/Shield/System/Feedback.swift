import AppKit
import AVFoundation
import ShieldCore

/// The catch you hear before you understand it.
///
/// Both tones are bundled rather than borrowed from the system, because system
/// sounds arrive carrying meanings the user already has — and none of those
/// meanings is "a hand on your arm".
enum Feedback {

    private static var catchPlayer: AVAudioPlayer?
    private static var revealPlayer: AVAudioPlayer?
    private static var prepared = false

    static func prepare() {
        guard !prepared else { return }
        prepared = true
        catchPlayer = load("catch")
        revealPlayer = load("reveal")
        DebugLog.write("audio: catch=\(catchPlayer != nil) reveal=\(revealPlayer != nil) systemUI=\(systemUISoundsOn)")
    }

    private static func load(_ name: String) -> AVAudioPlayer? {
        guard let url = ShieldResources.url(name, "wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.volume = name == "catch" ? 0.85 : 0.5
        p.prepareToPlay()
        return p
    }

    /// Honours the system's "play user interface sound effects" preference as
    /// well as Shield's own toggle.
    private static var systemUISoundsOn: Bool {
        guard let v = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.sound.uiaudio.enabled"] as? Bool
        else { return true }
        return v
    }

    static func catchHappened() {
        prepare()
        if AppSettings.shared.soundEnabled && systemUISoundsOn {
            catchPlayer?.currentTime = 0
            let played = catchPlayer?.play() ?? false
            DebugLog.write("catch tone played=\(played)")
        } else {
            DebugLog.write("catch tone suppressed: setting=\(AppSettings.shared.soundEnabled) systemUI=\(systemUISoundsOn)")
        }
        if AppSettings.shared.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    static func revealHappened() {
        prepare()
        if AppSettings.shared.soundEnabled && systemUISoundsOn {
            revealPlayer?.currentTime = 0
            revealPlayer?.play()
        }
        if AppSettings.shared.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// For the settings screen, so the tone can be auditioned deliberately.
    static func previewCatch() {
        prepare()
        catchPlayer?.currentTime = 0
        catchPlayer?.play()
    }
}
