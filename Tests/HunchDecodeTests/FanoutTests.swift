import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private let v = FakeVocabulary.standard

private func search(_ session: FakeSession, required: String, config: DecodeConfig,
                    partials: UnsafeMutablePointer<[String]>? = nil) throws -> [Candidate] {
    var seen: [String] = []
    let results = try GreedyConstrainedSearch().search(in: session, requiredPrefix: Array(required.utf8),
                                                       config: config) { seen.append($0.text) }
    partials?.pointee = seen
    return results
}

private func cfg(k: Int = 1, maxWords: Int = 10, scoring: ScoringRule = .sum, floor: Float = -10) -> DecodeConfig {
    DecodeConfig(minWords: 1, maxWords: maxWords, maxTokens: 24, firstTokenFanout: k, scoring: scoring,
                 minMeanLogProb: floor, wordStartMinFirstLogProb: nil, midWordMinMeanLogProb: nil)
}

/// "I am an": the prompt is "I am" and " an" is required. The model prefers " a" as a token, and
/// the old greedy path then had to force "n…" ("anote"). " an" is a complete word here.
private let iAmAn = makeScript([
    "": [(" a", -0.4), (" an", -2.0), (" another", -5.0), (" avid", -6.0)],
    " a": [("note", -1.0), (" apple", -1.5)],
    " an": [(" engineer", -0.3), (" apple", -2.0), ("note", -6.0)],
    " an engineer": [(".", -0.2)],
    " another": [(" apple", -0.5)],
    " an apple": [(".", -0.1)],
])

@Suite struct WordBoundaryDecisionTests {
    @Test func completeShortWordIsKept() throws {
        let session = FakeSession(script: iAmAn)
        let results = try search(session, required: " an", config: cfg())
        let best = try #require(results.first)
        #expect(best.text == " engineer.")
        #expect(best.tokens == [v.id(" an"), v.id(" engineer"), v.id(".")])
        // The winner ends up in the primary sequence for KV reuse.
        #expect(session.history == best.tokens)
        // Only the (forced) exact token is excluded from the statistics.
        #expect(abs(best.totalLogProb - (-0.3 - 0.2)) < 0.001)
        #expect(results.count == 1)
    }

    @Test func completeWordFollowedByNewWordIsKept() throws {
        // The model strongly prefers " an" + " apple" over any longer word.
        let script = makeScript([
            "": [(" a", -3.0), (" an", -0.3), (" another", -4.0)],
            " an": [(" apple", -0.2), ("note", -6.0)],
            " an apple": [(".", -0.1)],
        ])
        let best = try #require(try search(FakeSession(script: script), required: " an", config: cfg()).first)
        #expect(best.text == " apple.")
    }

    @Test func shortWordIsContinuedWhenTheModelWantsALongerWord() throws {
        // " another" is far likelier than "an" followed by anything: the word continues ("other").
        let script = makeScript([
            "": [(" a", -3.0), (" an", -2.5), (" another", -0.2)],
            " an": [(" apple", -2.0), ("note", -5.0)],
            " another": [(" apple", -0.3)],
            " another apple": [(".", -0.1)],
        ])
        let best = try #require(try search(FakeSession(script: script), required: " an", config: cfg()).first)
        #expect(best.text == "other apple.")
    }

    @Test func oldGreedyPathWouldHaveSplitTheWord() throws {
        // With one sequence and longer tokens present, the decision can't run: plain greedy.
        let session = FakeSession(script: iAmAn, parallel: 1)
        let best = try #require(try search(session, required: " an", config: cfg()).first)
        #expect(best.text == "ote")
        #expect(best.tokens == [v.id(" a"), v.id("note")])
    }

    @Test func partialWordStillCompletes() throws {
        // "Looking forward to hea" → prompt "...to", required " hea".
        let script = makeScript([
            "": [(" he", -1.0), (" hearing", -0.5), (" hea", -7.0)],
            " hea": [("ring", -0.2), (" apple", -3.0)],
            " hearing": [(" one", -0.2)],
            " hearing one": [(".", -0.1)],
        ])
        let session = FakeSession(script: script)
        var partials: [String] = []
        let best = try #require(try search(session, required: " hea", config: cfg(), partials: &partials).first)
        #expect(best.text == "ring one.")
        #expect(best.tokens.first == v.id(" hearing"))
        #expect(session.history == best.tokens)
        // " hearing" alone outweighs anything " hea" could lead to: no extra decode, no fork,
        // and the first word streams before the first step (like plain greedy).
        #expect(session.forks.isEmpty)
        #expect(session.decodedTokens == 3)
        #expect(partials.first == "ring")
    }

