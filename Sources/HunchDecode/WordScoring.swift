import Foundation
import HunchCore

/// Bytes a chosen token added to the candidate's output and its log-prob. Forced tokens that add no
/// text are not recorded. A token crossing the end of the required prefix records only the part
/// the user sees (bytes after the prefix) and its log-prob renormalized over the admissible tokens,
/// i.e. log P(token | it starts with the required bytes). Other tokens record their raw log-prob.
public struct TokenSpan: Sendable, Equatable {
    public var byteCount: Int
    public var logProb: Float
    public init(byteCount: Int, logProb: Float) {
        self.byteCount = byteCount
        self.logProb = logProb
    }
}

/// A search result with the per-token raw scores needed for per-word scores.
public struct ScoredCandidate: Sendable, Equatable {
    public var candidate: Candidate
    public var spans: [TokenSpan]
    /// The text before the confidence trim cut it back (nil when it wasn't trimmed).
    public var untrimmedText: String?
    public init(candidate: Candidate, spans: [TokenSpan], untrimmedText: String? = nil) {
        self.candidate = candidate
        self.spans = spans
        self.untrimmedText = untrimmedText
    }
}

/// A search that accepts a learned bias and reports per-token scores. `GreedyConstrainedSearch`
/// conforms; other searches fall back to `CompletionSearching` (no bias, no word scores).
public protocol BiasedCompletionSearching: CompletionSearching {
    func searchScored(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                      bias: LearnedBias, onPartial: (Candidate) -> Void) throws -> [ScoredCandidate]
}

/// Per-word raw model scores for the text that is finally shown. Pure.
public enum WordScoring {
    /// Words of `shown` (each with its leading whitespace) with the summed natural-log probability
    /// of their tokens under the raw model (no learned bias).
    ///
    /// - A token spanning several words splits its score by non-whitespace bytes.
    /// - For a healed first word (required prefix " hea", token " hearing"), only the visible
    ///   completion ("ring") exists as a word, scored with the token's log-prob renormalized over
    ///   tokens that start with the prefix (see `TokenSpan`), not the log-prob of the whole token.
    /// - `shown` is aligned with the candidate's own words (leading whitespace ignored when
    ///   comparing, e.g. a trimmed leading space). Post-processing may trim words from the end or
    ///   the start; at the first word that no longer matches exactly, the remaining shown words are
    ///   dropped rather than guessed.
    public static func scores(shown: String, for scored: ScoredCandidate) -> [WordScore] {
        let source = Array(scored.candidate.text.utf8)
        let target = Array(shown.utf8)
        let sourceWords = wordRanges(source)
        let targetWords = wordRanges(target)
        guard !sourceWords.isEmpty, !targetWords.isEmpty else { return [] }

        var sums = [Float](repeating: 0, count: sourceWords.count)
        var cursor = 0
        for span in scored.spans where span.byteCount > 0 {
            let start = cursor
            let end = min(cursor + span.byteCount, source.count)
            cursor += span.byteCount
            guard start < end else { continue }
            var weights: [(word: Int, weight: Int)] = []
            var total = 0
            for (index, range) in sourceWords.enumerated() where range.lowerBound < end && range.upperBound > start {
                let lo = max(start, range.lowerBound), hi = min(end, range.upperBound)
                let weight = source[lo..<hi].reduce(0) { $0 + (isSpace($1) ? 0 : 1) }
                weights.append((index, weight))
                total += weight
            }
            if total == 0 {
                if let first = weights.first { sums[first.word] += span.logProb }
            } else {
                for item in weights where item.weight > 0 {
                    sums[item.word] += span.logProb * Float(item.weight) / Float(total)
                }
            }
        }

        // Compare in a script-normalized form: post-processing may have converted the script
        // (simplified to traditional), and the words still correspond.
        func key(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
            let trimmed = bytes.drop { isSpace($0) }
            if trimmed.allSatisfy({ $0 < 0x80 }) { return Array(trimmed) }
            return Array(HanScript.simplified(String(decoding: trimmed, as: UTF8.self)).utf8)
        }
        let firstKey = key(target[targetWords[0]])
        guard let offset = sourceWords.firstIndex(where: { key(source[$0]) == firstKey }) else { return [] }
        var result: [WordScore] = []
        for (i, range) in targetWords.enumerated() {
            let j = offset + i
            guard j < sourceWords.count, key(source[sourceWords[j]]) == key(target[range]) else { break }
            result.append(WordScore(text: String(decoding: target[range], as: UTF8.self), logProb: sums[j]))
        }
        return result
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    /// Byte ranges of words: leading whitespace plus the following run of non-whitespace.
    /// Trailing whitespace belongs to no word.
    static func wordRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        var wordStart = 0
        while i < bytes.count {
            while i < bytes.count, isSpace(bytes[i]) { i += 1 }
            if i == bytes.count { break }
            while i < bytes.count, !isSpace(bytes[i]) { i += 1 }
            ranges.append(wordStart..<i)
            wordStart = i
        }
        return ranges
    }
}
