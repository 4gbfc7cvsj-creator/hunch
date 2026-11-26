import Foundation

/// Accumulates token bytes and exposes the longest complete-UTF-8 prefix as text. Trailing bytes of
/// an unfinished multi-byte sequence are held back until the sequence completes.
struct UTF8Accumulator {
    private(set) var bytes: [UInt8] = []

    mutating func append<S: Sequence>(contentsOf more: S) where S.Element == UInt8 { bytes.append(contentsOf: more) }

    /// Number of leading bytes that form complete sequences (invalid bytes count as complete;
    /// they decode to U+FFFD rather than blocking forever).
    var completeLength: Int {
        let n = bytes.count
        var i = n - 1
        var back = 0
        // Walk back over at most 3 continuation bytes to the lead byte.
        while i >= 0, back < 3, bytes[i] & 0xC0 == 0x80 {
            i -= 1
            back += 1
        }
        guard i >= 0 else { return n }
        let lead = bytes[i]
        let needed: Int
        switch lead {
        case 0xC0...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF7: needed = 4
        default: return n
        }
        let have = n - i
        return have < needed ? i : n
    }

    var text: String { String(decoding: bytes[..<completeLength], as: UTF8.self) }
}

/// Word counting and sentence rules for stop decisions. Pure.
enum TextRules {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF66...0xFF9F, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    /// Whitespace-separated words containing a letter or digit, plus CJK characters counted as
    /// one word per 3 characters (rounded up). Chinese has no spaces and averages roughly 1.5-2
    /// characters per word; dividing by 3 errs toward slightly longer CJK suggestions, which the
    /// eval can tune. CJK characters inside a mixed run are counted only by the CJK rule.
    static func wordCount(_ text: String) -> Int {
        var words = 0
        var cjk = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
                inWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { words += 1 }
                inWord = true
            }
            // Punctuation neither starts nor ends a word ("don't", "well-known" stay one word).
        }
        return words + (cjk + 2) / 3
    }

    static let fullWidthTerminators: Set<Character> = ["。", "！", "？"]
    static let terminators: Set<Character> = [".", "!", "?"]
    static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "»"]
    static let commas: Set<Character> = [",", "，", "、"]

    /// Lowercased abbreviations (without the final period) that do not end a sentence.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "approx", "no",
        "fig", "inc", "ltd", "co", "dept", "est", "a.m", "p.m", "u.s", "jan", "feb", "mar", "apr", "jun",
        "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    enum SentenceState { case none, tentative, definite }

    /// Whether `text` ends with a sentence terminator. Full-width terminators are definite;
    /// ASCII ones are tentative until the next token shows a space, newline, or end of text,
    /// and are ignored after abbreviations and single letters ("A.", "e.g.").
    static func sentenceState(_ text: String) -> SentenceState {
        var chars = Array(text)
        while let last = chars.last, closers.contains(last) { chars.removeLast() }
        guard let last = chars.last else { return .none }
        if fullWidthTerminators.contains(last) { return .definite }
        guard terminators.contains(last) else { return .none }
        if last == "." {
            var start = chars.count - 1
            while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
            var word = String(chars[start..<(chars.count - 1)]).lowercased()
            while let first = word.first, !(first.isLetter || first.isNumber) { word.removeFirst() }
            if abbreviations.contains(word) { return .none }
            if word.count == 1, word.first?.isLetter == true { return .none }
        }
        return .tentative
    }
}
