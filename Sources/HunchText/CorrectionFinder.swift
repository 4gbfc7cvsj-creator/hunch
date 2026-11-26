// Autocorrect (design §13, M4): finds the last completed word before the caret and proposes a fix.
// Fires under exactly the TypoDetector's guards, so a typo is either fixed or hides the suggestion.
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// A replacement for the misspelled word just typed. Applying it deletes `deleteCount` characters
/// before the caret (the word plus `trailing`) and types `replacement + trailing`.
public struct CorrectionProposal: Sendable, Equatable {
    public var misspelled: String
    public var replacement: String
    /// Characters to delete before the caret: the word plus any whitespace/punctuation typed after it.
    public var deleteCount: Int
    /// The whitespace/punctuation after the word, re-typed after the replacement.
    public var trailing: String

    public init(misspelled: String, replacement: String, deleteCount: Int, trailing: String) {
        self.misspelled = misspelled
        self.replacement = replacement
        self.deleteCount = deleteCount
        self.trailing = trailing
    }
}

/// Proposes a single correction for a misspelled word. `context` is the text before the caret
/// (ending with the word, possibly followed by trailing punctuation), used for disambiguation only.
public protocol CorrectionSuggesting: Sendable {
    func correction(for word: String, context: String, languages: [String]) -> String?
    /// The system's confident correction, kept apart from its ranked guesses ("fo": none, then
    /// "to", "of", "do", "go"). A suggester that can't tell them apart answers its correction as
    /// confident and no guesses.
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions
    /// Correctly spelled words that start with `prefix`, likeliest first (a short list).
    func completions(forPrefix prefix: String, languages: [String]) -> [String]
}

extension CorrectionSuggesting {
    public func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        CorrectionOptions(confident: correction(for: word, context: context, languages: languages), guesses: [])
    }
    public func completions(forPrefix prefix: String, languages: [String]) -> [String] { [] }
}

/// What the system offers for a misspelled word: a correction it would apply itself, and its guesses.
public struct CorrectionOptions: Sendable, Equatable {
    public var confident: String?
    public var guesses: [String]
    public init(confident: String?, guesses: [String]) {
        self.confident = confident
        self.guesses = guesses
    }
}

/// A misspelled word the system can't fix confidently, waiting for the next word so the language
/// model can choose among `candidates` ("fo" → "for", "of", "to"...). The candidates are cased like
/// the typed word and never include it; `fallback` is the system's first plausible guess.
public struct AmbiguousTypo: Sendable, Equatable {
    public var misspelled: String
    public var candidates: [String]
    public var fallback: String?
    /// The word plus `trailing` (deleted when replacing at the caret).
    public var deleteCount: Int
    public var trailing: String
    /// Natural-log margin the model's pick needs over the runner-up to be applied: stricter when the
    /// word as typed is itself a real word ("thee").
    public var margin: Float
    /// The system's confident fix (one of `candidates`), held back only because a rival is as likely
    /// a slip: it goes in unless the model clearly prefers another candidate (`margin`) or the word
    /// as typed (`CorrectionFinder.strictMargin`).
    public var preferred: String?
    /// For a finding over several words: false when the first word is fine and only taken along
    /// ("note th" → not the). A later finding that starts inside this one then takes over.
    public var leadIsSlip: Bool
    /// How the keys of `misspelled` were pressed (`KeyTimingLog.evidence`), when that says
    /// something: a swap or double the timing backs costs less, and needs less margin (`JointChoice`).
    public var timing: KeyTiming?
    /// The user's personal slips (`CorrectionFinder.slipProfile`): a candidate they often mistype
    /// costs less in `JointChoice`.
    public var personal: SlipProfile?
    /// A commonly confused word (`ConfusedWords`): the word as typed is a real everyday word, the
    /// candidates are its rivals. They cost the same (no keyboard slip prior), and a close call is
    /// left as typed rather than offered.
    public var confusable = false
    /// The word starts a sentence (and Auto-capitalization is on): whatever fix goes in gets a capital
    /// first letter ("ye" → "Yes"). The candidates stay as typed-case for scoring; `JointChoice.resolve`
    /// and the menu apply this. The typed word, kept for undo, is never changed.
    public var capitalizesFirst = false
    /// `word` as it goes into the text.
    public func cased(_ word: String) -> String { capitalizesFirst ? CapitalFix.capitalizingFirst(word) : word }

    public init(misspelled: String, candidates: [String], fallback: String?, deleteCount: Int, trailing: String,
                margin: Float = TypoChoice.defaultMargin, preferred: String? = nil, leadIsSlip: Bool = true) {
        self.misspelled = misspelled
        self.candidates = candidates
        self.fallback = fallback
        self.deleteCount = deleteCount
        self.trailing = trailing
        self.margin = margin
        self.preferred = preferred
        self.leadIsSlip = leadIsSlip
    }
}

/// What the finder makes of the last finished word.
public enum CorrectionFinding: Sendable, Equatable {
    /// A fix to show, or to apply right away.
    case fix(CorrectionProposal)
    /// Only guesses: wait for the next word and let the model choose ("Fix automatically" only).
    case ambiguous(AmbiguousTypo)

    /// The word as typed.
    public var misspelled: String {
        switch self {
        case .fix(let p): p.misspelled
        case .ambiguous(let t): t.misspelled
        }
    }
}