    @Test func shortcutNotTakenWhenTheExactTokenCouldWin() throws {
        // " another" is close to " an" but not above it: the exact token must still be checked.
        let script = makeScript([
            "": [(" an", -1.0), (" another", -1.2), (" avid", -9.0)],
            " an": [(" apple", -0.1)],
            " an apple": [(".", -0.1)],
        ])
        let session = FakeSession(script: script)
        let best = try #require(try search(session, required: " an", config: cfg()).first)
        #expect(!session.forks.isEmpty)
        #expect(best.text == " apple.")
    }

    @Test func manySmallContinuationsDoNotOutvoteTheTypedWord() throws {
        // Together the longer words outweigh " a" (≈ -0.9 vs -1.0), but no single one does.
        let script = makeScript([
            "": [(" a", -1.0), (" another", -2.0), (" avid", -2.0), (" apple", -2.0)],
            " a": [(" engineer", -0.2)],
        ])
        let best = try #require(try search(FakeSession(script: script), required: " a", config: cfg()).first)
        #expect(best.text == " engineer")
    }

    @Test func exactTokenThenWordCharacterCanContinue() throws {
        // No single longer token is likely, but " hea" + "ring" is.
        let script = makeScript([
            "": [(" he", -1.0), (" hea", -1.2), (" hearing", -9.0)],
            " hea": [("ring", -0.1), (" apple", -4.0)],
            " hearing": [(" one", -0.1)],
        ])
        let best = try #require(try search(FakeSession(script: script), required: " hea", config: cfg()).first)
        #expect(best.text == "ring one")
        #expect(best.tokens == [v.id(" hea"), v.id("ring"), v.id(" one")])
    }

    @Test func boundaryLongerTokenCountsAsComplete() throws {
        // " an," spells the word plus a comma: it votes for "complete" and can be the root.
        let script = makeScript([
            "": [(" a", -0.3), (" an,", -1.0), (" an", -4.0), (" another", -3.0)],
            " an,": [(" one", -0.1)],
            " an": [(" one", -0.5)],
            " an, one": [(".", -0.1)],
        ])
        let best = try #require(try search(FakeSession(script: script), required: " an", config: cfg()).first)
        #expect(best.text == ", one.")
        #expect(best.tokens.first == v.id(" an,"))
    }

    @Test func noLongerTokensDecodesOnPrimaryWithoutForking() throws {
        // Required " engineer": no longer token exists in the vocabulary.
        let script = makeScript([
            "": [(" engineer", -1.0)],
            " engineer": [("ring", -3.0), (".", -0.1)],
        ])
        let session = FakeSession(script: script, parallel: 1)
        let best = try #require(try search(session, required: " engineer", config: cfg()).first)
        #expect(best.text == ".")
        #expect(session.forks.isEmpty)
        #expect(session.history == best.tokens)
    }

    @Test func notAppliedAfterTrailingSpace() throws {
        let script = makeScript(["": [(" a", -0.3), (" an", -1.0)], " a": [(" apple", -0.1)]])
        let session = FakeSession(script: script)
        let best = try #require(try search(session, required: " ", config: cfg()).first)
        #expect(best.text == "a apple")
        #expect(session.forks.isEmpty)
    }

    @Test func extraSequencesAreDiscarded() throws {
        let session = FakeSession(script: iAmAn)
        _ = try search(session, required: " an", config: cfg())
        #expect(Array(session.histories.keys) == [0])
    }

    @Test func speculativeDecodeIsOneBatchedStep() throws {
        let session = FakeSession(script: iAmAn)
        _ = try search(session, required: " an", config: cfg())
        // Step 1: exact + 2 speculated longer tokens; then " engineer"; then ".".
        #expect(session.steps == 3)
        #expect(session.decodedTokens == 5)
    }

