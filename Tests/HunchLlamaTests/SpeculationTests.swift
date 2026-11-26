// Draft-and-verify primitive against the dev model. Skipped when the models drive is not mounted.
import Foundation
import Testing
import HunchCore
@testable import HunchLlama

// Part of ModelIntegrationTests (same serialized suite): the tests share one host, and other tests release/cancel it.
extension ModelIntegrationTests {
    @Test func draftRowsMatchSequentialDecodeAndSettleKeepsKVConsistent() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let prompt = try s.tokenize([content("Dear Sam, thanks for the photos from the trip. The lake looked")], addBOS: true)

            // Reference: plain greedy, one decode per token.
            _ = try s.syncPrompt(prompt, plan: cold)
            var rows: [[Float]] = []
            var path: [TokenID] = []
            var buffer: [Float] = []
            for _ in 0..<6 {
                try s.logProbs(.primary, into: &buffer)
                rows.append(buffer)
                let token = argmax(buffer) { s.vocabulary.traits($0).isDisjoint(with: [.control, .unused, .byteFallback]) }
                path.append(token)
                try s.step([(.primary, token)])
            }
            try s.logProbs(.primary, into: &buffer)
            rows.append(buffer)

            // Speculated: prompt + the whole path in one decode; every row matches.
            let report = try ls.syncPrompt(prompt, plan: cold, speculating: path)
            #expect(report.decodedTokens == prompt.count)
            #expect(ls.speculatedTokens == path)
            var worst: Float = 0
            for k in 0...path.count {
                try ls.logProbs(speculated: k, into: &buffer)
                worst = max(worst, maxAbsDiff(buffer, rows[k]))
                #expect(argmax(buffer) == argmax(rows[k]), "argmax differs at draft position \(k)")
            }
            print("[HunchLlama] speculated vs sequential rows: max abs log-prob diff = \(worst)")
            #expect(worst < 5e-2)

            // Keep 3 draft tokens: KV and bookkeeping hold exactly prompt + 3.
            ls.settleSpeculation(keeping: 3)
            #expect(ls.speculatedTokens.isEmpty)
            #expect(ls.cachedTokens(.primary) == prompt + path.prefix(3))
            #expect(ls.memoryPosMax(.primary) == Int32(prompt.count + 3 - 1))
            try s.logProbs(.primary, into: &buffer)
            #expect(maxAbsDiff(buffer, rows[3]) < 5e-2)

            // Continue with a real step (a rejected draft token would do the same): matches the reference.
            try s.step([(.primary, path[3])])
            try s.logProbs(.primary, into: &buffer)
            #expect(argmax(buffer) == argmax(rows[4]))
            #expect(maxAbsDiff(buffer, rows[4]) < 5e-2)

