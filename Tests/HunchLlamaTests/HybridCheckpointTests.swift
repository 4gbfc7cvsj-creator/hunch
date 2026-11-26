// Checkpoint reuse on a hybrid (recurrent) model: every reuse path must give the same log-probs as
// a cold prefill. Own host; skipped when no Qwen3.5 file is on the models drive.
import Foundation
import Testing
import HunchCore
import HunchModels
@testable import HunchLlama

enum HybridModel {
    static let candidates = [
        "/Volumes/Samsung 1TB/LLM/GhostType/Qwen3.5-2B-Base.i1-Q4_K_M.gguf",
        "/Volumes/Samsung 1TB/LLM/GhostType/Qwen3.5-4B-Base.i1-Q5_K_M.gguf",
    ]
    static var path: String? { candidates.first { FileManager.default.fileExists(atPath: $0) } }
    static var available: Bool { _ = DevModel.noResidency; return path != nil }

    static func entry() -> ModelEntry {
        let url = URL(fileURLWithPath: path!)
        let (validity, summary) = GGUFInspector().inspect(url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ModelEntry(id: ModelEntryID(relativePath: url.lastPathComponent), url: url,
                          byteSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                          validity: validity, summary: summary)
    }

    static func options() -> RuntimeOptions {
        RuntimeOptions(contextTokens: 1024, batchTokens: 512, gpuLayers: -1, loadMode: .mmap,
                       fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)
    }
}

@Suite(.serialized, .enabled(if: HybridModel.available, "no Qwen3.5 model on the models drive"))
final class HybridCheckpointTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }

    /// Same tolerance as kvcheck's exact paths: the state is restored byte for byte.
    private static let tolerance: Float = 1e-2

    private func withHybrid(_ body: @escaping @Sendable (LlamaSession) throws -> Void) async throws {
        let host = LlamaModelHost()
        await host.load(HybridModel.entry(), options: HybridModel.options())
        guard case .ready = await host.state() else {
            Issue.record("load failed: \(await host.state())")
            return
        }
        // Always unload: ggml-metal asserts at exit while a model is still resident.
        do {
            try await host.withSession(RequestID(1)) { s in
                let ls = try #require(s as? LlamaSession)
                try body(ls)
            }
        } catch {
            await host.unload()
            throw error
        }
        await host.unload()
    }

    /// Log-probs after a cold prefill of `tokens` (sequence 0 is rebuilt from scratch).
    private static func coldReference(_ s: LlamaSession, _ tokens: [TokenID]) throws -> [Float] {
        s.discard([.primary])
        _ = try s.syncPrompt(tokens, plan: cold)
        var out: [Float] = []
        try s.logProbs(.primary, into: &out)
        return out
    }

    /// Log-probs after a cold prefill of `prompt` and then `tail` decoded as one batch: the same
    /// batch shapes as a reuse path that keeps `prompt` and decodes `tail`. A recurrent layer's
    /// one-token update and its chunked prefill differ slightly in float, so comparisons against a
    /// single cold prefill of `prompt + tail` are only close (see `stepVersusPrefillGap`), while
    /// these are exact.
    private static func steppedReference(_ s: LlamaSession, _ prompt: [TokenID], _ tail: [TokenID]) throws -> [Float] {
        s.discard([.primary])
        _ = try s.syncPrompt(prompt, plan: cold)
        #expect(s.decodeRaw(tail, at: prompt.count) == 0)
        var out: [Float] = []
        try s.logProbs(.primary, into: &out)
        return out
    }

    private static func greedyPath(_ s: LlamaSession, from prompt: [TokenID], count: Int) throws -> [TokenID] {
        s.discard([.primary])
        _ = try s.syncPrompt(prompt, plan: cold)
        var buffer: [Float] = []
        var path: [TokenID] = []
        for _ in 0..<count {
            try s.logProbs(.primary, into: &buffer)
            let token = argmax(buffer) { s.vocabulary.traits($0).isDisjoint(with: [.control, .unused, .byteFallback]) }
            path.append(token)
            try s.step([(.primary, token)])
        }
        return path
    }

    @Test func editGoesBackToTheNearestCheckpointAndMatchesACold() async throws {
        try await withHybrid { s in
            #expect(s.reuseCapability == .checkpoint)
            let base = try longPrompt(s, tokens: 400)
            // Pieces of 256: checkpoints at 256 and 400.
            _ = try s.syncPrompt(base, plan: cold)
            #expect(s.profile.checkpointSaves >= 2)

            // Backspace-like edit at 380: back to 256, re-read 256..<edited.count.
            let edited = Array(base.prefix(380)) + Array(base[300..<310])
            let reference = try Self.coldReference(s, edited)
            _ = try s.syncPrompt(base, plan: cold)
            let report = try s.syncPrompt(edited, plan: ReusePlan(action: .trimAndAppend(keep: 380), tokensToDecode: 10))
            #expect(report.reusedTokens == 256)
            #expect(s.cachedTokens(.primary) == edited)
            #expect(s.memoryPosMax(.primary) == Int32(edited.count - 1))
            var got: [Float] = []
            try s.logProbs(.primary, into: &got)
            #expect(maxAbsDiff(got, reference) < Self.tolerance, "diff \(maxAbsDiff(got, reference)) argmax-same \(argmax(got) == argmax(reference))")
            #expect(argmax(got) == argmax(reference))
        }
    }

    @Test func promptEndCheckpointServesTheNextRequestAfterGeneration() async throws {
        try await withHybrid { s in
            let prompt = try longPrompt(s, tokens: 120)
            let path = try Self.greedyPath(s, from: prompt, count: 4)
            // Sequence 0 holds prompt + 4 generated tokens; the next prompt shares only the prompt.
            let next = prompt + [path[1]]
            let reference = try Self.steppedReference(s, prompt, [path[1]])
            _ = try s.syncPrompt(prompt, plan: cold)
            for t in path { try s.step([(.primary, t)]) }
            let report = try s.syncPrompt(next, plan: ReusePlan(action: .trimAndAppend(keep: prompt.count), tokensToDecode: 1))
            #expect(report.reusedTokens == prompt.count)
            #expect(report.decodedTokens == 1)
            var got: [Float] = []
            try s.logProbs(.primary, into: &got)
            #expect(maxAbsDiff(got, reference) < Self.tolerance, "diff \(maxAbsDiff(got, reference)) argmax-same \(argmax(got) == argmax(reference))")
        }
    }

    @Test func speculationSettlesThroughCheckpoints() async throws {
        try await withHybrid { s in
            let prompt = try longPrompt(s, tokens: 80)
            let path = try Self.greedyPath(s, from: prompt, count: 5)
            var rows: [[Float]] = []
            var buffer: [Float] = []
            for k in 0...3 {
                rows.append(try Self.coldReference(s, prompt + path.prefix(k)))
            }
            let settledAt2 = try Self.steppedReference(s, prompt, Array(path.prefix(2)))
            for keep in [0, 2, 5] {
                s.discard([.primary])
                _ = try s.syncPrompt(prompt, plan: cold, speculating: path)
                #expect(s.speculatedTokens == path)
                for k in 0...3 {
                    try s.logProbs(speculated: k, into: &buffer)
                    #expect(maxAbsDiff(buffer, rows[k]) < 5e-2, "draft row \(k) diff \(maxAbsDiff(buffer, rows[k])) argmax-same \(argmax(buffer) == argmax(rows[k]))")
                }
                s.settleSpeculation(keeping: keep)
                #expect(s.cachedTokens(.primary) == prompt + path.prefix(keep))
                #expect(s.memoryPosMax(.primary) == Int32(prompt.count + keep - 1))
                if keep <= 3 {
                    // Kept 0: the prompt's own row. Kept 2: the prompt end's checkpoint plus the
                    // two kept tokens re-read in one batch.
                    let expected = keep == 2 ? settledAt2 : rows[keep]
                    try s.logProbs(.primary, into: &buffer)
                    #expect(maxAbsDiff(buffer, expected) < Self.tolerance, "settled at \(keep) diff \(maxAbsDiff(buffer, expected))")
                }
                // The search then steps on from the settled state.
                if keep < path.count {
                    try s.step([(.primary, path[keep])])
                    #expect(s.memoryPosMax(.primary) == Int32(prompt.count + keep))
                }
            }
        }
    }

    @Test func forkedBranchesMatchColdDecodes() async throws {
        try await withHybrid { s in
            let prompt = try longPrompt(s, tokens: 100)
            let path = try Self.greedyPath(s, from: prompt, count: 1)
            // Two different continuations of the same prompt.
            let other = try s.tokenize([content(" banana")], addBOS: false)[0]
            let refA = try Self.steppedReference(s, prompt, [path[0]])
            let refB = try Self.steppedReference(s, prompt, [other])

            s.discard([.primary])
            _ = try s.syncPrompt(prompt, plan: cold)
            try s.fork(.primary, into: [SeqID(1), SeqID(2)])
            try s.step([(SeqID(1), path[0]), (SeqID(2), other)])
            var a: [Float] = []
            var b: [Float] = []
            try s.logProbs(SeqID(1), into: &a)
            try s.logProbs(SeqID(2), into: &b)
            #expect(maxAbsDiff(a, refA) < 5e-2, "diff \(maxAbsDiff(a, refA)) argmax-same \(argmax(a) == argmax(refA))")
            #expect(maxAbsDiff(b, refB) < 5e-2, "diff \(maxAbsDiff(b, refB)) argmax-same \(argmax(b) == argmax(refB))")
            // Branch work leaves sequence 0 intact: the next request still reuses its prompt end.
            s.discard([SeqID(1), SeqID(2)])
            let report = try s.syncPrompt(prompt + [other], plan: ReusePlan(action: .appendOnly(keep: prompt.count), tokensToDecode: 1))
            #expect(report.reusedTokens == prompt.count)
            var c: [Float] = []
            try s.logProbs(.primary, into: &c)
            #expect(maxAbsDiff(c, refB) < Self.tolerance, "diff \(maxAbsDiff(c, refB)) argmax-same \(argmax(c) == argmax(refB))")
        }
    }

    /// Not a pass/fail check of the engine: how far a one-token step after a prefill is from a
    /// single prefill of the same tokens on this model (the float gap the other tests avoid).
    @Test func stepVersusPrefillGap() async throws {
        try await withHybrid { s in
            let prompt = try longPrompt(s, tokens: 120)
            let path = try Self.greedyPath(s, from: prompt, count: 1)
            let stepped = try Self.steppedReference(s, prompt, path)
            let prefilled = try Self.coldReference(s, prompt + path)
            print("[HunchLlama] hybrid one-token step vs prefill: max|dlogp|=\(maxAbsDiff(stepped, prefilled)) "
                  + "argmax-same=\(argmax(stepped) == argmax(prefilled))")
            #expect(argmax(stepped) == argmax(prefilled))
        }
    }

    /// Idle release frees the context (and its checkpoints); the reload re-probes and checkpoints work again.
    @Test func checkpointsWorkAfterIdleRelease() async throws {
        let host = LlamaModelHost()
        await host.load(HybridModel.entry(), options: HybridModel.options())
        guard case .ready = await host.state() else { Issue.record("load failed"); return }
        host.releaseNow()
        for await state in host.states() { if case .releasedIdle = state { break } }
        try await host.withSession(RequestID(2)) { s in
            let ls = try #require(s as? LlamaSession)
            #expect(ls.reuseCapability == .checkpoint)
            let base = try longPrompt(s, tokens: 300)
            _ = try s.syncPrompt(base, plan: cold)
            let edited = Array(base.prefix(290))
            let report = try s.syncPrompt(edited, plan: ReusePlan(action: .trimAndAppend(keep: 289), tokensToDecode: 1))
            #expect(report.reusedTokens == 256)
            #expect(ls.cachedTokens(.primary) == edited)
        }
        await host.unload()
    }
}
