import Foundation
import HunchCore

/// A session that can decode a guessed continuation (the "draft") together with the prompt and
/// serve the logits of every draft position afterwards. Optional capability: the search checks
/// for it with a cast, so sessions without it (and the whole HunchCore contract) are unaffected.
///
/// Contract:
/// - `syncPrompt(_:plan:speculating:)` behaves like `syncPrompt`; additionally, if it could,
///   the draft tokens are decoded after the prompt in the same pass and `speculatedTokens`
///   returns them. The session's current logits for `SeqID.primary` remain the prompt's.
/// - `logProbs(speculated: k)` is the log-softmax of the logits after the prompt plus the first
///   `k` draft tokens (0...speculatedTokens.count). Valid until the next decode or settle.
/// - `settleSpeculation(keeping: k)` keeps the prompt plus the first `k` draft tokens in the KV
///   cache, drops the rest, and makes the logits after the last kept token the current logits of
///   `SeqID.primary`. Idempotent; a no-op without a speculation. Any other session call that
///   decodes or forks settles with `keeping: 0` first.
public protocol SpeculativeSession: LanguageModelSession {
    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan, speculating draft: [TokenID]) throws -> PromptSyncReport
    var speculatedTokens: [TokenID] { get }
    func logProbs(speculated count: Int, into buffer: inout [Float]) throws
    func settleSpeculation(keeping count: Int)
    /// Mid-generation draft: decodes `draft` after sequence 0's current tokens in one decode and
    /// serves it like a prompt speculation (`logProbs(speculated: 0)` is the current row). A no-op
    /// (`speculatedTokens` stays empty) when it can't; any live speculation is settled with 0 first.
    func speculate(_ draft: [TokenID]) throws
}

/// Makes a speculated draft invisible to the search: a `step` that appends exactly the next draft
/// token is answered from the pre-decoded rows (no decode), and `logProbs` of the primary sequence
/// reads the row for the current position. Anything else (a different token, other sequences, a
/// fork) settles the speculation first and then goes to the real session. Because every decision
/// the search makes is a function of the log-probs it reads, the result is what plain stepping
/// would produce (up to the numerics of a batched versus single-token decode on a real model).
final class DraftingSession: LanguageModelSession {
    private let inner: any SpeculativeSession
    private let draft: [TokenID]
    private var consumed = 0
    private var live = true
    /// Tokens served from the draft without a decode (statistics).
    private(set) var acceptedDraftTokens = 0

    init?(_ session: any LanguageModelSession) {
        guard let speculative = session as? any SpeculativeSession, !speculative.speculatedTokens.isEmpty else { return nil }
        self.inner = speculative
        self.draft = speculative.speculatedTokens
    }

    /// Ends the speculation, keeping what the search consumed. Safe to call repeatedly.
    func settle() {
        guard live else { return }
        live = false
        inner.settleSpeculation(keeping: consumed)
    }

    var vocabulary: any VocabularyTable { inner.vocabulary }
    var maxParallelSequences: Int { inner.maxParallelSequences }
    var reuseCapability: ReuseCapability { inner.reuseCapability }
    var isCancellationRequested: Bool { inner.isCancellationRequested }
    var retainedPromptTokens: [TokenID] { inner.retainedPromptTokens }

    func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] {
        try inner.tokenize(segments, addBOS: addBOS)
    }

    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
        settle()
        return try inner.syncPrompt(tokens, plan: plan)
    }

    func fork(_ source: SeqID, into targets: [SeqID]) throws {
        settle()
        try inner.fork(source, into: targets)
    }

    func step(_ appends: [(SeqID, TokenID)]) throws {
        if live, appends.count == 1, appends[0].0 == .primary, consumed < draft.count, draft[consumed] == appends[0].1 {
            if inner.isCancellationRequested { throw CancellationError() }
            consumed += 1
            acceptedDraftTokens += 1
            return
        }
        settle()
        try inner.step(appends)
    }

    func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {
        if live, seq == .primary, consumed > 0 {
            try inner.logProbs(speculated: consumed, into: &buffer)
        } else {
            try inner.logProbs(seq, into: &buffer)
        }
    }

    func discard(_ seqs: [SeqID]) {
        settle()
        inner.discard(seqs)
    }
}

/// A session that can keep a second prompt aside, so two kinds of request each keep their own
/// prompt cache (see `LlamaSession.swapParkedPrompt`). Optional capability, checked with a cast.
public protocol PromptParkingSession: LanguageModelSession {
    var canParkPrompt: Bool { get }
    /// Swaps sequence 0 (with its current row) and the parked prompt. Drops branches.
    func swapParkedPrompt() throws
}
