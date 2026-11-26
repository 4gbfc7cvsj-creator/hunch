// The parked prompt: two prompts keep their own cache by swapping sequence 0 with the parked
// sequence. Skipped when the models drive is not mounted.
import Foundation
import Testing
import HunchCore
@testable import HunchLlama

extension ModelIntegrationTests {
    @Test func parkedPromptKeepsBothCachesAcrossSwaps() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            #expect(ls.canParkPrompt)
            #expect(ls.maxParallelSequences == 4)
            let a = try s.tokenize([content("Dear Sam, thanks for the photos from the trip. The lake looked")], addBOS: true)
            let b = try s.tokenize([content("Fix the slips in my text: i realy think we shoud move the meeting")], addBOS: true)
            var buffer: [Float] = []
            _ = try s.syncPrompt(a, plan: cold)
            try s.logProbs(.primary, into: &buffer)
            let rowA = buffer

            // Swap in (nothing parked yet): an empty sequence 0, then B.
            try ls.swapParkedPrompt()
            #expect(ls.retainedPromptTokens.isEmpty)
            #expect(ls.parkedPromptTokens == a)
            _ = try s.syncPrompt(b, plan: cold)
            try s.logProbs(.primary, into: &buffer)
            let rowB = buffer

            // Back: A is whole, with its row; syncing it again decodes nothing.
            try ls.swapParkedPrompt()
            #expect(ls.retainedPromptTokens == a)
            #expect(ls.parkedPromptTokens == b)
            #expect(ls.memoryPosMax(.primary) == Int32(a.count - 1))
            let again = try s.syncPrompt(a, plan: ReusePlan(action: .appendOnly(keep: a.count), tokensToDecode: 0))
            #expect(again.decodedTokens == 0)
            try s.logProbs(.primary, into: &buffer)
            #expect(maxAbsDiff(buffer, rowA) < 1e-3)

            // A suggestion-like request: branches, then a longer A.
            try s.fork(.primary, into: [SeqID(1), SeqID(2)])
            try s.step([(SeqID(1), a[3]), (SeqID(2), a[4])])
            let longer = a + Array(b.suffix(3))
            let grown = try s.syncPrompt(longer, plan: ReusePlan(action: .appendOnly(keep: a.count), tokensToDecode: 3))
            #expect(grown.reusedTokens == a.count)

            // B is still parked intact: swapping it in reuses all of it.
            try ls.swapParkedPrompt()
            #expect(ls.retainedPromptTokens == b)
            #expect(ls.memoryPosMax(.primary) == Int32(b.count - 1))
            let reusedB = try s.syncPrompt(b, plan: ReusePlan(action: .appendOnly(keep: b.count), tokensToDecode: 0))
            #expect(reusedB.decodedTokens == 0)
            try s.logProbs(.primary, into: &buffer)
            #expect(maxAbsDiff(buffer, rowB) < 1e-3)
            // And generating on it works.
            try s.step([(.primary, b[2])])
            try ls.swapParkedPrompt()
            #expect(ls.retainedPromptTokens == longer)
            #expect(ls.parkedPromptTokens == b + [b[2]])
        }
    }

    @Test func parkedPromptGivesWayToALongPrompt() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let short = try s.tokenize([content("Hello Anna, I hope your week has been")], addBOS: true)
            _ = try s.syncPrompt(short, plan: cold)
            try ls.swapParkedPrompt()
            #expect(ls.parkedPromptTokens == short)
            // Context 512: a 470-token prompt plus the parked one leaves no room for branches.
            let long = try longPrompt(s, tokens: 470)
            _ = try s.syncPrompt(long, plan: cold)
            #expect(ls.parkedPromptTokens.isEmpty)
            #expect(ls.retainedPromptTokens == long)
            var buffer: [Float] = []
            try s.logProbs(.primary, into: &buffer)
            try ls.swapParkedPrompt()
            #expect(ls.retainedPromptTokens.isEmpty)
            #expect(ls.parkedPromptTokens == long)
            try ls.swapParkedPrompt()
            #expect(ls.retainedPromptTokens == long)
        }
    }
}
