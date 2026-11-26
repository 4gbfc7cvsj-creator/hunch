// Auto-capitalization: capital slips that have exactly one right answer, and the first word of a sentence.
import Foundation

/// A capital fix for one finished word ("THe" → "The", "tHIS" → "This", "i'm" → "I'm", "monday" →
/// "Monday", "iphone" → "iPhone"), or nil. Pure text rules; the caller decides where it may run
/// (not in code or terminals, not in chat apps, not where the switch is off).
public enum CapitalFix {
    /// Words the dictionary lacks or that differ from plain capitalization.
    static let brands: [String: String] = [
        "iphone": "iPhone", "ipad": "iPad", "ipod": "iPod", "imac": "iMac", "macbook": "MacBook",
        "macos": "macOS", "ios": "iOS", "ipados": "iPadOS", "watchos": "watchOS", "tvos": "tvOS",
        "visionos": "visionOS", "icloud": "iCloud", "itunes": "iTunes", "airpods": "AirPods",
        "youtube": "YouTube", "github": "GitHub", "linkedin": "LinkedIn", "whatsapp": "WhatsApp",
        "facebook": "Facebook", "instagram": "Instagram", "paypal": "PayPal", "javascript": "JavaScript",
        "typescript": "TypeScript", "google": "Google", "microsoft": "Microsoft", "tiktok": "TikTok",
        "wikipedia": "Wikipedia", "chatgpt": "ChatGPT", "openai": "OpenAI",
    ]

    /// "may" and "march" are ordinary words, so they are left alone.
    static let datedNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "april", "june", "july", "august", "september", "october",
        "november", "december",
    ]

    static let iContractions: Set<String> = ["i'm", "i'll", "i've", "i'd"]

    /// `token`: the finished word without surrounding punctuation. `before`: the text before the
    /// token. `trailing`: what was typed after it. `isWord`: true when the lowercase form is a
    /// correctly spelled word.
    static func fix(token: String, before: Substring, trailing: String, isWord: (String) -> Bool) -> String? {
        guard !token.isEmpty, token.count <= 20 else { return nil }
        // Only plain words: no digits, symbols, dots, slashes (links, paths, handles, code, emails).
        let plain = token.allSatisfy { ($0.isASCII && $0.isLetter) || $0 == "'" || $0 == "\u{2019}" }
        guard plain else { return nil }
        // Out of reach inside backticks, links, handles, paths, hashtags or attached to other text.
        if let prev = before.last, !(prev.isWhitespace || "\"“‘«".contains(prev)) { return nil }
        if NeverTouch.insideCode(String(before)) { return nil }
        let lower = token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let letters = token.filter(\.isLetter)

        // A lone "i" and its contractions. A full stop after it may be a list number ("i.").
        if lower == "i" {
            guard token == "i", !trailing.hasPrefix(".") else { return nil }
            return "I"
        }
        if iContractions.contains(lower) {
            guard token.hasPrefix("i") else { return nil }
            return "I" + token.dropFirst()
        }
        // Two apostrophes, "'" at the edges and other leftovers are not words.
        guard !token.contains("'"), letters.count >= 2 else { return nil }
        // Two-letter words ("so", "it", "we") only get a sentence's first capital.
        if letters.count == 2 {
            return token == lower && startsSentence(before: before) && isWord(lower) ? lower.capitalized : nil
        }

        if let brand = brands[lower] {
            // Already right, or shouted (IOS, NASA-style): leave it.
            guard token != brand, token != token.uppercased() else { return nil }
            return brand
        }
        guard !brands.values.contains(token) else { return nil }
        if datedNames.contains(lower) { return token == token.lowercased() ? lower.capitalized : nil }

        let chars = Array(token)
        // Two capitals at the start, then lower case: "THe".
        if chars.count >= 3, chars[0].isUppercase, chars[1].isUppercase,
           chars.dropFirst(2).allSatisfy(\.isLowercase), isWord(lower) {
            return lower.capitalized
        }
        // Caps Lock left on after the first letter: "tHIS".
        if chars.count >= 3, chars[0].isLowercase, chars.dropFirst().allSatisfy(\.isUppercase), isWord(lower) {
            return lower.capitalized
        }
        // The first word of a sentence, typed all lower case ("hello" after ". ").
        if token == lower, startsSentence(before: before), isWord(lower) { return lower.capitalized }
        return nil
    }

    /// Abbreviations whose full stop does not end a sentence ("Dr. smith"). Ones with inner dots
    /// ("e.g.", "i.e.", "a.m.") and single letters (initials, list letters) are caught separately.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "sr", "jr", "st", "mt", "ft", "vs", "etc", "inc", "ltd", "co",
        "corp", "dept", "approx", "est", "fig", "figs", "vol", "cf", "ca", "al", "gov", "sen", "col", "lt",
        "cmdr", "capt", "sgt", "rev", "hon", "ave", "blvd", "rd", "apt", "tel", "ext", "misc", "ref", "eg", "ie",
        "jan", "feb", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// `word` with its first letter upper case, when it is plain lower case ("yes" → "Yes", "don't" →
    /// "Don't"). Words with a capital inside ("iPhone", "macOS") and non-letters stay as they are.
    static func capitalizingFirst(_ word: String) -> String {
        guard let first = word.first, first.isLowercase, !word.dropFirst().contains(where: \.isUppercase) else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// True when a word typed right after `before` opens a sentence: the start of the field, a new
    /// line, or after `.` `!` `?` and a space. Not after an abbreviation, initial, ellipsis, decimal,
    /// link or file name.
    static func startsSentence(before: Substring) -> Bool {
        var t = before
        // Opening quotes and brackets in front of the word.
        while let l = t.last, "\"“‘«([".contains(l) { t = t.dropLast() }
        if t.isEmpty { return true }
        guard let last = t.last, last.isWhitespace else {
            return false  // "end.the", "a-the": attached to the text before
        }
        // A new line (also after spaces): the start of a line.
        let lineStart = t.reversed().first(where: { !($0 == " " || $0 == "\u{00A0}" || $0 == "\t") })
        if lineStart == nil || lineStart!.isNewline { return true }
        var body = Substring(t.trimmingCharacters(in: .whitespaces))
        // Closing quotes and brackets after the stop: `He said "go." then`.
        while let l = body.last, "\"”’»)]'".contains(l) { body = body.dropLast() }
        guard let stop = body.last, stop == "." || stop == "!" || stop == "?" else { return false }
        let chunk = NeverTouch.lastChunk(of: String(body))
        if NeverTouch.insideCode(String(before)) { return false }
        if stop != "." {
            // "what?" fine; "site.com?" or "?!" runs are not sentence ends we are sure of.
            return NeverTouch.kind(of: chunk) == nil
        }
        var word = Substring(chunk)
        while let l = word.last, l == "." { word = word.dropLast() }
        if chunk.hasSuffix("..") { return false }  // ellipsis: the sentence goes on
        while let f = word.first, "\"“‘«([".contains(f) { word = word.dropFirst() }
        guard !word.isEmpty else { return false }
        if word.contains(".") { return false }  // e.g. i.e. U.S. file.txt example.com 3.5
        if word.count == 1, word.first!.isLetter { return false }  // initials, "a." list letters
        if abbreviations.contains(word.lowercased()) { return false }
        // Version numbers, links, emails, paths and the like.
        if NeverTouch.kind(of: chunk) == .url || NeverTouch.kind(of: chunk) == .email
            || NeverTouch.kind(of: chunk) == .path { return false }
        return true
    }
}
