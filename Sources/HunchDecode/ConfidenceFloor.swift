import HunchCore

/// The confidence floor: whether a finished suggestion is too unsure to show.
///
/// Split by where the caret is (2026-11-18, `docs/features/confidence-floor-study-20261118.md`):
/// - **Mid-word** (the required prefix ends in part of a word): only `midWordMinMeanLogProb`, a
///   safety net. The typed letters force an unlikely start, yet these are taken as often as
///   confident ones.
/// - **Word start**: `minMeanLogProb` on the mean, plus `wordStartMinFirstLogProb` on the first
///   token, the score that best predicts whether a suggestion gets taken.
/// - **CJK text** (no word boundaries; not measured): `minMeanLogProb` only, as before.
public enum ConfidenceFloor {
    public enum Failure: Equatable, Sendable {
        /// The mean log-prob is below `limit`.
        case mean(limit: Float)
        /// At a word start, the first token's log-prob is below `limit`.
        case firstToken(limit: Float)
    }

    /// Whether the caret ends mid-word: the required prefix (healed spaces + partial word) ends in
    /// a word character.
    public static func isMidWord(requiredPrefix: some Sequence<UInt8>) -> Bool {
        guard let last = String(decoding: Array(requiredPrefix), as: UTF8.self).last else { return false }
        return !last.isWhitespace
    }

    /// nil when the suggestion passes. `firstLogProb` is the first visible token's log-prob.
    public static func check(text: String, mean: Float, firstLogProb: Float?, midWord: Bool,
                             config: DecodeConfig) -> Failure? {
        let cjk = text.unicodeScalars.contains(where: TextRules.isCJK)
        if midWord, !cjk {
            let limit = config.midWordMinMeanLogProb ?? config.minMeanLogProb
            return mean < limit ? .mean(limit: limit) : nil
        }
        if mean < config.minMeanLogProb { return .mean(limit: config.minMeanLogProb) }
        return firstTokenFailure(text: text, firstLogProb: firstLogProb, midWord: midWord, config: config)
    }

    /// The word-start first-token part alone. It is known as soon as the first token is, so a
    /// streamed partial that fails it is never shown (the finished result would hide it).
    public static func firstTokenFailure(text: String, firstLogProb: Float?, midWord: Bool,
                                         config: DecodeConfig) -> Failure? {
        guard !midWord, !text.unicodeScalars.contains(where: TextRules.isCJK),
              let limit = config.wordStartMinFirstLogProb, let firstLogProb, firstLogProb < limit else { return nil }
        return .firstToken(limit: limit)
    }
}
