import Foundation

public typealias TokenID = Int32

/// Per-token facts computed once at model load from the vocabulary.
public struct TokenTraits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let control = TokenTraits(rawValue: 1 << 0)
    public static let endOfGeneration = TokenTraits(rawValue: 1 << 1)
    public static let unused = TokenTraits(rawValue: 1 << 2)
    public static let byteFallback = TokenTraits(rawValue: 1 << 3)
    public static let leadingSpace = TokenTraits(rawValue: 1 << 4)
    public static let containsNewline = TokenTraits(rawValue: 1 << 5)
    public static let wordStart = TokenTraits(rawValue: 1 << 6)
    public static let punctuation = TokenTraits(rawValue: 1 << 7)
    public static let sentenceEnd = TokenTraits(rawValue: 1 << 8)
    public static let invalidUTF8Alone = TokenTraits(rawValue: 1 << 9)
    public static let containsComma = TokenTraits(rawValue: 1 << 10)
}

public protocol VocabularyTable: Sendable {
    var count: Int { get }
    func bytes(_ id: TokenID) -> ArraySlice<UInt8>
    func traits(_ id: TokenID) -> TokenTraits
    /// Token ids whose bytes are prefix-compatible with `required` (either one is a prefix of the other).
    func admissible(forRequired required: ArraySlice<UInt8>) -> [TokenID]
}

public struct SeqID: Hashable, Sendable {
    public let raw: Int32
    public init(_ raw: Int32) { self.raw = raw }
    public static let primary = SeqID(0)
}

/// What the session's KV cache can do beyond appending.
/// - `trimSuffix`: a partial `seq_rm` of the tail works.
/// - `none`: only a strict prefix extension is reusable; anything else is a cold prefill.
/// - `trimAndShift`: trimming works and the backend can re-rotate positions (`llama_memory_can_shift`),
///   so a run of cached tokens can be moved to earlier positions instead of being re-decoded.
/// - `checkpoint`: the cache can't be cut in place (a hybrid model's recurrent layers keep one
///   running state per sequence), but the session saves that state at chosen points and, asked to
///   trim, goes back to the nearest saved point at or before it and re-reads the rest. A trim may
///   therefore keep fewer tokens than asked for.
public enum ReuseCapability: Sendable, Equatable {
    case trimSuffix, none, trimAndShift, checkpoint

    /// Whether a trim of sequence 0 is allowed (exact, or back to a checkpoint).
    public var canTrim: Bool { self != .none }
}

public struct ReusePlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case appendOnly(keep: Int)
        case trimAndAppend(keep: Int)
        case coldPrefill
        /// Keep `cached[0..<keep]`, drop `cached[keep..<keep+drop]`, and move the run
        /// `cached[keep+drop..<keep+drop+matched]`, which equals `next[keep+skip..<keep+skip+matched]`,
        /// to the positions `keep+skip...`. The `skip` tokens `next[keep..<keep+skip]` (re-tokenized
        /// window boundary) are decoded before the moved run; everything after it is decoded as usual.
        /// Requires `ReuseCapability.trimAndShift`.
        case removeAndShift(keep: Int, drop: Int, matched: Int, skip: Int)
    }
    public var action: Action
    public var tokensToDecode: Int
    public init(action: Action, tokensToDecode: Int) {
        self.action = action
        self.tokensToDecode = tokensToDecode
    }
}

public protocol ReusePlanning: Sendable {
    func plan(cached: [TokenID], next: [TokenID], capability: ReuseCapability) -> ReusePlan
}

public struct PromptSyncReport: Sendable, Equatable {
    public var decodedTokens: Int
    public var reusedTokens: Int
    public var duration: Duration
    public init(decodedTokens: Int, reusedTokens: Int, duration: Duration) {
        self.decodedTokens = decodedTokens
        self.reusedTokens = reusedTokens
        self.duration = duration
    }
}

/// Executor-confined view of a loaded model + context. Deliberately NOT Sendable:
/// it is only ever touched on the generation executor thread.
public protocol LanguageModelSession: AnyObject {
    var vocabulary: any VocabularyTable { get }
    var maxParallelSequences: Int { get }
    var reuseCapability: ReuseCapability { get }
    func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID]
    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport
    /// Copies the KV state of `source` into each target sequence.
    func fork(_ source: SeqID, into targets: [SeqID]) throws
    /// One batched decode appending one token to each listed sequence.
    func step(_ appends: [(SeqID, TokenID)]) throws
    /// Log-softmax of the last logits of `seq`, written into `buffer` (resized to the vocabulary size).
    func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws
    func discard(_ seqs: [SeqID])
    var isCancellationRequested: Bool { get }
    /// Prompt tokens the session actually kept in sequence 0 (after a successful or failed sync).
    var retainedPromptTokens: [TokenID] { get }
}

extension LanguageModelSession {
    /// Sessions that can't report what they kept (test fakes) report nothing; callers then fall
    /// back to a conservative prefix.
    public var retainedPromptTokens: [TokenID] { [] }
}

