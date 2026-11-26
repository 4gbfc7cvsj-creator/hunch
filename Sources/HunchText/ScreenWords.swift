import Foundation

/// The distinctive words on screen: names, product names and terms ("Kubernetes", "csv", "@alex")
/// that autocorrect must not "fix" and may offer for a garbled version. Built once per screen
/// excerpt from its text (a few milliseconds at most), never per key press. Only words the system
/// dictionary rejects can matter to the finder, so everyday words are left out and the set stays
/// small. Held in memory with the excerpt; never stored.
///
/// A typo quoted on screen must not protect itself: a plain lowercase word the dictionary rejects
/// ("recieve") counts only when it appears twice or more. A word with a name or term shape (a capital
/// mid-sentence, a digit, mixed case, a dash or underscore inside, an all-caps acronym, an @handle or
/// #tag) counts at once.
public struct ScreenWords: Sendable, Equatable {
    /// Lowercased distinctive words.
    public let words: Set<String>

    public static let empty = ScreenWords(words: [])

    public init(words: Set<String>) { self.words = words }

    public var isEmpty: Bool { words.isEmpty }

    public func contains(_ word: String) -> Bool { words.contains(word.lowercased()) }

    /// Plain lowercase words need this many sightings.
    public static let plainSightings = 2
    static let maxWords = 400
    static let maxTextLength = 20_000

    /// - Parameter isMisspelled: the system dictionary's verdict for a lowercase word.
    public init(text: String, isMisspelled: (String) -> Bool) {
        var shaped = Set<String>()
        var plain: [String: Int] = [:]
        var verdicts: [String: Bool] = [:]
        func rejected(_ w: String) -> Bool {
            if let v = verdicts[w] { return v }
            let v = isMisspelled(w)
            verdicts[w] = v
            return v
        }
        let chars = Array(text.prefix(Self.maxTextLength))
        var atSentenceStart = true
        var i = 0
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
        while i < chars.count {
            let c = chars[i]
            // @handles and #tags
            var start = i
            var handle = false
            if (c == "@" || c == "#"), i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1].isNumber {
                handle = true
                start = i + 1
            } else if !isWordChar(c) {
                if c == "." || c == "!" || c == "?" || c == "\n" || c == "…" { atSentenceStart = true }
                i += 1
                continue
            }
            var j = start
            while j < chars.count {
                let d = chars[j]
                if isWordChar(d) { j += 1 }
                else if (d == "-" || d == "_"), j + 1 < chars.count, isWordChar(chars[j + 1]) { j += 1 }
                else { break }
            }
            var token = String(chars[start..<j])
            while let l = token.last, l == "'" || l == "’" { token.removeLast() }
            let wasStart = atSentenceStart
            atSentenceStart = false
            i = max(j, i + 1)
            let letters = token.filter(\.isLetter)
            guard letters.count >= 2, token.count >= 3 else { continue }
            let lower = token.lowercased()
            if handle { shaped.insert(lower); continue }
            let upperCount = letters.filter(\.isUppercase).count
            let hasDigit = token.contains(where: \.isNumber)
            let inner = token.dropFirst().contains(where: \.isUppercase)
            let mixed = inner && letters.contains(where: \.isLowercase)
            let acronym = upperCount == letters.count && letters.count <= 8
            let joined = token.contains("-") || token.contains("_")
            let capitalMid = token.first?.isUppercase == true && !wasStart && !inner
            if hasDigit || mixed || acronym || joined || capitalMid {
                if joined {
                    // each part may be a plain word ("well-known"): shaped only when the whole is rejected
                    guard rejected(lower) else { continue }
                }
                if hasDigit || mixed || acronym || joined || rejected(lower) { shaped.insert(lower) }
            } else if rejected(lower) {
                plain[lower, default: 0] += 1
            }
        }
        var out = shaped
        for (w, n) in plain where n >= Self.plainSightings { out.insert(w) }
        if out.count > Self.maxWords { out = Set(out.sorted().prefix(Self.maxWords)) }
        self.words = out
    }

    /// Screen words a garbled `word` is close to (same first letter, at most 2 edits, 3 from 8
    /// letters), nearest first, at most 3.
    public func candidates(for word: String) -> [String] {
        guard word.count >= 5, !words.isEmpty else { return [] }
        let limit = word.count >= 8 ? 3 : 2
        var out: [(word: String, distance: Int)] = []
        for w in words {
            guard w != word, w.count >= 5, w.first == word.first, abs(w.count - word.count) <= limit,
                  !w.contains(where: { !$0.isLetter && $0 != "'" }) else { continue }
            let d = EditDistance.osa(word, w)
            if d <= limit { out.append((w, d)) }
        }
        return out.sorted { ($0.distance, $0.word) < ($1.distance, $1.word) }.prefix(3).map(\.word)
    }
}
