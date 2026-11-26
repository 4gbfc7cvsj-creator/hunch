import Foundation

// MARK: Learning contract (M3 track L ↔ track I). Frozen for M3 wave 1; changes go through the orchestrator.

/// How unlikely the model found one word of a suggestion, for "surprise" weighting in learning.
/// `text` is the word as shown (with its leading space, if any); `logProb` is the natural-log
/// probability summed over the word's tokens (≤ 0). More negative = more surprising.
public struct WordScore: Sendable, Equatable, Codable {
    public var text: String
    public var logProb: Float
    public init(text: String, logProb: Float) {
        self.text = text
        self.logProb = logProb
    }
}

/// Learned vocabulary passed with a request: words and short phrases the user confirmed, each
/// with a weight. The decoder adds `weight * strength` to the logit of any token that starts or
/// continues one of these entries consistently with the text already generated in this word.
/// Empty or `strength == 0` means no effect.
public struct LearnedBias: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Codable {
        /// The word or phrase, starting with a space when it follows a word boundary (" Kubernetes").
        public var text: String
        /// Relative preference, 0...1 (already includes repetition and recency).
        public var weight: Float
        public init(text: String, weight: Float) {
            self.text = text
            self.weight = weight
        }
    }
    public var entries: [Entry]
    /// Words or phrases the user blocked: the decoder subtracts `avoidPenalty` from tokens that
    /// continue toward one of them (same matching rules as `entries`). Applied even when
    /// `strength` is 0, because blocking is an explicit user choice.
    public var avoid: [String]
    /// User's "personalize word choice" slider, in logit units at weight 1 (0 = off).
    public var strength: Float
    /// Logit penalty for blocked entries (at full match).
    public var avoidPenalty: Float
    /// Learned phrases (part of "Learn words and phrases"): continuations of the text at the caret
    /// drawn from the user's own saved sentences in the same app or category. Unlike `entries`, each is anchored at
    /// the caret: `text` is what would follow the typed text directly (" tomorrow at 5" after
    /// "see you", "orrow" after "see you tom"), and it only applies from the first generated
    /// byte. The decoder adds at most `weight * phraseStrength` in total along the phrase, and only
    /// to tokens the model itself gives at least `phraseMinLogProb`, so it can steer between
    /// plausible continuations but never force an unlikely one.
    public var phrases: [Entry]
    /// Logit units at weight 1 for `phrases` (0 = off).
    public var phraseStrength: Float
    public static let phraseMinLogProb: Float = -4
    /// `phraseStrength` at the default "Personalize word choice" setting (1.5), picked from the
    /// 2026-11-11 measurement (2, 4 and 8 tried; 8 changed the most and judged best). Lower slider
    /// settings scale it down (0 turns phrases off); higher ones keep 8, the most that was measured.
    public static let defaultPhraseStrength: Float = 8
    public static func phraseStrength(personalize: Float) -> Float {
        max(0, min(defaultPhraseStrength, defaultPhraseStrength * personalize / 1.5))
    }
    public init(entries: [Entry] = [], strength: Float = 0, avoid: [String] = [], avoidPenalty: Float = 8,
                phrases: [Entry] = [], phraseStrength: Float = 0) {
        self.entries = entries
        self.strength = strength
        self.avoid = avoid
        self.avoidPenalty = avoidPenalty
        self.phrases = phrases
        self.phraseStrength = phraseStrength
    }
    public var isEmpty: Bool {
        (entries.isEmpty || strength <= 0) && avoid.isEmpty && (phrases.isEmpty || phraseStrength <= 0)
    }

    /// Only the entries that finish the half-typed word at the end of `before`, for a prompt that already
    /// names the learned words (gated notes on instruct models). `BiasBuilder` writes those entries as the
    /// whole word with no leading space, and every other entry starts with a space when the caret is
    /// mid-word, so mid-word that is the entries without leading whitespace; at a word boundary, none.
    /// Blocked words and phrases are kept.
    public func midWordOnly(before: String) -> LearnedBias {
        var out = self
        let midWord = before.last.map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" } ?? false
        out.entries = midWord ? entries.filter { !($0.text.first?.isWhitespace ?? true) } : []
        return out
    }
}
