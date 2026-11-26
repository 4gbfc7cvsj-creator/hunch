import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private let v = FakeVocabulary.standard

@Suite struct ConfidenceFloorTests {
    private let split = DecodeConfig(minMeanLogProb: -2.5, wordStartMinFirstLogProb: -1.0, midWordMinMeanLogProb: -8)

    @Test func midWordIsTheTypedPartialWord() {
        #expect(ConfidenceFloor.isMidWord(requiredPrefix: Array(" a".utf8)))
        #expect(ConfidenceFloor.isMidWord(requiredPrefix: Array("caf".utf8)))
        #expect(!ConfidenceFloor.isMidWord(requiredPrefix: Array(" ".utf8)))
        #expect(!ConfidenceFloor.isMidWord(requiredPrefix: []))
    }

    @Test func midWordOnlyTheSafetyNet() {
        // A forced, unlikely start that would fail today's -2.5 floor passes mid-word...
        #expect(ConfidenceFloor.check(text: "anual rating", mean: -4, firstLogProb: -6, midWord: true, config: split) == nil)
        // ...down to the safety net.
        #expect(ConfidenceFloor.check(text: "sue", mean: -9, firstLogProb: -9, midWord: true, config: split) == .mean(limit: -8))
    }

    @Test func wordStartChecksTheFirstToken() {
        #expect(ConfidenceFloor.check(text: " the plan", mean: -0.5, firstLogProb: -0.9, midWord: false, config: split) == nil)
        #expect(ConfidenceFloor.check(text: " the plan", mean: -0.5, firstLogProb: -1.2, midWord: false, config: split)
                == .firstToken(limit: -1.0))
        // The mean floor still applies at word starts.
        #expect(ConfidenceFloor.check(text: " the plan", mean: -3, firstLogProb: -0.1, midWord: false, config: split)
                == .mean(limit: -2.5))
    }

    @Test func cjkKeepsTheMeanFloor() {
        #expect(ConfidenceFloor.check(text: "下午見", mean: -2, firstLogProb: -3, midWord: false, config: split) == nil)
        #expect(ConfidenceFloor.check(text: "下午見", mean: -3, firstLogProb: -0.1, midWord: true, config: split)
                == .mean(limit: -2.5))
    }

    @Test func offMeansTodaysFloor() {
        let off = DecodeConfig(minMeanLogProb: -2.5, wordStartMinFirstLogProb: nil, midWordMinMeanLogProb: nil)
        #expect(ConfidenceFloor.check(text: " the plan", mean: -0.5, firstLogProb: -5, midWord: false, config: off) == nil)
        #expect(ConfidenceFloor.check(text: "anual", mean: -3, firstLogProb: -3, midWord: true, config: off) == .mean(limit: -2.5))
    }

    @Test func searchAppliesTheSplitFloor() throws {
        let script = makeScript([
            "": [(" apple", -1.5), (" banana", -1.6)],
            " apple": [(" is", -0.1)],
            " apple is": [(" red", -0.1)],
        ])
        let config = DecodeConfig(minWords: 1, maxWords: 10, minMeanLogProb: -2.5, wordStartMinFirstLogProb: -1.0,
                                  midWordMinMeanLogProb: -8)
        // Word start (nothing healed): the first token (-1.5) is below -1.0. (After a typed space the
        // first token is scored only against tokens that start with a space.)
        let start = try #require(GreedyConstrainedSearch().search(in: FakeSession(script: script), requiredPrefix: [],
                                                                  config: config) { _ in }.first)
        #expect(start.stop == .lowConfidence)
        // Mid-word ("a" typed): the same path is shown.
        let mid = try #require(GreedyConstrainedSearch().search(in: FakeSession(script: script), requiredPrefix: Array(" a".utf8),
                                                                config: config) { _ in }.first)
        #expect(mid.stop != .lowConfidence)
        #expect(mid.text == "pple is red")
    }

    @Test func firstTokenFailureIsKnownEarly() {
        #expect(ConfidenceFloor.firstTokenFailure(text: " the", firstLogProb: -1.2, midWord: false, config: split)
                == .firstToken(limit: -1.0))
        #expect(ConfidenceFloor.firstTokenFailure(text: " the", firstLogProb: -0.5, midWord: false, config: split) == nil)
        #expect(ConfidenceFloor.firstTokenFailure(text: "anual", firstLogProb: -6, midWord: true, config: split) == nil)
        #expect(ConfidenceFloor.firstTokenFailure(text: "下午", firstLogProb: -6, midWord: false, config: split) == nil)
        #expect(ConfidenceFloor.firstTokenFailure(text: " the", firstLogProb: nil, midWord: false, config: split) == nil)
    }

    @Test func partialsCarryTheFirstTokenScore() throws {
        let script = makeScript([
            "": [(" apple", -1.5), (" banana", -1.6)],
            " apple": [(" is", -0.1)],
            " apple is": [(" red", -0.1)],
        ])
        var partials: [Candidate] = []
        _ = try GreedyConstrainedSearch().search(in: FakeSession(script: script), requiredPrefix: [],
                                                 config: DecodeConfig(minWords: 1, maxWords: 10)) { partials.append($0) }
        #expect(!partials.isEmpty)
        #expect(partials.allSatisfy { abs(($0.firstLogProb ?? 0) - -1.5) < 0.001 })
    }

    @Test func settingsWrittenBeforeTheSplitFloorGetIt() throws {
        let old = #"{"minWords":2,"maxWords":4,"maxTokens":24,"firstTokenFanout":1,"scoring":"sum","minMeanLogProb":-2.5}"#
        let decoded = try JSONDecoder().decode(DecodeConfig.self, from: Data(old.utf8))
        #expect(decoded.wordStartMinFirstLogProb == DecodeConfig.defaultWordStartMinFirstLogProb)
        #expect(decoded.midWordMinMeanLogProb == DecodeConfig.defaultMidWordMinMeanLogProb)
        let round = try JSONDecoder().decode(DecodeConfig.self, from: JSONEncoder().encode(split))
        #expect(round == split)
    }
}
