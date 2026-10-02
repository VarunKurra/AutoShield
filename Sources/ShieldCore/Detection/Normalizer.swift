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

    /// Tokens folded onto the lexicon: stretched letters cut back ("stuuupid"),
    /// spelling dodges resolved ("fck", "biatch"). Words the lexicon does not
    /// know are left exactly as typed.
    public let canonical: [String]
    /// `canonical` joined with single spaces and padded at both ends, so every
    /// pattern can match on whole-word boundaries. This is what the rules read.
    public let text: String
    /// As `text`, but with runs of single letters glued back together, so
    /// "k y s" and "k.y.s" read as "kys". Never glued across real words, which
    /// is what made "if you" read as "f you" and "pinky swear" as "kys".
    public let joined: String

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
        let canon = tokens.map(Normalizer.canonicalize)
        self.canonical = canon
        self.text = " " + canon.joined(separator: " ") + " "
        self.joined = " " + Normalizer.joinSingles(canon).joined(separator: " ") + " "
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

        s = resolveMasks(in: s)
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

    // MARK: Canonical forms

    /// Spellings people use to slip a word past a filter, mapped home.
    static let aliases: [String: String] = [
        "fck": "fuck", "fk": "fuck", "fuk": "fuck", "fuq": "fuck", "phuck": "fuck",
        "fcuk": "fuck", "fucc": "fuck", "fuc": "fuck", "frick": "fuck", "effing": "fucking",
        "fking": "fucking", "fkin": "fucking", "fcking": "fucking", "fuckin": "fucking",
        "fukin": "fucking", "fukking": "fucking", "fuking": "fucking", "fricking": "fucking",
        "biatch": "bitch", "bish": "bitch", "btch": "bitch", "bytch": "bitch", "biotch": "bitch",
        "sht": "shit", "shiet": "shit", "stoopid": "stupid", "stupit": "stupid", "stoopit": "stupid",
        "dum": "dumb", "idot": "idiot", "idoit": "idiot", "idiyot": "idiot", "retart": "retard",
        "retardd": "retard", "azz": "ass", "arse": "ass", "phat": "fat",
        "yu": "you", "yuo": "you", "yoo": "you", "chu": "you", "yourslef": "yourself",
        "urslef": "urself", "kil": "kill", "kll": "kill",
        "loosr": "loser", "lozer": "loser", "looser": "loser", "uggo": "ugly", "ugli": "ugly",
        "cnt": "cunt", "kunt": "cunt", "wh0re": "whore", "hore": "whore", "sl4t": "slut",
        "nigg": "nigger", "nibba": "nigga", "fagg": "fag", "fagget": "faggot", "faget": "faggot",
        "mf": "motherfucker", "mfer": "motherfucker", "muthafucka": "motherfucker",
        "motherfucka": "motherfucker", "fucka": "fucker", "dik": "dick", "dikhead": "dickhead",
        "asshat": "asshole", "a55hole": "asshole", "pos": "pos",
    ]

    /// Every word a rule names, so stretching can be folded back onto it.
    static let vocabulary: Set<String> = {
        var v = Set<String>()
        for list in [Lexicon.slurWords, Lexicon.profanityWords, Lexicon.explicitWords, Lexicon.insultNouns,
                     Lexicon.insultAdjectives, Lexicon.secondPerson, Lexicon.firstPerson] {
            v.formUnion(list)
        }
        v.formUnion(["kill", "kys", "kms", "die", "dead", "yourself", "urself", "hate",
                     "stfu", "gtfo", "gfy", "shut", "please", "dumbass", "ugly", "fat",
                     "nobody", "hell", "hope", "suck", "sucks", "cancer", "bleach", "loser"])
        return v
    }()

    /// Folds one token onto the lexicon if, and only if, a known word is
    /// underneath it. "looooser" becomes "loser"; "cooool" stays as typed.
    static func canonicalize(_ token: String) -> String {
        if let a = aliases[token] { return a }
        if vocabulary.contains(token) { return token }
        guard token.count > 2 else { return token }
        if let fixed = typoFix(token) { return fixed }
        let two = collapseRuns(token, to: 2)
        if two != token {
            if let a = aliases[two] { return a }
            if vocabulary.contains(two) { return two }
        }
        let one = collapseRuns(token, to: 1)
        if one != token {
            if let a = aliases[one] { return a }
            if vocabulary.contains(one) { return one }
        }
        return token
    }

    // MARK: Typos

    /// Words that matter enough to be recognised through a typo. Only
    /// these: correcting everything would turn "lover" into "loser".
    static let typoTargets: [Int: [String]] = {
        var words = Set<String>()
        words.formUnion(["yourself", "urself", "kill", "loser", "worthless", "pathetic", "disgusting",
                         "stupid", "idiot", "retard", "retarded", "bitch", "whore", "slut", "faggot",
                         "nigger", "ugly", "dumbass", "moron", "freak", "weirdo", "fucking", "fuck",
                         "shit", "asshole", "cunt", "deserve", "suicide", "hang", "die", "dead"])
        words.formUnion(Lexicon.strongProfanity.filter { $0.count >= 4 })
        words.formUnion(Lexicon.slurWords.filter { $0.count >= 5 })
        var byLength: [Int: [String]] = [:]
        for w in words where w.count >= 4 { byLength[w.count, default: []].append(w) }
        return byLength
    }()

    /// The system word list, so real words are never "corrected".
    static let dictionary: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var set = Set<String>()
        set.reserveCapacity(240_000)
        text.enumerateLines { line, _ in set.insert(line.lowercased()) }
        return set
    }()

    /// In the word list, directly or as a plain inflection of a word in it.
    static func isRealWord(_ w: String) -> Bool {
        if dictionary.contains(w) { return true }
        for suffix in ["s", "es", "ed", "d", "ing", "er", "ers", "ly"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            let stem = String(w.dropLast(suffix.count))
            if dictionary.contains(stem) || dictionary.contains(stem + "e") { return true }
            // "batted" -> "bat", "stopping" -> "stop"
            if let last = stem.last, stem.dropLast().last == last, dictionary.contains(String(stem.dropLast())) { return true }
        }
        return false
    }

    /// Touches the large tables once, off the keystroke path.
    public static func warmUp() {
        _ = dictionary.count
        _ = vocabulary.count
        _ = typoTargets.count
        _ = normalize("warm up")
    }

    /// Keys that sit next to each other on a QWERTY keyboard.
    static let adjacent: [Character: Set<Character>] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)
        var map: [Character: Set<Character>] = [:]
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                var n = Set<Character>()
                for dr in -1...1 {
                    let rr = r + dr
                    guard rows.indices.contains(rr) else { continue }
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let cc = c + dc
                        if rows[rr].indices.contains(cc) { n.insert(rows[rr][cc]) }
                    }
                }
                map[ch] = n
            }
        }
        return map
    }()

    /// "yourswlf" → "yourself": one slip of the finger onto a neighbouring
    /// key, or two letters swapped. Words of five letters or more only, and
    /// only onto words worth catching.
    static func typoFix(_ token: String) -> String? {
        guard token.count >= 5, token.allSatisfy({ $0.isLetter }) else { return nil }
        // A real word is never a typo: "ducking" and "botch" stay as written.
        guard !isRealWord(token) else { return nil }
        let t = Array(token)
        for w in typoTargets[t.count] ?? [] where w.first == t.first {
            let a = Array(w)
            var diffs: [Int] = []
            for i in 0..<t.count where t[i] != a[i] {
                diffs.append(i)
                if diffs.count > 2 { break }
            }
            if diffs.count == 1, let n = adjacent[a[diffs[0]]], n.contains(t[diffs[0]]) { return w }
            if diffs.count == 2, diffs[1] == diffs[0] + 1,
               t[diffs[0]] == a[diffs[1]], t[diffs[1]] == a[diffs[0]] { return w }
        }
        return nil
    }

    /// Glues runs of single-letter tokens: ["k","y","s"] → ["kys"]. Two letters
    /// are glued only when the result is a word the lexicon cares about, so
    /// an ordinary "a" or "i" between words is never swallowed.
    static func joinSingles(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if run.count >= 3 {
                out.append(canonicalize(run.joined()))
            } else if run.count == 2, vocabulary.contains(run.joined()) || aliases[run.joined()] != nil {
                out.append(canonicalize(run.joined()))
            } else {
                out.append(contentsOf: run)
            }
            run.removeAll()
        }
        for t in tokens {
            if t.count == 1, t.first?.isLetter == true { run.append(t) } else { flush(); out.append(t) }
        }
        flush()
        return out
    }

    /// Masked words ("f*ck", "b!tch" after leet, "n****r", "sh#t") resolved
    /// against the lexicon by treating each mask run as one to three letters.
    private static let maskChars: Set<Character> = ["*", "#", "%", "_"]
    private static let maskVocabulary: [String] = {
        var v = Set(Lexicon.profanityWords).union(Lexicon.slurWords).union(Lexicon.explicitWords)
            .union(Lexicon.insultNouns).union(Lexicon.insultAdjectives)
        v.formUnion(["kill", "yourself", "die", "hell"])
        return v.sorted { $0.count < $1.count }
    }()

    static func resolveMasks(in s: String) -> String {
        guard s.contains(where: { maskChars.contains($0) }) else { return s }
        var words = s.components(separatedBy: " ")
        for (i, raw) in words.enumerated() where raw.contains(where: { maskChars.contains($0) }) {
            // Leading and trailing punctuation is not part of the mask.
            let core = raw.trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "*#%_")))
            guard core.contains(where: { $0.isLetter }), core.count >= 2 else { continue }
            // Each run of mask characters stands for about as many letters
            // as it has: "f*ck" for one, "n****r" for four.
            var pattern = "^"
            var run = 0
            func flushRun() {
                guard run > 0 else { return }
                pattern += "[a-z]{\(max(1, run - 1)),\(run + 1)}"
                run = 0
            }
            for c in core {
                if maskChars.contains(c) {
                    run += 1
                } else {
                    flushRun()
                    pattern += NSRegularExpression.escapedPattern(for: String(c))
                }
            }
            flushRun()
            pattern += "$"
            guard pattern.contains("[a-z]"),
                  let re = try? NSRegularExpression(pattern: pattern) else { continue }
            if let hit = maskVocabulary.first(where: {
                re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }) {
                words[i] = raw.replacingOccurrences(of: core, with: hit)
            }
        }
        return words.joined(separator: " ")
    }

    public static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }
}

/// A phrase list matched on whole-word boundaries against the canonical
/// form of a draft. Each phrase is normalised once, at startup, exactly as a
/// draft would be, so "you're dead" in the list matches "ur dead" and "YOU'RE
/// DEAD!!" alike, and never matches inside a longer word.
public struct PhraseSet: Sendable {
    let phrases: [String]
    let needles: [String]
    let evasive: Bool

    public init(_ phrases: [String], evasive: Bool = false) {
        self.phrases = phrases
        self.needles = phrases.map { Normalizer.normalize($0).text }
        self.evasive = evasive
    }

    public var all: [String] { phrases }

    func matches(in n: Normalized) -> [String] {
        var out: [String] = []
        for (i, needle) in needles.enumerated() where needle.count > 2 {
            if n.text.contains(needle) || (evasive && n.joined.contains(needle)) {
                out.append(phrases[i])
            }
        }
        return out
    }

    func anyMatch(in n: Normalized) -> Bool {
        for needle in needles where needle.count > 2 {
            if n.text.contains(needle) || (evasive && n.joined.contains(needle)) { return true }
        }
        return false
    }

    func count(in n: Normalized) -> Int {
        matches(in: n).count
    }
}
