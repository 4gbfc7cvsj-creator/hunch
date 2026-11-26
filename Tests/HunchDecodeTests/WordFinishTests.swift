import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private func first(_ script: [String: [(String, Float)]], maxTokens: Int = 24) throws -> Candidate {
    let config = DecodeConfig(minWords: 1, maxWords: 10, maxTokens: maxTokens, minMeanLogProb: -10,
                              stopAtComma: false, allowNewline: false)
    let results = try GreedyConstrainedSearch().search(in: FakeSession(script: makeScript(script)),
                                                       requiredPrefix: [], config: config) { _ in }
    return try #require(results.first)
}

/// Finishing a word the model ended its turn (or hit the token cap) in the middle of.
@Suite struct WordFinishTests {
    @Test func wholeWordAtEndOfTurnIsNotExtended() throws {
        // The model ends after " Thanks"; a letter token is the runner-up but far less likely.
        let c = try first(["": [(" Thanks", -0.1)], " Thanks": [("<eos>", -0.1), ("note", -2)]])
        #expect(c.text == " Thanks")
        #expect(c.stop == .endOfGeneration)
    }

    @Test func halfWordAtEndOfTurnIsFinished() throws {
        // End of turn is the single best token, but continuing the word has more probability in total.
        let c = try first(["": [(" hea", -0.1)], " hea": [("<eos>", -0.9), ("ring", -1), ("aring", -1)]])
        #expect(c.text == " hearing")
        #expect(c.stop == .endOfGeneration)
    }

    @Test func finishingStopsOnceTheWordIsComplete() throws {
        let c = try first(["": [(" hea", -0.1)], " hea": [("<eos>", -0.9), ("ring", -1), ("aring", -1)],
                           " hearing": [("<eos>", -0.1), ("note", -1.5)]])
        #expect(c.text == " hearing")
    }

    @Test func wordStillUnfinishedAtTheLimitIsDroppedWithItsStatistics() throws {
        let c = try first(["": [(" one", -0.2)], " one": [(" hea", -0.1)],
                           " one hea": [("<eos>", -0.9), ("ring", -1), ("aring", -1)],
                           " one hearing": [("ring", -0.1)], " one hearingring": [("ring", -0.1)],
                           " one hearingringring": [("ring", -0.1)]])
        #expect(c.text == " one")
        #expect(abs(c.meanLogProb - -0.2) < 0.001)
        #expect(abs(c.totalLogProb - -0.2) < 0.001)
    }

    @Test func endsMidWordCoversAccentedLettersButNotCJK() {
        #expect(SearchRun.endsMidWord("au caf"))
        #expect(SearchRun.endsMidWord("nächste Woche in Mü"))
        #expect(SearchRun.endsMidWord("don\u{2019}"))
        #expect(!SearchRun.endsMidWord("好"))
        #expect(!SearchRun.endsMidWord("ok."))
        #expect(!SearchRun.endsMidWord("ok "))
        #expect(!SearchRun.endsMidWord(""))
    }
}
