// What part of a suggestion still being written may be shown: whole words only. Pure.
import Foundation

public enum StreamWords {
    /// The longest prefix of `text` that ends on a finished word. A Latin-script word counts as
    /// finished once whitespace follows it (the next token may still extend it); a Chinese or
    /// Japanese character is finished as soon as it is written. Empty when no word is finished yet.
    public static func complete(_ text: String) -> String {
        guard let last = text.last else { return "" }
        if last.isWhitespace || isIdeographic(last) { return trimmedEnd(text) }
        // Back up to the last whitespace or ideograph that follows written text.
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            let c = text[previous]
            if c.isWhitespace {
                return trimmedEnd(String(text[..<previous]))
            }
            if isIdeographic(c) { return String(text[..<end]) }
            end = previous
        }
        return ""
    }

    /// False only when `complete(text) == complete(previous)` is certain: `text` merely extends
    /// `previous` by characters that are neither whitespace nor ideographic. A cheap filter for the
    /// token hot path; true whenever in doubt.
    public static func mayHaveNewWord(_ text: String, after previous: String) -> Bool {
        guard text.utf8.count > previous.utf8.count,
              text.unicodeScalars.starts(with: previous.unicodeScalars) else { return true }
        let tail = text.unicodeScalars.dropFirst(previous.unicodeScalars.count)
        // Whitespace appended to a word could merge with a preceding scalar into one Character;
        // such text is rare, and the filter above only claims "no new word" for plain growth.
        return tail.contains { $0.properties.isWhitespace || isIdeographic(Character($0)) }
    }

    private static func trimmedEnd(_ text: String) -> String {
        var t = Substring(text)
        while let last = t.last, last.isWhitespace { t = t.dropLast() }
        return t.contains(where: { !$0.isWhitespace }) ? String(t) : ""
    }

    /// Han, kana, and full-width CJK punctuation: each is a whole unit when written.
    static func isIdeographic(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xFF00...0xFFEF, 0x20000...0x2FFFF: true
            default: false
            }
        }
    }
}
