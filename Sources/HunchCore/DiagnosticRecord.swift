import Foundation

// The diagnostic console's data (Settings → Privacy & Data → Diagnostics). One `DiagnosticRecord`
// per model request: what went in (sections plus the full prompt) and what came out (the generated
// text word by word, where it was cut and why, and what the user was shown). Pure values; the
// in-memory `DiagnosticRecorder` holds them while the console window is open.

public enum DiagnosticKind: String, Sendable, Equatable {
    case suggestion, dictation, writeForMe, suggestedReplies

    public var title: String {
        switch self {
        case .suggestion: "Suggestion"
        case .dictation: "Dictation cleanup"
        case .writeForMe: "Write for me"
        case .suggestedReplies: "Quick replies"
        }
    }
}

/// A prompt block the token budget dropped or shortened (`FrameAssembler`).
public struct BudgetNote: Sendable, Equatable {
    public enum Kind: String, Sendable { case dropped, cut }
    public var name: String
    public var kind: Kind
    public var detail: String
    public init(name: String, kind: Kind, detail: String) {
        self.name = name
        self.kind = kind
        self.detail = detail
    }

    public var text: String { "\(name): \(kind == .dropped ? "left out" : "shortened"), \(detail)" }
}

/// One labelled part of "what went in". Empty `items` means the model got nothing of this kind.
public struct DiagnosticSection: Sendable, Equatable, Identifiable {
    public struct Item: Sendable, Equatable {
        public var label: String?
        public var text: String
        public init(_ label: String? = nil, _ text: String) {
            self.label = label
            self.text = text
        }
    }
    public var title: String
    public var items: [Item]
    public var id: String { title }
    public init(_ title: String, _ items: [Item]) {
        self.title = title
        self.items = items
    }
}

public struct DiagnosticPromptSegment: Sendable, Equatable {
    public var text: String
    /// Block name from the framer ("text", "screen: …"); nil for chat markers and separators.
    public var label: String?
    /// Framer-authored control text (chat markers), as opposed to user or field text.
    public var isControl: Bool
    public init(text: String, label: String?, isControl: Bool) {
        self.text = text
        self.label = label
        self.isControl = isControl
    }
}

/// The prompt exactly as it went to the model, after redaction, with how it was framed.
public struct DiagnosticPrompt: Sendable, Equatable {
    public var framerID: String
    public var requiredPrefix: String
    public var segments: [DiagnosticPromptSegment]
    public var promptTokens: Int
    /// The framer's token budget (nil when the path has none worth showing).
    public var budget: Int?
    /// Prompt tokens decoded and reused from the KV cache for this request.
    public var decodedTokens: Int?
    public var reusedTokens: Int?
    public var notes: [BudgetNote]
    public init(framerID: String, requiredPrefix: String, segments: [DiagnosticPromptSegment], promptTokens: Int,
                budget: Int? = nil, decodedTokens: Int? = nil, reusedTokens: Int? = nil, notes: [BudgetNote] = []) {
        self.framerID = framerID
        self.requiredPrefix = requiredPrefix
        self.segments = segments
        self.promptTokens = promptTokens
        self.budget = budget
        self.decodedTokens = decodedTokens
        self.reusedTokens = reusedTokens
        self.notes = notes
    }

    /// The whole prompt as one string (control markers included).
    public var fullText: String { segments.map(\.text).joined() }

    /// Which framer class produced it, with the id its prompt carries.
    public var framerName: String {
        let name: String
        switch framerID {
        case let id where id.hasPrefix("document"): name = "DocumentFramer"
        case let id where id.hasPrefix("chat-prefill"): name = "ChatPrefillFramer"
        case let id where id.hasPrefix("dictation"): name = "DictationFramer"
        case let id where id.hasPrefix("write-for-me"): name = "WriteForMeFramer"
        default: name = "framer"
        }
        return "\(name) (\(framerID))"
    }
}