/// Settings → General → "Suggestion confidence": the word-start confidence floor
/// (`DecodeConfig.wordStartMinFirstLogProb`), ordered from showing more to fewer. Saved as its own
/// field so Off round-trips (nil isn't encoded in `DecodeConfig`).
public enum SuggestionConfidence: String, Codable, Sendable, CaseIterable {
    case off
    case minus2_0 = "-2.0", minus1_75 = "-1.75", minus1_5 = "-1.5", minus1_25 = "-1.25", minus1_0 = "-1.0"

    public static let standard: SuggestionConfidence = .minus1_5

    /// nil = off.
    public var wordStartMinFirstLogProb: Float? { self == .off ? nil : Float(rawValue) }
}

/// How candidates are ranked. Competitors use `.sum` (design §5.2 update).
public enum ScoringRule: String, Codable, Sendable, CaseIterable { case sum, mean }

public struct DecodeConfig: Codable, Sendable, Equatable {
    /// A sentence end does not stop generation before this many words (LengthPreset.minWords).
    public var minWords: Int
    public var maxWords: Int
    public var maxTokens: Int
    /// Number of first-token branches, each extended greedily. 1 = plain greedy (M1).
    public var firstTokenFanout: Int
    public var scoring: ScoringRule
    /// Mean log-prob below this suppresses the suggestion (confidence floor). With the confidence
    /// trim on, it applies to the trimmed suggestion. Mid-word, `midWordMinMeanLogProb` replaces it.
    public var minMeanLogProb: Float
    /// Split floor (2026-11-18): at a word start (nothing of the next word typed yet), a first
    /// token below this suppresses the suggestion, on top of `minMeanLogProb`. Not for suggestions
    /// with CJK text. nil = off. See `ConfidenceFloor` in HunchDecode.
    public var wordStartMinFirstLogProb: Float?
    /// Split floor: mid-word (the caret ends a partial word), this replaces `minMeanLogProb`, only
    /// as a safety net against garbage. Not for suggestions with CJK text. nil = `minMeanLogProb`.
    public var midWordMinMeanLogProb: Float?
    public var stopAtSentenceEnd: Bool
    public var stopAtComma: Bool
    public var allowNewline: Bool
    /// Confidence trim: when per-token confidence drops partway through a suggestion, cut it at the
    /// last clause end before the drop (else the last whole word). See `ConfidenceTrim` in HunchDecode.
    public var trimEnabled: Bool
    /// A drop is the first token where the mean log-prob of `trimWindow` tokens (it and the ones
    /// after it, fewer at the end) is below this.
    public var trimDropLogProb: Float
    public var trimWindow: Int
    /// Below `minWords`, the end of the model's turn and a newline don't end the suggestion: the
    /// best ordinary token is taken instead, so it goes on into the next sentence. Not for
    /// suggestions with CJK text. The app turns it on for `LengthPreset.holdsEnd`; the eval's
    /// `--hold-end on|off` overrides it.
    public var holdEndBelowMinWords: Bool
    /// With the hold, text added past the held end must average at least this log-prob per token,
    /// else the suggestion falls back to the text before the hold. Judged 2026-11-05 at Ultra
    /// (E4B): tails below -1.4 were mostly rated unrealistic.
    public var holdTailMinLogProb: Float
    public static let defaultHoldTailMinLogProb: Float = -1.4

    /// Tuned 2026-11-05 on 698 judged suggestions (E4B/E2B, medium length): the trim at -1.5 over
    /// one token touched 13 % of the judges' lows and 0.7 % of the well-rated ones; raising the
    /// floor anywhere up to -1.5 hid nothing judged, so it stays at -2.5.
    public static let defaultMinMeanLogProb: Float = -2.5
    /// Split floor, measured 2026-11-18 on floor-off replays (docs/features/confidence-floor-study-20261118.md):
    /// mean confidence barely predicts acceptance mid-word (~40 % taken even below -3), while at word
    /// starts the first token's log-prob separates taken from ignored suggestions best. -1.0 hid too
    /// much in use; -1.5 hides 18 % of word-start suggestions on the captures, of which 8 % were taken.
    /// The app's value comes from `SuggestionConfidence` (Settings → General); this is the eval's.
    public static let defaultWordStartMinFirstLogProb: Float = -1.5
    public static let defaultMidWordMinMeanLogProb: Float = -8.0
    public static let defaultTrimDropLogProb: Float = -1.5
    public static let defaultTrimWindow = 1

