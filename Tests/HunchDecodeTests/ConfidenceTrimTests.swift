import Foundation
import HunchCore
import Testing
@testable import HunchDecode

/// Text and spans from (token text, log-prob) pairs.
private func tokens(_ pairs: [(String, Float)]) -> (text: String, spans: [TokenSpan]) {
    (pairs.map(\.0).joined(), pairs.map { TokenSpan(byteCount: $0.0.utf8.count, logProb: $0.1) })
}

private func trim(_ pairs: [(String, Float)], drop: Float = -3, window: Int = 1, minWords: Int = 2) -> String? {
    let (text, spans) = tokens(pairs)
    return ConfidenceTrim.trim(text: text, spans: spans, dropLogProb: drop, window: window, minWords: minWords)?.text
}

@Suite struct ConfidenceTrimTests {
    @Test func cutsAtTheLastClauseEndBeforeTheDrop() throws {
        let pairs: [(String, Float)] = [(" booked", -0.1), (" until", -0.2), (" the", -0.1), (" fall", -0.3), (",", -1),
                                        (" and", -4), (" I", -1), (" wouldn", -1), ("'t", -0.1)]
        let (text, spans) = tokens(pairs)
        let result = try #require(ConfidenceTrim.trim(text: text, spans: spans, dropLogProb: -3, window: 1, minWords: 2))
        #expect(result.text == " booked until the fall")
        #expect(result.spans.count == 4)
        #expect(abs(result.meanLogProb - (-0.7 / 4)) < 0.0001)
        #expect(abs(result.totalLogProb - -0.7) < 0.0001)
    }

    @Test func keepsASentenceEnd() {
        #expect(trim([(" it", -0.1), (" works", -0.2), (".", -0.3), (" Then", -5), (" we", -1)]) == " it works.")
        #expect(trim([(" it", -0.1), (" works", -0.2), (".\"", -0.3), (" Then", -5)]) == " it works.\"")
    }

