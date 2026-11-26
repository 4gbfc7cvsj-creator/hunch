import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private let v = FakeVocabulary.standard

private func run(_ session: FakeSession, required: String = "", config: DecodeConfig = DecodeConfig(),
                 partials: UnsafeMutablePointer<[String]>? = nil) throws -> Candidate {
    var seen: [String] = []
    let results = try GreedyConstrainedSearch().search(in: session, requiredPrefix: Array(required.utf8),
                                                       config: config) { seen.append($0.text) }
    partials?.pointee = seen
    return try #require(results.first)
}

private func cfg(minWords: Int = 1, maxWords: Int = 10, maxTokens: Int = 24, comma: Bool = false,
                 newline: Bool = false, floor: Float = -10) -> DecodeConfig {
    DecodeConfig(minWords: minWords, maxWords: maxWords, maxTokens: maxTokens, minMeanLogProb: floor,
                 stopAtComma: comma, allowNewline: newline)
}

@Suite struct RequiredPrefixTests {
    @Test func tokenCrossingThePrefixIsChosenAndPrefixStripped() throws {
        let session = FakeSession(script: makeScript([
            "": [(" banana", -0.1), (" apple", -0.5), (" a", -1.0)],
            " apple": [(" is", -0.2)],
            " apple is": [(" red", -0.3)],
        ]))
        let c = try run(session, required: " a", config: cfg())
        #expect(c.text == "pple is red")
        #expect(c.tokens == [v.id(" apple"), v.id(" is"), v.id(" red")])
        #expect(c.stop == .endOfGeneration)
        #expect(session.history == c.tokens)
        // " apple" scored conditionally on the admissible set (" apple" vs " a", the rest ~ -30).
        let conditional: Float = -0.5 - log(exp(-0.5) + exp(-1.0))
        #expect(abs(c.totalLogProb - (conditional - 0.2 - 0.3)) < 0.01)
        #expect(abs(c.meanLogProb - c.totalLogProb / 3) < 0.0001)
    }

    @Test func exactPrefixTokenThenContinuation() throws {
        let session = FakeSession(script: makeScript([
            "": [(" a", -0.1), (" apple", -3)],
            " a": [("pple", -0.2), (" banana", -0.1)],
            " apple": [(" is", -0.4)],
        ]))
        let c = try run(session, required: " a", config: cfg())
        // After " a" the prefix is satisfied, so the free argmax " banana" wins.
        #expect(c.text == " banana")
        #expect(c.tokens == [v.id(" a"), v.id(" banana")])
        // The forced " a" is excluded from the statistics.
        #expect(abs(c.meanLogProb - -0.1) < 0.0001)
        #expect(abs(c.totalLogProb - -0.1) < 0.0001)
    }

    @Test func requiredSpaceThenWord() throws {
        let session = FakeSession(script: makeScript([
            "": [(" ", -2), (" a", -0.3), ("pple", -0.1)],
            " a": [("pple", -0.1)],
        ]))
        let c = try run(session, required: " ", config: cfg())
        #expect(c.text == "apple")
    }

    @Test func unsatisfiablePrefixReturnsNothing() throws {
        let session = FakeSession(script: [:])
        let results = try GreedyConstrainedSearch().search(in: session, requiredPrefix: Array(" xq".utf8),
                                                           config: cfg()) { _ in }
        #expect(results.isEmpty)
    }

    @Test func emptyCandidateWhenPrefixOnlyThenEOG() throws {
        let session = FakeSession(script: makeScript(["": [(" a", -0.1)]]))
        let c = try run(session, required: " a", config: cfg())
        #expect(c.text == "")
        #expect(c.stop == .endOfGeneration)
        #expect(c.meanLogProb == 0)
    }
}

@Suite struct MaskingTests {
    @Test func controlUnusedByteFallbackAndEmptyTokensAreMasked() throws {
        var script = makeScript(["": [(" ok", -2)]])
        script[""]![v.id("<|turn>")] = -0.01
        script[""]![TokenID(2)] = -0.02   // <unused0>
        script[""]![TokenID(3)] = -0.03   // byte fallback 0xE4
        script[""]![TokenID(5)] = -0.04   // empty token
        let c = try run(FakeSession(script: script), config: cfg())
        #expect(c.text == " ok")
    }

