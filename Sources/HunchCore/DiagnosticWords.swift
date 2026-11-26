import Foundation

/// Words of a generated text with a confidence each, and where the text was cut. Pure.
public enum DiagnosticWords {
    /// The rule behind every percentage the console shows.
    public static let ruleDescription =
        "A word's percentage is exp of the mean log-probability of the tokens that make up the word "
        + "(a token that spans several words counts for each of them). Chinese and Japanese characters count as one word each."

    /// Byte ranges of the words of `text`: a run of non-space characters with the whitespace before it,
    /// or one Chinese/Japanese character (CJK punctuation after it joins it). Trailing whitespace
    /// belongs to no word.
    public static func ranges(of text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        var wordStart = 0
        var open = false      // inside a word's content
        var lastHan = false   // the open word is one Han character (so far)
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if open { ranges.append(wordStart..<offset); wordStart = offset; open = false }
                lastHan = false
            } else if isHan(scalar) {
                if open { ranges.append(wordStart..<offset); wordStart = offset }
                open = true
                lastHan = true
            } else if isCJKPunctuation(scalar) {
                open = true
            } else {
                if open && lastHan { ranges.append(wordStart..<offset); wordStart = offset }
                open = true
                lastHan = false
            }
            offset += utf8Length(scalar)
        }
        if open { ranges.append(wordStart..<offset) }
        return ranges
    }

    public static func wordCount(_ text: String) -> Int { ranges(of: text).count }

    /// `text` split into words, each with the probability from its tokens (see `ruleDescription`).
    /// `tokens` are the visible tokens in order (`TokenSpan` bytes and log-probs). A word that no token
    /// covers has no probability.
    public static func group(text: String, tokens: [DiagnosticToken]) -> [DiagnosticWord] {
        let bytes = Array(text.utf8)
        let ranges = ranges(of: text)
        // Where each word's own content starts (after its leading whitespace).
        let contentStarts = ranges.map { range -> Int in
            var i = range.lowerBound
            while i < range.upperBound, isSpaceByte(bytes[i]) { i += 1 }
            return i
        }
        var logs = [[Float]](repeating: [], count: ranges.count)
        var cursor = 0
        for token in tokens where token.byteCount > 0 {
            let start = cursor
            let end = min(cursor + token.byteCount, bytes.count)
            cursor += token.byteCount
            guard start < end else { continue }
            for index in ranges.indices where contentStarts[index] < end && ranges[index].upperBound > start {
                logs[index].append(token.logProb)
            }
        }
        return ranges.enumerated().map { index, range in
            let values = logs[index]
            let probability: Float? = values.isEmpty
                ? nil : Float(exp(Double(values.reduce(0, +)) / Double(values.count)))
            return DiagnosticWord(text: String(decoding: bytes[range], as: UTF8.self), probability: probability,
                                  tokenCount: values.count, byteRange: range)
        }
    }

    /// The generated output laid out for display.
    /// - Parameters:
    ///   - generated: everything the model wrote (before any cut).
    ///   - tokens: per-token scores of `generated` (empty = not scored, the text is shown plain).
    ///   - trim: the confidence trim's kept text and what it found, when it cut.
    ///   - postCuts: post-processing steps that shortened the text, in the order they ran.
    ///   - shown: the text that passed post-processing (nil when it was suppressed).
    public static func output(generated: String, tokens: [DiagnosticToken], trim: (kept: String, facts: ConfidenceTrimFacts)?,
                              postCuts: [PostCutStep], shown: String?, stopText: String?, meanLogProb: Float?,
                              alternatives: [String] = []) -> DiagnosticOutput {
        let words = tokens.isEmpty ? [] : group(text: generated, tokens: tokens)
        var cuts: [DiagnosticCutMark] = []
        var keptWords = words.count
        if tokens.isEmpty {
            keptWords = wordCount(generated)
        }
        if let trim {
            // A word the cut only clips (a trailing comma) still counts as kept.
            let keptBytes = trim.kept.utf8.count
            let before = tokens.isEmpty ? wordCount(trim.kept) : words.filter { $0.byteRange.lowerBound < keptBytes }.count
            if before < keptWords {
                cuts.append(DiagnosticCutMark(afterWords: before, reason: .confidenceTrim(trim.facts)))
                keptWords = before
            }
        }
        // The last step that shortened the text decides where the shown text ends; earlier ones cut
        // further on.
        if let shown, let last = postCuts.last {
            let shownWords = min(wordCount(shown), keptWords)
            if shownWords < keptWords {
                cuts.append(DiagnosticCutMark(afterWords: shownWords, reason: .postProcessing(last)))
            }
        }
        cuts.sort { $0.afterWords < $1.afterWords }
        return DiagnosticOutput(text: generated, words: words, cuts: cuts, stopText: stopText,
                                generatedTokens: tokens.count, meanLogProb: meanLogProb, alternatives: alternatives)
    }

    static func isSpaceByte(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    static func utf8Length(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case ..<0x80: 1
        case ..<0x800: 2
        case ..<0x10000: 3
        default: 4
        }
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3040...0x30FF: true
        default: false
        }
    }

    static func isCJKPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0xFF00...0xFF0F, 0xFF1A...0xFF20: true
        default: false
        }
    }
}

/// One generated token's visible bytes and log-probability (the decoder's `TokenSpan`).
public struct DiagnosticToken: Sendable, Equatable {
    public var byteCount: Int
    public var logProb: Float
    public init(byteCount: Int, logProb: Float) {
        self.byteCount = byteCount
        self.logProb = logProb
    }
}
