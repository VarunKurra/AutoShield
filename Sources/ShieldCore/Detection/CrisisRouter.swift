import Foundation

/// The crisis path. It offers and never acts.
///
/// Nothing here contacts anyone, logs anywhere off the machine, or blocks a
/// send. It decides one thing: whether to put resources on screen once.
public final class CrisisRouter: @unchecked Sendable {
    private var seen = Set<Int>()
    private let lock = NSLock()

    public init() {}

    public struct Offer: Sendable, Equatable {
        /// True when the language is the writer's own, false when it arrived
        /// from someone else. Only the copy differs.
        public var incoming: Bool
    }

    /// Returns an offer at most once per distinct message.
    public func consider(_ verdict: Verdict, text: String, incoming: Bool = false) -> Offer? {
        guard verdict.distress == .present else { return nil }
        let key = Normalizer.normalize(text).squashed.hashValue
        lock.lock(); defer { lock.unlock() }
        guard !seen.contains(key) else { return nil }
        seen.insert(key)
        if seen.count > 400 { seen.removeAll() }
        return Offer(incoming: incoming)
    }

    public func reset() {
        lock.lock(); seen.removeAll(); lock.unlock()
    }
}

/// The resources themselves, kept in one place so the copy stays honest.
public enum CrisisResources {
    public static let headline = "Someone to talk to"
    /// Shown beside a message someone else sent. Same resources, no diagnosis
    /// of either person.
    public static let incomingHeadline = "Here if they help"

    public struct Item: Identifiable, Sendable {
        public var id: String { title }
        public var title: String
        public var detail: String
        public var action: String
        public var url: URL?
    }

    public static let items: [Item] = [
        Item(title: "Call or text 988",
             detail: "Suicide and Crisis Lifeline. Any hour.",
             action: "Call 988",
             url: URL(string: "tel:988")),
        Item(title: "Text HOME to 741741",
             detail: "Crisis Text Line.",
             action: "Open Messages",
             url: URL(string: "sms:741741&body=HOME")),
    ]

    public static let note = "Calling 988 does not send police."
}
