import Foundation
import HunchCore

/// Makes a suggestion's quotes and apostrophes match the ones already in the field: curly
/// (’ ‘ “ ”, what smart quotes produce in Mail, Notes and Pages) or straight (' "). Models write
/// either, so without this a suggestion could drop a straight "can't" into curly text.
public enum QuoteStyle {
    public enum Style: Equatable { case curly, straight }

    static let curlyMarks: Set<Character> = ["\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}"]
    static let straightMarks: Set<Character> = ["'", "\""]

    /// The field's style from the text before the caret: the only style used, else the one used
    /// last. Nil when the field has no quotes or apostrophes yet (the suggestion is left alone).
    public static func detect(in before: String) -> Style? {
        for c in before.suffix(4000).reversed() {
            if curlyMarks.contains(c) { return .curly }
            if straightMarks.contains(c) { return .straight }
        }
        return nil
    }

    /// `text` with its quotes converted to the field's style. `before` supplies the character in
    /// front of the suggestion, which decides opening vs closing marks. `.straight` (smart quotes
    /// off for the app or site) converts curly marks to straight whatever the field uses.
    public static func match(_ text: String, before: String, preference: QuotePreference = .matchField) -> String {
        let detected: Style? = preference == .straight ? .straight : detect(in: before)
        guard let style = detected,
              text.contains(where: { curlyMarks.contains($0) || straightMarks.contains($0) }) else { return text }
        var out = ""
        var previous: Character? = before.last
        for c in text {
            let converted: Character
            switch (style, c) {
            case (.straight, "\u{2018}"), (.straight, "\u{2019}"): converted = "'"
            case (.straight, "\u{201C}"), (.straight, "\u{201D}"): converted = "\""
            case (.curly, "'"): converted = opens(after: previous) ? "\u{2018}" : "\u{2019}"
            case (.curly, "\""): converted = opens(after: previous) ? "\u{201C}" : "\u{201D}"
            default: converted = c
            }
            out.append(converted)
            previous = converted
        }
        return out
    }

    /// A quote opens at the start, after whitespace, or after an opening bracket, dash or quote;
    /// otherwise it closes (or is an apostrophe, which is the same mark as a closing single quote).
    static func opens(after previous: Character?) -> Bool {
        guard let p = previous else { return true }
        return p.isWhitespace || "([{<\u{2014}\u{2013}-\u{201C}\u{2018}".contains(p)
    }
}
