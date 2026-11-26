// Post-processing rules for code buffers (`PostContext.surface == .code`). Pure.
import Foundation

/// How `DefaultPostProcessor` treats a completion for source code: no typo check (identifiers
/// are not misspellings), no quote or script normalization (a string literal must stay as
/// written), a clamp by characters cut at a token boundary instead of by prose words, and a
/// single trailing newline only when the kept line ends a statement. Suppression rules that
/// catch model chatter (AI voice, meta replies, echoes, markup) still apply.
public enum CodePostProfile {
    /// Characters allowed per "word" of the length preset: a code token is short and carries
    /// its punctuation, so `maxWords` prose words make room for about this many characters each.
    public static let charactersPerWord = 10

    /// A line ending in one of these has finished a statement or opened a block.
    static let statementEnders: Set<Character> = [";", "{", "}", ")", ":"]

    /// Character budget for `maxWords` (no limit for `maxWords <= 0`).
    public static func characterBudget(maxWords: Int) -> Int? {
        maxWords > 0 ? maxWords * charactersPerWord : nil
    }

    /// The longest prefix of `text` within the character budget that ends at a token boundary
    /// (whitespace, or where an identifier run meets symbols), trailing whitespace removed. A
    /// text with no boundary inside the budget is kept whole: an identifier is never cut.
    public static func clamp(_ text: String, maxWords: Int) -> String {
        guard let budget = characterBudget(maxWords: maxWords), text.count > budget else { return text }
        var cut: String.Index?
        var count = 0
        var previous: Bool?   // true = identifier character, false = symbol, nil = whitespace
        for index in text.indices {
            if count > budget { break }
            let c = text[index]
            let kind: Bool? = c.isWhitespace ? nil : (c.isLetter || c.isNumber || c == "_")
            if count > 0, kind == nil || (previous != nil && kind != previous) { cut = index }
            previous = kind
            count += 1
        }
        guard let cut else { return text }
        return trimTrailingWhitespace(String(text[..<cut]))
    }

    /// True when the line's last non-whitespace character ends a statement or opens a block.
    public static func endsStatement(_ line: String) -> Bool {
        guard let last = line.last(where: { !$0.isWhitespace }) else { return false }
        return statementEnders.contains(last)
    }

    /// Whether the kept line may carry one trailing newline: only when the model went on to a
    /// further line (`continued`), nothing of the kept line was clamped away, and it ends a
    /// statement. Multi-line completions stay out; this just lets the caret move on.
    public static func keepsTrailingNewline(line: String, continued: Bool, clamped: Bool) -> Bool {
        continued && !clamped && endsStatement(line)
    }

    /// Whether `raw` has text on a line after its first non-blank line.
    public static func continuesPastFirstLine(_ raw: String) -> Bool {
        let body = raw.drop(while: \.isWhitespace)
        guard let newline = body.firstIndex(where: \.isNewline) else { return false }
        return body[newline...].contains(where: { !$0.isWhitespace })
    }

    static func trimTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return String(result)
    }
}
