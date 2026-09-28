import Foundation

/// Where Shield's bundled resources live.
///
/// The app is assembled directly rather than through SwiftPM, so there is no
/// `Bundle.module`. Inside the app that means `Contents/Resources`; for the
/// command line tools it means whatever `SHIELD_RESOURCES` points at.
public enum ShieldResources {

    public static let bundle: Bundle = {
        if let path = ProcessInfo.processInfo.environment["SHIELD_RESOURCES"],
           let b = Bundle(path: path) {
            return b
        }
        return Bundle.main
    }()

    public static func url(_ name: String, _ ext: String) -> URL? {
        if let u = bundle.url(forResource: name, withExtension: ext) { return u }
        // Running straight out of the source tree.
        if let path = ProcessInfo.processInfo.environment["SHIELD_RESOURCES"] {
            let u = URL(fileURLWithPath: path).appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

extension Bundle {
    /// Kept so call sites read the same as they would under SwiftPM.
    static var module: Bundle { ShieldResources.bundle }
}