/// What the confidence trim found (`ConfidenceTrim.explain`).
public struct ConfidenceTrimFacts: Sendable, Equatable {
    /// The token where the drop started.
    public var dropText: String
    /// Mean log-prob of the `window` tokens from the drop (fewer at the end of the text).
    public var windowedMean: Float
    public var limit: Float
    public var window: Int
    /// Cut at a clause end (a sentence end, or just before a comma) rather than at a whole word.
    public var atClauseEnd: Bool
    public init(dropText: String, windowedMean: Float, limit: Float, window: Int, atClauseEnd: Bool) {
        self.dropText = dropText
        self.windowedMean = windowedMean
        self.limit = limit
        self.window = window
        self.atClauseEnd = atClauseEnd
    }
}

/// A step of the post-processor that shortened the text.
public enum PostCutStep: Sendable, Equatable {
    case lineBreak, listMarker, scriptGuard, urlGuard, copiesStyleExample, copiesScreen, taskTalk
    case wordLimit(Int)
    case codeLimit(Int)
}

public enum CutReason: Sendable, Equatable {
    case confidenceTrim(ConfidenceTrimFacts)
    case postProcessing(PostCutStep)

    /// Plain words for the ✂ marker.
    public var text: String {
        switch self {
        case .confidenceTrim(let f):
            let what = f.window <= 1
                ? "the model's confidence in “\(f.dropText)” was \(Self.percent(f.windowedMean)) (log \(Self.log(f.windowedMean)))"
                : "the average confidence over the \(f.window) tokens from “\(f.dropText)” was "
                    + "\(Self.percent(f.windowedMean)) (log \(Self.log(f.windowedMean)))"
            let limit = "below the limit of \(Self.percent(f.limit)) (log \(Self.log(f.limit)))"
            let where_ = f.atClauseEnd
                ? "Cut at the last clause end before it."
                : "Cut at the last whole word before it (no clause end left enough words)."
            return "Confidence trim: \(what), \(limit). \(where_)"
        case .postProcessing(let step):
            switch step {
            case .lineBreak: return "Cut at a line break: this field takes a single line."
            case .listMarker: return "Cut before the next list item, so accepting words stops there."
            case .scriptGuard: return "ScriptGuard cut it where a writing system you don't type began."
            case .urlGuard: return "URLGuard cut it where a web address began."
            case .copiesStyleExample: return "Cut just short of repeating one of your earlier sentences word for word."
            case .copiesScreen: return "Cut just short of repeating the on-screen text word for word."
            case .taskTalk: return "Cut just before it started talking about the task (AI-voice check)."
            case .wordLimit(let n): return "Word limit: suggestions are held to \(n) word\(n == 1 ? "" : "s")."
            case .codeLimit(let n): return "Length limit: code suggestions are held to \(n) characters."
            }
        }
    }

    public static func percent(_ logProb: Float) -> String {
        let p = Double(exp(logProb)) * 100
        return p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    public static func log(_ value: Float) -> String { String(format: "%.2f", Double(value)).replacingOccurrences(of: "-", with: "\u{2212}") }
}

public struct DiagnosticCutMark: Sendable, Equatable {
    /// How many words come before the cut.
    public var afterWords: Int
    public var reason: CutReason
    public init(afterWords: Int, reason: CutReason) {
        self.afterWords = afterWords
        self.reason = reason
    }
}

public struct DiagnosticWord: Sendable, Equatable {
    /// With its leading whitespace, as generated.
    public var text: String
    /// exp of the mean log-prob of the word's tokens; nil when no token is known for it.
    public var probability: Float?
    public var tokenCount: Int
    /// Byte range in the generated text (leading whitespace included).
    public var byteRange: Range<Int>
    public init(text: String, probability: Float?, tokenCount: Int, byteRange: Range<Int>) {
        self.text = text
        self.probability = probability
        self.tokenCount = tokenCount
        self.byteRange = byteRange
    }
}

public struct DiagnosticOutput: Sendable, Equatable {
    /// Everything the model generated, before any cut.
    public var text: String
    /// The text split into words with their confidence. Empty when per-token scores are not
    /// available (dictation cleanup and Write for me: the text is shown plain).
    public var words: [DiagnosticWord]
    /// Where the text was shortened, earliest first.
    public var cuts: [DiagnosticCutMark]
    /// Why the model stopped writing, in plain words.
    public var stopText: String?
    public var generatedTokens: Int
    public var meanLogProb: Float?
    public var alternatives: [String]
    public init(text: String, words: [DiagnosticWord] = [], cuts: [DiagnosticCutMark] = [], stopText: String? = nil,
                generatedTokens: Int = 0, meanLogProb: Float? = nil, alternatives: [String] = []) {
        self.text = text
        self.words = words
        self.cuts = cuts
        self.stopText = stopText
        self.generatedTokens = generatedTokens
        self.meanLogProb = meanLogProb
        self.alternatives = alternatives
    }

