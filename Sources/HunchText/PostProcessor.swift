// Turns a raw decoded candidate into display text, or a reason to show nothing. Pure.
import HunchCore
import Synchronization

/// The M1 post-processor (design §5.1-5.2). Suppression always wins over substitution: a bad
/// candidate is never rewritten into a different suggestion, only trimmed and clamped.
///
/// `raw` is the generated text with the healed required prefix already removed, so it continues
/// `context.before` directly. Steps, in order:
/// 1. Whitespace: trim trailing whitespace; strip leading line breaks (a space is kept in their
///    place when the text would otherwise glue onto a word); without `allowNewlines`, cut at the
///    first remaining line break; collapse whitespace runs; drop a leading space when `before`
///    already ends with whitespace; outside code, a space between sentence punctuation and a list
///    marker glued to it (`ListMarker`); inside a line, or with the next list item already after
///    the caret, the completion is cut before such a marker instead.
/// 2. Suppress: `.empty`, `.punctuationOnly`, `.markupLeak`, `.echoesAfter`, `.echoesBefore`,
///    `.repetitionLoop`, `.aiVoice` / `.metaReply` (classifier), `.lowConfidence`.
///    Also `.metaReply` when the text repeats or translates the framer's preface (`prefaceTexts`),
///    `.webAddress` when the completion makes the typed word a web address outside search fields
///    (an address later in it cuts the completion instead), and `.likelyTypo` when the word being typed or just finished looks misspelled (`spellChecker`).
/// 3. Clamp to `context.maxWords` at a word boundary (CJK-aware, see `TextMeasure`).
///
/// For code (`context.surface == .code`) the typo, quote and Han-script rules are skipped and the
/// clamp counts characters; see `CodePostProfile`.
public struct DefaultPostProcessor: SuggestionPostProcessing {
    /// Mean log-prob below this suppresses with `.lowConfidence`. nil disables the check.
    public var minMeanLogProb: Float?
    public var classifier: any AIVoiceClassifying

    /// Optional spell checker for the `.likelyTypo` rule; nil disables the rule.
    public var spellChecker: (any SpellChecking)?
    /// Languages the writer uses (for dictionary choice); CJK entries are ignored for spelling.
    public var spellLanguages: [String]
    /// The writer's learned vocabulary, lowercased. Never treated as typos.
    public var knownWords: Set<String>
    /// Extra framer header/label phrases to treat as preface (e.g. `DocumentFramer.prefacePhrases`).
    public var prefaceTexts: [String]
    /// Language guesser for the typo rule's foreign-word guard.
    var languageGuesser: any LanguageGuessing = NLLanguageGuesser()
    /// Words in a run shared with the screen text that count as copying it (CJK: twice as many
    /// characters). Screen text is the topic's own wording, so this is longer than for style examples.
    public var screenCopyRun = 6
    /// The same for Chinese and Japanese, in characters: 12 let a whole clause through (eval, 2026-11-02).
    public var screenCopyRunCJK = 8
    /// Eval A/B: false checks the completion alone for copied runs (the old guard), which lets a copy
    /// through a few words per suggestion. 0 or less for `screenCopyRun` turns the screen guard off.
    public var copyGuardCountsTypedWords = true

    public init(minMeanLogProb: Float? = nil, classifier: any AIVoiceClassifying = DefaultAIVoiceClassifier(),
                spellChecker: (any SpellChecking)? = nil, spellLanguages: [String] = [],
                knownWords: Set<String> = [], prefaceTexts: [String] = []) {
        self.minMeanLogProb = minMeanLogProb
        self.classifier = classifier
        self.spellChecker = spellChecker
        self.spellLanguages = spellLanguages
        self.knownWords = Set(knownWords.map { $0.lowercased() })
        self.prefaceTexts = prefaceTexts
    }

