import Foundation

/// Folds the ways people dodge a keyword filter back onto plain text:
/// leetspeak, unicode lookalikes, inserted separators, stretched letters.
///
/// Produces several variants rather than one, because collapsing repeats is
/// lossy in both directions ("loooser" needs collapsing, "ass" does not).
/// Everything a matcher needs is computed once here, because the rules tier
/// asks thousands of questions of every draft.
public struct Normalized: Sendable {
    /// Lowercased, diacritics folded, lookalikes and leet resolved, whitespace collapsed.
    public let plain: String
    /// `plain` with runs of 3+ identical letters cut to 2.
    public let deStretched: String
    /// `plain` with every non-alphanumeric removed and all repeats cut to 1.
    public let squashed: String
    /// Word tokens of `plain`, in order.
    public let tokens: [String]

    let tokenSet: Set<String>
    let stretchedTokenSet: Set<String>
    /// Squashed forms of the tokens that were actually stretched, so
    /// "loooooser" reaches "loser" without "as" reaching "ass".
    let unstretchedTokenSet: Set<String>

    init(plain: String, deStretched: String, squashed: String, tokens: [String]) {
        self.plain = plain
        self.deStretched = deStretched
        self.squashed = squashed
        self.tokens = tokens
        self.tokenSet = Set(tokens)
        self.stretchedTokenSet = plain == deStretched
            ? Set(tokens)
            : Set(Normalizer.tokenize(deStretched))
        var unstretched = Set<String>()
        for t in tokens where Normalizer.hasLongRun(t) {
            unstretched.insert(Normalizer.squash(t))
        }
        self.unstretchedTokenSet = unstretched
    }

    public var variants: [String] { [plain, deStretched, squashed] }

    /// Substring match against the plain and de-stretched forms. Use for
    /// phrases; single words belong in `hasWord`.
    public func contains(_ needle: String) -> Bool {
        if plain.contains(needle) { return true }
        if deStretched != plain, deStretched.contains(needle) { return true }
        return false
    }

    /// As `contains`, but also checks the squashed form. Reserved for the
    /// short, high-stakes lists where evasion is the whole point.
    func containsEvasive(_ needle: String, squashedNeedle: String) -> Bool {
        if contains(needle) { return true }
        return !squashedNeedle.isEmpty && squashed.contains(squashedNeedle)
    }

    /// Whole-word match, so "ass" does not fire inside "pass" or "classic".
    public func hasWord(_ word: String) -> Bool {
        tokenSet.contains(word)
            || stretchedTokenSet.contains(word)
            || unstretchedTokenSet.contains(word)
    }

    public func hasAnyWord(_ words: Set<String>) -> Bool {
        !tokenSet.isDisjoint(with: words)
            || !stretchedTokenSet.isDisjoint(with: words)
            || !unstretchedTokenSet.isDisjoint(with: words)
    }

    public func hasAnyWord(_ words: [String]) -> Bool {
        hasAnyWord(Set(words))
    }

    /// True when `word` is aimed at the person being spoken to, rather than
    /// merely sharing a sentence with them.
    ///
    /// "you are an idiot" and "you should see this idiotic bug" both contain a
    /// second person and a harsh word. Only the first is about them. Checking
    /// for the word anywhere in the sentence is what made Shield stop honest
    /// complaints, so aim is measured by distance.
    public func isAimed(_ word: String, window: Int = 3) -> Bool {
        guard let index = tokens.firstIndex(of: word) else {
            // The word only survived de-stretching, so fall back to presence.
            return hasAnyWord(Lexicon.secondPersonSet)
        }
        let lower = max(0, index - window)
        let upper = min(tokens.count - 1, index + window)
        for i in lower...upper where i != index {
            if Lexicon.secondPersonSet.contains(tokens[i]) { return true }
        }
        // "what a loser", "such an idiot": the insult is a bare noun phrase,
        // which in a message to someone is still aimed.
        if index >= 1, ["a", "an", "such", "total", "absolute", "complete"].contains(tokens[index - 1]) {
            return hasAnyWord(Lexicon.secondPersonSet)
        }
        return false
    }

    /// The tokens that appear in `words`. Iterates the draft, not the lexicon.
    func words(in words: Set<String>) -> [String] {
        var out: [String] = []
        for t in tokenSet where words.contains(t) { out.append(t) }
        for t in stretchedTokenSet where words.contains(t) && !out.contains(t) { out.append(t) }
        for t in unstretchedTokenSet where words.contains(t) && !out.contains(t) { out.append(t) }
        return out
    }
}

public enum Normalizer {