            // Next request extends the prompt along the old path: the cached draft tail is trimmed,
            // the last prompt token re-decoded, and a new draft rides along.
            let longer = prompt + path.prefix(2)
            let again = try ls.syncPrompt(longer, plan: ReusePlan(action: .trimAndAppend(keep: longer.count - 1),
                                                                   tokensToDecode: 1), speculating: Array(path.dropFirst(2)))
            #expect(again.reusedTokens == longer.count - 1 && again.decodedTokens == 1)
            try ls.logProbs(speculated: 2, into: &buffer)
            #expect(argmax(buffer) == argmax(rows[4]))
            // Settling with nothing kept leaves the plain prompt state.
            ls.settleSpeculation(keeping: 0)
            #expect(ls.cachedTokens(.primary) == longer)
            try s.logProbs(.primary, into: &buffer)
            #expect(argmax(buffer) == argmax(rows[2]))
            // A fork of the settled state keeps working.
            try s.fork(.primary, into: [SeqID(1)])
            try s.step([(SeqID(1), path[2])])
            try s.logProbs(SeqID(1), into: &buffer)
            #expect(argmax(buffer) == argmax(rows[3]))
            s.discard([SeqID(1)])
        }
    }

    @Test func midGenerationDraftRowsMatchSequentialDecode() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let prompt = try s.tokenize([content("Thanks for the notes from the meeting. I will send the")], addBOS: true)

            // Reference: prompt + 2 greedy tokens, then 5 more, one decode each.
            _ = try s.syncPrompt(prompt, plan: cold)
            var rows: [[Float]] = []
            var path: [TokenID] = []
            var buffer: [Float] = []
            for _ in 0..<7 {
                try s.logProbs(.primary, into: &buffer)
                rows.append(buffer)
                let token = argmax(buffer) { s.vocabulary.traits($0).isDisjoint(with: [.control, .unused, .byteFallback]) }
                path.append(token)
                try s.step([(.primary, token)])
            }

            // Same prefix, then the last 5 tokens as one mid-generation draft.
            _ = try s.syncPrompt(prompt, plan: cold)
            try s.step([(.primary, path[0])])
            try s.step([(.primary, path[1])])
            let draft = Array(path[2..<7])
            try ls.speculate(draft)
            #expect(ls.speculatedTokens == draft)
            #expect(ls.cachedTokens(.primary) == prompt + path)
            for k in 0..<draft.count {
                try ls.logProbs(speculated: k, into: &buffer)
                #expect(maxAbsDiff(buffer, rows[2 + k]) < 5e-2)
                #expect(argmax(buffer) == argmax(rows[2 + k]), "argmax differs at draft position \(k)")
            }

            // Keep 2: the cache holds the prompt + 4 tokens and the current row is the one after them.
            ls.settleSpeculation(keeping: 2)
            #expect(ls.cachedTokens(.primary) == prompt + path.prefix(4))
            #expect(ls.memoryPosMax(.primary) == Int32(prompt.count + 4 - 1))
            try s.logProbs(.primary, into: &buffer)
            #expect(argmax(buffer) == argmax(rows[4]))
            try s.step([(.primary, path[4])])
            try s.logProbs(.primary, into: &buffer)
            #expect(argmax(buffer) == argmax(rows[5]))

            // A speculation settled with nothing kept leaves the current row as it was.
            try ls.speculate([path[5], path[6]])
            ls.settleSpeculation(keeping: 0)
            #expect(ls.cachedTokens(.primary) == prompt + path.prefix(5))
            try s.logProbs(.primary, into: &buffer)
            #expect(argmax(buffer) == argmax(rows[5]))
        }
    }

    @Test func draftThatDoesNotFitIsDropped() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let prompt = try longPrompt(s, tokens: 480)   // batch is 512: no room for 100 draft tokens
            let draft = [TokenID](repeating: prompt[5], count: 100)
            _ = try ls.syncPrompt(prompt, plan: cold, speculating: draft)
            #expect(ls.speculatedTokens.isEmpty)
            #expect(ls.cachedTokens(.primary) == prompt)
        }
    }

    @Test func syncPromptSettlesALiveSpeculation() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let prompt = try s.tokenize([content("Hello Anna, I hope your week has been")], addBOS: true)
            var buffer: [Float] = []
            _ = try s.syncPrompt(prompt, plan: cold)
            try s.logProbs(.primary, into: &buffer)
            let reference = buffer

            // Live speculation, then the SAME prompt again without settling: the draft rows must be
            // trimmed out of the cache, not just forgotten, and the logits must be the prompt's.
            let draft = Array(prompt.suffix(3))
            let other = try s.tokenize([content("Completely different text about boats")], addBOS: true)
            _ = try s.syncPrompt(other, plan: cold)
            _ = try ls.syncPrompt(prompt, plan: cold, speculating: draft)
            #expect(ls.speculatedTokens == draft)
            _ = try ls.syncPrompt(prompt, plan: ReusePlan(action: .appendOnly(keep: prompt.count), tokensToDecode: 0))
            #expect(ls.speculatedTokens.isEmpty)
            #expect(ls.cachedTokens(.primary) == prompt)
            #expect(ls.memoryPosMax(.primary) == Int32(prompt.count - 1))
            try s.logProbs(.primary, into: &buffer)
            #expect(maxAbsDiff(buffer, reference) < 5e-2)

            // Live speculation, then a longer prompt along the same path.
            _ = try s.syncPrompt(other, plan: cold)
            _ = try ls.syncPrompt(prompt, plan: cold, speculating: draft)
            let longer = prompt + draft.prefix(1)
            _ = try ls.syncPrompt(longer, plan: ReusePlan(action: .trimAndAppend(keep: prompt.count), tokensToDecode: 1))
            #expect(ls.cachedTokens(.primary) == longer)
            #expect(ls.memoryPosMax(.primary) == Int32(longer.count - 1))
        }
    }
}

