// Keeps a next-list-item marker apart from the sentence it follows. Pure.
import Foundation

/// While the writer is still on one list item, the model often finishes it and moves to the next.
/// Suggestions are one line, so the marker can end up glued to the sentence end ("casual.3. Email",
/// from a dropped line break or a decoder alternative to one). Word-by-word accept splits at
/// whitespace, so the glued marker would come with the last word. A space after the punctuation
/// keeps the marker a separate word the writer can stop before.
enum ListMarker {
    static let sentenceEnds: Set<Character> = [".", "!", "?", ":", ";"]

    /// `text` with a space put between sentence-ending punctuation and a list marker right after it,
    /// including at the start of `text` when `before` ends with such punctuation.
    static func separated(_ text: String, before: String) -> String {
        var out = ""
        var previous = before.last
        var beforePrevious = before.dropLast().last
        var rest = Substring(text)
        while let c = rest.first {
            // Not after "1." in "v1.2." (version separator, decimal point) or "3:" in "3:16)" and
            // "10:30)" (verse, time, ratio): punctuation glued between digits ends no sentence.
            if let p = previous, sentenceEnds.contains(p), !(isNumberSeparator(p) && beforePrevious?.isNumber == true),
               startsMarker(rest) {
                out.append(" ")
            }
            out.append(c)
            beforePrevious = previous
            previous = c
            rest = rest.dropFirst()
        }
        return out
    }

    /// Punctuation that joins two numbers when it sits right between digits: "1.5", "3:16", "10:30".
    static func isNumberSeparator(_ c: Character) -> Bool { c == "." || c == ":" }

    /// A numbered marker ("3. " "3) ") or a bullet ("- " "• " …) at the start of `text`. `loose` also
    /// takes a numbered marker at the very end of `text` ("quotes)3.") or right before a CJK
    /// character, and the "3、" form.
    static func startsMarker(_ text: Substring, loose: Bool = false) -> Bool {
        let chars = Array(text.prefix(5))
        guard let first = chars.first else { return false }
        func spaced(_ i: Int) -> Bool { i < chars.count && (chars[i] == " " || chars[i] == "\t") }
        if "-*•‣◦▪–—".contains(first) { return spaced(1) }
        var i = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        guard i > 0, i <= 3, i < chars.count else { return false }
        if chars[i] == "." || chars[i] == ")" {
            if spaced(i + 1) { return true }
        } else if !(loose && chars[i] == "、") {
            return false
        }
        guard loose else { return false }
        if i + 1 == chars.count { return text.count == chars.count }
        return chars[i] == "、" || TextMeasure.isCJK(chars[i + 1])
    }

    // MARK: - Inside existing text

    /// Sentence ends and closers, ASCII and CJK, that a next-item number can be glued to.
    static let closers: Set<Character> = sentenceEnds.union([")", "]", "\"", "'", "\u{201D}", "\u{2019}",
                                                             "」", "』", "。", "！", "？", "：", "；", "）"])
    static let cjkSentenceEnds: Set<Character> = ["。", "！", "？", "：", "；"]

    /// Whether a completion here must stop before any next-item marker: the caret is inside a
    /// line (text follows it on the same line), or the text after the caret starts a list item.
    /// At the end of a line with no item after it, the marker only gets a space (`separated`).
    static func mustStopBeforeMarker(after: String) -> Bool {
        let line = after.prefix { !$0.isNewline }
        if line.contains(where: { !$0.isWhitespace }) { return true }
        return startsMarker(after.drop { $0.isWhitespace }, loose: true)
    }

    /// `text` cut before the first next-list-item marker ("quotes)3." → "quotes)", "done. - next" →
    /// "done."), trailing whitespace removed. A marker counts when it follows a sentence end or a
    /// closer (directly or after spaces), or starts the line; a number after "1." ("v1.2.") or
    /// after a word ("page 3.") does not.
    static func cutBeforeNextItem(_ text: String, before: String) -> String {
        let beforeLast = before.reversed().first { $0 != " " && $0 != "\t" } ?? "\n"
        // "(John 3:" + "16) says": the text continues a number, not a new item.
        let beforeEndsInsideNumber = before.last == ":" && before.dropLast().last?.isNumber == true
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.first.map({ $0 != " " && $0 != "\t" }) == true,
               let p = previousNonSpace(in: text, before: index, fallback: beforeLast,
                                        fallbackInsideNumber: beforeEndsInsideNumber),
               startsAfter(p, rest: rest) {
                return TextMeasure.trimTrailingWhitespace(String(text[..<index]))
            }
            index = text.index(after: index)
        }
        return text
    }

    /// The last non-space character before `index` (one of `closers`, a line break or something
    /// else), or nil when `index` is inside a word or number (no marker can start there).
    /// `fallbackInsideNumber`: `before` ends in "3:", so text glued to its start continues a number.
    private static func previousNonSpace(in text: String, before index: String.Index, fallback: Character,
                                         fallbackInsideNumber: Bool) -> Character? {
        var i = index
        var sawSpace = false
        while i > text.startIndex {
            i = text.index(before: i)
            let c = text[i]
            if c == " " || c == "\t" { sawSpace = true; continue }
            if !sawSpace, c.isLetter || c.isNumber { return nil }
            // "v1.2.", "$5.3": a dot right after a digit is a decimal point or version separator.
            if c == ".", i > text.startIndex, text[text.index(before: i)].isNumber { return nil }
            // "3:16)", "10:30)": a colon glued between digits is part of the number.
            if c == ":", !sawSpace, i > text.startIndex, text[text.index(before: i)].isNumber { return nil }
            return c
        }
        if !sawSpace, fallbackInsideNumber { return nil }
        return fallback
    }

    private static func startsAfter(_ p: Character, rest: Substring) -> Bool {
        guard startsMarker(rest, loose: true) else { return false }
        if p.isNewline { return true }
        // Bullets only after a sentence end: "(see above) - and" is a dash, not a new item.
        if let first = rest.first, !first.isNumber { return sentenceEnds.contains(p) || cjkSentenceEnds.contains(p) }
        return closers.contains(p)
    }
}
