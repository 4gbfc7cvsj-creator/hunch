// One check for text autocorrect must never change: links, emails, @mentions, #hashtags, file paths,
// identifiers (camelCase, PascalCase, snake_case), code (inline or fenced), all-caps abbreviations,
// version numbers and decimals. Every fix path in `CorrectionFinder` and `PunctuationFixer` asks here,
// so a word that is part of such a token ("example" in "example.com", a segment of a path) is never
// fixed, and never used as a neighbour to fix another word with.
import Foundation
import HunchCore

public enum NeverTouch {
    public enum Kind: String, Sendable, CaseIterable {
        case url, email, mention, hashtag, path, identifier, code, abbreviation, number
        /// A dot between letters or digits ("file.txt", "node.js", "e.g"): part of a name or address.
        case dotted
    }

    // MARK: Text before the caret

    /// True when the last word of `text` (which ends at the word: no space or punctuation after it)
    /// is untouchable: part of a token of any kind, or inside code. `forSpacing` leaves out kinds that
    /// spacing fixes may still act on ("NASA  " → "NASA. ", "end.Next").
    public static func protectsLastWord(in text: String, forSpacing: Bool = false) -> Bool {
        if insideCode(text) { return true }
        return kind(of: lastChunk(of: text), forSpacing: forSpacing) != nil
    }

    /// The whitespace-free chunk at the end of `text`.
    public static func lastChunk(of text: String) -> String {
        var start = text.endIndex
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace { start = text.index(before: start) }
        return String(text[start...])
    }

    /// An odd number of backticks on the current line (inline code), or an unclosed fence ("```").
    public static func insideCode(_ text: String) -> Bool {
        guard text.contains("`") else { return false }
        if text.components(separatedBy: "```").count % 2 == 0 { return true }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return line.filter { $0 == "`" }.count % 2 == 1
    }

    // MARK: One chunk

    private static let leadingWrap = Set("([{<\"'\u{201C}\u{2018}\u{00AB}")
    private static let trailingWrap = Set(".,;:!?\"')]}>\u{201D}\u{2019}\u{00BB}\u{2026}*")

    /// What kind of untouchable token `chunk` (text between whitespace, as typed) is, or nil.
    public static func kind(of chunk: String, forSpacing: Bool = false) -> Kind? {
        guard !chunk.isEmpty else { return nil }
        if chunk.contains("`") { return .code }
        var t = Substring(chunk)
        while let f = t.first, leadingWrap.contains(f) { t = t.dropFirst() }
        while let l = t.last, trailingWrap.contains(l) { t = t.dropLast() }
        guard !t.isEmpty else { return nil }
        let s = String(t)
        let chars = Array(s)

        if URLShape.isURL(chunk) || URLShape.isURL(s) { return .url }
        if matches(emailPattern, s) { return .email }
        if chars[0] == "@", chars.count > 1, chars[1].isLetter || chars[1].isNumber { return .mention }
        if chars.dropFirst().contains("@"), chars.last != "@" { return .email }
        if chars[0] == "#", chars.count > 1, chars[1].isLetter || chars[1].isNumber { return .hashtag }
        if isPath(s, chars) { return .path }
        if isIdentifier(s, chars) { return .identifier }
        if matches(decimalPattern, s) || matches(versionPattern, s) { return .number }
        if matches(initialsPattern, s) { return .dotted }
        if forSpacing { return nil }
        if isAbbreviation(chars) { return .abbreviation }
        if hasInnerDot(chars) { return .dotted }
        return nil
    }

    // MARK: Shapes

    private static let emailPattern = try! NSRegularExpression(pattern: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#)
    private static let decimalPattern = try! NSRegularExpression(pattern: #"\d+[.,]?\d*\.\d+"#)
    private static let versionPattern = try! NSRegularExpression(pattern: #"^[vV]\d+(\.\d+)*$"#)
    /// "e.g", "i.e", "U.S", "U.S.A", "a.m": single letters between dots.
    private static let initialsPattern = try! NSRegularExpression(pattern: #"^\p{L}(\.\p{L})+$"#)
    private static let drivePattern = try! NSRegularExpression(pattern: #"^[A-Za-z]:[\\/]"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `~/x`, `/usr/x`, `./x`, `../x`, `C:\x`, anything with two or more slashes or a backslash
    /// between letters. One slash alone ("and/or", "w/o") is ordinary text.
    private static func isPath(_ s: String, _ chars: [Character]) -> Bool {
        if s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("~\\") { return true }
        if matches(drivePattern, s) { return true }
        if chars[0] == "/", chars.count > 1, chars[1].isLetter || chars[1] == "." || chars[1] == "~" { return true }
        if chars.filter({ $0 == "/" }).count >= 2, chars.contains(where: \.isLetter) { return true }
        for i in chars.indices.dropFirst().dropLast() where chars[i] == "\\" {
            if chars[i - 1].isLetter || chars[i - 1].isNumber, chars[i + 1].isLetter || chars[i + 1].isNumber { return true }
        }
        return false
    }

    /// snake_case, `__dunder__`, camelCase, PascalCase. A Caps Lock slip ("tHIS": lowercase first
    /// letter, all capitals after) is not an identifier, and `_italic_` is markdown.
    private static func isIdentifier(_ s: String, _ chars: [Character]) -> Bool {
        if chars.contains("_") {
            let letters = chars.filter(\.isLetter)
            if !letters.isEmpty, !matches(italicPattern, s) { return true }
        }
        let letters = chars.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if letters[0].isLowercase, letters.count >= 3, letters.dropFirst().allSatisfy(\.isUppercase) { return false }
        for i in chars.indices.dropFirst() where chars[i].isUppercase && chars[i - 1].isLowercase { return true }
        return false
    }

    private static let italicPattern = try! NSRegularExpression(pattern: #"^_[^_]+_$"#)

    /// Two or more capitals, no lower case ("API", "NASA", "APIs", "COVID-19", "B2B").
    private static func isAbbreviation(_ chars: [Character]) -> Bool {
        var letters = chars.filter(\.isLetter)
        if letters.last == "s", letters.count >= 3, letters.dropLast().allSatisfy(\.isUppercase), chars.last == "s" {
            letters.removeLast()
        }
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    private static func hasInnerDot(_ chars: [Character]) -> Bool {
        for i in chars.indices.dropFirst().dropLast() where chars[i] == "." {
            if (chars[i - 1].isLetter || chars[i - 1].isNumber), (chars[i + 1].isLetter || chars[i + 1].isNumber) { return true }
        }
        return false
    }
}