/// Word-level edit distance (optimal string alignment: insert, delete, substitute, adjacent swap).
enum EditDistance {
    static func osa(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var rows = [[Int]](repeating: [Int](repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { rows[i][0] = i }
        for j in 0...t.count { rows[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                var best = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    best = min(best, rows[i - 2][j - 2] + 1)
                }
                rows[i][j] = best
            }
        }
        return rows[s.count][t.count]
    }

    /// True when `b` is `a` with one adjacent pair swapped.
    static func isTransposition(_ a: String, _ b: String) -> Bool {
        let s = Array(a), t = Array(b)
        guard s.count == t.count, s != t else { return false }
        let diff = (0..<s.count).filter { s[$0] != t[$0] }
        guard diff.count == 2, diff[1] == diff[0] + 1 else { return false }
        return s[diff[0]] == t[diff[1]] && s[diff[1]] == t[diff[0]]
    }

    /// Acceptance rule for a spell-checker guess that is not the system's autocorrect choice.
    static func isPlausibleGuess(_ guess: String, for word: String) -> Bool {
        let w = word.lowercased(), g = guess.lowercased()
        if isSplit(g, of: w) { return true }
        if g.contains(where: \.isWhitespace) { return false }
        if isTransposition(w, g) { return true }
        let d = osa(w, g)
        return d <= 1 || (w.first == g.first && d <= 2)
    }

    /// "moments ago" for "momentsago": the guess is the word with exactly one space inserted.
    static func isSplit(_ guess: String, of word: String) -> Bool {
        let parts = guess.split(separator: " ", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && parts.joined() == word
    }
}

/// Whether a misspelled word looks like a slip of a real word ("dont" → "don't", "teh" → "the")
/// rather than a name or term the dictionary lacks ("hunch", "kubernetes").
public enum TypoShape {
    /// True when `fix` is one word (not a split) one edit from `word` (a swap counts as one).
    /// Two edits already reach unrelated words ("bread" → "brand").
    public static func isSlip(_ word: String, fixedTo fix: String) -> Bool {
        let w = word.lowercased(), f = fix.lowercased()
        guard !f.contains(where: \.isWhitespace), w != f else { return false }
        return EditDistance.osa(w, f) <= 1
    }

    /// A contraction with its ending cut off: `fix` is `word`, an apostrophe and more ("doesn" →
    /// "doesn't"). Two edits, so `isSlip` misses it.
    public static func isCutContraction(_ word: String, fixedTo fix: String) -> Bool {
        let w = word.lowercased(), f = fix.lowercased().replacingOccurrences(of: "’", with: "'")
        guard !w.isEmpty, let a = f.firstIndex(of: "'"), f.index(after: a) < f.endIndex else { return false }
        return f[..<a] == w
    }

    /// Only apostrophes differ ("dont" → "don't", "ive" → "I've"): the writer's style, not a typo.
    public static func isApostropheOnly(_ word: String, fixedTo fix: String) -> Bool {
        func bare(_ s: String) -> String { s.lowercased().filter { $0 != "'" && $0 != "’" } }
        return word.lowercased() != fix.lowercased() && bare(word) == bare(fix)
    }

    /// A word kept over fixes that is most likely the writer's own typo, not a term worth learning:
    /// `fix` (the system's correction) is an everyday word one edit away ("stil" → "still",
    /// "teh" → "the"), or a cut-off contraction ("doesn"). A missing apostrophe alone is style;
    /// a rarer fix ("cyberware" → "cyberwar", "clawd" → "claws") leaves the word learnable.
    public static func isLikelyTypo(_ word: String, fixedTo fix: String, isEveryday: (String) -> Bool) -> Bool {
        if isApostropheOnly(word, fixedTo: fix) { return false }
        if isCutContraction(word, fixedTo: fix) { return true }
        return isSlip(word, fixedTo: fix) && isEveryday(fix.lowercased())
    }
}

public struct CorrectionFinder: Sendable {
    private let spellChecker: any SpellChecking
    private let suggester: any CorrectionSuggesting
    private let languages: [String]
    private let knownLower: Set<String>
    private let knownByLower: [String: String]
    private let guesser: any LanguageGuessing
    /// Common words, to keep the one-edit candidates for an ambiguous word to likely ones; nil = any
    /// correctly spelled word.
    private let isCommonWord: (@Sendable (String) -> Bool)?
    /// The everyday core of the common words ("the", "from"). With `isCommonWord`, it turns on
    /// real-word slips: a correctly spelled word can still be a slip ("thee" → "the", "wrk" → "work").
    private let isEverydayWord: (@Sendable (String) -> Bool)?
    /// Words searched for a long garbled word nothing else reaches (`fuzzyCandidates`).
    private let lexicon: FuzzyLexicon?
    /// Chat shorthand ("ofc", "id", "tbh", `ChatShorthand`) is left alone: never fixed, never part of
    /// a fix over several words. Off by default (an experiment, measured in the autocorrect eval).
    public var leavesShorthand = false
    /// The user's macOS Text Replacements: a shortcut is never a typo, never part of a fix over
    /// several words. Set on a copy per call, like `leavesShorthand`.
    public var textReplacements = TextReplacements.empty
    /// "Fix punctuation" (`PunctuationFixer`): missing apostrophes, a space before punctuation, no
    /// space after a full stop, doubled spaces. Set on a copy per call (formal apps only).
    public var fixesPunctuation = false
    /// What two spaces in a row become when `fixesPunctuation` is on (off where the host does it).
    public var doubleSpace = PunctuationFixer.DoubleSpace.off
    /// With `textReplacements` and "Fix automatically" (`deferAmbiguous`): a typed shortcut becomes a
    /// fix to its replacement. Off in apps that replace it themselves.
    public var appliesReplacements = false
    /// The user's recent key presses ("Fix automatically"): each waiting word gets its key timing
    /// (`AmbiguousTypo.timing`). Set on a copy per call, like `leavesShorthand`. Nil: no timing.
    public var keyTiming: KeyTimingLog?
    /// With `keyTiming`: an everyday word whose two keys went down together, and that is another
    /// everyday word with those two swapped ("form" for "from"), goes to the model too.
    public var flagsTimedSwaps = true
    /// Words the user often mistypes (learned from automatic fixes they kept): offered for a
    /// misspelled word within reach, and cheaper slips. Set on a copy per call. Nil: none.
    public var slipProfile: SlipProfile?
    /// Distinctive words on screen (`ScreenWords`): a word typed exactly like one is never "fixed",
    /// and a garbled word close to one gets it as a candidate. Set on a copy per call. Empty: off
    /// (screen context off globally or for the app).
    public var screenWords = ScreenWords.empty
    /// Auto-capitalization (`CapitalFix`: THe → The, tHIS → This, i → I, monday → Monday, iphone →
    /// iPhone). Set on a copy per call from the global and per-app switches. A fix right away, on
    /// both the Tab path and "Fix automatically".
    public var fixesCapitals = false
    /// Strength Light: only what the system spell checker alone is sure of. A word with several
    /// possible fixes (the model would choose), two-letter words, real-word slips, confused words, timed
    /// swaps and multi-word regroupings are all left alone, so nothing ever needs the model. Punctuation, capital and text
    /// replacement fixes (their own switches) still apply. Set on a copy per call, like `leavesShorthand`.
    public var modelFree = false
    /// The learned words used in the current app or its category (lowercased; `LearnedWordPlaces`).
    /// A learned word offered as a fix comes from these first; one from another app only when none
    /// of these is within reach. Set on a copy per call. Nil: every learned word is equal. All
    /// learned words still count as spelled right (`knownWords`, the spell checker).
    public var learnedHere: Set<String>?

    public init(spellChecker: any SpellChecking, suggester: any CorrectionSuggesting,
                languages: [String], knownWords: Set<String>,
                isCommonWord: (@Sendable (String) -> Bool)? = nil,
                isEverydayWord: (@Sendable (String) -> Bool)? = nil,
                lexicon: FuzzyLexicon? = nil) {
        self.init(spellChecker: spellChecker, suggester: suggester, languages: languages,
                  knownWords: knownWords, guesser: NLLanguageGuesser(), isCommonWord: isCommonWord,
                  isEverydayWord: isEverydayWord, lexicon: lexicon)
    }

    init(spellChecker: any SpellChecking, suggester: any CorrectionSuggesting, languages: [String],
         knownWords: Set<String>, guesser: any LanguageGuessing,
         isCommonWord: (@Sendable (String) -> Bool)? = nil,
         isEverydayWord: (@Sendable (String) -> Bool)? = nil,
         lexicon: FuzzyLexicon? = nil) {
        self.lexicon = lexicon
        self.isCommonWord = isCommonWord
        self.isEverydayWord = isEverydayWord
        self.spellChecker = spellChecker
        self.suggester = suggester
        self.languages = languages
        self.guesser = guesser
        var byLower: [String: String] = [:]
        for word in knownWords.sorted() {  // deterministic when two entries differ only by case
            let key = word.lowercased()
            if byLower[key] == nil || word.contains(where: \.isUppercase) { byLower[key] = word }
        }
        self.knownByLower = byLower
        self.knownLower = Set(byLower.keys)
    }

    private static let punctuation = Set(".,;:!?…")

    /// A fix for the last completed word before the caret, or nil. Accepted endings: the word +
    /// one space, the word + punctuation, the word + punctuation + one space. A word with nothing
    /// after it is still being typed ("beautif" is not a typo of "beautify"), so it gets no fix.
    /// How sure this finder is of a fix of `typed` to `fixed` it made (`FixConfidence`): unsure when it
    /// put in a word that is neither common (`isCommonWord`) nor one of the writer's learned words.
    /// Without `isCommonWord`: sure. A set lookup per word, recorded with the fix.
    public func confidence(typed: String, fixed: String) -> FixConfidence {
        guard let isCommonWord else { return .sure }
        return FixConfidence.of(typed: typed, fixed: fixed, isEveryday: isCommonWord, isLearned: { knownLower.contains($0) })
    }

    public func proposal(before: String) -> CorrectionProposal? {
        if case .fix(let proposal) = finding(before: before, deferAmbiguous: false) { return proposal }
        return nil
    }

    /// Most candidates the model is asked to choose among (the typed word is scored besides).
    public static let maxCandidates = 10

    /// Like `proposal`, but with `deferAmbiguous` ("Fix automatically" where a word behind the caret
    /// can be replaced) a word the system has only guesses for comes back `.ambiguous` instead of
    /// being fixed with the first guess. Two-letter words are checked then too, and are always
    /// ambiguous: the model also scores the word as typed, so "ui" or "js" stays.
    public func finding(before: String, deferAmbiguous: Bool) -> CorrectionFinding? {
        let found = atSentenceStart(untimedFinding(before: before, deferAmbiguous: deferAmbiguous), before: before)
        // Typed as "/btw", "@alex" or "#tag": the host may have made it a chip that reads back
        // without the trigger character; deleting and retyping the word would destroy that chip.
        if let keyTiming, let word = found?.misspelled, keyTiming.typedAfterTokenTrigger(word) { return nil }
        guard case .ambiguous(var typo)? = found else { return found }
        guard let keyTiming, typo.timing == nil else { return found }
        typo.timing = keyTiming.evidence(for: typo.misspelled)
        return .ambiguous(typo)
    }

    /// A fix of the word that starts a sentence is capitalized in the same step ("ye " → "Yes",
    /// "teh" after a full stop → "The", "dont" → "Don't"). An instant fix gets the capital now; an
    /// ambiguous word is flagged so the model's pick gets it. Only with Auto-capitalization on, and
    /// not for the user's own Text Replacements (applied exactly as defined).
    private func atSentenceStart(_ found: CorrectionFinding?, before: String) -> CorrectionFinding? {
        guard fixesCapitals, let found else { return found }
        switch found {
        case .fix(var p):
            guard p.deleteCount <= before.count, Self.lowerInitial(p.misspelled),
                  textReplacements.replacement(for: p.misspelled) != p.replacement,
                  CapitalFix.startsSentence(before: Substring(before.dropLast(p.deleteCount))) else { return found }
            p.replacement = CapitalFix.capitalizingFirst(p.replacement)
            return .fix(p)
        case .ambiguous(var typo):
            guard typo.deleteCount <= before.count, Self.lowerInitial(typo.misspelled),
                  CapitalFix.startsSentence(before: Substring(before.dropLast(typo.deleteCount))) else { return found }
            typo.capitalizesFirst = true
            return .ambiguous(typo)
        }
    }

    private static func lowerInitial(_ word: String) -> Bool { word.first?.isLowercase == true }

    private func untimedFinding(before: String, deferAmbiguous: Bool) -> CorrectionFinding? {
        if fixesPunctuation, let fix = PunctuationFixer.spacingFix(
            before: before, doubleSpace: doubleSpace, languages: languages,
            isKnownWord: { [self] in !spellChecker.isMisspelled($0, languages: languages) }) {
            return .fix(fix)
        }
        guard let (stripped, token, trailing) = Self.lastWord(before) else { return nil }
        // Links, paths, identifiers, code, abbreviations...: no fix path touches them (`NeverTouch`).
        if NeverTouch.insideCode(before) || NeverTouch.kind(of: NeverTouch.lastChunk(of: stripped)) != nil { return nil }
        if leavesShorthand, ChatShorthand.contains(token) { return nil }
        if textReplacements.protects(token) {
            guard deferAmbiguous, appliesReplacements, let with = textReplacements.replacement(for: token) else { return nil }
            return .fix(CorrectionProposal(misspelled: token, replacement: with,
                                           deleteCount: token.count + trailing.count, trailing: trailing))
        }
        if fixesPunctuation, !screenWords.contains(token.lowercased()),
           PunctuationFixer.isPlainWordPosition(token: token, in: stripped),
           let fixed = PunctuationFixer.contraction(for: token, apostrophe: PunctuationFixer.apostropheStyle(in: stripped)) {
            return .fix(CorrectionProposal(misspelled: token, replacement: fixed,
                                           deleteCount: token.count + trailing.count, trailing: trailing))
        }
        if fixesCapitals, let cased = capitalFix(stripped: stripped, token: token, trailing: trailing) {
            return .fix(CorrectionProposal(misspelled: token, replacement: cased,
                                           deleteCount: token.count + trailing.count, trailing: trailing))
        }
        var single = wordFinding(stripped: stripped, token: token, trailing: trailing, deferAmbiguous: deferAmbiguous)
        if modelFree {
            // Strength Light: only a fix the spell checker alone is sure of (exactly one obvious
            // fix); anything the model would have to choose or score is left as typed.
            if case .ambiguous? = single { single = nil }
            return single
        }
        guard deferAmbiguous else { return single }
        if let regrouped = resegmentFinding(stripped: stripped, token: token, trailing: trailing, waitOnly: false,
                                            single: single) {
            return regrouped
        }
        return pairFinding(stripped: stripped, token: token, trailing: trailing, single: single)
            ?? resegmentFinding(stripped: stripped, token: token, trailing: trailing, waitOnly: true, single: single)
            ?? single
    }

    private func capitalFix(stripped: String, token: String, trailing: String) -> String? {
        let before = stripped.dropLast(token.count)
        // A word typed like one on screen, or one the user taught the app, is meant as typed.
        if screenWords.contains(token) { return nil }
        if knownByLower[token.lowercased()] == token, token.contains(where: \.isUppercase) { return nil }
        guard let cased = CapitalFix.fix(token: token, before: before, trailing: trailing,
                                         isWord: { spellChecker.isSurelySpelled($0, languages: languages) }),
              cased != token else { return nil }
        return cased
    }

    /// The text up to the last word, the word, and what follows it (space and/or punctuation).
    private static func lastWord(_ before: String) -> (stripped: String, token: String, trailing: String)? {
        let tail = String(before.suffix(120))
        var body = Substring(tail)
        var trailing = ""
        // Chromium/Electron editors store a trailing typed space as a no-break space (U+00A0).
        if let last = body.last, last == " " || last == "\u{00A0}" { trailing = String(last); body = body.dropLast() }
        var punct = ""
        while let l = body.last, Self.punctuation.contains(l), punct.count < 3 {
            punct = String(l) + punct
            body = body.dropLast()
        }
        trailing = punct + trailing
        guard !trailing.isEmpty else { return nil }
        let stripped = String(body)
        let token = TypoDetector.trailingToken(of: stripped)
        // Quoted or bracketed words are out of scope (the token must end exactly at the caret region).
        guard !token.isEmpty, stripped.hasSuffix(token) else { return nil }
        return (stripped, token, trailing)
    }

    private func wordFinding(stripped: String, token: String, trailing: String, deferAmbiguous: Bool) -> CorrectionFinding? {
        // A capitalized word is checked only when it starts a sentence ("Teh"); elsewhere a
        // capital means a name or acronym and is left alone.
        let sentenceStart = Self.isSentenceStartCapital(token, before: stripped.dropLast(token.count))
        if deferAmbiguous, let typo = symbolSlip(token: token, stripped: stripped, trailing: trailing) {
            return .ambiguous(typo)
        }
        // "Fix automatically" also looks at a capitalized word mid-sentence ("Deember"), but only
        // lets the model fix it, strictly: a capital there is usually a name.
        let capitalMid = deferAmbiguous && !sentenceStart && Self.isInitialCapital(token)
        let checkedToken = sentenceStart || capitalMid ? token.lowercased() : token
        guard let word = TypoDetector.checkable(checkedToken, known: knownLower,
                                                minLetters: deferAmbiguous ? 2 : 3) else { return nil }
        // A name or term that is on screen is meant as typed ("csv" in a chat about a csv).
        if screenWords.contains(word) { return nil }
        guard !TypoDetector.looksForeign(word: word, recentText: stripped, languages: languages,
                                         guesser: guesser) else { return nil }
        guard spellChecker.isMisspelled(word, languages: languages) else {
            guard deferAmbiguous, !capitalMid else { return nil }
            if let typo = confusedWordSlip(word: word, token: token, stripped: stripped, trailing: trailing) {
                return .ambiguous(typo)
            }
            return (realWordSlip(word: word, token: token, trailing: trailing)
                ?? timedSwapSlip(word: word, token: token, trailing: trailing)).map { .ambiguous($0) }
        }
        if capitalMid {
            return deferredFinding(word: word, token: token, stripped: stripped, trailing: trailing,
                                   onlyModel: true)
        }
        if deferAmbiguous {
            return deferredFinding(word: word, token: token, stripped: stripped, trailing: trailing)
        }
        let suggested = suggester.correction(for: word, context: stripped, languages: languages)

        let replacement: String
        if let learned = learnedCandidate(for: word) {
            replacement = learned
        } else if let suggested, let cased = acceptable(suggested, for: word, token: token) {
            replacement = cased
        } else if let split = splitCandidate(for: word) {
            // Run-together words the system offers nothing for ("momentsago" → "moments ago").
            replacement = Self.matchCase(split, to: token)
        } else {
            return nil
        }
        guard !replacement.isEmpty, replacement != token else { return nil }
        return .fix(CorrectionProposal(misspelled: token, replacement: replacement,
                                       deleteCount: token.count + trailing.count, trailing: trailing))
    }

    /// "Fix automatically": a learned word or the system's confident correction is a fix now; only
    /// guesses make the word ambiguous. A two-letter word is always ambiguous (a confident
    /// correction just goes first among its candidates).
    /// `onlyModel` (a capitalized word mid-sentence): never a fix now, and the model needs
    /// `strictMargin`.
    private func deferredFinding(word: String, token: String, stripped: String, trailing: String,
                                 onlyModel: Bool = false) -> CorrectionFinding? {
        func fix(_ replacement: String) -> CorrectionFinding? {
            guard !replacement.isEmpty, replacement != token else { return nil }
            return .fix(CorrectionProposal(misspelled: token, replacement: replacement,
                                           deleteCount: token.count + trailing.count, trailing: trailing))
        }
        let short = onlyModel || word.filter(\.isLetter).count < 3
        if !short, let learned = learnedCandidate(for: word) { return fix(learned) }
        let options = suggester.options(for: word, context: stripped, languages: languages)
        let confident = options.confident.flatMap { acceptable($0, for: word, token: token) }
        let guesses = options.guesses.filter { EditDistance.isPlausibleGuess($0, for: word) }
            .compactMap { acceptable($0, for: word, token: token) }
        let edits = editCandidates(for: word)
        let twoSlips = twoSlipCandidates(for: word)
        // Words the user often mistypes, within reach of this one (none for short or capitalized-mid words).
        let trouble = short || onlyModel ? [] : (slipProfile?.candidates(for: word) ?? [])
        let troubleCased = trouble.map { (word: Self.matchCase($0.word, to: token), exact: $0.exact) }
        // A typed form the user kept the fix of before: that fix is the default.
        let exactTrouble = troubleCased.first(where: \.exact)?.word
        // Only a misspelled word's candidates are priced with the slip list (never a real word's).
        let personal = slipProfile.flatMap { $0.isEmpty ? nil : $0 }
        func personalCost(_ c: String) -> Float {
            slipProfile?.cost(typed: word, candidate: c) ?? SlipCost.cost(typed: word, candidate: c)
        }
        if !short, let confident {
            // The confident fix goes in at once unless another likely word is as cheap a slip
            // ("thnk": think or thank), or is a word the user often mistypes; then the model
            // chooses, the confident fix by default (a repeat of a kept fix: that fix).
            let cost = personalCost(confident)
            var rivals: [String] = []
            for t in troubleCased where t.word.lowercased() != confident.lowercased() { rivals.append(t.word) }
            for r in guesses + (edits + twoSlips).map({ Self.matchCase($0, to: token) }) {
                let lower = r.lowercased()
                guard lower != confident.lowercased(), !lower.contains(" "),
                      !rivals.contains(where: { $0.lowercased() == lower }),
                      isCommonWord?(lower) ?? true,
                      personalCost(lower) <= cost + Self.rivalSlack else { continue }
                rivals.append(r)
            }
            guard !rivals.isEmpty else { return fix(confident) }
            var typo = AmbiguousTypo(misspelled: token, candidates: Array(([confident] + rivals).prefix(Self.maxCandidates)),
                                     fallback: confident, deleteCount: token.count + trailing.count,
                                     trailing: trailing, preferred: exactTrouble ?? confident)
            typo.personal = personal
            return .ambiguous(typo)
        }

        var candidates: [String] = []
        func add(_ c: String) {
            if c != token, !candidates.contains(where: { $0.lowercased() == c.lowercased() }) { candidates.append(c) }
        }
        if let confident { add(confident) }
        for f in fieldCandidates(for: word, in: stripped) { add(Self.matchCase(f, to: token)) }
        for f in screenWords.candidates(for: word) { add(Self.matchCase(f, to: token)) }
        for g in guesses.prefix(5) { add(g) }
        if short, let learned = learnedCandidate(for: word) { add(learned) }
        for s in spaceKeyCandidates(for: word) { add(Self.matchCase(s, to: token)) }
        for e in edits + twoSlips where candidates.count < Self.maxCandidates {
            add(Self.matchCase(e, to: token))
        }
        // A long word garbled past every guess and edit, for which the system has nothing at all
        // ("pucntioans"): search the dictionary. Any real word beats such a garble easily, so the
        // model needs the strict margin.
        var fuzzy = false
        if candidates.isEmpty, !onlyModel, options.confident == nil, options.guesses.isEmpty {
            for f in fuzzyCandidates(for: word) { add(Self.matchCase(f, to: token)) }
            fuzzy = !candidates.isEmpty
        }
        // Trouble words go first; with nothing else found, they are a dictionary-search hit and
        // need the same strict margin.
        if !troubleCased.isEmpty {
            if candidates.isEmpty { fuzzy = true }
            let others = candidates
            candidates = []
            for t in troubleCased { add(t.word) }
            for o in others { add(o) }
        }
        if !candidates.isEmpty {
            var typo = AmbiguousTypo(misspelled: token, candidates: Array(candidates.prefix(Self.maxCandidates)),
                                     fallback: onlyModel ? nil : confident ?? exactTrouble ?? guesses.first,
                                     deleteCount: token.count + trailing.count, trailing: trailing,
                                     margin: onlyModel || fuzzy ? Self.strictMargin : TypoChoice.defaultMargin,
                                     preferred: exactTrouble)
            typo.personal = onlyModel ? nil : personal
            return .ambiguous(typo)
        }
        if !short, let split = splitCandidate(for: word) { return fix(Self.matchCase(split, to: token)) }
        return nil
    }

    /// Margin for a word the dictionary accepts but few people write ("wrk", "fr"), and for a
    /// capitalized word mid-sentence.
    public static let strictMargin: Float = 3.0
    /// Margin for a common real word that is one slip from an everyday word ("thee" → "the").
    public static let realWordMargin: Float = 4.0

    /// A correctly spelled word that may still be a slip ("Fix automatically" with `isEverydayWord`):
    /// one the dictionary accepts but that is not a common word ("wrk", "wth", "na"), or a common but
    /// not everyday word ("thee", "thy"). Candidates are common words one slip away (everyday ones
    /// for a common word). The model needs a strict margin, and an everyday word is never questioned.
    private func realWordSlip(word: String, token: String, trailing: String) -> AmbiguousTypo? {
        guard let isCommonWord, let isEverydayWord, !isEverydayWord(word) else { return nil }
        let common = isCommonWord(word)
        var candidates = editCandidates(for: word).filter { Self.plausibleRealWordSlip(typed: word, meant: $0) }
        if common { candidates = candidates.filter(isEverydayWord) }
        guard !candidates.isEmpty else { return nil }
        return AmbiguousTypo(misspelled: token,
                             candidates: candidates.prefix(Self.maxCandidates).map { Self.matchCase($0, to: token) },
                             fallback: nil, deleteCount: token.count + trailing.count, trailing: trailing,
                             margin: common ? Self.realWordMargin : Self.strictMargin)
    }

    /// "Fix commonly confused words" (`ConfusedWords`): the model may swap a word for a rival in its
    /// set ("their" → "there"), only with `confusedWordMargin` over the word as typed. Off: never.
    public var fixesConfusedWords = false
    /// Natural-log margin a rival needs over the confused word as typed (and any other rival). Strict:
    /// these are correct everyday words, and a wrong fix is worse than a missed one.
    public var confusedWordMargin: Float = Self.defaultConfusedWordMargin
    public static let defaultConfusedWordMargin: Float = 5.0

    /// A word from a confused set, typed as one of its rivals may have been meant.
    private func confusedWordSlip(word: String, token: String, stripped: String, trailing: String) -> AmbiguousTypo? {
        guard fixesConfusedWords else { return nil }
        let rivals = ConfusedWords.rivals(of: word, trailing: trailing)
        guard !rivals.isEmpty else { return nil }
        var typo = AmbiguousTypo(misspelled: token,
                                 candidates: rivals.map { ConfusedWords.styled($0, typed: token, before: stripped) },
                                 fallback: nil, deleteCount: token.count + trailing.count, trailing: trailing,
                                 margin: confusedWordMargin)
        typo.confusable = true
        return typo
    }

    /// An everyday word typed with two keys pressed together, that is another everyday word with
    /// those two letters swapped ("form" for "from", "on" for "no"): the model decides, strictly.
    /// The timing explains the fix, so the margin is eased (`JointChoice.timedMarginScale`).
    private func timedSwapSlip(word: String, token: String, trailing: String) -> AmbiguousTypo? {
        guard flagsTimedSwaps, let keyTiming, let isEverydayWord, isEverydayWord(word),
              let timing = keyTiming.evidence(for: token) else { return nil }
        let chars = Array(word)
        guard timing.rolled.count == chars.count - 1 else { return nil }
        var candidates: [String] = []
        for i in timing.rolled.indices where timing.rolled[i] && chars[i] != chars[i + 1] {
            var c = chars
            c.swapAt(i, i + 1)
            let candidate = String(c)
            if candidate != word, isEverydayWord(candidate) { candidates.append(Self.matchCase(candidate, to: token)) }
        }
        guard !candidates.isEmpty else { return nil }
        var typo = AmbiguousTypo(misspelled: token, candidates: candidates, fallback: nil,
                                 deleteCount: token.count + trailing.count, trailing: trailing, margin: Self.strictMargin)
        typo.timing = timing
        return typo
    }

    /// Endings that make another form of the same word ("full"/"fully", "starter"/"started").
    static let inflections: Set<String> = ["", "s", "es", "d", "ed", "r", "er", "y", "ly", "ing"]

    /// Whether a real word typed could be a slip for `meant`. Not when the two are forms of the same
    /// word ("fully" for "full", "totals" for "total", "starter" for "started": the model can't tell
    /// which form was meant, and both read fine), nor when a word of 5+ letters would have a letter
    /// too many ("slide" for "side"): an extra key rarely makes a longer real word.
    static func plausibleRealWordSlip(typed: String, meant: String) -> Bool {
        let a = Array(typed.lowercased()), b = Array(meant.lowercased())
        var stem = 0
        while stem < min(a.count, b.count), a[stem] == b[stem] { stem += 1 }
        if stem >= 3, inflections.contains(String(a[stem...])), inflections.contains(String(b[stem...])) { return false }
        if a.count >= 5, b.count < a.count { return false }
        return true
    }

    /// Number-row keys and the letter keys right below them.
    static let numberRowLetters: [Character: [Character]] = [
        "1": ["q"], "2": ["w", "q"], "3": ["e", "w"], "4": ["r", "e"], "5": ["t", "r"], "6": ["y", "t"],
        "7": ["u", "y"], "8": ["i", "u"], "9": ["o", "i"], "0": ["p", "o"],
    ]

    /// A word with one number-row key in it ("whe4n", "s3with", "I9", "(off0"): the digit hit
    /// instead of or next to a letter, or Shift let go early ("0" for ")"). Candidates are the word
    /// without the digit, or with a letter under it instead, when that is a common word (one slip
    /// more is allowed after taking the digit out: "s3with" → "switch"). Names with digits
    /// ("mp3", "k8s", "4th") have no such reading and stay; the model also scores the word as typed.
    private func symbolSlip(token: String, stripped: String, trailing: String) -> AmbiguousTypo? {
        let chars = Array(token)
        guard chars.count >= 2, chars.count <= 20,
              chars.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "'" || $0 == "\u{2019}" }),
              chars.filter(\.isNumber).count == 1, let at = chars.firstIndex(where: \.isNumber) else { return nil }
        let digit = chars[at]
        let letters = chars.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        // Upper-case beyond the first letter means a code or an acronym ("MP3", "B2B").
        guard letters.dropFirst().allSatisfy({ !$0.isUppercase }) else { return nil }
        func isWord(_ cased: String) -> Bool {
            let lower = cased.lowercased()
            if lower.count == 1 { return cased == "I" }  // "I9"; "a1" is a label
            guard spellChecker.isSurelySpelled(lower, languages: languages)
                || spellChecker.isSurelySpelled(cased, languages: languages) else { return false }
            return isCommonWord?(lower.replacingOccurrences(of: "\u{2019}", with: "'")) ?? true
        }
        var candidates: [String] = []
        func add(_ c: String) { if c != token, !candidates.contains(c) { candidates.append(c) } }
        var without = chars; without.remove(at: at)
        // Shift let go early on ")": "(off0" → "(off)", only inside an open bracket.
        if digit == "0", at == chars.count - 1, isWord(String(without)),
           stripped.dropLast(token.count).last == "(" || openBracket(in: stripped.dropLast(token.count)) {
            add(String(without) + ")")
        }
        // An extra digit is a slip only when it sits right above a letter beside it ("whe4n": 4 above
        // e; "s3with": 3 above w). "stage2", "v2" are labels.
        let rowLetters = Self.numberRowLetters[digit] ?? []
        let extraDigit = [at - 1, at + 1].contains { i in
            chars.indices.contains(i) && rowLetters.contains(Character(chars[i].lowercased()))
        }
        if extraDigit, isWord(String(without)) { add(String(without)) }
        for l in Self.numberRowLetters[digit] ?? [] {
            var c = chars; c[at] = letters.first?.isUppercase == true && at == 0 ? Character(l.uppercased()) : l
            if isWord(String(c)) { add(String(c)) }
        }
        if candidates.isEmpty, extraDigit, String(without).count >= 3 {
            for e in editCandidates(for: String(without).lowercased()) { add(Self.matchCase(e, to: String(without))) }
        }
        guard !candidates.isEmpty else { return nil }
        return AmbiguousTypo(misspelled: token, candidates: Array(candidates.prefix(Self.maxCandidates)),
                             fallback: candidates.count == 1 ? candidates[0] : nil,
                             deleteCount: token.count + trailing.count, trailing: trailing)
    }