    public init(minWords: Int = 2, maxWords: Int = 4, maxTokens: Int = 24, firstTokenFanout: Int = 1, scoring: ScoringRule = .sum,
                minMeanLogProb: Float = DecodeConfig.defaultMinMeanLogProb,
                wordStartMinFirstLogProb: Float? = DecodeConfig.defaultWordStartMinFirstLogProb,
                midWordMinMeanLogProb: Float? = DecodeConfig.defaultMidWordMinMeanLogProb, stopAtSentenceEnd: Bool = true,
                stopAtComma: Bool = false, allowNewline: Bool = false, trimEnabled: Bool = true,
                trimDropLogProb: Float = DecodeConfig.defaultTrimDropLogProb,
                trimWindow: Int = DecodeConfig.defaultTrimWindow, holdEndBelowMinWords: Bool = false,
                holdTailMinLogProb: Float = DecodeConfig.defaultHoldTailMinLogProb) {
        self.minWords = minWords
        self.maxWords = maxWords
        self.maxTokens = maxTokens
        self.firstTokenFanout = firstTokenFanout
        self.scoring = scoring
        self.minMeanLogProb = minMeanLogProb
        self.wordStartMinFirstLogProb = wordStartMinFirstLogProb
        self.midWordMinMeanLogProb = midWordMinMeanLogProb
        self.stopAtSentenceEnd = stopAtSentenceEnd
        self.stopAtComma = stopAtComma
        self.allowNewline = allowNewline
        self.trimEnabled = trimEnabled
        self.trimDropLogProb = trimDropLogProb
        self.trimWindow = trimWindow
        self.holdEndBelowMinWords = holdEndBelowMinWords
        self.holdTailMinLogProb = holdTailMinLogProb
    }

    private enum CodingKeys: String, CodingKey {
        case minWords, maxWords, maxTokens, firstTokenFanout, scoring, minMeanLogProb, wordStartMinFirstLogProb,
             midWordMinMeanLogProb, stopAtSentenceEnd, stopAtComma,
             allowNewline, trimEnabled, trimDropLogProb, trimWindow, holdEndBelowMinWords, holdTailMinLogProb
    }

    /// Keys added later are optional, so settings files written before them still decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DecodeConfig()
        minWords = try c.decodeIfPresent(Int.self, forKey: .minWords) ?? d.minWords
        maxWords = try c.decodeIfPresent(Int.self, forKey: .maxWords) ?? d.maxWords
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        firstTokenFanout = try c.decodeIfPresent(Int.self, forKey: .firstTokenFanout) ?? d.firstTokenFanout
        scoring = try c.decodeIfPresent(ScoringRule.self, forKey: .scoring) ?? d.scoring
        minMeanLogProb = try c.decodeIfPresent(Float.self, forKey: .minMeanLogProb) ?? d.minMeanLogProb
        // Files written before the split floor (and nil, which encoding omits) get the defaults.
        wordStartMinFirstLogProb = try c.decodeIfPresent(Float.self, forKey: .wordStartMinFirstLogProb)
            ?? d.wordStartMinFirstLogProb
        midWordMinMeanLogProb = try c.decodeIfPresent(Float.self, forKey: .midWordMinMeanLogProb) ?? d.midWordMinMeanLogProb
        stopAtSentenceEnd = try c.decodeIfPresent(Bool.self, forKey: .stopAtSentenceEnd) ?? d.stopAtSentenceEnd
        stopAtComma = try c.decodeIfPresent(Bool.self, forKey: .stopAtComma) ?? d.stopAtComma
        allowNewline = try c.decodeIfPresent(Bool.self, forKey: .allowNewline) ?? d.allowNewline
        trimEnabled = try c.decodeIfPresent(Bool.self, forKey: .trimEnabled) ?? d.trimEnabled
        trimDropLogProb = try c.decodeIfPresent(Float.self, forKey: .trimDropLogProb) ?? d.trimDropLogProb
        trimWindow = try c.decodeIfPresent(Int.self, forKey: .trimWindow) ?? d.trimWindow
        holdEndBelowMinWords = try c.decodeIfPresent(Bool.self, forKey: .holdEndBelowMinWords) ?? d.holdEndBelowMinWords
        holdTailMinLogProb = try c.decodeIfPresent(Float.self, forKey: .holdTailMinLogProb) ?? d.holdTailMinLogProb
    }
}

public enum StopReason: String, Sendable, Codable {
    /// Partial result delivered through `onPartial`; generation has not finished.
    case inProgress
    case wordBudget, sentenceEnd, comma, endOfGeneration, newline, tokenCap, lowConfidence, cancelled
    /// Cut back by the confidence trim (`DecodeConfig.trimEnabled`).
    case confidenceTrim
}

public struct Candidate: Sendable, Equatable {
    /// Generated text with the required prefix already removed. Empty means the model produced
    /// only the forced required prefix (nothing new to show).
    public var text: String
    public var tokens: [TokenID]
    public var meanLogProb: Float
    public var totalLogProb: Float
    public var stop: StopReason
    /// The first visible token's log-prob (nil when unknown or nothing scored yet). Lets a streamed
    /// partial be held to the word-start confidence floor before the suggestion is finished.
    public var firstLogProb: Float?
    public init(text: String, tokens: [TokenID], meanLogProb: Float, totalLogProb: Float, stop: StopReason,
                firstLogProb: Float? = nil) {
        self.firstLogProb = firstLogProb
        self.text = text
        self.tokens = tokens
        self.meanLogProb = meanLogProb
        self.totalLogProb = totalLogProb
        self.stop = stop
    }
}

public protocol CompletionSearching {
    func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                onPartial: (Candidate) -> Void) throws -> [Candidate]
}
