import Foundation

/// What the model's scores say about an ambiguous word.
public enum TypoChoice: Sendable, Equatable {
    /// Clearly better than the word as typed and every other candidate.
    case fix(String)
    /// Better than the word as typed, but not by enough over the runner-up: offered, not applied.
    case unsure(String)
    /// The word as typed scored best ("ui", a name): leave it.
    case keep

    /// Natural-log margin the winner needs over the runner-up (the typed word included) to be applied.
    public static let defaultMargin: Float = 2.0

    /// `scores[0]` is the word as typed, `scores[i]` (i ≥ 1) is `candidates[i - 1]`.
    public static func decide(candidates: [String], scores: [Float], margin: Float = defaultMargin) -> TypoChoice {
        guard scores.count == candidates.count + 1, scores.count >= 2 else { return .keep }
        let order = scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
        let best = order[0]
        guard best != 0, scores[best].isFinite else { return .keep }
        let runnerUp = scores[order[1]]
        let pick = candidates[best - 1]
        return scores[best] - runnerUp >= margin ? .fix(pick) : .unsure(pick)
    }
}