    /// True when the text has a "(" not closed after it on the same line.
    private func openBracket(in text: Substring) -> Bool {
        var depth = 0
        for c in text.reversed() {
            if c.isNewline { break }
            if c == ")" { depth += 1 } else if c == "(" { if depth == 0 { return true }; depth -= 1 }
        }
        return false
    }

    /// Words already written earlier in the field that a garbled long word is close to
    /// ("autocrereect" after "autocorrect"): same first letter, at most 2 edits (3 from 8 letters).
    func fieldCandidates(for word: String, in text: String) -> [String] {
        guard word.count >= 5 else { return [] }
        let limit = word.count >= 8 ? 3 : 2
        var seen = Set<String>()
        var out: [(word: String, distance: Int)] = []
        let body = text.suffix(4000).dropLast(word.count)
        for raw in body.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            let w = raw.lowercased()
            guard w.count >= 5, w != word, w.first == word.first, abs(w.count - word.count) <= limit,
                  seen.insert(w).inserted else { continue }
            guard knownLower.contains(w) || spellChecker.isSurelySpelled(w, languages: languages) else { continue }
            let d = EditDistance.osa(word, w)
            if d <= limit { out.append((w, d)) }
        }
        return out.sorted { $0.distance < $1.distance }.prefix(3).map(\.word)
    }

    /// A key next to the space bar typed instead of a space ("thebcat" → "the cat"): both sides are
    /// common words (or "a"/"I").
    func spaceKeyCandidates(for word: String) -> [String] {
        let chars = Array(word)
        guard chars.count >= 4 else { return [] }
        func ok(_ part: [Character]) -> Bool {
            let w = String(part)
            if w == "a" || w == "i" { return true }
            guard w.count >= 2, spellChecker.isSurelySpelled(w, languages: languages) else { return false }
            return isCommonWord?(w) ?? true
        }
        var out: [String] = []
        for i in 1..<(chars.count - 1) where "bnmvc".contains(chars[i]) {
            let left = Array(chars[..<i]), right = Array(chars[(i + 1)...])
            if ok(left), ok(right) { out.append(String(left) + " " + String(right)) }
        }
        return out
    }

    /// Correctly spelled common words one typing slip from `word`: a letter left out ("fo" → "for"),
    /// two letters swapped ("of"), a letter too many, or a neighbouring key hit instead.
    func editCandidates(for word: String) -> [String] {
        let chars = Array(word)
        guard chars.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var out: [String] = []
        func consider(_ c: [Character]) {
            guard c.count >= 2 else { return }
            let w = String(c)
            guard w != word, !out.contains(w) else { return }
            if let isCommonWord, !isCommonWord(w) { return }
            out.append(w)
        }
        for i in 0...chars.count { for l in letters { var c = chars; c.insert(l, at: i); consider(c) } }
        for i in 0..<(chars.count - 1) where chars[i] != chars[i + 1] { var c = chars; c.swapAt(i, i + 1); consider(c) }
        for i in chars.indices { var c = chars; c.remove(at: i); consider(c) }
        for i in chars.indices {
            for l in Self.neighbours[chars[i]] ?? [] { var c = chars; c[i] = l; consider(c) }
        }
        let words = out.filter { spellChecker.isSurelySpelled($0, languages: languages) }
        // Everyday words first ("and" before "add", "dad"): fewer candidates are scored over two or three words.
        guard let isEverydayWord else { return words }
        return words.filter(isEverydayWord) + words.filter { !isEverydayWord($0) }
    }

    /// How much more a rival may cost (`SlipCost`) than the confident fix and still be a rival.
    static let rivalSlack: Float = 0.25

    /// Everyday words two typing slips from `word` ("htw" → "the": swapped, then a neighbouring
    /// key), for short words only. The second slip is never another left-out letter.
    func twoSlipCandidates(for word: String) -> [String] {
        let chars = Array(word)
        guard let isEverydayWord, (2...6).contains(chars.count),
              chars.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
        let first = Self.oneSlipVariants(chars, inserting: true)
        let firstSet = Set(first.map { String($0) })
        var out = Set<String>()
        for v in first {
            for w in Self.oneSlipVariants(v, inserting: false) {
                let s = String(w)
                guard s.count >= 2, s != word, !firstSet.contains(s), isEverydayWord(s) else { continue }
                out.insert(s)
            }
        }
        return out.filter { spellChecker.isSurelySpelled($0, languages: languages) }
            .sorted { (SlipCost.cost(typed: word, candidate: $0), $0) < (SlipCost.cost(typed: word, candidate: $1), $1) }
            .prefix(5).map { $0 }
    }

    /// Every string one slip from `chars`: a letter swapped with the next, left out, replaced by a
    /// neighbouring key, or (with `inserting`) one more letter anywhere.
    static func oneSlipVariants(_ chars: [Character], inserting: Bool) -> [[Character]] {
        var out: [[Character]] = []
        if inserting {
            for i in 0...chars.count { for l in "abcdefghijklmnopqrstuvwxyz" { var c = chars; c.insert(l, at: i); out.append(c) } }
        }
        for i in 0..<max(0, chars.count - 1) where chars[i] != chars[i + 1] { var c = chars; c.swapAt(i, i + 1); out.append(c) }
        for i in chars.indices { var c = chars; c.remove(at: i); out.append(c) }
        for i in chars.indices { for l in neighbours[chars[i]] ?? [] { var c = chars; c[i] = l; out.append(c) } }
        return out
    }

    /// A slip across two words: a space typed inside a word ("a s" → "as"), or one key early or
    /// late ("ye spklease" → "yes please", the second word then one slip from a word). Only when one
    /// of the two is not an ordinary word. The finding covers both words, and keeps what the last
    /// word alone would get (`single`) as candidates with the first word unchanged.
    private func pairFinding(stripped: String, token: String, trailing: String,
                             single: CorrectionFinding?) -> CorrectionFinding? {
        let lead = stripped.dropLast(token.count)
        guard lead.last == " ", let beforeSpace = lead.dropLast().last, !beforeSpace.isWhitespace else { return nil }
        let prevText = String(lead.dropLast())
        let prev = TypoDetector.trailingToken(of: prevText)
        guard !prev.isEmpty, prevText.hasSuffix(prev),
              !Self.opensQuote(prevText.dropLast(prev.count).last) else { return nil }
        let isPlain: (String) -> Bool = { $0.allSatisfy { $0.isASCII && $0.isLetter } }
        guard isPlain(prev), isPlain(token), prev.count + token.count >= 2, prev.count <= 20, token.count <= 20,
              !token.contains(where: \.isUppercase),
              prev.dropFirst().allSatisfy({ !$0.isUppercase }),
              !(prev.first?.isUppercase ?? false)
                || Self.isSentenceStartCapital(prev, before: Substring(prevText.dropLast(prev.count))) else { return nil }
        let p = prev.lowercased(), t = token.lowercased()
        guard !Self.touchesNeverTouch(prevText) else { return nil }
        if leavesShorthand, ChatShorthand.contains(p) || ChatShorthand.contains(t) { return nil }
        if textReplacements.protects(p) || textReplacements.protects(t) { return nil }
        func isWord(_ w: String) -> Bool {
            if w == "a" || w == "i" { return true }
            guard w.count >= 2, spellChecker.isSurelySpelled(w, languages: languages) else { return false }
            return isCommonWord?(w) ?? true
        }
        guard !isWord(p) || !isWord(t) else { return nil }
        var options: [String] = []
        // Merged: an everyday word ("as", not "pas").
        if isWord(p + t), isEverydayWord?(p + t) ?? true { options.append(p + t) }
        // Moved: only when the second word is not an everyday word ("ye spklease", "herea re"; "si the"
        // is "is the", not "sit he").
        let movable = !isWord(t) || !(isEverydayWord?(t) ?? true)
        // Two correctly spelled words ("integrations marketplace") may have a space moved, but the
        // moved half is not fixed besides: two slips to undo two good words is too many.
        let bothSpelled = p.count >= 2 && t.count >= 2 && !spellChecker.isMisspelled(p, languages: languages)
            && !spellChecker.isMisspelled(t, languages: languages)
        for (l, r) in [(p + t.prefix(1), String(t.dropFirst())), (String(p.dropLast()), String(p.suffix(1)) + t)] where movable {
            guard !l.isEmpty, !r.isEmpty, isWord(l) else { continue }
            if isWord(r) {
                options.append(l + " " + r)
            } else if !bothSpelled, r.count >= 3, spellChecker.isMisspelled(r, languages: languages) {
                for c in editCandidates(for: r).prefix(2) { options.append(l + " " + c) }
            }
        }
        guard !options.isEmpty else { return nil }
        let region = prev + " " + token
        var candidates = options.map { Self.matchCase($0, to: prev) }
        // What the first word alone gets (it waited for this word): its fixes stay candidates, also
        // with the second word's own fixes.
        if !isWord(p) {
            let firstFixes = Self.fixes(wordFinding(stripped: prevText, token: prev, trailing: " ", deferAmbiguous: true),
                                        for: prev)
            candidates += firstFixes.prefix(4).map { $0 + " " + token }
            for f in firstFixes.prefix(2) {
                for l in Self.fixes(single, for: token).prefix(2) { candidates.append(f + " " + l) }
            }
        }
        var preferred: String?
        var fallback: String?
        var margin = TypoChoice.defaultMargin
        switch single {
        case .fix(let fix)? where fix.misspelled == token:
            preferred = prev + " " + fix.replacement
            candidates.append(prev + " " + fix.replacement)
        case .ambiguous(let typo)? where typo.misspelled == token:
            candidates += typo.candidates.map { prev + " " + $0 }
            preferred = typo.preferred.map { prev + " " + $0 }
            fallback = typo.fallback.map { prev + " " + $0 }
            margin = typo.margin
        default:
            break
        }
        var unique: [String] = []
        for c in candidates where c != region && !unique.contains(c) { unique.append(c) }
        unique = Array(unique.prefix(Self.maxCandidates))
        if let preferred, !unique.contains(preferred) { unique[unique.count - 1] = preferred }
        return .ambiguous(AmbiguousTypo(misspelled: region, candidates: unique,
                                        fallback: fallback, deleteCount: region.count + trailing.count,
                                        trailing: trailing, margin: margin, preferred: preferred, leadIsSlip: !isWord(p)))
    }

    /// Shortest misspelled word searched for in the dictionary (`fuzzyCandidates`).
    public static let fuzzyMinLetters = 8
    /// `SlipCost` budget per letter: the spell checker's completions (likeliest first), and the
    /// lexicon (a little stricter).
    static let fuzzyBudgetPerLetter: Float = 0.45
    static let lexiconBudgetPerLetter: Float = 0.4

    /// Words a long garbled word may be (≥ `fuzzyMinLetters`, same first letter, at most one letter
    /// shorter (fast typing drops letters; shorter hits are junk: "thecluggage" → tutelage) and 3 longer,
    /// keyboard-slip cost within ~0.4 per letter), cheapest first, at most 4: the spell checker's
    /// completions of a few prefixes of the word ("pun" for "pucntioans", the 4th letter swapped
    /// in), learned words, then the lexicon. A word typed with a final "s" also matches plurals.
    func fuzzyCandidates(for word: String) -> [String] {
        let chars = Array(word)
        guard chars.count >= Self.fuzzyMinLetters, chars.allSatisfy({ $0.isASCII && $0.isLetter && $0.isLowercase }) else {
            return []
        }
        let budget = Float(chars.count) * Self.fuzzyBudgetPerLetter + 0.01
        let plural = word.hasSuffix("s")
        var hits: [(word: String, cost: Float)] = []
        func consider(_ c: String, needsCheck: Bool) {
            guard c.first == chars.first, c.count >= chars.count - 1, c.count <= chars.count + 3, c != word,
                  !hits.contains(where: { $0.word == c }) else { return }
            // Fast typing drops and swaps letters more than it adds them: a candidate keeps most of
            // the typed letters ("banneton" is not "bastion").
            guard Self.lettersMissing(from: c, typed: word) <= max(1, chars.count / 4) else { return }
            let cost = SlipCost.cost(typed: word, candidate: c)
            guard cost <= budget, !needsCheck || spellChecker.isSurelySpelled(c, languages: languages) else { return }
            hits.append((c, cost))
        }
        var prefixes = [String(chars[0..<2]), String(chars[0..<3]), String(chars[0..<4]),
                        String(chars[0..<2]) + String(chars[3]), String(chars[0..<3]) + String(chars[4])]
        prefixes = prefixes.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        for p in prefixes {
            for c in suggester.completions(forPrefix: p, languages: languages) {
                let lower = c.lowercased()
                guard lower.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
                consider(lower, needsCheck: false)
                if plural, !lower.hasSuffix("s") { consider(lower + "s", needsCheck: true) }
            }
        }
        for k in knownLower where k.allSatisfy({ $0.isASCII && $0.isLetter }) { consider(k, needsCheck: false) }
        hits.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.word < $1.word }
        var out = Array(hits.prefix(3).map(\.word))
        if let lexicon {
            let more = lexicon.nearest(word, limit: 4, budget: Float(chars.count) * Self.lexiconBudgetPerLetter,
                                       candidates: 40, isWord: { spellChecker.isSurelySpelled($0, languages: languages) })
            for m in more where out.count < 4 && !out.contains(m) && m.count >= chars.count - 1
                && Self.lettersMissing(from: m, typed: word) <= max(1, chars.count / 4) { out.append(m) }
        }
        return out
    }

    /// Typed letters (with repeats) that `candidate` doesn't have.
    static func lettersMissing(from candidate: String, typed: String) -> Int {
        var counts: [Character: Int] = [:]
        for c in candidate { counts[c, default: 0] += 1 }
        var missing = 0
        for c in typed { if let n = counts[c], n > 0 { counts[c] = n - 1 } else { missing += 1 } }
        return missing
    }

    /// Spaces typed a letter early or late across several words ("therea res till" → "there are
    /// still"): the first word misspelled, it and the next 1–3 words joined and split again into
    /// everyday words (as many words, or one more or fewer). The finding covers the whole group.
    /// `waitOnly`: no full split, but one that leaves 1–2 letters to start the next word
    /// ("therea res" → "there are" + "s…"): the group waits for that word, with the first word's own
    /// fixes as candidates.
    private func resegmentFinding(stripped: String, token: String, trailing: String, waitOnly: Bool,
                                  single: CorrectionFinding?) -> CorrectionFinding? {
        guard let isEverydayWord else { return nil }
        // The words before the token, back to 3, each one space apart on the same line.
        var words = [token]
        var rest = Substring(stripped.dropLast(token.count))
        while words.count < 4, rest.last == " " {
            let before = rest.dropLast()
            guard let l = before.last, !l.isWhitespace else { break }
            let w = TypoDetector.trailingToken(of: String(before))
            guard !w.isEmpty, before.hasSuffix(w) else { break }
            // A link, path or identifier is no part of a group, nor a neighbour to fix it with.
            guard !Self.touchesNeverTouch(String(before)) else { return nil }
            words.insert(w, at: 0)
            rest = before.dropLast(w.count)
        }
        guard words.count >= 2 else { return nil }
        let isPlain: (String) -> Bool = { $0.allSatisfy { $0.isASCII && $0.isLetter } }
        for k in stride(from: words.count, through: 2, by: -1) {
            // Text quoted as typed ("the "therea res till" in the beginning") is left alone.
            if k == words.count, Self.opensQuote(rest.last) { continue }
            let group = Array(words.suffix(k))
            // All lowercase: a capitalized word ("Friday") is checked with its capital elsewhere.
            guard group.allSatisfy(isPlain), group.allSatisfy({ $0 == $0.lowercased() }),
                  !leavesShorthand || !group.contains(where: ChatShorthand.contains),
                  !group.contains(where: textReplacements.protects) else { continue }
            let first = group[0]
            guard first.count >= 2, spellChecker.isMisspelled(first, languages: languages) else { continue }
            let joined = group.joined().lowercased()
            let region = group.joined(separator: " ")
            let original = group.map { $0.lowercased() }
            let counts = max(1, k - 1)...(k + 1)
            if !waitOnly {
                // Three words at least, and the last one changes too ("si the new" is not "sit he new";
                // two words are the pair finding's).
                guard k >= 3 else { continue }
                // ...but not by only cutting an everyday last word in two ("some" → "so me"): then
                // the group is one word shorter ("therea res till" + "some").
                let lastIsEveryday = isEverydayWord(original[original.count - 1])
                let splits = Self.segmentations(joined, counts: counts, isWord: isEverydayWord)
                    .filter { $0 != original && $0.last != original.last }
                    .filter { !(lastIsEveryday && $0.count >= 2 && $0.suffix(2).joined() == original.last) }
                    .map { $0.joined(separator: " ") }
                guard !splits.isEmpty else { continue }
                var candidates = splits
                candidates += firstWordFixes(group, prevText: String(rest)).map { $0 + " " + group.dropFirst().joined(separator: " ") }
                // What the first two words get as a pair ("ther ooms" → the rooms) stays a candidate.
                if case .ambiguous(let pair)? = pairFinding(stripped: String(rest) + group[0] + " " + group[1], token: group[1],
                                                            trailing: " ", single: nil) {
                    candidates += pair.candidates.prefix(3).map { $0 + " " + group.dropFirst(2).joined(separator: " ") }
                }
                let list = Self.unique(candidates, except: region)
                guard !list.isEmpty else { continue }
                return .ambiguous(AmbiguousTypo(misspelled: region, candidates: list,
                                                fallback: nil, deleteCount: region.count + trailing.count, trailing: trailing))
            }
            // Waiting for the next word: a split of all but the last 1–2 letters, which start a word.
            // Not when the last word is a whole everyday word ("therea res till some": the group
            // "therea res till" is the slip, and "some" only follows it).
            guard !isEverydayWord(original[original.count - 1]) else { continue }
            for cut in 1...2 where joined.count > cut + 2 {
                let tail = String(joined.suffix(cut))
                guard spellChecker.isKnownPrefix(tail, languages: languages) else { continue }
                let head = Self.segmentations(String(joined.dropLast(cut)), counts: counts, isWord: isEverydayWord)
                guard let split = head.first else { continue }
                let firstFixes = firstWordFixes(group, prevText: String(rest))
                let middle = group.dropFirst().dropLast().map { " " + $0 }.joined()
                var candidates = firstFixes.map { $0 + " " + group.dropFirst().joined(separator: " ") }
                let lastFixes = Self.fixes(single, for: token)
                // The left-over letters are the whole last word ("stilld o th" → still do + "th"): the
                // split with that word's own fixes, or as typed, goes first ("still do the").
                if tail == token.lowercased(), k >= 3 {
                    let resplit = split.joined(separator: " ")
                    candidates.insert(contentsOf: lastFixes.prefix(2).map { resplit + " " + $0 } + [resplit + " " + token],
                                      at: 0)
                }
                // The last word's own fixes, alone and with the first word's ("aand sees" → and see).
                for l in lastFixes.prefix(2) {
                    candidates.append(group.dropLast().joined(separator: " ") + " " + l)
                    for f in firstFixes.prefix(2) { candidates.append(f + middle + " " + l) }
                }
                if candidates.isEmpty { candidates.append((split + [tail]).joined(separator: " ")) }
                let list = Self.unique(candidates, except: region)
                guard !list.isEmpty else { continue }
                return .ambiguous(AmbiguousTypo(misspelled: region, candidates: list,
                                                fallback: nil, deleteCount: region.count + trailing.count, trailing: trailing))
            }
        }
        return nil
    }

    /// True when the last word of `text` is a link, path, identifier, code... (`NeverTouch`).
    static func touchesNeverTouch(_ text: String) -> Bool {
        NeverTouch.protectsLastWord(in: text)
    }

    /// A quote mark or backtick right before a word: what follows is likely quoted as typed.
    static func opensQuote(_ c: Character?) -> Bool {
        guard let c else { return false }
        return "\"'`\u{201C}\u{2018}".contains(c)
    }

    /// The fixes a word's own finding offers.
    private static func fixes(_ finding: CorrectionFinding?, for token: String) -> [String] {
        switch finding {
        case .fix(let fix)? where fix.misspelled == token: [fix.replacement]
        case .ambiguous(let typo)? where typo.misspelled == token: typo.candidates
        default: []
        }
    }

    /// The first word's own fixes, as it would get them alone.
    private func firstWordFixes(_ group: [String], prevText: String) -> [String] {
        switch wordFinding(stripped: prevText + group[0], token: group[0], trailing: " ", deferAmbiguous: true) {
        case .fix(let fix)?: [fix.replacement]
        case .ambiguous(let typo)?: Array(typo.candidates.prefix(4))
        case nil: []
        }
    }

    private static func unique(_ candidates: [String], except typed: String) -> [String] {
        var out: [String] = []
        for c in candidates where c != typed && !out.contains(c) && out.count < maxCandidates { out.append(c) }
        return out
    }

    /// Ways to split `text` into words `isWord` accepts ("a" and "i" alone as one-letter words),
    /// with a word count in `counts`; at most 6, fewest words first.
    static func segmentations(_ text: String, counts: ClosedRange<Int>, isWord: (String) -> Bool) -> [[String]] {
        let chars = Array(text)
        var memo: [Int: [[String]]] = [:]
        func from(_ i: Int) -> [[String]] {
            if i == chars.count { return [[]] }
            if let m = memo[i] { return m }
            var out: [[String]] = []
            for j in stride(from: chars.count, to: i, by: -1) {
                let w = String(chars[i..<j])
                guard w.count >= 2 ? isWord(w) : (w == "a" || w == "i") else { continue }
                for rest in from(j) where rest.count + 1 <= counts.upperBound { out.append([w] + rest) }
                if out.count > 24 { break }
            }
            memo[i] = out
            return out
        }
        return Array(from(0).filter { counts.contains($0.count) }.sorted { $0.count < $1.count }.prefix(6))
    }

    /// Keys next to each letter on a QWERTY keyboard.
    static let neighbours: [Character: [Character]] = {
        let rows: [Character: String] = [
            "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh", "u": "yihj", "i": "uojk",
            "o": "ipkl", "p": "ol", "a": "qwsz", "s": "adwezx", "d": "sferxc", "f": "dgrtcv", "g": "fhtyvb",
            "h": "gjyubn", "j": "hkuinm", "k": "jliom", "l": "kop", "z": "asx", "x": "zcsd", "c": "xvdf",
            "v": "cbfg", "b": "vngh", "n": "bmhj", "m": "njk",
        ]
        return rows.mapValues { Array($0) }
    }()

    /// The system's suggestion, cased like the user's token, if it's a real fix: one word (or the
    /// word split in two), different from the typo, and every part spelled correctly.
    private func acceptable(_ suggested: String, for word: String, token: String) -> String? {
        let cased = Self.matchCase(suggested, to: token)
        let lower = cased.lowercased()
        guard !cased.isEmpty, lower != word else { return nil }
        if cased.contains(where: \.isWhitespace) && !EditDistance.isSplit(lower, of: word) { return nil }
        let parts = lower.split(separator: " ").map(String.init)
        guard parts.allSatisfy({ spellChecker.isSurelySpelled($0, languages: languages) }) else { return nil }
        return cased
    }

    /// Splits a run-together word into two correctly spelled words, longest left part first;
    /// each part needs at least 2 letters (the shorter of "a"/"I" splits would be too eager).
    private func splitCandidate(for word: String) -> String? {
        let chars = Array(word)
        guard chars.count >= 6 else { return nil }
        for cut in stride(from: chars.count - 2, through: 2, by: -1) {
            let left = String(chars[..<cut]), right = String(chars[cut...])
            if spellChecker.isSurelySpelled(left, languages: languages),
               spellChecker.isSurelySpelled(right, languages: languages) {
                return left + " " + right
            }
        }
        return nil
    }

    /// "Deember", "I'l": an upper-case first letter and no other.
    static func isInitialCapital(_ token: String) -> Bool {
        guard let first = token.first, first.isUppercase else { return false }
        return token.dropFirst().allSatisfy { !$0.isUppercase }
    }

    /// Initial capital only ("Teh") where a sentence starts (`CapitalFix.startsSentence`: the start
    /// of the text or a line, or after . ! ? but not after "Dr." "e.g." or an ellipsis).
    static func isSentenceStartCapital(_ token: String, before: Substring) -> Bool {
        isInitialCapital(token) && CapitalFix.startsSentence(before: before)
    }

    /// Nearest learned word within edit distance 2 (1 for short words); keeps the learned word's case.
    /// With `learnedHere`, the nearest of this app's words; another app's only when none is in reach.
    private func learnedCandidate(for word: String) -> String? {
        if let here = learnedHere, let found = nearestLearned(to: word, among: knownLower.intersection(here)) {
            return found
        }
        return nearestLearned(to: word, among: knownLower)
    }

    private func nearestLearned(to word: String, among words: Set<String>) -> String? {
        let limit = word.count <= 4 ? 1 : 2
        var best: (lower: String, distance: Int)?
        for lower in words where abs(lower.count - word.count) <= limit {
            let d = EditDistance.osa(word, lower)
            guard d >= 1, d <= limit else { continue }
            if let b = best {
                if d < b.distance || (d == b.distance && lower < b.lower) { best = (lower, d) }
            } else {
                best = (lower, d)
            }
        }
        return best.flatMap { knownByLower[$0.lower] }
    }

    /// Applies the user's capitalization pattern: lowercase stays lowercase, Initial-cap and ALL-CAPS carry over.
    static func matchCase(_ replacement: String, to original: String) -> String {
        let letters = original.filter(\.isLetter)
        guard let first = letters.first else { return replacement }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return replacement.uppercased() }
        if first.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement.lowercased()
    }

    /// Other words a fix of `original` could have been (autocorrect "undo a fix later": the menu
    /// under a fixed word), likeliest first: the finder's own candidates for the word in this
    /// context (`head` is the text before it), then the system's guesses. Leaves out `current` (the
    /// fix in place) and the word as typed; at most `limit`. One word only; else none.
    public func alternatives(for original: String, head: String, current: String, limit: Int = 4) -> [String] {
        guard !original.isEmpty, original.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return [] }
        var out: [String] = []
        // At the start of a sentence every fix, also one from the menu, has its capital.
        let capital = fixesCapitals && Self.lowerInitial(original) && CapitalFix.startsSentence(before: Substring(head))
        func add(_ picked: String) {
            let word = capital ? CapitalFix.capitalizingFirst(picked) : picked
            let lower = word.lowercased()
            guard !word.isEmpty, lower != current.lowercased(), lower != original.lowercased(),
                  !out.contains(where: { $0.lowercased() == lower }) else { return }
            out.append(word)
        }
        switch finding(before: head + original + " ", deferAmbiguous: true) {
        case .ambiguous(let typo)?:
            typo.candidates.forEach(add)
            if let fallback = typo.fallback { add(fallback) }
        case .fix(let proposal)?:
            add(proposal.replacement)
        case nil:
            break
        }
        let options = suggester.options(for: original, context: head + original, languages: languages)
        if let confident = options.confident { add(Self.matchCase(confident, to: original)) }
        for guess in options.guesses { add(Self.matchCase(guess, to: original)) }
        return Array(out.prefix(limit))
    }
}

