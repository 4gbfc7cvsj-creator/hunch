// Scoring alternative continuations on the suggestion model (autocorrect for ambiguous words).
import Foundation
import HunchCore
import HunchLlama

extension LocalCompletionEngine: ContinuationScoring {
    /// Frames `request` exactly like a suggestion (so the KV cache keeps serving suggestions), then
    /// scores every continuation on forks of sequence 0, a batch of forks at a time. Each
    /// continuation starts with the framer's required prefix (the healed trailing space).
    public func scoreContinuations(_ request: CompletionRequest, continuations: [String]) async throws -> [Float]? {
        guard !continuations.isEmpty else { return [] }
        guard case .ready(_, let profile) = await host.state() else { return nil }
        lastProfile.withLock { $0 = profile }
        let framer = registry.framer(for: profile, override: framerOverride)
        let input = request.input
        let budget = promptTokenBudget
        let cache = self.cache
        let planner = self.planner
        return try await host.withSession(request.id) { session -> [Float] in
            _ = cache.adopt(session)
            let counter = SessionTokenCounter(session: session)
            let framed = framer.frame(input, profile: profile, budget: budget, counter: counter)
            let tokens = try session.tokenize(framed.segments, addBOS: profile.addsBOS)
            let plan = planner.plan(cached: cache.tokens, next: tokens, capability: session.reuseCapability)
            do {
                _ = try session.syncPrompt(tokens, plan: plan)
                cache.set(prompt: tokens)
            } catch {
                cache.recordAfterFailure(session: session, attempted: tokens)
                throw error
            }
            let tails = try continuations.map { text in
                try session.tokenize([PromptSegment(text: framed.requiredPrefix + text, kind: .content,
                                                    stability: .perKeystroke)], addBOS: false)
            }
            return try Self.score(tails, in: session)
        }
    }

    /// Sum of log-probs of each token list after sequence 0, which is left as it was.
    static func score(_ tails: [[TokenID]], in session: any LanguageModelSession) throws -> [Float] {
        var scores = [Float](repeating: -.infinity, count: tails.count)
        let lanes = max(1, session.maxParallelSequences - 1)
        guard session.maxParallelSequences >= 2 else { throw LlamaError.invalidSequence(1) }
        var buffer: [Float] = []
        var start = 0
        while start < tails.count {
            let group = Array(start..<min(tails.count, start + lanes))
            let seqs = group.indices.map { SeqID(Int32($0 + 1)) }
            try session.fork(.primary, into: seqs)
            defer { session.discard(seqs) }
            var sums = [Float](repeating: 0, count: group.count)
            let longest = group.map { tails[$0].count }.max() ?? 0
            for position in 0..<longest {
                if session.isCancellationRequested { throw CancellationError() }
                var appends: [(SeqID, TokenID)] = []
                for (lane, index) in group.enumerated() where position < tails[index].count {
                    let token = tails[index][position]
                    try session.logProbs(seqs[lane], into: &buffer)
                    sums[lane] += Int(token) < buffer.count ? buffer[Int(token)] : -.infinity
                    if position + 1 < tails[index].count { appends.append((seqs[lane], token)) }
                }
                if !appends.isEmpty { try session.step(appends) }
            }
            for (lane, index) in group.enumerated() where !tails[index].isEmpty { scores[index] = sums[lane] }
            start += group.count
        }
        return scores
    }
}