    /// Unicode lookalikes that survive NFKD folding.
    private static let confusables: [Character: Character] = [
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p",
        "\u{0441}": "c", "\u{0445}": "x", "\u{0443}": "y", "\u{0456}": "i",
        "\u{04BB}": "h", "\u{0405}": "s", "\u{03B1}": "a", "\u{03BF}": "o",
        "\u{03C1}": "p", "\u{03C5}": "u", "\u{03BD}": "v", "\u{03BA}": "k",
        "\u{2013}": "-", "\u{2014}": "-", "\u{2018}": "'", "\u{2019}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{00A0}": " ",
    ]

    /// Leet and symbol substitutions. Applied only between or adjacent to letters
    /// so that plain numbers ("i have 4 tickets") survive untouched.
    private static let leet: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b",
        "@": "a", "$": "s", "!": "i", "|": "i", "+": "t", "(": "c", "€": "e",
    ]

    private static let invisible: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
        "\u{00AD}", "\u{034F}", "\u{180E}",
    ]

    public static func normalize(_ raw: String) -> Normalized {
        // The common case is plain ASCII, where the expensive transliteration
        // and folding passes have nothing to do.
        let ascii = raw.allSatisfy { $0.isASCII }
        var s = raw

        if !ascii {
            s = String(s.filter { !invisible.contains($0) })
            s = s.folding(options: [.diacriticInsensitive, .widthInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
            s = s.applyingTransform(.toLatin, reverse: false) ?? s
            s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            s = s.lowercased()
            s = String(s.map { confusables[$0] ?? $0 })
        } else {
            s = s.lowercased()
        }

        s = applyLeet(to: s)

        let plain = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")

        return Normalized(
            plain: plain,
            deStretched: collapseRuns(plain, to: 2),
            squashed: squash(plain),
            tokens: tokenize(plain)
        )
    }

    /// Substitutes leet characters only when a letter sits on either side,
    /// which keeps real digits ("room 101", "i'm 14") intact.
    private static func applyLeet(to s: String) -> String {
        guard s.contains(where: { leet[$0] != nil }) else { return s }
        let chars = Array(s)
        var out = [Character]()
        out.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            guard let replacement = leet[c] else { out.append(c); continue }
            let prev = i > 0 ? chars[i - 1] : " "
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            let touchesLetter = prev.isLetter || next.isLetter
                || leet[prev] != nil || leet[next] != nil
            out.append(touchesLetter ? replacement : c)
        }
        return String(out)
    }

    /// Cuts runs of the same character down to `limit`.
    public static func collapseRuns(_ s: String, to limit: Int) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var last: Character? = nil
        var run = 0
        for c in s {
            if c == last {
                run += 1
                if run <= limit { out.append(c) }
            } else {
                last = c
                run = 1
                out.append(c)
            }
        }
        return out
    }

    /// Everything that is not a letter or digit disappears and every repeat
    /// collapses, so "k.y.s", "k y s" and "kkyyss" all land on "kys".
    public static func squash(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var last: Character? = nil
        for c in s where c.isLetter || c.isNumber {
            if c != last { out.append(c); last = c }
        }
        return out
    }

    /// True when a character repeats three or more times in a row — the
    /// signature of deliberate stretching rather than ordinary spelling.
    static func hasLongRun(_ s: String) -> Bool {
        var last: Character? = nil
        var run = 0
        for c in s {
            if c == last { run += 1; if run >= 3 { return true } }
            else { last = c; run = 1 }
        }
        return false
    }

    public static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }
}

/// A phrase list with its squashed forms computed once at startup rather than
/// once per draft. This is the difference between a millisecond and a
/// microsecond, and the rules tier runs on every keystroke.
public struct PhraseSet: Sendable {
    let phrases: [String]
    let squashedPhrases: [String]
    let evasive: Bool

    public init(_ phrases: [String], evasive: Bool = false) {
        self.phrases = phrases
        self.squashedPhrases = evasive ? phrases.map(Normalizer.squash) : []
        self.evasive = evasive
    }

    public var all: [String] { phrases }

    func matches(in n: Normalized) -> [String] {
        var out: [String] = []
        if evasive {
            for (i, p) in phrases.enumerated()
            where n.containsEvasive(p, squashedNeedle: squashedPhrases[i]) {
                out.append(p)
            }
        } else {
            for p in phrases where n.contains(p) { out.append(p) }
        }
        return out
    }

    func anyMatch(in n: Normalized) -> Bool {
        if evasive {
            for (i, p) in phrases.enumerated()
            where n.containsEvasive(p, squashedNeedle: squashedPhrases[i]) { return true }
            return false
        }
        for p in phrases where n.contains(p) { return true }
        return false
    }

    func count(in n: Normalized) -> Int {
        matches(in: n).count
    }
}