#if canImport(AppKit)
/// `NSSpellChecker`-backed suggester. Same threading rule as `SystemSpellChecker`: main thread only,
/// reached with an async hop and a bounded wait; a timeout answers nil (and is not cached).
public final class SystemCorrectionSuggester: CorrectionSuggesting, @unchecked Sendable {
    public var mainWaitTimeout: DispatchTimeInterval = .milliseconds(50)
    private struct Key: Hashable, Sendable { var word: String; var languages: [String] }
    private let lock = NSLock()
    private var cache: BoundedLRUCache<Key, CorrectionOptions>

    public init(cacheCapacity: Int = 256) { cache = BoundedLRUCache(capacity: cacheCapacity) }

    public func correction(for word: String, context: String, languages: [String]) -> String? {
        let options = options(for: word, context: context, languages: languages)
        if let confident = options.confident { return confident }
        // The first language's first guess, if it is plausible.
        if let first = options.guesses.first, EditDistance.isPlausibleGuess(first, for: word) { return first }
        return nil
    }

    public func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        let key = Key(word: word, languages: languages)
        lock.lock(); let hit = cache.value(for: key); lock.unlock()
        if let hit { return hit }
        let text = context.hasSuffix(word) ? context : word
        guard let answer = onMain({ @Sendable in Self.query(word: word, text: text, languages: languages) }) else {
            return CorrectionOptions(confident: nil, guesses: [])  // timeout: unknown, not cached
        }
        lock.lock(); cache.insert(answer, for: key); lock.unlock()
        return answer
    }

    private var completionCache = BoundedLRUCache<Key, [String]>(capacity: 128)

    public func completions(forPrefix prefix: String, languages: [String]) -> [String] {
        let key = Key(word: prefix, languages: languages)
        lock.lock(); let hit = completionCache.value(for: key); lock.unlock()
        if let hit { return hit }
        guard let answer = onMain({ @Sendable in Self.completions(prefix, languages: languages) }) else { return [] }
        lock.lock(); completionCache.insert(answer, for: key); lock.unlock()
        return answer
    }

    private static func completions(_ prefix: String, languages: [String]) -> [String] {
        let checker = NSSpellChecker.shared
        var resolved = SystemSpellChecker.resolve(languages, available: checker.availableLanguages)
        if resolved.isEmpty { resolved = [checker.language()] }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return checker.completions(forPartialWordRange: range, in: prefix, language: resolved[0],
                                   inSpellDocumentWithTag: 0) ?? []
    }

    /// The first confident correction over the languages, and the guesses of the first language
    /// that has any.
    private static func query(word: String, text: String, languages: [String]) -> CorrectionOptions {
        let checker = NSSpellChecker.shared
        var resolved = SystemSpellChecker.resolve(languages, available: checker.availableLanguages)
        if resolved.isEmpty { resolved = [checker.language()] }
        let ns = text as NSString
        let range = NSRange(location: ns.length - (word as NSString).length, length: (word as NSString).length)
        var confident: String?
        for language in resolved {
            if let fix = checker.correction(forWordRange: range, in: text, language: language,
                                            inSpellDocumentWithTag: 0), !fix.isEmpty {
                confident = fix
                break
            }
        }
        var guesses: [String] = []
        for language in resolved {
            guesses = checker.guesses(forWordRange: range, in: text, language: language,
                                      inSpellDocumentWithTag: 0) ?? []
            if !guesses.isEmpty { break }
        }
        return CorrectionOptions(confident: confident, guesses: guesses)
    }

    private func onMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        if Thread.isMainThread { return body() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { box.set(body()); done.signal() }
        return done.wait(timeout: .now() + mainWaitTimeout) == .success ? box.get() : nil
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
#endif

/// Common chat shorthand: abbreviations people type on purpose in casual chat ("id ofc" is "I'd, of
/// course"), which autocorrect would otherwise read as slips. Lowercase as typed; contractions typed
/// without the apostrophe ("dont", "im") are not here: those are worth fixing.
public enum ChatShorthand {
    public static let words: Set<String> = [
        "afaik", "asap", "bc", "bf", "brb", "btw", "cuz", "dm", "dms", "fr", "fwiw", "fyi", "gf", "gg", "gn", "gtg",
        "hbu", "id", "idc", "idk", "iirc", "ik", "ikr", "ily", "imo", "imho", "irl", "jk", "kk", "lmao", "lmk",
        "lol", "nah", "ngl", "np", "nvm", "obv", "obvs", "ofc", "omg", "omw", "pls", "plz", "ppl", "prob",
        "probs", "rn", "rly", "smh", "srsly", "tbf", "tbh", "thx", "tho", "tmr", "tmrw", "ttyl", "ty", "ur",
        "wyd", "ya", "yea", "yup",
    ]

    public static func contains(_ word: String) -> Bool { words.contains(word.lowercased()) }
}
