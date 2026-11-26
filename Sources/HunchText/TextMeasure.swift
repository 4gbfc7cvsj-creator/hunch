// Word counting, word-boundary clamping, and normalized word lists for suggestion checks. Pure.
import Foundation

/// Small text helpers shared by the post-processor and the engine's timing code.
///
/// Word rule (kept identical to the decoder's stop rule so the two agree): a run of letters or
/// digits separated by whitespace counts as one word; punctuation never starts or ends a word
/// ("don't", "well-known" stay one word). CJK characters (Han, kana, half-width katakana) count
/// together as one word per 3 characters, rounded up.
public enum TextMeasure {
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF66...0xFF9F, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    public static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map(isCJK) ?? false
    }

    private struct Counter {
        var words = 0
        var cjk = 0
        var inWord = false
        var total: Int { words + (cjk + 2) / 3 }

        /// Feeds one scalar; returns true when it starts a new non-CJK word.
        mutating func feed(_ scalar: Unicode.Scalar) -> Bool {
            if TextMeasure.isCJK(scalar) {
                cjk += 1
                inWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                defer { inWord = true }
                if !inWord {
                    words += 1
                    return true
                }
            }
            return false
        }
    }

    public static func wordCount(_ text: String) -> Int {
        var counter = Counter()
        for scalar in text.unicodeScalars { _ = counter.feed(scalar) }
        return counter.total
    }

    /// The longest prefix of `text` that holds at most `maxWords` words, cut at a word boundary
    /// (before the first word that would exceed the budget, or between CJK characters), with
    /// trailing whitespace removed. Punctuation attached to a kept word stays. `maxWords <= 0`
    /// means no limit.
    public static func clamp(_ text: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return text }
        var counter = Counter()
        var cut: String.Index?
        for index in text.indices {
            var probe = counter
            for scalar in text[index].unicodeScalars { _ = probe.feed(scalar) }
            if probe.total > maxWords {
                cut = index
                break
            }
            counter = probe
        }
        guard let cut else { return text }
        return trimTrailingWhitespace(String(text[..<cut]))
    }

    public static func trimTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return String(result)
    }

    /// Lowercased words for comparisons: punctuation is dropped (apostrophes inside words are
    /// kept), whitespace separates words, and every CJK character is its own word.
    public static func normalizedWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for character in text.lowercased() {
            if isCJK(character) {
                flush()
                words.append(String(character))
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "\u{2019}", !current.isEmpty {
                current.append("'")
            } else {
                flush()
            }
        }
        flush()
        return words.map { $0.hasSuffix("'") ? String($0.dropLast()) : $0 }
    }
}