    public var hasScores: Bool { !words.isEmpty }
    /// Words from here on were cut off (nil: nothing was cut).
    public var firstCutAfterWord: Int? { cuts.map(\.afterWords).min() }
}

/// What the user was shown of a suggestion.
public enum DiagnosticFate: Sendable, Equatable {
    /// The result has not been judged yet (the app decides a moment later).
    case pending
    case shown(String)
    /// Post-processing or a guard hid it. `detail` adds numbers where there are some.
    case suppressed(SuppressReason, detail: String?)
    /// A good result that was not drawn (`why` says what had changed).
    case notDisplayed(String)
    /// A newer keystroke cancelled the request while it was at the model.
    case cancelled
    /// No model output was involved (a shell history match) or the line does not apply.
    case notApplicable
    /// The shell check refused the command.
    case blockedByShellCheck
    /// What became of a suggested-replies bubble: `summary` for the list ("inserted #2"), `detail`
    /// in full ("inserted reply 2 after 2 Tabs, 4.1 s after it showed").
    case replies(summary: String, detail: String)

    /// The text after "Shown to you:".
    public var text: String {
        switch self {
        case .pending: "not decided yet"
        case .shown(let text): "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))”"
        case .suppressed(let reason, let detail):
            "nothing: " + reason.plainWords + (detail.map { " (\($0))" } ?? "")
        case .notDisplayed(let why): "nothing: \(why)"
        case .cancelled: "nothing: you kept typing, which cancelled this request before it finished"
        case .notApplicable: "not applicable"
        case .blockedByShellCheck: "nothing: the shell check refused the command (unknown command, bad syntax, or risky)"
        case .replies(_, let detail): detail
        }
    }

    public var isShown: Bool { if case .shown = self { true } else { false } }

    /// Short form for the list.
    public var summary: String {
        switch self {
        case .pending: "…"
        case .shown: "shown"
        case .suppressed(let reason, _): "hidden: \(reason.shortWords)"
        case .notDisplayed: "not drawn"
        case .cancelled: "cancelled"
        case .notApplicable: ""
        case .blockedByShellCheck: "hidden: shell check"
        case .replies(let summary, _): summary
        }
    }
}

extension SuppressReason {
    /// Why nothing was shown, in plain words (the guard's name where there is one).
    public var plainWords: String {
        switch self {
        case .empty: "nothing was left of the text after clean-up"
        case .punctuationOnly: "it was only punctuation"
        case .aiVoice: "it read like an AI introducing itself (AI-voice check)"
        case .metaReply: "it talked about the text instead of continuing it (AI-voice check, or PrefaceEcho: it repeated the prompt's own wording)"
        case .echoesBefore: "it only repeated words you had just typed"
        case .echoesAfter: "it only repeated the text after the caret"
        case .repetitionLoop: "it was stuck repeating itself"
        case .lowConfidence: "below the confidence floor"
        case .likelyTypo: "a typo check hid it: the word being typed (or just finished) looks misspelled"
        case .markupLeak: "chat markup leaked into the text"
        case .tooShort: "it was too short to be useful"
        case .copiesStyleExample: "it would have copied one of your earlier sentences word for word"
        case .foreignScript: "ScriptGuard: it was in a writing system you don't type"
        case .webAddress: "URLGuard: it would have made a web address"
        case .copiesScreen: "it would have copied the on-screen text word for word"
        }
    }

