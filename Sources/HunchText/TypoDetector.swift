// Likely-typo detection around the caret (design §13 "Autocorrect"). Pure given a `SpellChecking`.
import Foundation
import NaturalLanguage

/// Guesses the language of a piece of text (BCP-47 base code such as "en") with a confidence in 0...1.
protocol LanguageGuessing: Sendable {
    func guess(_ text: String) -> (language: String, confidence: Double)?
}

/// `NLLanguageRecognizer`-backed guesser (pure computation, safe on any thread).
struct NLLanguageGuesser: LanguageGuessing {
    func guess(_ text: String) -> (language: String, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        let base = top.key.rawValue.split(separator: "-").first.map(String.init) ?? top.key.rawValue
        return (base.lowercased(), top.value)
    }
}

/// Decides whether the writer should fix a misspelled word before being offered more text.
enum TypoDetector {
    /// True when the suggestion should be hidden.
    ///
    /// - Caret after a word (the suggestion starts with a space/punctuation, or `before` ends in a
    ///   boundary): the last completed word is checked.
    /// - Caret mid-word (`before` ends in letters and the suggestion continues them): the word the
    ///   suggestion would complete is checked, and the partial must not be a prefix of any correct word.
    /// Anything uncertain (capitalized, ALL-CAPS, camelCase, digits, URLs, mentions, tags, code, CJK,
    /// shorter than 3 letters, in `knownWords`) is never a typo.
    ///
    /// Precision first: recent text confidently in a language the checker was not asked to use,
    /// and common slang/abbreviations (`slang`), never suppress.
    static func shouldSuppress(before: String, suggestion: String, checker: any SpellChecking,
                               languages: [String], knownWords: Set<String>, learnedInPlay: [String] = [],
                               guesser: any LanguageGuessing = NLLanguageGuesser()) -> Bool {
        let tail = String(before.suffix(120))
        let chunk = continuation(of: suggestion)
        let partial = trailingLetters(of: tail)

        if !partial.isEmpty, !chunk.isEmpty {
            // Mid-word: the token is everything since the last whitespace plus the suggested chunk.
            let token = trailingToken(of: tail) + chunk
            guard let word = checkable(token, known: knownWords) else { return false }
            let partialWord = normalizeApostrophes(partial).lowercased()
            guard checker.isMisspelled(word, languages: languages) else { return false }
            // A learned word in play starts with the typed letters, and the suggestion finishes them into
            // neither that word nor a dictionary word ("microsp" + "eak"): a mangled learned word.
            if learnedInPlay.contains(where: { finishes(partialWord, into: $0, not: word) }) { return true }
            if looksForeign(word: word, recentText: tail, languages: languages, guesser: guesser) { return false }
            return !checker.isKnownPrefix(partialWord, languages: languages)
        }

        // Caret at a word boundary: check the last completed word.
        guard let word = checkable(trailingToken(of: tail), known: knownWords) else { return false }
        guard checker.isMisspelled(word, languages: languages) else { return false }
        return !looksForeign(word: word, recentText: tail, languages: languages, guesser: guesser)
    }

    /// `learned` (as written, any case) extends `partial` and isn't the finished `word`.
    static func finishes(_ partial: String, into learned: String, not word: String) -> Bool {
        let l = normalizeApostrophes(learned.trimmingCharacters(in: .whitespaces)).lowercased()
        return l.count > partial.count && l.hasPrefix(partial) && l != word
    }

    /// Frequent informal words and abbreviations that dictionaries lack; never typos.
    static let slang: Set<String> = [
        "tbh", "imo", "imho", "lol", "lmao", "btw", "idk", "omg", "pls", "plz", "thx", "ty", "np", "brb", "afk",
        "fyi", "asap", "irl", "smh", "ikr", "rn", "gonna", "wanna", "gotta", "kinda", "sorta", "lemme", "gimme",
        "dunno", "ok", "okay", "yeah", "yep", "yup", "nope", "nah", "hmm", "hmmm", "ugh", "meh", "yay", "wow",
        "cuz", "coz", "tho", "thru", "ya", "yall", "ain't", "tmrw", "tmr", "bc", "wtf", "wth", "ppl", "msg",
        "info", "app", "apps", "wifi", "email", "emails", "selfie", "vlog", "blog", "emoji", "emojis",
    ]

    /// True when the recent text is confidently in a language the writer's checker does not cover
    /// (a whole sentence of Spanish). A single word is not judged on its own: the language guesser
    /// labels most typos as some other language ("tihs" → Indonesian), so a word is a typo exactly
    /// when the spell checker says so, the same check that draws the system's red underline.
    static func looksForeign(word: String, recentText: String, languages: [String],
                             guesser: any LanguageGuessing) -> Bool {
        var own = Set(languages.compactMap { raw in
            raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { $0.lowercased() }
        })
        if own.isEmpty, let system = Locale.preferredLanguages.first?.split(separator: "-").first {
            own = [system.lowercased()]
        }
        own.subtract(["zh", "ja", "ko"])
        guard !own.isEmpty else { return false }
        let context = String(recentText.dropLast(word.count))
        if context.filter(\.isLetter).count >= 20, let g = guesser.guess(context), g.confidence >= 0.7,
           !own.contains(g.language) {
            return true
        }
        return false
    }

    /// Letters and interior apostrophes at the start of the suggestion ("ved", "'t").
    static func continuation(of suggestion: String) -> String {
        var out = ""
        for c in suggestion {
            if c.isLetter && !TextMeasure.isCJK(c) { out.append(c) } else if isApostrophe(c) { out.append(c) } else { break }
        }
        return out
    }

    private static func trailingLetters(of text: String) -> String {
        var out: [Character] = []
        for c in text.reversed() {
            if c.isLetter && !TextMeasure.isCJK(c) { out.append(c) } else if isApostrophe(c), !out.isEmpty { out.append(c) } else { break }
        }
        // A leading apostrophe belongs to quoting, not the word.
        while out.last.map(isApostrophe) == true { out.removeLast() }
        return String(out.reversed())
    }

    /// The last whitespace-delimited chunk, with edge quoting/punctuation stripped. Mid-word callers
    /// pass text that ends in the partial word, so nothing trailing is stripped there in practice.
    static func trailingToken(of text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        var start = end
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace { start = text.index(before: start) }
        var token = Substring(text[start..<end])
        let leading = Set("\"'“‘([{«¿¡*_")
        let trailing = Set(".,;:!?\"'”’)]}»…*")
        while let f = token.first, leading.contains(f) { token = token.dropFirst() }
        while let l = token.last, trailing.contains(l) { token = token.dropLast() }
        return String(token)
    }

    /// The lowercase word to look up, or nil when this token must never be treated as a typo.
    /// `minLetters`: shorter words are never checked (2 only where the model picks the fix).
    static func checkable(_ rawToken: String, known: Set<String>, minLetters: Int = 3) -> String? {
        let token = normalizeApostrophes(rawToken)
        guard !token.isEmpty else { return nil }
        var letters = 0
        for (i, c) in token.enumerated() {
            if c == "'" {
                if i == 0 || i == token.count - 1 { return nil }
                continue
            }
            guard c.isLetter, isLatin(c) else { return nil }  // digits, symbols, URLs, @, #, -, _, /, CJK ...
            guard !c.isUppercase else { return nil }  // proper nouns, acronyms, camelCase
            letters += 1
        }
        guard letters >= minLetters else { return nil }
        if known.contains(token) || slang.contains(token) { return nil }
        return token
    }

    private static func isLatin(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) || $0.properties.isGraphemeExtend }
    }

    private static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "\u{2019}" }

    private static func normalizeApostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
