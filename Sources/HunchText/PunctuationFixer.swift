// "Fix punctuation" (formal apps): a space before punctuation ("word ."), no space after a full stop
// ("end.Next"), doubled spaces (or two spaces for a full stop, like macOS) and missing apostrophes
// ("dont" → "don't"). Pure text rules; `CorrectionFinder` runs them when `fixesPunctuation` is on and
// the fix goes through the same struck-through / automatic paths as a spelling fix.
//
// Every fix is made only when the finished word or punctuation is certain; anything that could be a
// link, address, path, number, abbreviation, ellipsis or code is left alone.
import Foundation

public enum PunctuationFixer {
    /// What a doubled space becomes.
    public enum DoubleSpace: Sendable, Equatable {
        /// Left alone: the host app handles it (native text views apply macOS's period shortcut).
        case off
        /// "end  " → "end ".
        case collapse
        /// "end  " → "end. ", like the macOS "Add period with double-space" shortcut, in apps that don't do it.
        case period
    }

    // MARK: Apostrophes

    /// Contractions typed without the apostrophe. Only forms that are not an everyday word of their
    /// own. Left out on purpose because they are real words: its, well, were, wed, ill, hell, shell,
    /// id (also chat shorthand), lets, hes, whos. "cant" and "wont" are real but rare words ("wont" =
    /// habit, "cant" = jargon); the contraction is far likelier, so they are fixed.
    public static let contractions: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "isnt": "isn't", "arent": "aren't",
        "wasnt": "wasn't", "werent": "weren't", "wont": "won't", "cant": "can't", "couldnt": "couldn't",
        "shouldnt": "shouldn't", "wouldnt": "wouldn't", "hasnt": "hasn't", "havent": "haven't",
        "hadnt": "hadn't", "mustnt": "mustn't", "youre": "you're", "theyre": "they're", "thats": "that's",
        "theres": "there's", "whats": "what's", "heres": "here's", "im": "I'm", "ive": "I've",
        "youve": "you've", "weve": "we've", "theyve": "they've", "youll": "you'll", "theyll": "they'll",
        "itll": "it'll", "wouldve": "would've", "couldve": "could've", "shouldve": "should've",
    ]

    /// The contraction for a typed word ("Dont" → "Don't"), or nil. All-caps and odd casing are left
    /// alone; `apostrophe` is the character to use (straight or typographic).
    public static func contraction(for token: String, apostrophe: Character = "'") -> String? {
        let lower = token.lowercased()
        guard var fixed = contractions[lower] else { return nil }
        if token != lower {
            // "Dont" (first letter capital, rest lower) only; "DONT", "dOnt" are left as typed.
            guard token.first?.isUppercase == true, token.dropFirst() == lower.dropFirst() else { return nil }
            fixed = fixed.prefix(1).uppercased() + fixed.dropFirst()
        }
        return apostrophe == "'" ? fixed : fixed.replacingOccurrences(of: "'", with: String(apostrophe))
    }

    /// Straight unless the text before uses only typographic apostrophes.
    static func apostropheStyle(in text: String) -> Character {
        let tail = text.suffix(400)
        return tail.contains("\u{2019}") && !tail.contains("'") ? "\u{2019}" : "'"
    }

    /// The word is plain: not glued to a path, address, hashtag, mention, number or code.
    static func isPlainWordPosition(token: String, in stripped: String) -> Bool {
        let before = stripped.dropLast(token.count)
        if let c = before.last, c.isLetter || c.isNumber || "/@#._-~\\:$%&=+<>`".contains(c) { return false }
        return !NeverTouch.protectsLastWord(in: stripped, forSpacing: true)
    }

    /// An odd number of backticks on the line: the caret is inside inline code.
    static func insideBackticks(_ text: String) -> Bool { NeverTouch.insideCode(text) }

    // MARK: Spacing and full stops

    private static let spaces: Set<Character> = [" ", "\u{00A0}"]
    private static let closers: Set<Character> = [")", "]", "\"", "\u{201D}", "\u{2019}", "'"]
    private static let domainWords: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "co", "uk", "de", "fr", "js", "py", "ts", "rs", "md", "app",
        "dev", "ai", "html", "css", "php", "txt", "pdf", "png", "jpg", "json", "xml", "swift",
    ]

    /// A spacing/full-stop fix for the text before the caret, nil when there is nothing sure to fix.
    /// Runs when the character just typed is a space. `isKnownWord` answers for lowercase words.
    public static func spacingFix(before: String, doubleSpace: DoubleSpace, languages: [String],
                                  isKnownWord: (String) -> Bool) -> CorrectionProposal? {
        guard let last = before.last, spaces.contains(last) else { return nil }
        var body = Substring(String(before.suffix(160)))
        body = body.dropLast()
        if let c = body.last, spaces.contains(c) {
            return doubledSpace(body: body, mode: doubleSpace)
        }
        if let fix = spaceBeforePunctuation(body: body, languages: languages) { return fix }
        return missingSpaceAfterStop(body: body, isKnownWord: isKnownWord)
    }

    private static func whitespaceToken(_ s: Substring) -> Substring {
        guard let i = s.lastIndex(where: { $0.isWhitespace }) else { return s }
        return s[s.index(after: i)...]
    }

    private static func isCleanToken(_ token: Substring) -> Bool {
        !token.isEmpty && !token.contains(where: { "/@\\#_".contains($0) })
            && !token.contains("://") && !token.contains("`")
            && NeverTouch.kind(of: String(token), forSpacing: true) == nil
    }

    /// "word ." + space → "word. ". Only after a word, never for ":" or ";" (emoticons), never an
    /// ellipsis, and "! ?" are left to French (where the space belongs).
    private static func spaceBeforePunctuation(body: Substring, languages: [String]) -> CorrectionProposal? {
        guard let p = body.last, ".,!?".contains(p) else { return nil }
        let french = languages.contains { $0.lowercased().hasPrefix("fr") }
        if french && (p == "!" || p == "?") { return nil }
        var rest = body.dropLast()
        var gap = 0
        while let c = rest.last, spaces.contains(c) { rest = rest.dropLast(); gap += 1 }
        guard gap > 0, gap <= 2 else { return nil }
        let token = whitespaceToken(rest)
        guard isCleanToken(token), let end = token.last,
              end.isLetter || closers.contains(end) else { return nil }
        guard !insideBackticks(String(rest)) else { return nil }
        // The punctuation is one mark ("word . ." and "word .." are not touched).
        let span = String(token) + String(repeating: " ", count: gap) + String(p) + " "
        return CorrectionProposal(misspelled: span, replacement: String(token) + String(p) + " ",
                                  deleteCount: span.count, trailing: "")
    }

    /// "end.Next" + space → "end. Next ". Both sides plain lowercase/Capitalized words that spell
    /// correctly, so "e.g.", "U.S.", "v1.2", "3.5", "site.Com", "file.Txt" and "Node.Js" stay.
    private static func missingSpaceAfterStop(body: Substring, isKnownWord: (String) -> Bool) -> CorrectionProposal? {
        let token = whitespaceToken(body)
        guard isCleanToken(token), token.filter({ $0 == "." }).count == 1,
              let dot = token.firstIndex(of: ".") else { return nil }
        let left = token[..<dot], right = token[token.index(after: dot)...]
        guard left.count >= 3, left.allSatisfy({ $0.isLetter && $0.isLowercase }),
              right.count >= 2, right.first?.isUppercase == true,
              right.dropFirst().allSatisfy({ $0.isLetter && $0.isLowercase }) else { return nil }
        let rightLower = right.lowercased()
        guard !domainWords.contains(rightLower), !domainWords.contains(String(left)),
              isKnownWord(String(left)), isKnownWord(rightLower),
              !insideBackticks(String(body)) else { return nil }
        let span = String(token) + " "
        return CorrectionProposal(misspelled: span, replacement: "\(left). \(right) ",
                                  deleteCount: span.count, trailing: "")
    }

    /// Two spaces typed after a word: a full stop and a space (macOS's shortcut) or one space.
    private static func doubledSpace(body: Substring, mode: DoubleSpace) -> CorrectionProposal? {
        guard mode != .off else { return nil }
        var rest = body
        var gap = 0
        while let c = rest.last, spaces.contains(c) { rest = rest.dropLast(); gap += 1 }
        guard gap == 1 else { return nil }   // exactly the second space just typed
        let token = whitespaceToken(rest)
        guard isCleanToken(token), let end = token.last, !insideBackticks(String(rest)) else { return nil }
        let endsWord = end.isLetter || end.isNumber || closers.contains(end)
        let sentenceEnd = ".!?".contains(end)
        guard endsWord || sentenceEnd || ",;:".contains(end) else { return nil }
        let span = String(token) + "  "
        // Period only after a plain word; after punctuation or a closing mark it is just one space.
        let makesPeriod = mode == .period && (end.isLetter || end.isNumber)
        return CorrectionProposal(misspelled: span, replacement: String(token) + (makesPeriod ? ". " : " "),
                                  deleteCount: span.count, trailing: "")
    }
}