    @Test func eogMeansStop() throws {
        let c = try run(FakeSession(script: makeScript(["": [("<eos>", -0.1), (" ok", -1)]])), config: cfg())
        #expect(c.text == "")
        #expect(c.tokens.isEmpty)
        #expect(c.stop == .endOfGeneration)
    }

    @Test func holdEndContinuesBelowMinWordsThenStops() throws {
        let script = makeScript(["": [(" ok", -0.1)], " ok": [("<eos>", -0.1), ("\n", -0.2), (" is", -1)],
                                 " ok is": [("<eos>", -0.1), (" red", -2)]])
        var config = cfg(minWords: 2)
        config.holdEndBelowMinWords = true
        let held = try run(FakeSession(script: script), config: config)
        #expect(held.text == " ok is")
        #expect(held.stop == .endOfGeneration)
        let plain = try run(FakeSession(script: script), config: cfg(minWords: 2))
        #expect(plain.text == " ok")
    }

    @Test func holdEndSkipsCJKText() throws {
        let script = makeScript(["": [("好", -0.1)], "好": [("<eos>", -0.1), ("好", -0.5)]])
        var config = cfg(minWords: 3)
        config.holdEndBelowMinWords = true
        let c = try run(FakeSession(script: script), config: config)
        #expect(c.text == "好")
        #expect(c.stop == .endOfGeneration)
    }

    @Test func holdEndFallsBackWhenTheContinuationFailsTheFloor() throws {
        let script = makeScript(["": [(" ok", -0.1)], " ok": [("<eos>", -0.1), (" one", -9)],
                                 " ok one": [(" two", -9)]])
        var config = cfg(minWords: 3, floor: -2)
        config.holdEndBelowMinWords = true
        config.trimEnabled = false
        let c = try run(FakeSession(script: script), config: config)
        #expect(c.text == " ok")
        #expect(c.stop == .endOfGeneration)
    }

    @Test func holdEndFallsBackWhenTheAddedTextIsUnsure() throws {
        let script = makeScript(["": [(" ok", -0.1)], " ok": [("<eos>", -0.1), (" one", -1.5)],
                                 " ok one": [(" two", -1.5)]])
        var config = cfg(minWords: 3)
        config.holdEndBelowMinWords = true
        config.trimEnabled = false
        #expect(try run(FakeSession(script: script), config: config).text == " ok")
        config.holdTailMinLogProb = -2
        #expect(try run(FakeSession(script: script), config: config).text == " ok one two")
    }

    @Test func newlineStopsWhenNotAllowed() throws {
        let script = makeScript(["": [(" ok", -0.1)], " ok": [("\n", -0.1), (" two", -1)]])
        let c = try run(FakeSession(script: script), config: cfg())
        #expect(c.text == " ok")
        #expect(c.stop == .newline)
    }

