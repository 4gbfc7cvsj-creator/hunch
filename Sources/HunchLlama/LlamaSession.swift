// Executor-confined LanguageModelSession over one llama_context (design §5.2, §5.3).
import Accelerate
import Foundation
import HunchCore
import llama

/// Where the most recent logits of a sequence live.
private enum LogitsSource {
    /// Row `index` (batch index) of the decode numbered `epoch`; valid only while that decode is the latest.
    case row(epoch: Int, index: Int32)
    /// Copied out of llama's buffer before a later decode overwrote it.
    case saved([Float])
}

/// Not Sendable: every call must happen on the generation executor thread.
///
/// Bookkeeping: `seqTokens[s]` mirrors exactly the tokens held in the KV cache for sequence `s`
/// (positions 0..<count). Every append comes with a decode that outputs logits for the sequence's
/// last token, so a sequence with tokens normally has a `LogitsSource`.
public final class LlamaSession: LanguageModelSession {
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let memory: llama_memory_t
    private let executor: GenerationExecutor
    private let table: LlamaVocabularyTable
    private let nVocab: Int
    private let nBatch: Int
    private let nCtxSeq: Int
    private var batch: llama_batch
    private var closed = false

    private var seqTokens: [Int32: [TokenID]] = [:]
    private var logits: [Int32: LogitsSource] = [:]
    private var epoch = 0
    private var scratch: [Float] = []
    /// Tokenizer results for this session's model (see `TokenizationCache`); cleared in `close()`.
    private var tokenCache = TokenizationCache()

    /// Raw logits rows already computed, by token path (see `LogitMemo`); cleared in `close()`.
    /// `HUNCH_LOGIT_MEMO=0` turns it off (A/B measurements).
    private var memo: LogitMemo

    /// Where one speculated row lives: a row of the decode numbered `epoch`, or a memo row.
    private enum SpeculatedRow {
        case batch(epoch: Int, index: Int32)
        case saved([Float])
    }

    /// Draft tokens decoded together with the prompt, or still held from an earlier request (see
    /// `syncPrompt(_:plan:speculating:)`). While present, `seqTokens[0]` holds prompt + draft and
    /// `logits[0]` is the prompt's row; `rows[i]` holds the logits after the first `i` draft tokens.
    private struct Speculation {
        var base: Int
        var draft: [TokenID]
        var rows: [SpeculatedRow]
    }
    private var speculation: Speculation?

    /// Saved recurrent states of sequence 0 (`ReuseCapability.checkpoint` only). Every entry's
    /// position is at most `seqTokens[0].count` and describes exactly that prefix.
    private var checkpoints: CheckpointStore
    /// On a checkpoint cache, a prompt prefill is decoded in pieces of at most this many tokens
    /// with a checkpoint after each, so going back re-reads at most this much.
    static let checkpointSpacing = 256
    private static let partialState = llama_state_seq_flags(LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY)

    /// Cumulative cost counters (profiling only; no text). Read via `profile` on the executor.
    public struct Profile: Sendable, Equatable {
        public var decodeCalls = 0
        public var decodeTokens = 0
        public var decodeNanos: Int64 = 0
        public var logProbCalls = 0
        public var logProbNanos: Int64 = 0
        /// Part of `logProbNanos` spent waiting for the GPU (llama_synchronize) rather than computing.
        public var gpuWaitNanos: Int64 = 0
        /// Speculation: requests that carried a draft, draft tokens decoded, and draft tokens kept.
        public var draftRequests = 0
        public var draftTokens = 0
        public var draftKept = 0
        /// Tokenize lookups (`tokenizeText`, `tokenizeContent`), cache hits among them, and their total time.
        public var tokenizeCalls = 0
        public var tokenizeHits = 0
        public var tokenizeNanos: Int64 = 0
        /// Rows served from the logit memo instead of a decode (prompt rows and held draft rows).
        public var memoRows = 0
        /// Checkpoint caches: states saved and restored, time spent copying them, and tokens
        /// re-read after a restore to reach an exact length (speculation settle, memo rows).
        public var checkpointSaves = 0
        public var checkpointRestores = 0
        public var checkpointNanos: Int64 = 0
        public var replayedTokens = 0
        public init() {}
    }
    public private(set) var profile = Profile()
    public func resetProfile() { profile = Profile() }

    public let maxParallelSequences: Int
    /// The sequence holding the parked prompt (one past the search's sequences), if the context has one.
    private let parkedSeq: Int32?
    /// The row after the parked prompt, if it had one when it was parked.
    private var parkedRow: [Float]?
    public internal(set) var reuseCapability: ReuseCapability = .none
    public var vocabulary: any VocabularyTable { table }

    init(ctx: OpaquePointer, vocab: OpaquePointer, table: LlamaVocabularyTable, executor: GenerationExecutor,
         parking: Bool = false) {
        self.ctx = ctx
        self.vocab = vocab
        self.memory = llama_get_memory(ctx)
        self.executor = executor
        self.table = table
        self.nVocab = Int(llama_vocab_n_tokens(vocab))
        self.nBatch = Int(llama_n_batch(ctx))
        self.nCtxSeq = Int(llama_n_ctx_seq(ctx))
        let nSeq = Int(llama_n_seq_max(ctx))
        let parks = parking && nSeq > 2
        self.parkedSeq = parks ? Int32(nSeq - 1) : nil
        self.maxParallelSequences = parks ? nSeq - 1 : nSeq
        self.batch = llama_batch_init(Int32(max(nBatch, maxParallelSequences)), 0, 1)
        let memoOff = ProcessInfo.processInfo.environment["HUNCH_LOGIT_MEMO"] == "0"
        self.memo = LogitMemo(vocabularySize: nVocab, byteBudget: memoOff ? 0 : LogitMemo.defaultByteBudget)
        // HUNCH_CHECKPOINT_MB overrides the checkpoint budget (A/B measurements).
        let budgetMB = ProcessInfo.processInfo.environment["HUNCH_CHECKPOINT_MB"].flatMap(Int.init)
        self.checkpoints = CheckpointStore(byteBudget: budgetMB.map { $0 << 20 } ?? CheckpointStore.defaultByteBudget)
    }

    deinit {
        llama_batch_free(batch)
    }

    /// Called by the runtime right before the context is freed.
    func close() {
        closed = true
        speculation = nil
        checkpoints.removeAll()
        seqTokens.removeAll()
        logits.removeAll()
        parkedRow = nil
        tokenCache.removeAll()
        memo.removeAll()
    }