    @Test func anAbbreviationOrInitialIsNotAClauseEnd() {
        // "Dr." and "J." don't end the clause: the cut falls back to a whole word instead.
        #expect(trim([(" talk", -0.1), (" to", -0.1), (" Dr", -0.2), (".", -0.1), (" Smith", -0.2), (" about", -0.2),
                      (" the", -0.1), (" plan", -5)]) == " talk to Dr. Smith")
        #expect(trim([(" ask", -0.1), (" J", -0.2), (".", -0.1), (" Smith", -0.2), (" now", -0.2), (" or", -5)])
            == " ask J. Smith now")
        #expect(trim([(" fruit", -0.1), (" e", -0.1), (".", -0.1), ("g", -0.1), (".", -0.1), (" apples", -0.2),
                      (" today", -5)]) == " fruit e.g. apples")
        // A real sentence end is still kept.
        #expect(trim([(" it", -0.1), (" works", -0.2), (".", -0.3), (" Then", -5), (" we", -1)]) == " it works.")
    }

    @Test func fallsBackToTheLastWholeWord() {
        #expect(trim([(" one", -0.1), (" two", -0.1), (" three", -0.2), (" fo", -5), ("ur", -0.1)]) == " one two three")
    }

    @Test func wholeWordCutDoesNotEndOnAFunctionWord() {
        #expect(trim([(" into", -0.1), (" a", -0.1), (" clean", -2), (" table", -0.1)]) == nil)
        #expect(trim([(" keep", -0.1), (" the", -0.1), (" price", -0.2), (" estimates", -4)]) == " keep the price")
        #expect(trim([(" send", -0.1), (" the", -0.1), (" report", -0.1), (" to", -0.2), (" Alex", -4)])
            == " send the report")
    }

    @Test func neverLeavesAHalfWord() {
        #expect(trim([(" one", -0.1), (" two", -0.1), (" thr", -0.2), ("ee", -5), (" four", -0.1)]) == " one two")
    }

    @Test func respectsTheWordMinimum() {
        #expect(trim([(" one", -0.1), (" two", -5), (" three", -0.1)]) == nil)
        #expect(trim([(" one", -0.1), (" two", -5), (" three", -0.1)], minWords: 1) == " one")
        // The clause end leaves one word; the whole-word cut leaves enough.
        #expect(trim([(" Sure", -0.1), (",", -0.1), (" I", -0.1), (" can", -0.2), (" zz", -6)]) == " Sure, I can")
    }

    @Test func noDropNoTrim() {
        #expect(trim([(" one", -0.1), (" two", -1), (" three", -2.9)]) == nil)
    }

    @Test func windowAveragesTheDrop() {
        let pairs: [(String, Float)] = [(" one", -0.1), (" two", -0.1), (" three", -4), (" four", -0.1)]
        #expect(trim(pairs, window: 1) == " one two")
        #expect(trim(pairs, window: 2) == nil)   // (-4 - 0.1) / 2 = -2.05
        #expect(trim([(" one", -0.1), (" two", -0.1), (" three", -4), (" four", -2.5)], window: 2) == " one two")
    }

    @Test func decimalsAndThousandsAreNotClauseEnds() {
        #expect(trim([(" it", -0.1), (" costs", -0.1), (" 3", -0.2), (".", -0.1), ("14", -5)]) == " it costs")
        #expect(trim([(" about", -0.1), (" 1", -0.1), (",", -0.1), ("000", -6)]) == nil)
    }

    @Test func traditionalChineseCutsAtClauseMarks() {
        #expect(trim([("謝謝", -0.1), ("你的", -0.2), ("幫忙", -0.2), ("。", -0.1), ("我們", -5), ("下次", -1)]) == "謝謝你的幫忙。")
        #expect(trim([("我們", -0.1), ("明天", -0.2), ("見面", -0.3), ("，", -0.2), ("然後", -5), ("吃飯", -1)]) == "我們明天見面")
        #expect(trim([("好的", -0.1), ("、", -0.1), ("謝謝", -0.2), ("你們", -0.2), ("的", -5)]) == "好的、謝謝你們")
    }

    @Test func chineseWithoutClauseMarkCutsAtACharacter() {
        // "好的，" is too short (one word); the cut falls back to the last character before the drop.
        #expect(trim([("好的", -0.1), ("，", -0.2), ("我們", -0.3), ("明天", -0.5), ("見", -5)]) == "好的，我們明天")
        #expect(trim([("我們", -0.1), ("見", -5)]) == nil)   // 3 characters: one word
    }

    @Test func neverCutsInsideACharacter() throws {
        // 我 split over two tokens; the drop is on its second half.
        let text = "今天天氣很好我"
        let head = "今天天氣很好".utf8.count
        let spans = [TokenSpan(byteCount: head, logProb: -0.2), TokenSpan(byteCount: 2, logProb: -0.5),
                     TokenSpan(byteCount: 1, logProb: -6)]
        let result = try #require(ConfidenceTrim.trim(text: text, spans: spans, dropLogProb: -3, window: 1, minWords: 2))
        #expect(result.text == "今天天氣很好")
        #expect(result.spans.count == 1)
    }

    @Test func dropOnTheFirstTokenKeepsNothing() {
        #expect(trim([(" zz", -6), (" one", -0.1), (" two", -0.1)]) == nil)
    }
}

@Suite struct ConfidenceTrimSearchTests {
    private let v = FakeVocabulary.standard

    private func session() -> FakeSession {
        FakeSession(script: makeScript([
            "": [(" one", -0.1)],
            " one": [(" two", -0.1)],
            " one two": [(",", -0.5)],
            " one two,": [(" three", -9)],
        ]))
    }

    private func config(trim: Bool) -> DecodeConfig {
        DecodeConfig(minWords: 1, maxWords: 10, minMeanLogProb: -2, trimEnabled: trim, trimDropLogProb: -3, trimWindow: 1)
    }

