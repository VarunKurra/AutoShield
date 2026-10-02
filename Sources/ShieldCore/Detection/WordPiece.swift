import Foundation

/// BERT's uncased WordPiece tokenizer, the same algorithm as Hugging Face's
/// `BertTokenizer`, so the on-device transformer sees exactly the ids it was
/// trained on. Verified against the Python tokenizer by `Tools/convert_tier1.py`.
///
/// 1. Clean: drop control characters, map whitespace to spaces.
/// 2. Lowercase and strip accents (NFD, drop combining marks).
/// 3. Split on whitespace, then split off every punctuation character and
///    every CJK ideograph as its own token.
/// 4. Greedy longest-match-first against the vocabulary, continuation
///    pieces prefixed with "##". A word with no match becomes [UNK].
public final class WordPiece: @unchecked Sendable {
    private let vocab: [String: Int32]
    public let cls: Int32, sep: Int32, pad: Int32, unk: Int32
    private let maxWordChars = 100

    public init?(vocabURL: URL) {
        guard let text = try? String(contentsOf: vocabURL, encoding: .utf8) else { return nil }
        var v: [String: Int32] = [:]
        var i: Int32 = 0
        text.enumerateLines { line, _ in
            v[line] = i
            i += 1
        }
        guard let cls = v["[CLS]"], let sep = v["[SEP]"], let pad = v["[PAD]"], let unk = v["[UNK]"] else { return nil }
        vocab = v
        self.cls = cls; self.sep = sep; self.pad = pad; self.unk = unk
    }

    /// `[CLS] tokens… [SEP]`, truncated and padded to `length`.
    public func encode(_ text: String, length: Int) -> (ids: [Int32], mask: [Int32]) {
        var ids: [Int32] = [cls]
        for word in basicTokens(text) {
            ids.append(contentsOf: wordPieces(word))
            if ids.count >= length - 1 { break }
        }
        if ids.count > length - 1 { ids = Array(ids.prefix(length - 1)) }
        ids.append(sep)
        var mask = [Int32](repeating: 1, count: ids.count)
        while ids.count < length { ids.append(pad); mask.append(0) }
        return (ids, mask)
    }

    // MARK: Basic tokenizer

    func basicTokens(_ text: String) -> [String] {
        var cleaned = ""
        cleaned.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD { continue }
            if WordPiece.isWhitespace(s) { cleaned.unicodeScalars.append(" "); continue }
            if WordPiece.isControl(s) { continue }
            if WordPiece.isCJK(s) {
                cleaned.unicodeScalars.append(" "); cleaned.unicodeScalars.append(s); cleaned.unicodeScalars.append(" ")
                continue
            }
            cleaned.unicodeScalars.append(s)
        }

        var out: [String] = []
        for raw in cleaned.split(separator: " ", omittingEmptySubsequences: true) {
            // Lowercase, then strip accents.
            let lowered = raw.lowercased().decomposedStringWithCanonicalMapping
            var word = String.UnicodeScalarView()
            for s in lowered.unicodeScalars where s.properties.generalCategory != .nonspacingMark {
                word.append(s)
            }
            // Split punctuation off as separate tokens.
            var current = String.UnicodeScalarView()
            for s in word {
                if WordPiece.isPunctuation(s) {
                    if !current.isEmpty { out.append(String(current)); current = String.UnicodeScalarView() }
                    out.append(String(s))
                } else {
                    current.append(s)
                }
            }
            if !current.isEmpty { out.append(String(current)) }
        }
        return out
    }

    // MARK: WordPiece

    func wordPieces(_ word: String) -> [Int32] {
        let chars = Array(word.unicodeScalars)
        guard chars.count <= maxWordChars else { return [unk] }
        var pieces: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32? = nil
            while start < end {
                var sub = String(String.UnicodeScalarView(chars[start..<end]))
                if start > 0 { sub = "##" + sub }
                if let id = vocab[sub] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            pieces.append(id)
            start = end
        }
        return pieces
    }

    // MARK: Character classes, as BERT defines them

    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        if s == " " || s == "\t" || s == "\n" || s == "\r" { return true }
        return s.properties.generalCategory == .spaceSeparator
    }

    static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        // All non-letter/number ASCII counts, as in BERT.
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