    @Test func endsInWordRules() {
        #expect(WordBoundary.endsInWord(Array(" an".utf8)[...]))
        #expect(WordBoundary.endsInWord(Array(" caf\u{E9}".utf8)[...]))
        #expect(!WordBoundary.endsInWord(Array(" ".utf8)[...]))
        #expect(!WordBoundary.endsInWord(Array("James'".utf8)[...]))
        #expect(WordBoundary.continuesWord(Array("note".utf8)))
        #expect(WordBoundary.continuesWord(Array("\u{E9}t\u{E9}".utf8)))
        #expect(WordBoundary.continuesWord(Array("'s".utf8)))
        #expect(!WordBoundary.continuesWord(Array(" apple".utf8)))
        #expect(!WordBoundary.continuesWord(Array(",".utf8)))
        #expect(!WordBoundary.continuesWord(Array("我".utf8)))
        #expect(!WordBoundary.continuesWord([UInt8]()))
        #expect(WordBoundary.continuesWord([0xC3]))      // incomplete two-byte lead (Latin)
        #expect(!WordBoundary.continuesWord([0xE6, 0x88]))  // incomplete CJK
    }
}

@Suite struct FanoutTests {
    private let script = makeScript([
        "": [(" one", -0.5), (" two", -0.9), (" three", -2.0), ("<eos>", -0.7)],
        " one": [(" apple", -2.0)],
        " one apple": [(" is", -2.0)],
        " two": [(".", -0.1)],
        " three": [(".", -0.1)],
    ])

    @Test func kOneIsPlainGreedy() throws {
        let session = FakeSession(script: script)
        let results = try search(session, required: "", config: cfg(k: 1))
        #expect(results.count == 1)
        #expect(results[0].text == " one apple is")
        #expect(session.forks.isEmpty)
    }

    @Test func kTwoRanksBySummedRawLogProb() throws {
        let session = FakeSession(script: script)
        var partials: [String] = []
        let results = try search(session, required: "", config: cfg(k: 2), partials: &partials)
        // " two." = -1.0 beats " one apple is" = -4.5; EOG is not a fan-out root.
        #expect(results.map(\.text) == [" two.", " one apple is"])
        #expect(session.history == results[0].tokens)
        #expect(Array(session.histories.keys) == [0])
        // Partials follow the first root (the greedy one) only.
        #expect(partials == [" one", " one apple", " one apple is"])
    }

    @Test func meanScoringCanPreferTheLongerBranch() throws {
        let script = makeScript([
            "": [(" one", -0.1), (" two", -0.4)],
            " one": [(" apple", -0.5)],
            " one apple": [(" is", -0.5)],
            " two": [(".", -0.5)],
        ])
        let sum = try search(FakeSession(script: script), required: "", config: cfg(k: 2, scoring: .sum))
        #expect(sum.first?.text == " two.")           // -0.9 vs -1.1
        let mean = try search(FakeSession(script: script), required: "", config: cfg(k: 2, scoring: .mean))
        #expect(mean.first?.text == " one apple is")  // -0.37 vs -0.45
    }

    @Test func lowConfidenceRanksLast() throws {
        let script = makeScript([
            "": [(" zz", -2.6), (" two", -3.0)],
            " two": [(".", -0.1)],
        ])
        // " zz" alone has the better raw score (-2.6 vs -3.1) but falls below the floor.
        let results = try search(FakeSession(script: script), required: "", config: cfg(k: 2, floor: -2.5))
        #expect(results.first?.text == " two.")
        #expect(results.last?.stop == .lowConfidence)
    }

    @Test func kTwoWithWordBoundaryKeepsBothOutcomes() throws {
        let session = FakeSession(script: iAmAn)
        let results = try search(session, required: " an", config: cfg(k: 2))
        #expect(results.count == 2)
        #expect(results.contains { $0.text == " engineer." })
        #expect(session.history == results[0].tokens)
        #expect(Array(session.histories.keys) == [0])
    }

    @Test func fanoutIsCappedBySequences() throws {
        let session = FakeSession(script: script, parallel: 2)
        let results = try search(session, required: "", config: cfg(k: 3))
        #expect(results.count == 2)
    }

    @Test func topHelperOrdersAndFilters() {
        let classes = TokenClasses(v)
        var logProbs = [Float](repeating: -30, count: v.count)
        logProbs[Int(v.id(" one"))] = -1
        logProbs[Int(v.id(" two"))] = -2
        logProbs[Int(v.id("<|turn>"))] = -0.1     // control: never returned
        logProbs[Int(v.id("note"))] = -0.5
        #expect(classes.top(logProbs, count: 2) { _, _ in true } == [v.id("note"), v.id(" one")])
        #expect(classes.top(logProbs, count: 2) { id, _ in !classes.continuesWord(id) } == [v.id(" one"), v.id(" two")])
    }
}