    @Test func trimmedBeforeTheFloor() throws {
        let off = try #require(GreedyConstrainedSearch().search(in: session(), requiredPrefix: [], config: config(trim: false)) { _ in }.first)
        #expect(off.text == " one two, three")
        #expect(off.stop == .lowConfidence)   // mean (-0.1 - 0.1 - 0.5 - 9) / 4 < -2

        let run = session()
        let scored = try GreedyConstrainedSearch().searchScored(in: run, requiredPrefix: [], config: config(trim: true),
                                                                bias: LearnedBias()) { _ in }
        let best = try #require(scored.first)
        #expect(best.candidate.text == " one two")
        #expect(best.candidate.stop == .confidenceTrim)
        #expect(abs(best.candidate.meanLogProb - -0.1) < 0.0001)
        #expect(best.untrimmedText == " one two, three")
        // The tokens stay the decoded path (what the KV cache holds).
        #expect(best.candidate.tokens == [v.id(" one"), v.id(" two"), v.id(","), v.id(" three")])
        #expect(run.history == best.candidate.tokens)
        // Word scores cover the kept words only.
        #expect(WordScoring.scores(shown: best.candidate.text, for: best).map(\.text) == [" one", " two"])
    }

    @Test func settingsWrittenBeforeTheTrimStillDecode() throws {
        let old = #"{"minWords":2,"maxWords":4,"maxTokens":24,"firstTokenFanout":1,"scoring":"sum","minMeanLogProb":-2.5,"#
            + #""stopAtSentenceEnd":true,"stopAtComma":false,"allowNewline":false}"#
        let decoded = try JSONDecoder().decode(DecodeConfig.self, from: Data(old.utf8))
        #expect(decoded.trimEnabled == DecodeConfig().trimEnabled)
        #expect(decoded.trimDropLogProb == DecodeConfig.defaultTrimDropLogProb)
        #expect(decoded.minMeanLogProb == -2.5)
        let round = try JSONDecoder().decode(DecodeConfig.self, from: JSONEncoder().encode(config(trim: true)))
        #expect(round == config(trim: true))
    }
}

@Suite struct ConfidenceTrimExplainTests {
    private func explain(_ pairs: [(String, Float)], drop: Float = -3, window: Int = 1, minWords: Int = 2)
        -> (kept: String?, facts: ConfidenceTrimFacts?) {
        let (text, spans) = tokens(pairs)
        let kept = ConfidenceTrim.trim(text: text, spans: spans, dropLogProb: drop, window: window, minWords: minWords)?.text
        guard let kept else { return (nil, nil) }
        return (kept, ConfidenceTrim.explain(untrimmed: text, kept: kept, spans: spans, dropLogProb: drop, window: window))
    }

    @Test func reportsTheDropTokenTheAverageAndAClauseEnd() throws {
        let pairs: [(String, Float)] = [(" booked", -0.1), (" until", -0.2), (" the", -0.1), (" fall", -0.3), (",", -1),
                                        (" and", -4), (" I", -1)]
        let result = explain(pairs)
        let facts = try #require(result.facts)
        #expect(result.kept == " booked until the fall")
        #expect(facts.dropText == "and")
        #expect(facts.windowedMean == -4)
        #expect(facts.limit == -3)
        #expect(facts.atClauseEnd)
    }

    @Test func aSentenceEndCountsAsAClauseEnd() throws {
        let result = explain([(" it", -0.1), (" works", -0.2), (".", -0.3), (" Then", -5), (" we", -1)])
        #expect(try #require(result.facts).atClauseEnd)
    }

    @Test func aWholeWordCutIsNotAClauseEnd() throws {
        let result = explain([(" one", -0.1), (" two", -0.1), (" three", -0.2), (" fo", -5), ("ur", -0.1)])
        let facts = try #require(result.facts)
        #expect(result.kept == " one two three")
        #expect(!facts.atClauseEnd)
        #expect(facts.dropText == "fo")
    }

    @Test func theWindowAveragesTheTokensFromTheDrop() throws {
        // Window 2: the drop is the first token whose two-token mean is below the limit.
        let result = explain([(" one", -0.1), (" two", -0.1), (" three", -0.2), (" four", -4), (" five", -4)], window: 2)
        let facts = try #require(result.facts)
        #expect(facts.window == 2)
        #expect(abs(facts.windowedMean - -4) < 0.001)
    }

    @Test func nilWhenNothingDrops() {
        let (text, spans) = tokens([(" fine", -0.1), (" text", -0.2)])
        #expect(ConfidenceTrim.explain(untrimmed: text, kept: text, spans: spans, dropLogProb: -3, window: 1) == nil)
    }
}