extension ModelIntegrationTests {
    /// A keystroke inside a word keeps the healed prompt, and typing along with a suggestion keeps
    /// its first tokens: the session serves the rows it already computed instead of re-decoding.
    @Test func heldPromptAndDraftRowsComeFromTheMemoWithoutADecode() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let prompt = try s.tokenize([content("Hi Jonas, thanks for sending the slides so quickly. I")], addBOS: true)
            let allowed = { (id: TokenID) in s.vocabulary.traits(id).isDisjoint(with: [.control, .unused, .byteFallback]) }

            // A first request: prompt, then 5 greedy steps (every row read is remembered).
            _ = try s.syncPrompt(prompt, plan: cold)
            var rows: [[Float]] = []
            var path: [TokenID] = []
            var buffer: [Float] = []
            for _ in 0..<5 {
                try s.logProbs(.primary, into: &buffer)
                rows.append(buffer)
                path.append(argmax(buffer, allowed: allowed))
                try s.step([(.primary, path.last!)])
            }
            try s.logProbs(.primary, into: &buffer)
            rows.append(buffer)
            #expect(ls.cachedTokens(.primary) == prompt + path)

            // Same prompt again (a keystroke inside a word): no decode, the very same root row.
            var before = ls.profile
            let same = try s.syncPrompt(prompt, plan: ReusePlan(action: .trimAndAppend(keep: prompt.count), tokensToDecode: 0))
            #expect(same.decodedTokens == 0 && same.reusedTokens == prompt.count)
            #expect(ls.profile.decodeCalls == before.decodeCalls)
            #expect(ls.cachedTokens(.primary) == prompt)
            #expect(ls.memoryPosMax(.primary) == Int32(prompt.count - 1))
            try s.logProbs(.primary, into: &buffer)
            #expect(buffer == rows[0])
            // Stepping on from there matches the first request.
            try s.step([(.primary, path[0])])
            try s.logProbs(.primary, into: &buffer)
            #expect(argmax(buffer, allowed: allowed) == argmax(rows[1], allowed: allowed))
            #expect(maxAbsDiff(buffer, rows[1]) < 5e-2)
            for k in 1..<5 { try s.step([(.primary, path[k])]) }
            try s.logProbs(.primary, into: &buffer)

            // Typing along: the prompt plus the held path as a draft, whose rows are all remembered.
            before = ls.profile
            let draft = Array(path.dropFirst(2)) + [path[0]]          // last token not held: decoded
            let longer = prompt + path.prefix(2)
            let along = try ls.syncPrompt(longer, plan: ReusePlan(action: .trimAndAppend(keep: longer.count), tokensToDecode: 0),
                                          speculating: draft)
            #expect(along.decodedTokens == 0)
            #expect(ls.speculatedTokens == draft)
            #expect(ls.profile.decodeTokens - before.decodeTokens == 1)   // only the token past the held path
            for k in 0...3 {
                try ls.logProbs(speculated: k, into: &buffer)
                #expect(maxAbsDiff(buffer, rows[2 + k]) < 5e-2, "row \(k)")
                #expect(argmax(buffer, allowed: allowed) == argmax(rows[2 + k], allowed: allowed))
            }
            try ls.logProbs(speculated: 1, into: &buffer)
            #expect(buffer == rows[3])                                    // a memo row is the row itself
            ls.settleSpeculation(keeping: 2)
            #expect(ls.cachedTokens(.primary) == longer + draft.prefix(2))
            #expect(ls.memoryPosMax(.primary) == Int32(longer.count + 2 - 1))
            try s.logProbs(.primary, into: &buffer)
            #expect(buffer == rows[4])

            // A changed prompt still re-decodes as before.
            let other = Array(prompt.dropLast()) + [path[1]]
            before = ls.profile
            let changed = try s.syncPrompt(other, plan: ReusePlan(action: .trimAndAppend(keep: prompt.count - 1), tokensToDecode: 1))
            #expect(changed.decodedTokens == 1)
            #expect(ls.profile.decodeCalls == before.decodeCalls + 1)
        }
    }
}