    public var shortWords: String {
        switch self {
        case .empty: "empty"
        case .punctuationOnly: "punctuation only"
        case .aiVoice: "AI voice"
        case .metaReply: "meta reply"
        case .echoesBefore: "echoes before"
        case .echoesAfter: "echoes after"
        case .repetitionLoop: "repetition"
        case .lowConfidence: "low confidence"
        case .likelyTypo: "typo"
        case .markupLeak: "markup"
        case .tooShort: "too short"
        case .copiesStyleExample: "copies a style example"
        case .foreignScript: "script guard"
        case .webAddress: "URL guard"
        case .copiesScreen: "copies screen"
        }
    }
}

extension StopReason {
    /// Why the model stopped writing, in plain words.
    public var plainWords: String {
        switch self {
        case .inProgress: "still writing"
        case .wordBudget: "it reached the word limit"
        case .sentenceEnd: "it ended the sentence"
        case .comma: "it stopped at a comma"
        case .endOfGeneration: "it ended its turn"
        case .newline: "it started a new line"
        case .tokenCap: "it hit the token limit"
        case .lowConfidence: "its confidence was too low overall"
        case .cancelled: "it was cancelled"
        case .confidenceTrim: "the confidence trim cut it back"
        }
    }
}

public struct DiagnosticTiming: Sendable, Equatable {
    public var totalMs: Double?
    public var framingMs: Double?
    public var promptSyncMs: Double?
    public var firstWordsMs: Double?
    public init(totalMs: Double? = nil, framingMs: Double? = nil, promptSyncMs: Double? = nil, firstWordsMs: Double? = nil) {
        self.totalMs = totalMs
        self.framingMs = framingMs
        self.promptSyncMs = promptSyncMs
        self.firstWordsMs = firstWordsMs
    }

    public init(_ timings: CompletionTimings) {
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        self.init(totalMs: ms(timings.total), framingMs: ms(timings.framing), promptSyncMs: ms(timings.promptSync),
                  firstWordsMs: timings.firstVisible.map(ms))
    }
}

public struct DiagnosticRecord: Sendable, Equatable, Identifiable {
    /// Counts up as requests are recorded.
    public var id: Int
    /// The suggestion request's id (the app matches its "shown to you" note by it).
    public var requestKey: UInt64?
    public var date: Date
    public var kind: DiagnosticKind
    public var appName: String?
    public var domain: String?
    public var windowTitle: String?
    public var model: String?
    /// How the model was reached: "cache", "reuse", "fresh", "cold" (suggestions).
    public var servePath: String?
    public var sections: [DiagnosticSection]
    public var prompt: DiagnosticPrompt?
    public var output: DiagnosticOutput?
    public var fate: DiagnosticFate
    public var timing: DiagnosticTiming
    /// A line of context where the entry is unusual ("served from cache", "cancelled before…").
    public var note: String?

    public init(id: Int = 0, requestKey: UInt64? = nil, date: Date = Date(), kind: DiagnosticKind,
                appName: String? = nil, domain: String? = nil, windowTitle: String? = nil, model: String? = nil,
                servePath: String? = nil, sections: [DiagnosticSection] = [], prompt: DiagnosticPrompt? = nil,
                output: DiagnosticOutput? = nil, fate: DiagnosticFate = .notApplicable,
                timing: DiagnosticTiming = DiagnosticTiming(), note: String? = nil) {
        self.id = id
        self.requestKey = requestKey
        self.date = date
        self.kind = kind
        self.appName = appName
        self.domain = domain
        self.windowTitle = windowTitle
        self.model = model
        self.servePath = servePath
        self.sections = sections
        self.prompt = prompt
        self.output = output
        self.fate = fate
        self.timing = timing
        self.note = note
    }

    /// App (and site) for the list.
    public var placeSummary: String {
        let app = appName ?? "Unknown app"
        if let domain, !domain.isEmpty { return "\(app) · \(domain)" }
        return app
    }

    /// The list's outcome column: what was shown, or why not.
    public var outcomeSummary: String {
        switch fate {
        case .shown(let text): return "“\(text.trimmingCharacters(in: .whitespacesAndNewlines))”"
        case .notApplicable:
            if let text = output?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return "“\(text)”" }
            return "no text"
        default: return fate.summary
        }
    }
}