    public var isCancellationRequested: Bool { executor.isCancellationRequested }

    // MARK: - Tokenize

    public func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] {
        try checkOpen()
        var out: [TokenID] = []
        if addBOS {
            let bos = llama_vocab_bos(vocab)
            if bos != LLAMA_TOKEN_NULL { out.append(bos) }
        }
        for segment in segments where !segment.text.isEmpty {
            // Special-token parsing only for framer-authored control text (injection safety).
            if segment.kind == .control {
                out.append(contentsOf: try tokenizeText(segment.text, parseSpecial: true))
            } else {
                out.append(contentsOf: try tokenizeContent(segment.text))
            }
        }
        return out
    }

    /// Content text with special parsing OFF. llama.cpp still matches USER_DEFINED tokens in that
    /// mode, so any marker-like user-defined string (see `RawTokenInfo.isMarkerLike`) is split
    /// right after its first character: the pieces are tokenized separately and can never
    /// re-form the marker token.
    /// Cached as a whole (marker scan included) under its own key, since for marker text the
    /// result differs from `tokenizeText(_, parseSpecial: false)`.
    func tokenizeContent(_ text: String) throws -> [TokenID] {
        try cached(TokenizationCache.Key(bytes: Array(text.utf8), parseSpecial: false, splitsMarkers: true)) { _ in
            try splitContent(text)
        }
    }

    private func splitContent(_ text: String) throws -> [TokenID] {
        let markers = table.protectedMarkers
        guard !markers.isEmpty, markers.contains(where: { text.contains($0) }) else {
            return try llamaTokenize(Array(text.utf8), parseSpecial: false)
        }
        var out: [TokenID] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let hit = markers.compactMap { rest.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            guard let hit else {
                out.append(contentsOf: try llamaTokenize(Array(rest.utf8), parseSpecial: false))
                break
            }
            let cut = rest.index(after: hit.lowerBound)
            out.append(contentsOf: try llamaTokenize(Array(rest[..<cut].utf8), parseSpecial: false))
            rest = rest[cut...]
        }
        return out
    }

    /// Tokenizes `text` without BOS. Cached like `tokenizeContent`.
    func tokenizeText(_ text: String, parseSpecial: Bool) throws -> [TokenID] {
        try cached(TokenizationCache.Key(bytes: Array(text.utf8), parseSpecial: parseSpecial, splitsMarkers: false)) {
            try llamaTokenize($0, parseSpecial: parseSpecial)
        }
    }

    /// Answers from the tokenization cache or runs `compute` on the key's bytes and stores the
    /// result, so the framer's repeated measurements of the same text skip the tokenizer; a hit
    /// returns the identical tokens. Counts one `tokenizeCalls` per lookup.
    private func cached(_ key: TokenizationCache.Key, _ compute: ([UInt8]) throws -> [TokenID]) throws -> [TokenID] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            profile.tokenizeCalls += 1
            profile.tokenizeNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0)
        }
        if let tokens = tokenCache.value(for: key) {
            profile.tokenizeHits += 1
            return tokens
        }
        let tokens = try compute(key.bytes)
        tokenCache.store(tokens, for: key)
        return tokens
    }

    private func llamaTokenize(_ utf8: [UInt8], parseSpecial: Bool) throws -> [TokenID] {
        var capacity = utf8.count + 8
        while true {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let n = utf8.withUnsafeBufferPointer { raw in
                raw.withMemoryRebound(to: CChar.self) { chars in
                    llama_tokenize(vocab, chars.baseAddress, Int32(chars.count), &tokens, Int32(capacity),
                                   false, parseSpecial)
                }
            }
            if n >= 0 { return Array(tokens.prefix(Int(n))) }
            if n == Int32.min { throw LlamaError.tokenizeFailed }
            capacity = Int(-n)
        }
    }

    // MARK: - Prompt sync

    /// Brings sequence 0 to exactly `tokens`, reusing the cached prefix as allowed by `plan`.
    /// Any other sequences (branches of an earlier request) are discarded first.
    public func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
        try syncPrompt(tokens, plan: plan, speculating: [])
    }

    /// Draft tokens currently pre-decoded after the prompt in sequence 0 (empty when there are none).
    public var speculatedTokens: [TokenID] { speculation?.draft ?? [] }

    /// Like `syncPrompt`, and when the last prompt batch has room also decodes `draft` (a guess at
    /// the tokens that will follow the prompt) in the SAME `llama_decode`, with logits for the last
    /// prompt token and for every draft token. Nothing is read or decided here: the caller reads
    /// `logProbs(speculated:)` for as many draft tokens as its own rules accept, then calls
    /// `settleSpeculation(keeping:)`. If the draft doesn't fit (or the prompt was already fully
    /// cached) it is silently dropped and `speculatedTokens` is empty.
    public func syncPrompt(_ tokens: [TokenID], plan: ReusePlan, speculating draft: [TokenID]) throws -> PromptSyncReport {
        try checkOpen()
        let clock = ContinuousClock()
        let start = clock.now
        // A caller that never settled its last speculation: trim the draft rows out of the cache
        // (rather than just forgetting them) so seqTokens/KV/logits agree before diffing the prompt.
        settleSpeculation(keeping: 0)
        guard !tokens.isEmpty else { throw LlamaError.emptyPrompt }
        guard tokens.count < nCtxSeq else { throw LlamaError.promptTooLong(tokens: tokens.count, limit: nCtxSeq) }
        if executor.isCancellationRequested { throw CancellationError() }

        for seq in seqTokens.keys where seq != 0 && seq != parkedSeq { dropSequence(seq) }
        // The parked prompt gives way when both wouldn't fit the shared cache with room for branches.
        if let p = parkedSeq, let parked = seqTokens[p],
           parked.count + tokens.count + min(RuntimeOptions.decodeHeadroom, nCtxSeq / 8) > nCtxSeq {
            dropSequence(p)
        }

        var cached = seqTokens[0] ?? []
        memo.keepHeld(by: [cached])
        if cached == tokens, logits[0] != nil {
            return PromptSyncReport(decodedTokens: 0, reusedTokens: tokens.count, duration: clock.now - start)
        }
        if try syncFromMemo(tokens, cached: cached, plan: plan, draft: draft) {
            return PromptSyncReport(decodedTokens: 0, reusedTokens: tokens.count, duration: clock.now - start)
        }
        // A memo attempt may have moved sequence 0 back (to a checkpoint) before giving up.
        cached = seqTokens[0] ?? []

        var keep: Int
        var shift: Shift?
        switch plan.action {
        case .appendOnly(let k), .trimAndAppend(let k): keep = k
        case .coldPrefill: keep = 0
        case .removeAndShift(let k, let drop, let matched, let skip):
            keep = k
            shift = Shift(drop: drop, matched: matched, skip: skip)
        }
        // Never trust the plan beyond the real common prefix, and always re-decode at least the
        // last token so its logits exist.
        keep = max(0, min(keep, commonPrefix(cached, tokens), tokens.count - 1))
        if let s = shift, !shiftIsApplicable(s, keep: keep, planned: plan.action, cached: cached, next: tokens) {
            shift = nil
        }
        // A shift keeps the common prefix AND a later run; a failure anywhere in it (the cache
        // refusing a step, or the decode that applies the pending K-shift) leaves sequence 0 dropped.
        var reused = keep
        if let s = shift {
            if try applyShift(s, keep: keep, tokens: tokens) {
                reused = keep + s.matched
                keep += s.skip + s.matched
            } else {
                shift = nil
                keep = 0
            }
        } else if keep < cached.count {
            // With checkpoints this may keep less than asked (the nearest saved state before it).
            keep = trimPrimary(to: keep)
            reused = keep
        }
        if keep == 0 {
            reused = 0
            if let p = parkedSeq, seqTokens[p] != nil {
                dropSequence(0)
            } else {
                llama_memory_clear(memory, false)
                checkpoints.removeAll()
                seqTokens.removeAll()
                logits.removeAll()
            }
        } else if shift == nil {
            seqTokens[0] = Array(tokens[0..<keep])
            logits[0] = nil
        }
        // The K-shift is applied by the first decode after `seq_add`; until that decode has
        // succeeded, any failure leaves the moved cells in an unknown state, so sequence 0 is dropped.
        var shiftPending = shift.map { $0.skip == 0 } ?? false

        // A checkpoint cache decodes the prompt in pieces with a checkpoint after each, and the
        // draft in a decode of its own, so that the state right after the prompt can be saved.
        let checkpointing = reuseCapability == .checkpoint
        let piece = checkpointing ? min(nBatch, Self.checkpointSpacing) : nBatch
        var position = keep
        while position < tokens.count {
            if executor.isCancellationRequested {
                if shiftPending { dropSequence(0) }
                throw CancellationError()
            }
            let end = min(position + piece, tokens.count)
            let isLast = end == tokens.count
            // The draft rides along only if it fits the batch buffers and the context.
            let fused = !checkpointing && isLast && !draft.isEmpty && (end - position) + draft.count <= nBatch
                && tokens.count + draft.count + 1 < nCtxSeq
                && draft.allSatisfy { $0 >= 0 && Int($0) < nVocab }
            fillBatch(tokens[position..<end], startPos: position, seq: 0, logitsOnLast: isLast)
            let rootRow = Int32(batch.n_tokens - 1)
            if fused {
                for (offset, token) in draft.enumerated() {
                    appendToBatch(token, pos: tokens.count + offset, seq: 0, wantLogits: true)
                }
            }
            let rc = decodeBatch(advancing: [0])
            guard rc == 0 else {
                reconcilePromptAfterFailure(tokens, shiftPending: shiftPending)
                throw rc == 2 ? CancellationError() : decodeError(rc)
            }
            shiftPending = false
            seqTokens[0, default: []].append(contentsOf: tokens[position..<end])
            if fused {
                seqTokens[0]!.append(contentsOf: draft)
                speculation = Speculation(base: tokens.count, draft: draft,
                                          rows: (0...draft.count).map { .batch(epoch: epoch, index: rootRow + Int32($0)) })
                profile.draftRequests += 1
                profile.draftTokens += draft.count
            }
            position = end
            if isLast { logits[0] = .row(epoch: epoch, index: rootRow) }
            if checkpointing { saveCheckpoint() }
        }
        if checkpointing, !draft.isEmpty {
            try speculateSeparately(draft, after: tokens)
        }
        return PromptSyncReport(decodedTokens: tokens.count - reused, reusedTokens: reused, duration: clock.now - start)
    }

    /// Checkpoint caches: decodes `draft` after the synced prompt in a decode of its own (the
    /// prompt's checkpoint is already saved, so settling can go back to it). The prompt's row is
    /// copied out first because the draft decode replaces llama's logits. A failed draft decode
    /// leaves the prompt synced without a draft; a cancelled one throws.
    private func speculateSeparately(_ draft: [TokenID], after tokens: [TokenID]) throws {
        guard draft.count <= nBatch, tokens.count + draft.count + 1 < nCtxSeq,
              draft.allSatisfy({ $0 >= 0 && Int($0) < nVocab }),
              seqTokens[0]?.count == tokens.count, checkpoints.contains(position: tokens.count),
              case .row(let e, let index)? = logits[0], e == epoch,
              let ptr = llama_get_logits_ith(ctx, index) else { return }
        let promptRow = Array(UnsafeBufferPointer(start: ptr, count: nVocab))
        logits[0] = .saved(promptRow)
        batch.n_tokens = 0
        for (offset, token) in draft.enumerated() {
            appendToBatch(token, pos: tokens.count + offset, seq: 0, wantLogits: true)
        }
        let rc = decodeBatch(advancing: [])
        guard rc == 0 else {
            if restoreCheckpoint(atMost: tokens.count) == tokens.count { logits[0] = .saved(promptRow) }
            if rc == 2 { throw CancellationError() }
            return
        }
        seqTokens[0]!.append(contentsOf: draft)
        speculation = Speculation(base: tokens.count, draft: draft,
                                  rows: [.saved(promptRow)] + (0..<draft.count).map { .batch(epoch: epoch, index: Int32($0)) })
        profile.draftRequests += 1
        profile.draftTokens += draft.count
    }

    /// Mid-generation draft-and-verify: decodes `draft` after sequence 0's current tokens in ONE
    /// decode, with logits for every draft token. Afterwards it reads like a prompt speculation:
    /// `logProbs(speculated: 0)` is sequence 0's current row (copied out first), `logProbs(speculated: k)`
    /// the row after the first `k` draft tokens, and `settleSpeculation(keeping:)` ends it. A live
    /// speculation is settled with `keeping: 0` first. Nothing happens (no speculation) when sequence 0
    /// has no current logits, or the draft doesn't fit the batch or the context. A failed decode
    /// leaves sequence 0 as it was and throws.
    public func speculate(_ draft: [TokenID]) throws {
        try checkOpen()
        settleSpeculation(keeping: 0)
        guard !draft.isEmpty, let held = seqTokens[0], !held.isEmpty,
              draft.count <= nBatch, held.count + draft.count + 1 < nCtxSeq,
              draft.allSatisfy({ $0 >= 0 && Int($0) < nVocab }) else { return }
        // Sequence 0's current row, copied out: the draft decode replaces llama's logits.
        let current: [Float]
        switch logits[0] {
        case .saved(let row)?: current = row
        case .row(let e, let index)? where e == epoch:
            guard let ptr = llama_get_logits_ith(ctx, index) else { return }
            current = Array(UnsafeBufferPointer(start: ptr, count: nVocab))
        default: return
        }
        if executor.isCancellationRequested { throw CancellationError() }
        logits[0] = .saved(current)
        batch.n_tokens = 0
        for (offset, token) in draft.enumerated() {
            appendToBatch(token, pos: held.count + offset, seq: 0, wantLogits: true)
        }
        let rc = decodeBatch(advancing: [])
        guard rc == 0 else {
            // Roll back whatever a partial decode left (as `step` does).
            if reuseCapability == .checkpoint {
                if restoreCheckpoint(atMost: held.count) == held.count { logits[0] = .saved(current) }
            } else if !llama_memory_seq_rm(memory, 0, Int32(held.count), -1) {
                dropSequence(0)
            }
            throw rc == 2 ? CancellationError() : decodeError(rc)
        }
        seqTokens[0]!.append(contentsOf: draft)
        speculation = Speculation(base: held.count, draft: draft,
                                  rows: [.saved(current)] + (0..<draft.count).map { .batch(epoch: epoch, index: Int32($0)) })
        profile.draftRequests += 1
        profile.draftTokens += draft.count
    }

    /// When sequence 0 already holds `tokens` and the memo has the row after them (a keystroke
    /// inside a word keeps the healed prompt; typing along with the suggestion keeps its first
    /// tokens): trims the cache to the prompt plus the draft tokens it still holds with recorded
    /// rows, and serves those rows without a decode. The rest of the draft, if any, is decoded in one
    /// batch as usual. False = not applicable, nothing changed (the caller syncs normally).
    ///
    /// The rows are the ones this session computed for exactly these tokens, so the search reads
    /// the same log-probs a re-decode would give (up to the numerics of a batched versus a
    /// single-token decode, as with any draft).
    private func syncFromMemo(_ tokens: [TokenID], cached: [TokenID], plan: ReusePlan, draft: [TokenID]) throws -> Bool {
        switch plan.action {
        case .appendOnly(let keep), .trimAndAppend(let keep):
            guard keep >= tokens.count else { return false }
        case .coldPrefill, .removeAndShift:
            return false
        }
        guard let rows = memo.walk(prompt: tokens, held: cached, draft: draft) else { return false }
        let heldDraft = rows.count - 1
        let held = tokens.count + heldDraft
        if cached.count > held {
            // Exact: on a checkpoint cache, the nearest saved state plus a short re-read.
            guard reuseCapability.canTrim, rewindPrimary(to: held) else { return false }
            if heldDraft == 0 { saveCheckpoint() } // the prompt end, for settling a draft later
        }
        seqTokens[0] = Array(cached.prefix(held))
        logits[0] = .saved(rows[0])
        profile.memoRows += 1

        var speculatedRows = rows.map { SpeculatedRow.saved($0) }
        var speculated = Array(draft.prefix(heldDraft))
        let rest = Array(draft.dropFirst(heldDraft))
        if !rest.isEmpty, rest.count <= nBatch, tokens.count + draft.count + 1 < nCtxSeq,
           rest.allSatisfy({ $0 >= 0 && Int($0) < nVocab }) {
            batch.n_tokens = 0
            for (offset, token) in rest.enumerated() {
                appendToBatch(token, pos: held + offset, seq: 0, wantLogits: true)
            }
            let rc = decodeBatch(advancing: [0])
            guard rc == 0 else {
                // Back to the plain prompt state (the prompt's row is still the memo's).
                if reuseCapability == .checkpoint {
                    if restoreCheckpoint(atMost: tokens.count) == tokens.count {
                        logits[0] = .saved(rows[0])
                    } else {
                        dropSequence(0)
                    }
                } else if llama_memory_seq_rm(memory, 0, Int32(tokens.count), -1) {
                    seqTokens[0] = tokens
                    logits[0] = .saved(rows[0])
                } else {
                    dropSequence(0)
                }
                throw rc == 2 ? CancellationError() : decodeError(rc)
            }
            seqTokens[0]!.append(contentsOf: rest)
            speculatedRows += (0..<rest.count).map { .batch(epoch: epoch, index: Int32($0)) }
            speculated += rest
        }
        if !speculated.isEmpty {
            speculation = Speculation(base: tokens.count, draft: speculated, rows: speculatedRows)
            profile.draftRequests += 1
            profile.draftTokens += speculated.count
        }
        return true
    }

    /// Keeps a copy of the raw row after `path` for later requests (see `LogitMemo`).
    private func remember(path: [TokenID], row: () -> [Float]?) {
        let held = Array(seqTokens.values)
        guard memo.row(after: path[...]) == nil, memo.wouldKeep(pathLength: path.count, held: held),
              let copy = row() else { return }
        memo.record(path: path, row: copy, held: held)
    }

    // MARK: - Context shift

    private struct Shift {
        var drop: Int
        var matched: Int
        var skip: Int
    }

    /// Scratch sequence for the moved run while the skipped boundary tokens are decoded before it.
    private static let shiftScratchSeq: Int32 = 1

    /// A shift is applied only as planned: the kept prefix was not clamped, the run really is the
    /// same in `cached` and `next`, at least one token stays to be decoded, and (when boundary tokens
    /// are skipped) a scratch sequence exists.
    private func shiftIsApplicable(_ s: Shift, keep: Int, planned: ReusePlan.Action, cached: [TokenID],
                                   next: [TokenID]) -> Bool {
        guard reuseCapability == .trimAndShift, case .removeAndShift(let plannedKeep, _, _, _) = planned,
              plannedKeep == keep, s.drop >= 0, s.skip >= 0, s.matched > 0, s.drop + s.skip > 0,
              keep + s.drop + s.matched <= cached.count, keep + s.skip + s.matched < next.count,
              s.skip == 0 || maxParallelSequences > Int(Self.shiftScratchSeq) else { return false }
        return cached[(keep + s.drop)..<(keep + s.drop + s.matched)] == next[(keep + s.skip)..<(keep + s.skip + s.matched)]
    }

    /// Drops `cached[keep..<keep+drop]` and anything after the run, moves the run to positions
    /// `keep+skip...` (metadata: the K cache is re-rotated by the next decode), and decodes the
    /// skipped boundary tokens in front of it. With skipped tokens the run waits in a scratch
    /// sequence so that the boundary decode starts right after the kept prefix (llama requires
    /// consecutive positions per sequence). On success sequence 0 holds exactly
    /// `tokens[0..<keep+skip+matched]`; on failure it is dropped and false is returned (a decode
    /// abort throws after dropping).
    private func applyShift(_ s: Shift, keep: Int, tokens: [TokenID]) throws -> Bool {
        let runStart = Int32(keep + s.drop)
        let runEnd = runStart + Int32(s.matched)
        let delta = Int32(s.skip - s.drop)
        let scratch = Self.shiftScratchSeq
        if s.skip == 0 {
            guard llama_memory_seq_rm(memory, 0, Int32(keep), runStart),
                  llama_memory_seq_rm(memory, 0, runEnd, -1) else {
                dropSequence(0)
                return false
            }
            llama_memory_seq_add(memory, 0, runStart, -1, delta)
        } else {
            _ = llama_memory_seq_rm(memory, scratch, -1, -1)
            llama_memory_seq_cp(memory, 0, scratch, runStart, runEnd)
            guard llama_memory_seq_rm(memory, 0, Int32(keep), -1) else {
                dropSequence(0)
                _ = llama_memory_seq_rm(memory, scratch, -1, -1)
                return false
            }
            if delta != 0 { llama_memory_seq_add(memory, scratch, runStart, -1, delta) }
            logits[0] = nil
            fillBatch(tokens[keep..<(keep + s.skip)], startPos: keep, seq: 0, logitsOnLast: false)
            let rc = decodeBatch(advancing: [0])
            guard rc == 0 else {
                dropSequence(0)
                _ = llama_memory_seq_rm(memory, scratch, -1, -1)
                throw rc == 2 ? CancellationError() : decodeError(rc)
            }
            llama_memory_seq_cp(memory, scratch, 0, -1, -1)
            _ = llama_memory_seq_rm(memory, scratch, -1, -1)
        }
        seqTokens[0] = Array(tokens[0..<(keep + s.skip + s.matched)])
        logits[0] = nil
        return true
    }

    /// Log-softmax of the logits after the prompt plus the first `count` speculated tokens
    /// (`count` 0 = the prompt itself). Valid until the next decode.
    public func logProbs(speculated count: Int, into buffer: inout [Float]) throws {
        try checkOpen()
        guard let spec = speculation, count >= 0, count <= spec.draft.count, count < spec.rows.count else {
            throw LlamaError.noLogits(0)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            profile.logProbCalls += 1
            profile.logProbNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0)
        }
        if buffer.count != nVocab { buffer = [Float](repeating: 0, count: nVocab) }
        switch spec.rows[count] {
        case .saved(let row):
            if count > 0 { profile.memoRows += 1 }
            try row.withUnsafeBufferPointer { try Self.logSoftmax($0, into: &buffer, scratch: &scratch) }
        case .batch(let e, let index):
            guard e == epoch, let ptr = llama_get_logits_ith(ctx, index) else { throw LlamaError.noLogits(0) }
            llama_synchronize(ctx)
            profile.gpuWaitNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0)
            let raw = UnsafeBufferPointer(start: ptr, count: nVocab)
            remember(path: Array((seqTokens[0] ?? []).prefix(spec.base + count))) { Array(raw) }
            try Self.logSoftmax(raw, into: &buffer, scratch: &scratch)
        }
    }

    /// Ends a speculation, keeping the prompt plus the first `count` draft tokens: the rest are
    /// trimmed from the KV cache and sequence 0's current logits become the row after the last kept
    /// token. If the cache refuses the trim, sequence 0 is dropped (the next sync re-prefills).
    public func settleSpeculation(keeping count: Int) {
        guard !closed, let spec = speculation else { return }
        speculation = nil
        let kept = max(0, min(count, spec.draft.count))
        profile.draftKept += kept
        let length = spec.base + kept
        if kept < spec.draft.count {
            let before = epoch
            guard rewindPrimary(to: length) else {
                // A cancelled re-read leaves sequence 0 at a checkpoint, which the next sync uses.
                if !executor.isCancellationRequested { dropSequence(0) }
                return
            }
            // Re-read after a checkpoint: the current logits are already the row after `length`.
            if epoch != before { return }
        }
        switch spec.rows[min(kept, spec.rows.count - 1)] {
        case .saved(let row): logits[0] = .saved(row)
        case .batch(let e, let index): logits[0] = e == epoch ? .row(epoch: e, index: index) : nil
        }
    }

    // MARK: - Parked prompt

    /// Whether a second prompt can be kept aside (a context with a spare sequence, on a cache that
    /// trims; checkpoints describe sequence 0 only).
    public var canParkPrompt: Bool {
        parkedSeq != nil && (reuseCapability == .trimSuffix || reuseCapability == .trimAndShift)
    }

    /// Prompt tokens currently parked (empty when none).
    public var parkedPromptTokens: [TokenID] { parkedSeq.flatMap { seqTokens[$0] } ?? [] }

    /// Swaps sequence 0 with the parked prompt, so two kinds of request (suggestions and the
    /// rewrite pass) each keep their own prompt cache: a request of the other kind swaps in, syncs
    /// and works on sequence 0 as usual, and swaps back after. Branches are dropped and a live
    /// speculation is settled with nothing kept. Sequence 0's current row goes along with its
    /// prompt. Cell copies only (`kv_unified`): no decode. A no-op when `canParkPrompt` is false.
    public func swapParkedPrompt() throws {
        try checkOpen()
        guard canParkPrompt, let p = parkedSeq else { return }
        settleSpeculation(keeping: 0)
        for seq in seqTokens.keys where seq != 0 && seq != p { dropSequence(seq) }
        let spare: Int32 = 1
        let primary = seqTokens[0], parked = seqTokens[p]
        var row: [Float]?
        switch logits[0] {
        case .saved(let r)?: row = r
        case .row(let e, let index)? where e == epoch:
            row = llama_get_logits_ith(ctx, index).map { Array(UnsafeBufferPointer(start: $0, count: nVocab)) }
        default: row = nil
        }
        _ = llama_memory_seq_rm(memory, spare, -1, -1)
        if primary != nil { llama_memory_seq_cp(memory, 0, spare, -1, -1) }
        _ = llama_memory_seq_rm(memory, 0, -1, -1)
        if parked != nil { llama_memory_seq_cp(memory, p, 0, -1, -1) }
        _ = llama_memory_seq_rm(memory, p, -1, -1)
        if primary != nil { llama_memory_seq_cp(memory, spare, p, -1, -1) }
        _ = llama_memory_seq_rm(memory, spare, -1, -1)
        seqTokens[0] = parked
        seqTokens[p] = primary
        logits[0] = parked != nil ? parkedRow.map { .saved($0) } : nil
        logits[p] = nil
        parkedRow = primary != nil ? row : nil
    }

    // MARK: - Fork / step / discard

    public func fork(_ source: SeqID, into targets: [SeqID]) throws {
        try checkOpen()
        settleSpeculation(keeping: 0)
        guard isValid(source), let tokens = seqTokens[source.raw], !tokens.isEmpty else {
            throw LlamaError.invalidSequence(source.raw)
        }
        for target in targets where target != source {
            guard isValid(target) else { throw LlamaError.invalidSequence(target.raw) }
            _ = llama_memory_seq_rm(memory, target.raw, -1, -1)
            llama_memory_seq_cp(memory, source.raw, target.raw, -1, -1)
            seqTokens[target.raw] = tokens
            logits[target.raw] = logits[source.raw]
        }
    }

    public func step(_ appends: [(SeqID, TokenID)]) throws {
        try checkOpen()
        guard !appends.isEmpty else { return }
        settleSpeculation(keeping: 0)
        var seen = Set<Int32>()
        for (seq, token) in appends {
            guard isValid(seq), seen.insert(seq.raw).inserted, let t = seqTokens[seq.raw], !t.isEmpty else {
                throw LlamaError.invalidSequence(seq.raw)
            }
            guard token >= 0, Int(token) < nVocab else { throw LlamaError.decodeFailed(-1) }
            if t.count + 1 >= nCtxSeq { throw LlamaError.contextFull }
        }
        if executor.isCancellationRequested { throw CancellationError() }

        batch.n_tokens = 0
        for (seq, token) in appends {
            appendToBatch(token, pos: seqTokens[seq.raw]!.count, seq: seq.raw, wantLogits: true)
        }
        let rc = decodeBatch(advancing: seen)
        guard rc == 0 else {
            // Roll back anything a partial/aborted decode left behind. A recurrent state can't be
            // rolled back in place (and an aborted decode may have half-written it): sequence 0
            // goes back to a checkpoint, branches are dropped.
            for (seq, _) in appends {
                let pos = Int32(seqTokens[seq.raw]!.count)
                if reuseCapability == .checkpoint {
                    if seq == .primary { _ = restoreCheckpoint(atMost: Int(pos)) } else { dropSequence(seq.raw) }
                } else if !llama_memory_seq_rm(memory, seq.raw, pos, -1) {
                    dropSequence(seq.raw)
                }
            }
            throw rc == 2 ? CancellationError() : decodeError(rc)
        }
        for (index, (seq, token)) in appends.enumerated() {
            seqTokens[seq.raw]!.append(token)
            logits[seq.raw] = .row(epoch: epoch, index: Int32(index))
        }
    }

    public func discard(_ seqs: [SeqID]) {
        guard !closed else { return }
        for seq in seqs where isValid(seq) { dropSequence(seq.raw) }
    }

    // MARK: - Log-probs

    public func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {
        try checkOpen()
        guard let source = logits[seq.raw] else { throw LlamaError.noLogits(seq.raw) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            profile.logProbCalls += 1
            profile.logProbNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0)
        }
        if buffer.count != nVocab { buffer = [Float](repeating: 0, count: nVocab) }
        if case .row = source {
            llama_synchronize(ctx) // decode is asynchronous on Metal; separate the GPU wait from the CPU math
            profile.gpuWaitNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0)
        }
        // While a speculation is live, sequence 0 holds prompt + draft but its current logits are the prompt's.
        var path = seqTokens[seq.raw] ?? []
        if seq == .primary, let spec = speculation { path = Array(path.prefix(spec.base)) }
        switch source {
        case .row(let e, let index):
            guard e == epoch, let ptr = llama_get_logits_ith(ctx, index) else { throw LlamaError.noLogits(seq.raw) }
            let raw = UnsafeBufferPointer(start: ptr, count: nVocab)
            remember(path: path) { Array(raw) }
            try Self.logSoftmax(raw, into: &buffer, scratch: &scratch)
        case .saved(let row):
            remember(path: path) { row }
            try row.withUnsafeBufferPointer { try Self.logSoftmax($0, into: &buffer, scratch: &scratch) }
        }
    }

    /// Numerically stable log-softmax: x - max - log(sum(exp(x - max))). Gemma's final-logit
    /// softcapping is already applied inside llama.cpp, so nothing is re-applied here.
    static func logSoftmax(_ input: UnsafeBufferPointer<Float>, into out: inout [Float], scratch: inout [Float]) throws {
        let n = input.count
        guard n > 0, let src = input.baseAddress else { return }
        if out.count != n { out = [Float](repeating: 0, count: n) }
        if scratch.count != n { scratch = [Float](repeating: 0, count: n) }
        var maxValue: Float = 0
        vDSP_maxv(src, 1, &maxValue, vDSP_Length(n))
        guard maxValue.isFinite else { throw LlamaError.decodeFailed(-2) }
        var negMax = -maxValue
        var sum: Float = 0
        out.withUnsafeMutableBufferPointer { o in
            scratch.withUnsafeMutableBufferPointer { s in
                vDSP_vsadd(src, 1, &negMax, o.baseAddress!, 1, vDSP_Length(n))
                var count = Int32(n)
                vvexpf(s.baseAddress!, o.baseAddress!, &count)
                vDSP_sve(s.baseAddress!, 1, &sum, vDSP_Length(n))
                var negLog = -logf(sum)
                vDSP_vsadd(o.baseAddress!, 1, &negLog, o.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }

    // MARK: - Internals (also used by tests and the load-time probe)

    /// Largest KV position held for `seq`, or -1 if empty.
    func memoryPosMax(_ seq: SeqID) -> Int32 { llama_memory_seq_pos_max(memory, seq.raw) }

    func cachedTokens(_ seq: SeqID) -> [TokenID] { seqTokens[seq.raw] ?? [] }

    /// Test seam: decodes `tokens` into `seq` at explicit positions starting at `position` (logits on
    /// the last token), appending them to the sequence's record. Returns llama's return code.
    func decodeRaw(_ tokens: [TokenID], at position: Int, seq: SeqID = .primary) -> Int32 {
        fillBatch(tokens[...], startPos: position, seq: seq.raw, logitsOnLast: true)
        let rc = decodeBatch(advancing: [seq.raw])
        guard rc == 0 else { return rc }
        seqTokens[seq.raw, default: []].append(contentsOf: tokens)
        logits[seq.raw] = .row(epoch: epoch, index: Int32(batch.n_tokens - 1))
        return rc
    }

    /// Test seam: `llama_memory_seq_add` over positions `from...` of `seq` (applied by the next decode).
    func shiftPositions(_ seq: SeqID, from p0: Int, by delta: Int) {
        llama_memory_seq_add(memory, seq.raw, Int32(p0), -1, Int32(delta))
    }

    /// Tokens sequence 0 really holds in the KV cache right now (after a failed or cancelled sync,
    /// the prefix that survived). Executor-confined like every other member.
    public var retainedPromptTokens: [TokenID] { closed ? [] : (seqTokens[0] ?? []) }

    /// Decides `.trimAndShift` / `.trimSuffix` / `.none`: decode a short probe into seq 0 and check
    /// that a partial `seq_rm` of its tail succeeds and leaves exactly the kept positions; trimming
    /// plus `llama_memory_can_shift` gives `.trimAndShift`. Clears the memory after.
    func probeReuseCapability() -> ReuseCapability {
        defer {
            llama_memory_clear(memory, false)
            checkpoints.removeAll()
            speculation = nil
            seqTokens.removeAll()
            logits.removeAll()
        }
        guard var probe = try? tokenizeText("Hunch checks whether the cache can be trimmed safely.", parseSpecial: false),
              probe.count >= 4 else { return .none }
        let bos = llama_vocab_bos(vocab)
        if bos != LLAMA_TOKEN_NULL { probe.insert(bos, at: 0) }
        probe = Array(probe.prefix(nBatch))
        llama_memory_clear(memory, false)
        fillBatch(probe[...], startPos: 0, seq: 0, logitsOnLast: true)
        guard decodeBatch(advancing: [0]) == 0 else { return .none }
        let keep = Int32(probe.count / 2)
        guard llama_memory_seq_rm(memory, 0, keep, -1),
              llama_memory_seq_pos_max(memory, 0) == keep - 1 else {
            return probeCheckpoints(probe) ? .checkpoint : .none
        }
        return llama_memory_can_shift(memory) ? .trimAndShift : .trimSuffix
    }

    /// For caches that refuse a partial trim (hybrid/recurrent models): decode the first half of
    /// `probe`, save the partial state, decode the rest, then go back to the saved state, re-read
    /// the rest and require the same final logits. Any model that passes gets checkpoints.
    private func probeCheckpoints(_ probe: [TokenID]) -> Bool {
        let half = probe.count / 2
        guard half > 0 else { return false }
        llama_memory_clear(memory, false)
        seqTokens.removeAll()
        logits.removeAll()
        fillBatch(probe[..<half], startPos: 0, seq: 0, logitsOnLast: true)
        guard decodeBatch(advancing: [0]) == 0, let state = capturePartialState() else { return false }
        fillBatch(probe[half...], startPos: half, seq: 0, logitsOnLast: true)
        guard decodeBatch(advancing: [0]) == 0,
              let ptr = llama_get_logits_ith(ctx, batch.n_tokens - 1) else { return false }
        let reference = Array(UnsafeBufferPointer(start: ptr, count: nVocab))
        let restored = state.withUnsafeBufferPointer {
            llama_state_seq_set_data_ext(ctx, $0.baseAddress, $0.count, 0, Self.partialState)
        }
        guard restored > 0, llama_memory_seq_rm(memory, 0, Int32(half), -1),
              llama_memory_seq_pos_max(memory, 0) == Int32(half - 1) else { return false }
        fillBatch(probe[half...], startPos: half, seq: 0, logitsOnLast: true)
        guard decodeBatch(advancing: [0]) == 0,
              let again = llama_get_logits_ith(ctx, batch.n_tokens - 1) else { return false }
        var worst: Float = 0
        for i in 0..<nVocab { worst = max(worst, abs(again[i] - reference[i])) }
        return worst.isFinite && worst < 1e-2
    }

    // MARK: - Checkpoints (ReuseCapability.checkpoint)

    /// Sequence 0's partial (recurrent) state as bytes, or nil if llama can't provide it.
    private func capturePartialState() -> [UInt8]? {
        let size = llama_state_seq_get_size_ext(ctx, 0, Self.partialState)
        guard size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeMutableBufferPointer {
            llama_state_seq_get_data_ext(ctx, $0.baseAddress, size, 0, Self.partialState)
        }
        guard written > 0, written <= size else { return nil }
        if written < size { data.removeLast(size - written) }
        return data
    }

    /// Saves a checkpoint at sequence 0's current length. Only right after a successful decode
    /// that left sequence 0 holding exactly `seqTokens[0]` (no draft in it).
    private func saveCheckpoint() {
        guard reuseCapability == .checkpoint, speculation == nil, let n = seqTokens[0]?.count, n > 0,
              !checkpoints.contains(position: n) else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { profile.checkpointNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0) }
        guard let data = capturePartialState() else { return }
        checkpoints.insert(position: n, data: data)
        profile.checkpointSaves += 1
    }

    /// Goes back to the newest checkpoint at or before `limit`: sequence 0 then holds exactly the
    /// tokens up to it, without current logits. Returns the kept length; 0 means sequence 0 was
    /// dropped (no usable checkpoint, or llama refused).
    @discardableResult
    private func restoreCheckpoint(atMost limit: Int) -> Int {
        guard let held = seqTokens[0], let entry = checkpoints.latest(atMost: min(limit, held.count)) else {
            dropSequence(0)
            return 0
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { profile.checkpointNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0) }
        speculation = nil
        let restored = entry.data.withUnsafeBufferPointer {
            llama_state_seq_set_data_ext(ctx, $0.baseAddress, $0.count, 0, Self.partialState)
        }
        guard restored > 0, llama_memory_seq_rm(memory, 0, Int32(entry.position), -1),
              llama_memory_seq_pos_max(memory, 0) == Int32(entry.position - 1) else {
            dropSequence(0)
            return 0
        }
        seqTokens[0] = Array(held.prefix(entry.position))
        logits[0] = nil
        checkpoints.drop(after: entry.position)
        profile.checkpointRestores += 1
        return entry.position
    }

    /// Trims sequence 0 to at most `keep` tokens and returns how many it holds afterwards (0 =
    /// dropped). Exact on trimmable caches; on a checkpoint cache it goes back to the nearest
    /// checkpoint at or before `keep`. Sequence 0 is left without current logits when trimmed.
    private func trimPrimary(to keep: Int) -> Int {
        let held = seqTokens[0]?.count ?? 0
        if keep >= held { return held }
        guard keep > 0 else {
            dropSequence(0)
            return 0
        }
        switch reuseCapability {
        case .trimSuffix, .trimAndShift:
            guard llama_memory_seq_rm(memory, 0, Int32(keep), -1) else {
                dropSequence(0)
                return 0
            }
            seqTokens[0] = Array(seqTokens[0]!.prefix(keep))
            logits[0] = nil
            return keep
        case .checkpoint:
            return restoreCheckpoint(atMost: keep)
        case .none:
            dropSequence(0)
            return 0
        }
    }

    /// Brings sequence 0 back to exactly its first `length` tokens. On a checkpoint cache: the
    /// nearest checkpoint, then the tokens after it are re-read, logits on the last (they become
    /// sequence 0's current logits). False = not reached: sequence 0 was dropped, or (cancelled
    /// re-read) left at the checkpoint.
    private func rewindPrimary(to length: Int) -> Bool {
        guard let held = seqTokens[0], length > 0, length <= held.count else { return false }
        if length == held.count { return true }
        let kept = trimPrimary(to: length)
        if kept == length { return true }
        guard kept > 0 else { return false }
        var position = kept
        while position < length {
            let end = min(position + nBatch, length)
            fillBatch(held[position..<end], startPos: position, seq: 0, logitsOnLast: end == length)
            guard decodeBatch(advancing: [0]) == 0 else {
                restoreCheckpoint(atMost: kept)
                return false
            }
            seqTokens[0]!.append(contentsOf: held[position..<end])
            profile.replayedTokens += end - position
            position = end
        }
        logits[0] = .row(epoch: epoch, index: Int32(batch.n_tokens - 1))
        return true
    }

    private func checkOpen() throws {
        if closed { throw LlamaError.sessionClosed }
        assert(executor.isOnExecutorThread, "LlamaSession used off the generation executor")
    }

    private func isValid(_ seq: SeqID) -> Bool { seq.raw >= 0 && Int(seq.raw) < maxParallelSequences }

    private func dropSequence(_ seq: Int32) {
        if seq == 0 {
            speculation = nil
            checkpoints.removeAll() // they need the attention cells kept for sequence 0
        }
        if seq == parkedSeq { parkedRow = nil }
        _ = llama_memory_seq_rm(memory, seq, -1, -1)
        seqTokens[seq] = nil
        logits[seq] = nil
    }

    private func commonPrefix(_ a: [TokenID], _ b: [TokenID]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }

    private func fillBatch(_ tokens: ArraySlice<TokenID>, startPos: Int, seq: Int32, logitsOnLast: Bool) {
        batch.n_tokens = 0
        var pos = startPos
        for (offset, token) in tokens.enumerated() {
            appendToBatch(token, pos: pos, seq: seq, wantLogits: logitsOnLast && offset == tokens.count - 1)
            pos += 1
        }
    }

    private func appendToBatch(_ token: TokenID, pos: Int, seq: Int32, wantLogits: Bool) {
        let i = Int(batch.n_tokens)
        batch.token[i] = token
        batch.pos[i] = llama_pos(pos)
        batch.n_seq_id[i] = 1
        batch.seq_id[i]![0] = seq
        batch.logits[i] = wantLogits ? 1 : 0
        batch.n_tokens += 1
    }

    /// Runs `llama_decode` on the prepared batch. Before it overwrites llama's logits buffer, the
    /// latest logits of every sequence NOT being advanced are copied out so they stay readable.
    private func decodeBatch(advancing: Set<Int32>) -> Int32 {
        for (seq, source) in logits {
            guard case .row(let e, let index) = source, e == epoch else { continue }
            if advancing.contains(seq) {
                logits[seq] = nil
            } else if let ptr = llama_get_logits_ith(ctx, index) {
                logits[seq] = .saved(Array(UnsafeBufferPointer(start: ptr, count: nVocab)))
            } else {
                logits[seq] = nil
            }
        }
        epoch += 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        let rc = llama_decode(ctx, batch)
        profile.decodeCalls += 1
        profile.decodeTokens += Int(batch.n_tokens)
        profile.decodeNanos += Int64(DispatchTime.now().uptimeNanoseconds - t0)
        return rc
    }

    /// After a failed/aborted prompt decode, processed ubatches may remain in memory: realign
    /// the bookkeeping with what the cache really holds. With a shift still pending (the failed
    /// decode was the one meant to apply it) the moved cells cannot be trusted: sequence 0 is dropped.
    private func reconcilePromptAfterFailure(_ tokens: [TokenID], shiftPending: Bool) {
        if shiftPending {
            dropSequence(0)
            return
        }
        if reuseCapability == .checkpoint {
            // The aborted piece may have half-written the recurrent state: back to the checkpoint
            // after the last piece that succeeded.
            let held = seqTokens[0]?.count ?? 0
            if held > 0 { _ = restoreCheckpoint(atMost: held) } else { dropSequence(0) }
            return
        }
        let posMax = Int(llama_memory_seq_pos_max(memory, 0))
        let held = max(0, min(posMax + 1, tokens.count))
        // A speculated draft may have been written past the prompt before the abort.
        if posMax + 1 > tokens.count, !llama_memory_seq_rm(memory, 0, Int32(tokens.count), -1) {
            dropSequence(0)
            return
        }
        seqTokens[0] = Array(tokens[0..<held])
        logits[0] = nil
        if held == 0 { seqTokens[0] = nil }
    }

    private func decodeError(_ rc: Int32) -> LlamaError {
        rc == 1 ? .contextFull : .decodeFailed(rc)
    }
}