    /// Template and markup debris that must never reach the screen.
    static let markupFragments: [String] = [
        "<|", "|>", "<start_of", "<end_of", "[INST]", "[/INST]", "<<SYS>>", "<turn", "turn|>", "<s>", "</s>",
        "<eos>", "<bos>", "<pad>", "<think", "</think", "<unused", "<mask>", "[MASK]", "<channel",
    ]

    static func matchHanScript(_ text: String, before: String, after: String = "", languages: [String] = [],
                               preferred: HanVariant? = nil) -> String {
        let recent = String(before.suffix(200))
        if HanConversion.shouldConvertToTraditional(text: text, recent: recent, languages: languages) {
            return HanConversion.toTraditional(text)
        }
        guard let preferred else { return text }
        // The text decides when it shows simplified-only characters or at least two traditional-only ones.
        let around = recent + String(after.prefix(200))
        if HanConversion.containsKana(around) || HanConversion.containsKana(text) { return text }
        if HanScript.usesSimplified(around) || HanConversion.traditionalOnlyCount(around) >= 2 { return text }
        switch preferred {
        case .traditional: return HanScript.usesSimplified(text) ? HanConversion.toTraditional(text) : text
        case .simplified: return HanScript.usesTraditional(text) ? HanScript.simplified(text) : text
        }
    }

    /// Longest shell command suggestion, in characters.
    static let shellCharacterLimit = 240

    /// A shell command: the first line only, whitespace runs kept as typed (they can matter inside
    /// quotes), no prose rules. Whether it names real commands and parses is checked by the app
    /// (`HunchShell`), which can look at the user's shell.
    static func processShell(_ raw: String, context: PostContext) -> PostOutcome {
        var text = String(raw.prefix(while: { $0 != "\n" && $0 != "\r" }))
        while let last = text.last, last.isWhitespace { text.removeLast() }
        if context.before.last?.isWhitespace == true {
            while let first = text.first, first == " " { text.removeFirst() }
        }
        guard text.contains(where: { !$0.isWhitespace }) else { return .suppress(.empty) }
        guard text.count <= shellCharacterLimit else { return .suppress(.repetitionLoop) }
        return .show(text)
    }

    public func process(_ raw: String, meanLogProb: Float?, context: PostContext) -> PostOutcome {
        process(raw, meanLogProb: meanLogProb, context: context, trace: nil)
    }

    /// Notes what shortened the text, for the diagnostic console. Observation only: the outcome is the
    /// same with or without a trace.
    public final class Trace {
        /// Steps that cut the text, in the order they ran.
        public var cuts: [PostCutStep] = []
        /// The text was suppressed for repeating the framer's preface (PrefaceEcho).
        public var prefaceEcho = false
        public init() {}
    }

    public func process(_ raw: String, meanLogProb: Float?, context: PostContext, trace: Trace?) -> PostOutcome {
        if context.surface == .shell { return Self.processShell(raw, context: context) }
        let code = context.surface == .code
        var text = Self.normalizeWhitespace(raw, context: context)
        if let trace, !context.allowNewlines {
            let body = TextMeasure.trimTrailingWhitespace(String(raw.drop(while: \.isWhitespace)))
            if let newline = body.firstIndex(where: \.isNewline), body[newline...].contains(where: { !$0.isWhitespace }) {
                trace.cuts.append(.lineBreak)
            }
        }
        // "casual.3. Email" → "casual. 3. Email", so accepting a word stops before the next list item.
        if !code {
            // Inside existing text, or with the next item already after the caret, stop before it instead.
            if ListMarker.mustStopBeforeMarker(after: context.after) {
                let uncut = text
                text = ListMarker.cutBeforeNextItem(text, before: context.before)
                if trace != nil, text.count < uncut.count { trace?.cuts.append(.listMarker) }
            }
            text = ListMarker.separated(text, before: context.before)
        }
        // Write in the user's script: a traditional-Chinese writer gets traditional suggestions
        // even when the model drifts into simplified. Not in code: a literal stays as written.
        if !code {
            text = Self.matchHanScript(text, before: context.before, after: context.after, languages: spellLanguages,
                                       preferred: context.preferredHanScript)
        }

        guard text.contains(where: { !$0.isWhitespace }) else { return .suppress(.empty) }
        // Never show a writing system the user cannot type (and is not already writing in).
        if let allowed = context.allowedScripts {
            let permitted = ScriptGuard.permitted(allowed, before: context.before, after: context.after)
            switch ScriptGuard.cut(text, allowed: permitted) {
            case .unchanged: break
            case .cut(let kept):
                text = kept
                trace?.cuts.append(.scriptGuard)
            case .foreign: return .suppress(.foreignScript)
            }
        }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .suppress(.punctuationOnly) }
        if Self.hasMarkupLeak(text, before: context.before) { return .suppress(.markupLeak) }
        // Web addresses only in search fields: elsewhere they come from screen text, not the writer.
        if !context.allowsURLs {
            switch URLGuard.check(text, before: context.before) {
            case .unchanged: break
            case .cut(let kept):
                text = kept
                trace?.cuts.append(.urlGuard)
            case .url: return .suppress(.webAddress)
            }
        }

