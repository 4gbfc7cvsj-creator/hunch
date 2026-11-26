// Whole-field rewrite on the shared local model: one short greedy generation per pass. The prompt's
// job text comes first and stays the same, so its tokens are reused from the last pass.
import Foundation
import HunchCore
import HunchDecode
import HunchPrompt
import HunchText

public final class LocalRewriter: @unchecked Sendable {
    public struct Pass: Sendable {
        /// The model's text, as it answered.
        public var revised: String
        public var promptTokens: Int
        public var reusedTokens: Int
        public var generatedTokens: Int
        /// Decodes the generation took (equal to `generatedTokens` without copy decoding).
        public var decodes: Int
        public var prefillMs: Double
        public var totalMs: Double
    }

    private let host: any ModelHosting
    private let framer = RewriteFramer()
    private let planner = DefaultReusePlanner()
    private let nextID: @Sendable () -> RequestID

    public init(host: any ModelHosting, nextID: @escaping @Sendable () -> RequestID) {
        self.host = host
        self.nextID = nextID
    }

    public enum RewriteError: Error { case notInstruct, notLoaded }

    public func rewrite(_ request: RewriteRequest) async throws -> Pass {
        guard case .ready(_, let profile) = await host.state() else { throw RewriteError.notLoaded }
        guard profile.isInstruct, let markers = profile.markers else { throw RewriteError.notInstruct }
        let framed = framer.frame(request, markers: markers)
        let planner = self.planner
        // Room for the copy plus a few added words; a target past that is cut off, and the
        // shortened copy then fails `FieldRewrite.cleanOutput`'s length check.
        let budget = (request.target.utf8.count + 2) / 3 * 3 / 2 + 24
        let singleLine = !request.target.contains("\n")
        let clock = ContinuousClock()
        let start = clock.now
        return try await host.withSession(nextID()) { session -> Pass in
            // The pass keeps its own prompt in the parked sequence, so it and the suggestions don't
            // evict each other's prompt cache.
            let parking = Self.ownCache ? (session as? any PromptParkingSession).flatMap { $0.canParkPrompt ? $0 : nil } : nil
            try parking?.swapParkedPrompt()
            defer { try? parking?.swapParkedPrompt() }
            let tokens = try session.tokenize(framed.segments, addBOS: profile.addsBOS)
            let plan = planner.plan(cached: session.retainedPromptTokens, next: tokens, capability: session.reuseCapability)
            let report = try session.syncPrompt(tokens, plan: plan)
            let prefill = clock.now - start
            var bytes: [UInt8] = []
            let generation: (generated: Int, decodes: Int)
            if Self.copyDecoding, session.reuseCapability != .checkpoint, let speculative = session as? any SpeculativeSession {
                let draft = try session.tokenize([PromptSegment(text: request.target, kind: .content, stability: .perKeystroke)],
                                                 addBOS: false)
                generation = try Self.copyDecode(speculative, copying: draft, budget: budget, singleLine: singleLine, into: &bytes)
            } else {
                generation = try Self.greedy(session, budget: budget, singleLine: singleLine, into: &bytes)
            }
            let generated = generation.generated
            let ms = { (d: Duration) in Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
            return Pass(revised: String(decoding: bytes, as: UTF8.self), promptTokens: tokens.count,
                        reusedTokens: report.reusedTokens, generatedTokens: generated, decodes: generation.decodes,
                        prefillMs: ms(prefill), totalMs: ms(clock.now - start))
        }
    }

    /// Log-probability of each of `continuations` after the pass's answer has reached `head` (the
    /// corrected copy up to a word), for `request`'s prompt: on the pass's own prompt cache, which
    /// still holds the prompt and the answer just written, so only the head's last tokens and one
    /// decode per continuation (all its tokens at once) are new. -inf for one that can't be scored.
    public func score(_ request: RewriteRequest, head: String, continuations: [String]) async throws -> [Float] {
        guard !continuations.isEmpty else { return [] }
        guard case .ready(_, let profile) = await host.state() else { throw RewriteError.notLoaded }
        guard profile.isInstruct, let markers = profile.markers else { throw RewriteError.notInstruct }
        let framed = framer.frame(request, markers: markers)
        let planner = self.planner
        return try await host.withSession(nextID()) { session -> [Float] in
            let parking = Self.ownCache ? (session as? any PromptParkingSession).flatMap { $0.canParkPrompt ? $0 : nil } : nil
            try parking?.swapParkedPrompt()
            defer { try? parking?.swapParkedPrompt() }
            var segments = framed.segments
            if !head.isEmpty { segments.append(PromptSegment(text: head, kind: .content, stability: .perKeystroke)) }
            let tokens = try session.tokenize(segments, addBOS: profile.addsBOS)
            let plan = planner.plan(cached: session.retainedPromptTokens, next: tokens, capability: session.reuseCapability)
            _ = try session.syncPrompt(tokens, plan: plan)
            let tails = try continuations.map {
                try session.tokenize([PromptSegment(text: $0, kind: .content, stability: .perKeystroke)], addBOS: false)
            }
            guard let speculative = session as? any SpeculativeSession else { return tails.map { _ in -.infinity } }
            var buffer: [Float] = []
            var out: [Float] = []
            for tail in tails {
                if session.isCancellationRequested { throw CancellationError() }
                try speculative.speculate(tail)
                guard !tail.isEmpty, speculative.speculatedTokens == tail else {
                    speculative.settleSpeculation(keeping: 0)
                    out.append(-.infinity)
                    continue
                }
                var sum: Float = 0
                for (k, token) in tail.enumerated() {
                    try speculative.logProbs(speculated: k, into: &buffer)
                    sum += Int(token) < buffer.count ? buffer[Int(token)] : -.infinity
                }
                speculative.settleSpeculation(keeping: 0)
                out.append(sum)
            }
            return out
        }
    }

    /// `HUNCH_REWRITE_COPY=0` turns copy decoding off (A/B measurements).
    static let copyDecoding = ProcessInfo.processInfo.environment["HUNCH_REWRITE_COPY"] != "0"
    /// `HUNCH_REWRITE_OWN_CACHE=0` keeps the pass on the suggestions' prompt cache (A/B measurements).
    static let ownCache = ProcessInfo.processInfo.environment["HUNCH_REWRITE_OWN_CACHE"] != "0"
    /// Draft tokens verified per decode.
    static let draftLength = 12

    /// The model's greedy pick from `logProbs`: never an unused or control token (end of
    /// generation aside). -1 when nothing qualifies.
    static func pick(_ logProbs: [Float], _ vocab: any VocabularyTable) -> TokenID {
        var best: TokenID = -1
        var bestScore = -Float.infinity
        for i in logProbs.indices where logProbs[i] > bestScore {
            let traits = vocab.traits(TokenID(i))
            if traits.contains(.unused) || (traits.contains(.control) && !traits.contains(.endOfGeneration)) { continue }
            best = TokenID(i)
            bestScore = logProbs[i]
        }
        return best
    }

    /// The plain loop: one decode per generated token.
    static func greedy(_ session: any LanguageModelSession, budget: Int, singleLine: Bool,
                       into bytes: inout [UInt8]) throws -> (generated: Int, decodes: Int) {
        let vocab = session.vocabulary
        var logProbs: [Float] = []
        var generated = 0
        while generated < budget {
            if session.isCancellationRequested { throw CancellationError() }
            try session.logProbs(.primary, into: &logProbs)
            let best = pick(logProbs, vocab)
            guard best >= 0, !vocab.traits(best).contains(.endOfGeneration) else { break }
            let piece = vocab.bytes(best)
            if singleLine, piece.contains(0x0A), !bytes.isEmpty { break }
            bytes.append(contentsOf: piece)
            generated += 1
            try session.step([(.primary, best)])
        }
        return (generated, generated)
    }

    /// Copy decoding: the answer is mostly a copy of the target, so the target's tokens after the
    /// point the answer has reached are a draft. Each decode appends the model's own next token
    /// plus up to `draftLength` draft tokens, with logits for every one; the loop then reads the
    /// rows in order and keeps the draft for as long as the model's greedy pick agrees. Every
    /// token is still the greedy pick from the row after exactly the tokens before it, with the
    /// same stops as `greedy`, so the answer is the same (up to the numerics of a batched versus a
    /// single-token decode).
    static func copyDecode(_ session: any SpeculativeSession, copying target: [TokenID], budget: Int,
                           singleLine: Bool, into bytes: inout [UInt8]) throws -> (generated: Int, decodes: Int) {
        let vocab = session.vocabulary
        var logProbs: [Float] = []
        var answer: [TokenID] = []
        var cursor = 0
        var decodes = 0
        // Draft = the rows decoded after the current position (`row` = the next one to read; 0 is the
        // current position). `live` = a speculation is in place; otherwise read the primary row.
        var draft: [TokenID] = []
        var row = 0
        var live = false
        defer { if live { session.settleSpeculation(keeping: row) } }
        while answer.count < budget {
            if session.isCancellationRequested { throw CancellationError() }
            if live { try session.logProbs(speculated: row, into: &logProbs) } else { try session.logProbs(.primary, into: &logProbs) }
            let best = pick(logProbs, vocab)
            guard best >= 0, !vocab.traits(best).contains(.endOfGeneration) else { break }
            let piece = vocab.bytes(best)
            if singleLine, piece.contains(0x0A), !bytes.isEmpty { break }
            bytes.append(contentsOf: piece)
            answer.append(best)
            if live, row < draft.count, draft[row] == best {
                row += 1  // already decoded
                continue
            }
            if live {
                session.settleSpeculation(keeping: row)
                live = false
            }
            // Decode `best` together with the target's next tokens.
            var next = copyDraft(answer: answer, target: target, cursor: &cursor)
            next = Array(next.prefix(max(0, min(draftLength, budget - answer.count - 1))))
            decodes += 1
            if !next.isEmpty {
                try session.speculate([best] + next)
                if session.speculatedTokens.count == next.count + 1 {
                    draft = [best] + next
                    row = 1
                    live = true
                    continue
                }
            }
            try session.step([(.primary, best)])
        }
        return (answer.count, decodes)
    }

    /// The target's tokens that should follow `answer`: after the latest place in `target` where
    /// the answer's last tokens (3, 2, then 1) occur, searching forward from `cursor` (where
    /// the copy was last found) and then anywhere. Empty at the end of the target or when nothing
    /// matches. `cursor` moves to the match.
    static func copyDraft(answer: [TokenID], target: [TokenID], cursor: inout Int) -> [TokenID] {
        guard !target.isEmpty else { return [] }
        guard !answer.isEmpty else { return target }
        for n in stride(from: min(3, answer.count), through: 1, by: -1) {
            let tail = Array(answer.suffix(n))
            guard target.count >= n else { continue }
            let starts = Array(0...(target.count - n))
            let from = min(cursor, target.count - n)
            let ordered = starts.filter { $0 >= from } + starts.filter { $0 < from }.reversed()
            for i in ordered where Array(target[i..<(i + n)]) == tail {
                cursor = i + n
                return Array(target[(i + n)...])
            }
        }
        return []
    }
}

/// An engine that can run a whole-field rewrite pass (the local model only).
public protocol FieldRewriting: Sendable {
    /// The model's corrected copy of `request.target`. `id`: the request id for the host's
    /// latest-wins executor (a newer suggestion request cancels it).
    func rewrite(_ request: RewriteRequest, id: RequestID) async throws -> LocalRewriter.Pass
    /// Log-probability of each continuation after the pass for `request` has written `head`
    /// (`LocalRewriter.score`), right after that pass.
    func score(_ request: RewriteRequest, head: String, continuations: [String], id: RequestID) async throws -> [Float]
}

extension LocalCompletionEngine: FieldRewriting {
    public func rewrite(_ request: RewriteRequest, id: RequestID) async throws -> LocalRewriter.Pass {
        try await LocalRewriter(host: host, nextID: { id }).rewrite(request)
    }

    public func score(_ request: RewriteRequest, head: String, continuations: [String], id: RequestID) async throws -> [Float] {
        try await LocalRewriter(host: host, nextID: { id }).score(request, head: head, continuations: continuations)
    }
}
