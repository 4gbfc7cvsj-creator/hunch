import Foundation

/// One word-like unit of text. Offsets are in `Character`s.
struct Token: Equatable, Sendable {
    var text: String
    var start: Int
    var end: Int
    /// True when something follows the token, so the user can no longer be mid-word.
    /// (A final CJK chunk or word at the very end of the text is not complete.)
    var completed: Bool
    /// Part of a URL, email address, or domain: never learned and never stored.
    var opaque: Bool
    var isCJK: Bool
}

/// Word segmentation shared by the tracker, scorer, and bias builder.
///
/// Spaced scripts: a word is a run of letters/digits, with inner `'`, `’`, `-` allowed between
/// letters. CJK (Han/kana, no spaces): runs are cut into fixed 2-character chunks counted from
/// the start of the run, which is a crude stand-in for real segmentation. The tracker only learns
/// CJK from confirmed text; typed-over / corrected / dismissed signals skip CJK.
/// TODO: proper CJK segmentation (NLTokenizer) if CJK learning proves worthwhile.
enum WordText {
    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func containsCJK(_ s: String) -> Bool { s.contains(where: isCJK) }

    static func tokens(in text: String) -> [Token] {
        let chars = Array(text)
        let n = chars.count
        let opaque = opaqueMask(chars)
        var out: [Token] = []
        var i = 0
        while i < n {
            let c = chars[i]
            guard isWordChar(c) else { i += 1; continue }
            if isCJK(c) {
                var runEnd = i
                while runEnd < n, isCJK(chars[runEnd]) { runEnd += 1 }
                var k = i
                while k < runEnd {
                    let e = min(k + 2, runEnd)
                    out.append(Token(text: String(chars[k..<e]), start: k, end: e, completed: e < n,
                                     opaque: opaque[k], isCJK: true))
                    k = e
                }
                i = runEnd
            } else {
                var j = i + 1
                while j < n {
                    let d = chars[j]
                    if isWordChar(d), !isCJK(d) {
                        j += 1
                    } else if d == "'" || d == "’" || d == "-", j + 1 < n,
                              isWordChar(chars[j + 1]), !isCJK(chars[j + 1]) {
                        j += 1
                    } else {
                        break
                    }
                }
                out.append(Token(text: String(chars[i..<j]), start: i, end: j, completed: j < n,
                                 opaque: opaque[i], isCJK: false))
                i = j
            }
        }
        return out
    }

    /// Up to `limit` words before the end of `text`, original casing, stopping at an opaque token.
    static func contextWords(of text: String, limit: Int = 2) -> [String] {
        var out: [String] = []
        for t in tokens(in: String(text.suffix(400))).reversed() {
            if t.opaque { break }   // a URL/email is a boundary: words beyond it are not neighbors
            out.insert(t.text, at: 0)
            if out.count >= limit { break }
        }
        return out
    }

    /// Words written with a capital first letter mid-sentence, as written: names such as "Mark" or
    /// "Swift" whose lowercase form may be an ordinary word. Only words starting at or after the
    /// Character offset `from` are returned. Not a name:
    ///  - a sentence-initial word: nothing before it, a newline before it, or the last non-space
    ///    character before it ends a sentence or opens a quote, bracket or list item;
    ///  - a word separated only by spaces from another capitalized word (Title Case headings such
    ///    as "Meeting Notes For Today"; "Hi, Mark" is fine);
    ///  - an all-caps word ("OK", "VERY", "I").
    static func namesMidSentence(in text: String, from: Int = 0) -> Set<String> {
        let chars = Array(text)
        let toks = tokens(in: text)
        func capitalized(_ t: Token) -> Bool {
            guard !t.isCJK, !t.opaque, let f = t.text.first, f.isUppercase else { return false }
            return t.text.contains { $0.isLowercase }
        }
        var out: Set<String> = []
        for (n, t) in toks.enumerated() where t.start >= from && capitalized(t) {
            var k = t.start - 1
            while k >= 0, chars[k].isWhitespace, !chars[k].isNewline { k -= 1 }
            if k < 0 || chars[k].isNewline || sentenceStarters.contains(chars[k]) { continue }
            if n > 0, capitalized(toks[n - 1]),
               chars[toks[n - 1].end..<t.start].allSatisfy({ $0 == " " || $0 == "\u{00A0}" }) { continue }
            out.insert(t.text)
        }
        return out
    }

    /// Characters after which the next word starts a sentence (or a quote, bracket or list item).
    private static let sentenceStarters: Set<Character> = [
        ".", "!", "?", ":", "…", "\"", "“", "‘", "'", "(", "[", "{", "«", "「", "『", "-", "*", "•",
        "#", ">", "。", "！", "？", "：",
    ]

    /// Marks characters belonging to whitespace-delimited chunks that look like URLs, emails, or domains.
    private static func opaqueMask(_ chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)
        var a = 0
        while a < chars.count {
            if chars[a].isWhitespace { a += 1; continue }
            var b = a
            while b < chars.count, !chars[b].isWhitespace { b += 1 }
            let chunk = Array(chars[a..<b])
            let s = String(chunk)
            var isOpaque = s.contains("://") || s.contains("@") || s.lowercased().hasPrefix("www.")
            if !isOpaque, chunk.count > 2 {
                for k in 1..<(chunk.count - 1) where chunk[k] == "." {
                    if chunk[k - 1].isLetter, chunk[k + 1].isLetter { isOpaque = true; break }
                }
            }
            if isOpaque { for k in a..<b { mask[k] = true } }
            a = b
        }
        return mask
    }
}

/// Stable hash of a field for the "distinct fields" count (ignores `generation` so that two focus
/// sessions in the same field count once).
enum FieldKey {
    static func hash(pid: Int32, element: Int) -> UInt32 {
        var h: UInt32 = 2166136261
        func mix(_ v: UInt64) {
            for s in stride(from: 0, to: 64, by: 8) {
                h = (h ^ UInt32((v >> UInt64(s)) & 0xFF)) &* 16777619
            }
        }
        mix(UInt64(bitPattern: Int64(pid)))
        mix(UInt64(bitPattern: Int64(element)))
        return h
    }
}