        let words = TextMeasure.normalizedWords(text)
        if Self.echoesAfter(words, after: context.after) { return .suppress(.echoesAfter) }
        let beforeWords = TextMeasure.normalizedWords(String(context.before.suffix(400)))
        if Self.echoesBefore(words, beforeWords: beforeWords) { return .suppress(.echoesBefore) }
        if Self.isRepetitionLoop(words, beforeWords: beforeWords) { return .suppress(.repetitionLoop) }
        // A completion that reproduces a run of a style example or of the screen text is cut just short
        // of the run; the words typed just before count toward the run, so a copy cannot get through
        // a few words per suggestion. Nothing left after the cut suppresses.
        let typed = copyGuardCountsTypedWords ? context.before : ""
        if let keep = Self.copyKeepWords(text, before: typed, sources: context.styleExamples,
                                         run: Self.styleCopyRun, runCJK: Self.styleCopyRunCJK) {
            text = Self.prefix(of: text, words: keep)
            trace?.cuts.append(.copiesStyleExample)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .suppress(.copiesStyleExample) }
        }
        if let screen = context.screenText, !code, screenCopyRun > 0, screenCopyRunCJK > 0,
           let keep = Self.copyKeepWords(text, before: typed, sources: [screen],
                                         run: screenCopyRun, runCJK: screenCopyRunCJK) {
            text = Self.prefix(of: text, words: keep)
            trace?.cuts.append(.copiesScreen)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .suppress(.copiesScreen) }
        }
        // The preface is talk about the text, not part of it: closest existing reason is .metaReply.
        if PrefaceEcho.echoes(text, phrases: prefaceTexts), !Self.beforeMentionsPreface(context.before, text) {
            trace?.prefaceEcho = true
            return .suppress(.metaReply)
        }

        if let reason = aiVoiceReason(before: context.before, completion: text) {
            // Task talk partway through: keep the words before it instead of hiding everything.
            guard reason == .metaReply, let kept = taskTalkCut(text, before: context.before) else {
                return .suppress(reason)
            }
            text = kept
            trace?.cuts.append(.taskTalk)
        }

        if let floor = minMeanLogProb, let meanLogProb, meanLogProb < floor { return .suppress(.lowConfidence) }

        if code { return processCode(text, raw: raw, context: context, trace: trace) }

        if let spellChecker,
           TypoDetector.shouldSuppress(before: context.before, suggestion: text, checker: spellChecker,
                                       languages: spellLanguages, knownWords: knownWords,
                                       learnedInPlay: context.learnedWords, guesser: languageGuesser) {
            return .suppress(.likelyTypo)
        }

        let clamped = TextMeasure.clamp(text, maxWords: context.maxWords)
        if trace != nil, clamped.count < text.count { trace?.cuts.append(.wordLimit(context.maxWords)) }
        guard clamped.contains(where: { !$0.isWhitespace }) else { return .suppress(.empty) }
        // Curly or straight quotes, as the field already uses (always straight when smart quotes are off).
        return .show(QuoteStyle.match(clamped, before: context.before, preference: context.quoteStyle))
    }

    /// Code profile tail: no typo rule (identifiers), no quote matching (literals), a character
    /// clamp at a token boundary, and one trailing newline when the kept line ends a statement and
    /// the model had gone on to another line (`allowNewlines` keeps all newlines as usual).
    private func processCode(_ text: String, raw: String, context: PostContext, trace: Trace?) -> PostOutcome {
        var clamped = CodePostProfile.clamp(text, maxWords: context.maxWords)
        if trace != nil, clamped.count < text.count { trace?.cuts.append(.codeLimit(context.maxWords)) }
        guard clamped.contains(where: { !$0.isWhitespace }) else { return .suppress(.empty) }
        if !context.allowNewlines,
           CodePostProfile.keepsTrailingNewline(line: clamped, continued: CodePostProfile.continuesPastFirstLine(raw),
                                                clamped: clamped != text) {
            clamped += "\n"
        }
        return .show(clamped)
    }

    /// Words in a run this long, shared with a style example, count as copying it. Chinese and Japanese
    /// tokenize per character, so a run of those needs `styleCopyRunCJK` characters (common 4-character
    /// phrases are not copying).
    static let styleCopyRun = 4
    static let styleCopyRunCJK = 8

    /// The leading part of `text` holding `count` words as `TextMeasure.normalizedWords` counts them
    /// (each CJK character is one word), trailing whitespace removed.
    static func prefix(of text: String, words count: Int) -> String {
        var seen = 0
        var inWord = false
        var cut = text.endIndex
        for index in text.indices {
            let c = text[index]
            let startsWord: Bool
            if TextMeasure.isCJK(c) {
                startsWord = true
                inWord = false
            } else if c.isLetter || c.isNumber {
                startsWord = !inWord
                inWord = true
            } else if (c == "'" || c == "\u{2019}") && inWord {
                startsWord = false
            } else {
                startsWord = false
                inWord = false
            }
            if startsWord {
                seen += 1
                if seen > count { cut = index; break }
            }
        }
        return TextMeasure.trimTrailingWhitespace(String(text[..<cut]))
    }

    /// For a completion that repeats a run of consecutive words from a style example: how many leading
    /// words to keep so that the run is not completed (the run's start index plus one word fewer than the
    /// run length). Nil when there is no such run.
    static func styleCopyKeepWords(_ words: [String], examples: [String]) -> Int? {
        copyKeepWords(words, tail: [], sources: examples, run: styleCopyRun, runCJK: styleCopyRunCJK)
    }

    /// `copyKeepWords` for a completion `text` that continues `before`: the last words typed count
    /// toward a run, and a word the completion finishes ("th" + "ere") is matched whole.
    static func copyKeepWords(_ text: String, before: String, sources: [String], run: Int, runCJK: Int) -> Int? {
        guard !sources.isEmpty else { return nil }
        var words = TextMeasure.normalizedWords(text)
        var tail = TextMeasure.normalizedWords(String(before.suffix(400)))
        func isWordChar(_ c: Character?) -> Bool {
            guard let c, c.isLetter || c.isNumber else { return false }
            return !c.unicodeScalars.contains(where: TextMeasure.isCJK)
        }
        if isWordChar(before.last), isWordChar(text.first), let last = tail.popLast(), !words.isEmpty {
            words[0] = last + words[0]
        }
        tail = Array(tail.suffix(max(run, runCJK) - 1))
        return copyKeepWords(words, tail: tail, sources: sources, run: run, runCJK: runCJK)
    }

    /// For a completion whose words (after the `tail` already typed) complete a run of consecutive words
    /// from a source: how many completion words to keep so the run is not completed. Nil when none does.
    /// A Latin run is `run` words; an all-CJK run (one character per word) is `runCJK`.
    static func copyKeepWords(_ words: [String], tail: [String], sources: [String], run: Int, runCJK: Int) -> Int? {
        guard !sources.isEmpty, !words.isEmpty else { return nil }
        func isCJKToken(_ w: String) -> Bool { w.count == 1 && w.first.map(TextMeasure.isCJK) == true }
        func keyed(_ ws: [String], at start: Int) -> [(n: Int, key: String)] {
            var out: [(Int, String)] = []
            for n in [run, runCJK] where start + n <= ws.count {
                let r = ws[start..<(start + n)]
                if n == run ? !r.allSatisfy(isCJKToken) : r.allSatisfy(isCJKToken) {
                    out.append((n, r.joined(separator: " ")))
                }
            }
            return out
        }
        let known = CopyRunCache.runs(for: sources, run: run, runCJK: runCJK) { ws, i in keyed(ws, at: i).map(\.key) }
        guard !known.isEmpty else { return nil }
        let all = tail + words
        var keep: Int?
        for i in 0..<all.count {
            for (n, key) in keyed(all, at: i) where i + n > tail.count && known.contains(key) {
                let k = max(0, i + n - 1 - tail.count)
                keep = min(keep ?? k, k)
            }
        }
        return keep
    }

    /// The writer is quoting the same wording themselves (e.g. writing about this app): not a leak.
    static func beforeMentionsPreface(_ before: String, _ text: String) -> Bool {
        let b = PrefaceEcho.normalized(String(before.suffix(600)))
        let t = PrefaceEcho.normalized(text)
        return t.count >= 12 && b.contains(t)
    }

    /// Small words a cut suggestion should not end on ("…identical for").
    static let danglingWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "for", "of", "to", "in", "on", "at", "by",
        "with", "from", "into", "onto", "as", "than", "that", "which", "who", "whom", "whose", "if",
        "because", "is", "are", "was", "were", "be", "been", "my", "your", "our", "their", "his", "her",
        "its", "this", "these", "those", "about", "like", "per", "via",
    ]

    /// For a completion the classifier flagged as task talk: the text before the first task-talk
    /// phrase, without dangling small words at its end. Nil (hide it) when the verdict is something
    /// else, nothing worth showing is left, or the cut text is still flagged.
    func taskTalkCut(_ text: String, before: String) -> String? {
        guard let detailed = classifier as? DefaultAIVoiceClassifier,
              detailed.verdict(before: before, completion: text) == .metaTalk,
              let start = DefaultAIVoiceClassifier.taskTalkStart(before: before, completion: text) else { return nil }
        var kept = TextMeasure.trimTrailingWhitespace(String(text[..<start]))
        // Drop dangling small words, but never a word the completion is finishing ("int" + "o").
        while let space = kept.lastIndex(where: \.isWhitespace) {
            let last = kept[kept.index(after: space)...]
            guard Self.danglingWords.contains(last.lowercased()) else { break }
            kept = TextMeasure.trimTrailingWhitespace(String(kept[..<space]))
        }
        // A lone small word after a space the writer typed ("Tell " + "the") dangles too.
        if !kept.contains(where: \.isWhitespace), Self.danglingWords.contains(kept.lowercased()),
           !(before.last.map { $0.isLetter || $0.isNumber } ?? false) {
            kept = ""
        }
        guard kept.contains(where: { $0.isLetter || $0.isNumber }),
              aiVoiceReason(before: before, completion: kept) == nil else { return nil }
        return kept
    }

    private func aiVoiceReason(before: String, completion: String) -> SuppressReason? {
        if let detailed = classifier as? DefaultAIVoiceClassifier {
            switch detailed.verdict(before: before, completion: completion) {
            case .selfIdentification: return .aiVoice
            case .chatReply, .metaTalk: return .metaReply
            case nil: return nil
            }
        }
        return classifier.isAIVoice(before: before, completion: completion) ? .aiVoice : nil
    }

    // MARK: - Steps

    static func normalizeWhitespace(_ raw: String, context: PostContext) -> String {
        var text = Substring(TextMeasure.trimTrailingWhitespace(raw))

        // Leading line breaks (with any whitespace around them).
        let leadingRun = text.prefix { $0.isWhitespace }
        if leadingRun.contains(where: \.isNewline) {
            text = text.dropFirst(leadingRun.count)
            if let first = text.first, first.isLetter || first.isNumber, !TextMeasure.isCJK(first),
               let last = context.before.last, !last.isWhitespace, !TextMeasure.isCJK(last) {
                text = " " + text
            }
        }
        if !context.allowNewlines, let newline = text.firstIndex(where: \.isNewline) {
            text = text[..<newline]
        }

        // Collapse runs: a run containing a line break becomes one "\n", any other run one space.
        var collapsed = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            collapsed.append(run.contains(where: \.isNewline) ? "\n" : " ")
            run = ""
        }
        for character in text {
            if character.isWhitespace {
                run.append(character)
            } else {
                flush()
                collapsed.append(character)
            }
        }
        flush()

        if let last = context.before.last, last.isWhitespace {
            while collapsed.first == " " { collapsed.removeFirst() }
        }
        return TextMeasure.trimTrailingWhitespace(collapsed)
    }

    static func hasMarkupLeak(_ text: String, before: String) -> Bool {
        if markupFragments.contains(where: { text.contains($0) }) { return true }
        // A code fence is fine while the writer is already writing Markdown with fences.
        return text.contains("```") && !before.contains("```")
    }

    /// The suggestion repeats the text right after the caret (at least 2 words).
    static func echoesAfter(_ words: [String], after: String) -> Bool {
        let afterWords = TextMeasure.normalizedWords(String(after.prefix(400)))
        let k = min(words.count, afterWords.count)
        guard k >= 2 else { return false }
        return words[..<k] == afterWords[..<k]
    }

    /// The suggestion contains the last 4 words of `before` verbatim.
    static func echoesBefore(_ words: [String], beforeWords: [String]) -> Bool {
        let n = 4
        guard beforeWords.count >= n, words.count >= n else { return false }
        let tail = Array(beforeWords.suffix(n))
        for start in 0...(words.count - n) where Array(words[start..<(start + n)]) == tail { return true }
        return false
    }

    /// A word repeated 3 times in a row, or a bigram repeated 3 times in a row, where the run
    /// reaches into the suggestion. Single CJK characters may repeat ("哈哈哈"); CJK bigram loops count.
    static func isRepetitionLoop(_ words: [String], beforeWords: [String]) -> Bool {
        let context = Array(beforeWords.suffix(4))
        let all = context + words
        let firstNew = context.count
        if all.count >= 3 {
            for i in 0...(all.count - 3) where i + 2 >= firstNew {
                let w = all[i]
                if w == all[i + 1], w == all[i + 2], !(w.count == 1 && w.unicodeScalars.allSatisfy(TextMeasure.isCJK)) {
                    return true
                }
            }
        }
        if all.count >= 6 {
            for i in 0...(all.count - 6) where i + 5 >= firstNew {
                if all[i] != all[i + 1], all[i] == all[i + 2], all[i] == all[i + 4],
                   all[i + 1] == all[i + 3], all[i + 1] == all[i + 5] {
                    return true
                }
            }
        }
        return false
    }
}

/// The run set of the last few sources, so a long screen excerpt is not re-split for every candidate.
enum CopyRunCache {
    private struct Key: Hashable { var sources: [String]; var run: Int; var runCJK: Int }
    private static let cache = Mutex<[Key: Set<String>]>([:])

    static func runs(for sources: [String], run: Int, runCJK: Int,
                     keyed: ([String], Int) -> [String]) -> Set<String> {
        let key = Key(sources: sources, run: run, runCJK: runCJK)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        var known = Set<String>()
        for source in sources {
            let ws = TextMeasure.normalizedWords(source)
            for i in 0..<ws.count { known.formUnion(keyed(ws, i)) }
        }
        cache.withLock { c in
            if c.count >= 8 { c.removeAll() }
            c[key] = known
        }
        return known
    }
}
