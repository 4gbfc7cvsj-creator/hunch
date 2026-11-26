import Foundation
import HunchCore
import NaturalLanguage

/// Acceptance-unit splitting for "accept next word" (design §13). Leading whitespace belongs to
/// the word it follows into the field; CJK runs are split with `NLTokenizer` because they have
/// no spaces between words.
public enum WordUnits {
    /// The next acceptance unit at the start of `suggestion` (empty only for an empty suggestion).
    public static func next(in suggestion: String, options: WordUnitOptions) -> String {
        guard !suggestion.isEmpty else { return "" }
        var index = suggestion.startIndex
        while index < suggestion.endIndex, suggestion[index].isWhitespace { index = suggestion.index(after: index) }
        guard index < suggestion.endIndex else { return suggestion }
        let wordStart = index

        var wordEnd: String.Index
        if isCJK(suggestion[wordStart]) {
            wordEnd = cjkWordEnd(in: suggestion, from: wordStart)
            if options.includeTrailingPunctuation {
                // CJK tokens never include punctuation; pull directly following marks in.
                while wordEnd < suggestion.endIndex, suggestion[wordEnd].isPunctuation {
                    wordEnd = suggestion.index(after: wordEnd)
                }
            }
        } else {
            wordEnd = wordStart
            while wordEnd < suggestion.endIndex, !suggestion[wordEnd].isWhitespace, !isCJK(suggestion[wordEnd]) {
                wordEnd = suggestion.index(after: wordEnd)
            }
            if !options.includeTrailingPunctuation {
                // Split trailing punctuation off; a unit made only of punctuation is taken whole.
                var trimmed = wordEnd
                while trimmed > wordStart {
                    let previous = suggestion.index(before: trimmed)
                    guard suggestion[previous].isPunctuation else { break }
                    trimmed = previous
                }
                if trimmed > wordStart { wordEnd = trimmed }
            }
        }

        if options.includeTrailingSpace, wordEnd < suggestion.endIndex, suggestion[wordEnd] == " " {
            wordEnd = suggestion.index(after: wordEnd)
        }
        return String(suggestion[suggestion.startIndex..<wordEnd])
    }

    /// Number of acceptance units in `text`, counting no further than `limit`.
    public static func count(in text: String, limit: Int = .max, options: WordUnitOptions = WordUnitOptions()) -> Int {
        var rest = Substring(text)
        var n = 0
        while n < limit {
            guard rest.contains(where: { !$0.isWhitespace }) else { break }
            let unit = next(in: String(rest), options: options)
            guard !unit.isEmpty else { break }
            rest = rest.dropFirst(unit.count)
            n += 1
        }
        return n
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func cjkWordEnd(in text: String, from start: String.Index) -> String.Index {
        // Tokenize only the contiguous CJK run so the token can't spill into Latin text.
        var runEnd = start
        while runEnd < text.endIndex, isCJK(text[runEnd]) { runEnd = text.index(after: runEnd) }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var end = text.index(after: start)
        tokenizer.enumerateTokens(in: start..<runEnd) { range, _ in
            if range.upperBound > start { end = min(range.upperBound, runEnd) }
            return false
        }
        return end
    }
}
