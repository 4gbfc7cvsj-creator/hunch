import Foundation
import HunchCore

/// Cuts a suggestion back when per-token confidence drops partway through it, so a good start
/// isn't shown with a bad tail ("booked until the fall" instead of "booked until the fall, and I
/// wouldn't"). Pure.
///
/// - **Drop:** the first token where the mean log-prob of `window` tokens (it and the ones after it;
///   fewer at the end) is below `dropLogProb`.
/// - **Cut:** the last clause end before the drop: after a sentence end (. ! ? … 。 ！ ？, with any
///   closing quote or bracket), or before a pause mark (, ; : ， 、 ； ：). ASCII marks count only
///   when whitespace follows ("3.5", "1,000" are not clause ends). If no clause end leaves enough
///   words, the last whole word before the drop: a space, or a boundary next to a CJK character
///   (Chinese and Japanese have no spaces; a cut never splits a character). A whole-word cut never
///   ends on a word that needs what follows it ("into a", "and the": `danglingWords`).
/// - **Minimum:** the kept text must have at least `minWords` words (`TextRules.wordCount`, so 2
///   words is 4+ Han characters); otherwise nothing is trimmed and the confidence floor decides.
public enum ConfidenceTrim {
    public struct Result: Equatable, Sendable {
        /// The kept text (trailing whitespace removed).
        public var text: String
        /// Spans of the tokens that start inside the kept text.
        public var spans: [TokenSpan]
        public var meanLogProb: Float
        public var totalLogProb: Float
    }

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let pauses: Set<Character> = [",", ";", ":", "，", "、", "；", "："]
    /// English words a whole-word cut may not end on: articles, conjunctions, prepositions and
    /// possessives, which leave the suggestion hanging.
    static let danglingWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "to", "of", "for", "in", "on", "at", "by", "with",
        "from", "into", "onto", "about", "as", "than", "that", "if", "my", "your", "our", "their", "his", "her",
        "its", "this", "these", "those",
    ]

    /// Index of the first token that starts a drop, or nil.
    public static func dropIndex(_ spans: [TokenSpan], dropLogProb: Float, window: Int) -> Int? {
        let w = max(1, window)
        for i in spans.indices {
            let slice = spans[i..<min(spans.count, i + w)]
            let mean = slice.reduce(0) { $0 + $1.logProb } / Float(slice.count)
            if mean < dropLogProb { return i }
        }
        return nil
    }

    /// The trimmed suggestion, or nil when nothing is cut. `text` is the candidate's visible text;
    /// `spans` give each visible token's byte count (in order, from the start of `text`).
    public static func trim(text: String, spans: [TokenSpan], dropLogProb: Float, window: Int,
                            minWords: Int) -> Result? {
        guard let drop = dropIndex(spans, dropLogProb: dropLogProb, window: window) else { return nil }
        let bytes = Array(text.utf8)
        var dropByte = spans[..<drop].reduce(0) { $0 + $1.byteCount }
        guard dropByte < bytes.count else { return nil }
        // Never inside a character: back up to the start of the character holding the drop.
        while dropByte > 0, bytes[dropByte] & 0xC0 == 0x80 { dropByte -= 1 }
        guard let cut = cutPoint(bytes: bytes, before: dropByte, minWords: max(1, minWords)) else { return nil }
        let kept = String(decoding: bytes[..<cut], as: UTF8.self)
        var keptSpans: [TokenSpan] = []
        var offset = 0
        for span in spans where offset < cut {
            keptSpans.append(span)
            offset += span.byteCount
        }
        guard !keptSpans.isEmpty else { return nil }
        let total = keptSpans.reduce(0) { $0 + $1.logProb }
        return Result(text: kept, spans: keptSpans, meanLogProb: total / Float(keptSpans.count), totalLogProb: total)
    }

    /// What `trim` found, for the diagnostic console: the token where the drop started, the windowed
    /// average there, and whether the cut fell on a clause end. `kept` is the text `trim` returned.
    /// Observation only; `trim` does not call it.
    public static func explain(untrimmed: String, kept: String, spans: [TokenSpan], dropLogProb: Float,
                               window: Int) -> ConfidenceTrimFacts? {
        guard let drop = dropIndex(spans, dropLogProb: dropLogProb, window: window) else { return nil }
        let w = max(1, window)
        let slice = spans[drop..<min(spans.count, drop + w)]
        let mean = slice.reduce(0) { $0 + $1.logProb } / Float(slice.count)
        let bytes = Array(untrimmed.utf8)
        let dropByte = min(spans[..<drop].reduce(0) { $0 + $1.byteCount }, bytes.count)
        let tokenEnd = min(dropByte + spans[drop].byteCount, bytes.count)
        let dropText = String(decoding: bytes[dropByte..<tokenEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Clause end: the kept text ends with a sentence end (and its closing quotes or brackets), or
        // the text right after it starts with a pause mark.
        var trailing = Substring(kept)
        while let last = trailing.last, TextRules.closers.contains(last) { trailing = trailing.dropLast() }
        let afterKept = String(decoding: bytes[min(kept.utf8.count, bytes.count)...], as: UTF8.self)
        let endsSentence = trailing.last.map { sentenceEnds.contains($0) } ?? false
        let beforePause = afterKept.first.map { pauses.contains($0) } ?? false
        return ConfidenceTrimFacts(dropText: dropText, windowedMean: mean, limit: dropLogProb, window: w,
                                   atClauseEnd: endsSentence || beforePause)
    }

    /// Byte offset to cut at (exclusive, trailing whitespace dropped), at or before `limit`.
    static func cutPoint(bytes: [UInt8], before limit: Int, minWords: Int) -> Int? {
        let text = String(decoding: bytes, as: UTF8.self)
        // Characters with their byte offsets.
        var chars: [(char: Character, start: Int, end: Int)] = []
        var offset = 0
        for c in text {
            let n = c.utf8.count
            chars.append((c, offset, offset + n))
            offset += n
        }
        func isSpace(_ c: Character) -> Bool { c.isWhitespace }
        func isCJK(_ c: Character) -> Bool { c.unicodeScalars.first.map(TextRules.isCJK) ?? false }
        func ascii(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { $0.isASCII } }
        func followedBySpace(_ i: Int) -> Bool { i + 1 >= chars.count || isSpace(chars[i + 1].char) }
        /// True when the period at `index` closes an abbreviation or an initial ("Dr.", "e.g.",
        /// "J."), which doesn't end a clause (same rule as `TextRules.sentenceState`).
        func endsAbbreviation(before index: Int) -> Bool {
            var word = ""
            var j = index - 1
            while j >= 0, !isSpace(chars[j].char), !"([{\"'\u{201C}\u{2018}".contains(chars[j].char) {
                word = String(chars[j].char) + word
                j -= 1
            }
            let lower = word.lowercased()
            return TextRules.abbreviations.contains(lower) || (word.count == 1 && word.first?.isLetter == true)
        }
        /// End of the text before `byte` with trailing whitespace removed, if it has enough words.
        func accept(_ byte: Int) -> Int? {
            var end = byte
            while end > 0, let last = chars.last(where: { $0.end == end }), isSpace(last.char) { end = last.start }
            guard end > 0 else { return nil }
            let kept = String(decoding: bytes[..<end], as: UTF8.self)
            return TextRules.wordCount(kept) >= minWords ? end : nil
        }

        // Clause ends, latest first.
        var clauseCuts: [Int] = []
        for (i, item) in chars.enumerated() where item.end <= limit {
            if sentenceEnds.contains(item.char) {
                // Keep closing quotes or brackets right after the sentence end.
                var last = i
                while last + 1 < chars.count, chars[last + 1].end <= limit,
                      TextRules.closers.contains(chars[last + 1].char) { last += 1 }
                if ascii(item.char), !followedBySpace(last) { continue }
                if item.char == ".", endsAbbreviation(before: i) { continue }
                clauseCuts.append(chars[last].end)
            } else if pauses.contains(item.char), !ascii(item.char) || followedBySpace(i) {
                clauseCuts.append(item.start)
            }
        }
        for cut in clauseCuts.reversed() { if let end = accept(cut) { return end } }

        // Whole words: a boundary at or before the drop, not right after a word that needs what
        // follows it ("into a", "and the").
        func dangles(_ end: Int) -> Bool {
            let kept = String(decoding: bytes[..<end], as: UTF8.self)
            guard let last = kept.split(whereSeparator: { $0.isWhitespace }).last else { return false }
            return danglingWords.contains(last.lowercased())
        }
        var wordCuts: [Int] = []
        for (i, item) in chars.enumerated() where item.start <= limit && item.start > 0 {
            let previous = chars[i - 1].char
            if isSpace(item.char) || isCJK(item.char) || isCJK(previous) { wordCuts.append(item.start) }
        }
        for cut in wordCuts.reversed() { if let end = accept(cut), !dangles(end) { return end } }
        return nil
    }
}
