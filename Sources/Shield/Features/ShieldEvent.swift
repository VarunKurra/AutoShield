import Foundation
import ShieldCore

/// Something that actually happened, in the words a person would use.
///
/// Distinct from a `Trace`, which is one scoring pass and exists for the
/// monitor. Typing a sentence produces a dozen traces and at most one event.
///
/// Events live in memory only. Shield writes counts to disk, never text.
struct ShieldEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case caught
        case covered
        case rephrased
        case sentAnyway
        case edited
        case deleted
        case resources

        var label: String {
            switch self {
            case .caught: return "Caught"
            case .covered: return "Covered"
            case .rephrased: return "Rephrased"
            case .sentAnyway: return "Sent anyway"
            case .edited: return "Edited"
            case .deleted: return "Deleted"
            case .resources: return "Showed resources"
            }
        }

        var symbol: String {
            switch self {
            case .caught: return "hand.raised.fill"
            case .covered: return "eye.slash.fill"
            case .rephrased: return "wand.and.sparkles"
            case .sentAnyway: return "paperplane.fill"
            case .edited: return "pencil"
            case .deleted: return "trash.fill"
            case .resources: return "heart.fill"
            }
        }

        /// What the database calls it.
        var wireName: String {
            switch self {
            case .caught: return "caught"
            case .covered: return "covered"
            case .rephrased: return "rephrased"
            case .sentAnyway: return "sent_anyway"
            case .edited: return "edited"
            case .deleted: return "deleted"
            case .resources: return "resources"
            }
        }
    }

    let id = UUID()
    var at = Date()
    var text: String
    var kind: Kind
    /// What it was rewritten to, when it was.
    var rewritten: String?
    /// 0...1, drives the severity colour.
    var score: Double = 0
    /// The one-line reason, when a tier gave one.
    var reason: String?
    var app: String?

    static func == (a: ShieldEvent, b: ShieldEvent) -> Bool { a.id == b.id }
}