    @Test func newlineEmittedWhenAllowed() throws {
        let script = makeScript(["": [(" ok", -0.1)], " ok": [("\n", -0.1)], " ok\n": [(" two", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(newline: true))
        #expect(c.text == " ok\n two")
    }
}

@Suite struct StopRuleTests {
    @Test func wordBudgetStopsBeforeTheExtraWord() throws {
        let script = makeScript(["": [(" one", -0.1)], " one": [(" two", -0.1)], " one two": [(" three", -0.1)]])
        let session = FakeSession(script: script)
        let c = try run(session, config: cfg(maxWords: 2))
        #expect(c.text == " one two")
        #expect(c.stop == .wordBudget)
        #expect(session.history == [v.id(" one"), v.id(" two")])
    }

    @Test func wordBudgetCountsTheCompletedPartialWord() throws {
        let script = makeScript(["": [(" apple", -0.1)], " apple": [(" is", -0.1)], " apple is": [(" red", -0.1)]])
        let c = try run(FakeSession(script: script), required: " a", config: cfg(maxWords: 2))
        #expect(c.text == "pple is")
        #expect(c.stop == .wordBudget)
    }

    @Test func sentenceEndAfterMinWords() throws {
        let script = makeScript(["": [(" It", -0.1)], " It": [(" works", -0.1)], " It works": [(".", -0.1)],
                                 " It works.": [(" Then", -0.1)], " It works. Then": [(" ok", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(minWords: 2))
        #expect(c.text == " It works.")
        #expect(c.stop == .sentenceEnd)
    }

    @Test func sentenceEndIgnoredBelowMinWords() throws {
        let script = makeScript(["": [(" It", -0.1)], " It": [(" works", -0.1)], " It works": [(".", -0.1)],
                                 " It works.": [(" Then", -0.1)], " It works. Then": [(" ok", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(minWords: 3))
        #expect(c.text == " It works. Then ok")
        #expect(c.stop == .endOfGeneration)
    }

    @Test func sentenceEndThenEOG() throws {
        let script = makeScript(["": [(" It", -0.1)], " It": [(" works", -0.1)], " It works": [("!", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(minWords: 1))
        #expect(c.text == " It works!")
        #expect(c.stop == .sentenceEnd)
    }

    @Test func decimalsDoNotEndSentences() throws {
        let script = makeScript(["": [(" costs", -0.1)], " costs": [(" 3", -0.1)], " costs 3": [(".", -0.1)],
                                 " costs 3.": [("14", -0.1)], " costs 3.14": [(" ok", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(minWords: 1))
        #expect(c.text == " costs 3.14 ok")
    }

    @Test func abbreviationsDoNotEndSentences() throws {
        let script = makeScript(["": [(" Mr", -0.1)], " Mr": [(".", -0.1)], " Mr.": [(" Smith", -0.1)],
                                 " Mr. Smith": [(" e", -0.1)], " Mr. Smith e": [(".", -0.1)], " Mr. Smith e.": [("g", -0.1)],
                                 " Mr. Smith e.g": [(".", -0.1)], " Mr. Smith e.g.": [(" ok", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(minWords: 1))
        #expect(c.text == " Mr. Smith e.g. ok")
    }

    @Test func sentenceStopCanBeDisabled() throws {
        let script = makeScript(["": [(" It", -0.1)], " It": [(" works", -0.1)], " It works": [(".", -0.1)],
                                 " It works.": [(" Then", -0.1)]])
        var config = cfg(minWords: 1)
        config.stopAtSentenceEnd = false
        let c = try run(FakeSession(script: script), config: config)
        #expect(c.text == " It works. Then")
    }

    @Test func chineseFullStopIsDefinite() throws {
        let session = FakeSession(script: [:])
        session.byStep = [[v.id("好"): -0.1], [v.id("的"): -0.1], [v.id("。"): -0.1], [v.id("我"): -0.1]]
        let c = try run(session, config: cfg(minWords: 1))
        #expect(c.text == "好的。")
        #expect(c.stop == .sentenceEnd)
    }

    @Test func commaStopWhenEnabled() throws {
        let script = makeScript(["": [(" Thanks", -0.1)], " Thanks": [(",", -0.1)], " Thanks,": [(" Sam", -0.1)]])
        let on = try run(FakeSession(script: script), config: cfg(comma: true))
        #expect(on.text == " Thanks,")
        #expect(on.stop == .comma)
        let off = try run(FakeSession(script: script), config: cfg(comma: false))
        #expect(off.text == " Thanks, Sam")
    }

    @Test func tokenCap() throws {
        let script = makeScript(["": [(" ok", -0.1)], " ok": [(" ok", -0.1)], " ok ok": [(" ok", -0.1)]])
        let c = try run(FakeSession(script: script), config: cfg(maxTokens: 2))
        #expect(c.text == " ok ok")
        #expect(c.stop == .tokenCap)
    }

    @Test func lowConfidenceIsFlagged() throws {
        let script = makeScript(["": [(" zz", -4)], " zz": [(" zz", -4)]])
        let c = try run(FakeSession(script: script), config: cfg(maxWords: 2, floor: -2.5))
        #expect(c.text == " zz zz")
        #expect(c.stop == .lowConfidence)
        #expect(c.meanLogProb < -2.5)
    }

    @Test func chineseWordBudgetUsesCharactersOverThree() throws {
        let session = FakeSession(script: [:])
        session.byStep = Array(repeating: [v.id("好"): -0.1], count: 10)
        let c = try run(session, config: cfg(maxWords: 2))
        #expect(c.text == "好好好好好好")
        #expect(c.stop == .wordBudget)
    }
}

@Suite struct UTF8AndStreamingTests {
    @Test func chineseCharacterSplitAcrossTokens() throws {
        let session = FakeSession(script: [:])
        session.byStep = [[TokenID(6): -0.1], [TokenID(7): -0.1], [v.id("们"): -0.1]]
        var partials: [String] = []
        let c = try run(session, config: cfg(), partials: &partials)
        #expect(c.text == "我们")
        #expect(partials == ["我", "我们"])
        #expect(!c.text.contains("\u{FFFD}"))
    }

    @Test func emojiSplitAcrossTokens() throws {
        let session = FakeSession(script: [:])
        session.byStep = [[v.id(" ok"): -0.1], [TokenID(8): -0.1], [TokenID(9): -0.1]]
        var partials: [String] = []
        let c = try run(session, config: cfg(), partials: &partials)
        #expect(c.text == " ok\u{1F600}")
        #expect(partials == [" ok", " ok\u{1F600}"])
    }

    @Test func partialsAreMonotonicExtensions() throws {
        let script = makeScript(["": [(" one", -0.1)], " one": [(" two", -0.1)], " one two": [(" three", -0.1)]])
        var partials: [String] = []
        let c = try run(FakeSession(script: script), config: cfg(), partials: &partials)
        #expect(partials == [" one", " one two", " one two three"])
        for (a, b) in zip(partials, partials.dropFirst()) { #expect(b.hasPrefix(a)) }
        #expect(partials.last == c.text)
    }

    @Test func accumulatorHoldsIncompleteSequences() {
        var acc = UTF8Accumulator()
        acc.append(contentsOf: [0x41, 0xE6])
        #expect(acc.text == "A")
        acc.append(contentsOf: [0x88])
        #expect(acc.text == "A")
        acc.append(contentsOf: [0x91])
        #expect(acc.text == "A我")
        acc.append(contentsOf: [0xFF])
        #expect(acc.text == "A我\u{FFFD}")
    }

    @Test func cancellationThrows() throws {
        let script = makeScript(["": [(" one", -0.1)], " one": [(" two", -0.1)], " one two": [(" three", -0.1)]])
        let session = FakeSession(script: script)
        session.cancelAfterSteps = 1
        #expect(throws: CancellationError.self) {
            _ = try GreedyConstrainedSearch().search(in: session, requiredPrefix: [], config: cfg()) { _ in }
        }
        #expect(session.steps == 1)
    }
}

@Suite struct TextRuleTests {
    @Test func wordCounts() {
        #expect(TextRules.wordCount("") == 0)
        #expect(TextRules.wordCount(" one two") == 2)
        #expect(TextRules.wordCount("don't well-known") == 2)
        #expect(TextRules.wordCount("Hi, there!") == 2)
        #expect(TextRules.wordCount("\u{1F600}") == 0)
        #expect(TextRules.wordCount("我") == 1)
        #expect(TextRules.wordCount("我们今天") == 2)
        #expect(TextRules.wordCount("我用 iPhone") == 2)
    }

    @Test func sentenceStates() {
        #expect(TextRules.sentenceState("It works.") == .tentative)
        #expect(TextRules.sentenceState("Really?\"") == .tentative)
        #expect(TextRules.sentenceState("Ask Dr.") == .none)
        #expect(TextRules.sentenceState("e.g.") == .none)
        #expect(TextRules.sentenceState("Plan A.") == .none)
        #expect(TextRules.sentenceState("好的。") == .definite)
        #expect(TextRules.sentenceState("Hello,") == .none)
    }
}
