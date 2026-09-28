import Foundation

public struct Fixture: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var note: String
    /// "hold", "pass" or "offer" — what a correct run should do.
    public var expect: String
    public var context: [String]
    public var draft: String
}

public enum Fixtures {
    private struct File: Codable { var version: Int; var cases: [Fixture] }

    public static let all: [Fixture] = {
        guard let url = ShieldResources.url("fixtures", "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.cases
    }()

    public static func expectationMet(_ fixture: Fixture, verdict: Verdict, sensitivity: Sensitivity) -> Bool {
        let held = HoldPolicy.shouldHold(verdict, sensitivity: sensitivity)
        switch fixture.expect {
        case "hold": return held
        case "pass": return !held
        case "offer": return !held && verdict.distress == .present
        default: return false
        }
    }
}

/// The single place that turns a verdict into a hold. Both the composer and
/// the rehearsal harness go through it, so they cannot disagree.
public enum HoldPolicy {
    public static func shouldHold(_ v: Verdict, sensitivity: Sensitivity) -> Bool {
        // A person describing their own pain is never held. First rule, no exceptions.
        if v.selfDirected { return false }
        guard v.level >= sensitivity.minimumLevel else { return false }
        return v.score >= sensitivity.holdThreshold
    }
}
