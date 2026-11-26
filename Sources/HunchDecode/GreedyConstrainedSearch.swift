import Foundation
import HunchCore

/// Deterministic constrained search over raw log-probabilities (design §5.2). No sampling.
///
/// Shape: a small set of first-token "roots", each extended greedily, all live branches advanced
/// with one batched `step` per iteration. With `firstTokenFanout` = 1 and no word-boundary
/// question there is exactly one root, on `SeqID.primary`, and the search is plain greedy.
///
/// Roots (see `RootPlanner`):
/// - **Word-boundary decision.** When the healed required prefix ends inside a word (" an", " hea")
///   and a token spells the prefix exactly, the search asks whether that word is already complete.
///   It decodes the exact token on a forked sequence (batched with the best longer tokens) and
///   compares, at the word level, P(typed word is complete) (exact token followed by any
///   boundary) against the most likely single longer word (a longer token, or the exact token
///   followed by a word character). The winner's best concrete option becomes the root. When the
///   best longer token alone beats the bound on "complete", the extra decode is skipped. This fixes "I am an" → " a" + "note" (a split no
///   tokenizer would produce) while "Looking forward to hea" still becomes "hearing".
/// - **Fan-out (k ≥ 2).** The k best first tokens (or first options of the boundary decision)
///   each get their own sequence; branches are ranked by raw path log-prob (`.sum`) or its
///   per-token mean (`.mean`). Confident branches rank above low-confidence ones.
///
/// Preconditions: the prompt has been synced into `SeqID.primary` and its last logits are current.
/// Postcondition: the winning branch's tokens are in `SeqID.primary` (copied there if it ran on
/// another sequence); other sequences used by the search are discarded.
///
/// Confidence trim (`DecodeConfig.trimEnabled`): each finished branch whose per-token confidence
/// drops partway is cut back (see `ConfidenceTrim`) before the confidence floor is applied, so the
/// floor judges the text that would be shown. Ranking between branches is unchanged.
///
/// Candidate statistics (`meanLogProb`, `totalLogProb`, used by the confidence floor): tokens whose
/// bytes lie entirely inside the required prefix are forced and excluded. A token that crosses the
/// end of the required prefix (" a" required, " apple" chosen) contributes its log-prob
/// renormalized over the admissible set, i.e. log P(token | it must start with the required
/// bytes). Non-finite log-probs are clamped to `logProbFloor`. Ranking between branches uses the
/// raw (unconditional) log-probs of every token, forced ones included, so paths that spell the
/// prefix differently stay comparable.
///
/// Newlines: with `allowNewline` off, newline tokens are never emitted; if the model's best choice
/// is a newline, the branch stops with `.newline` (the line is finished) instead of being forced
/// onto a less likely token.
///
/// Learned bias (`LearnedBias`): changes the CHOICE only. Candidate scores, the confidence floor and
/// per-word scores are raw model log-probs. Tokens that keep an in-progress word (or phrase)
/// consistent with a learned entry get `weight * strength` added to their log-prob when the next
/// token is chosen; see `CompiledBias`. Required-prefix admissibility is never relaxed.
///
/// Partial callbacks carry `stop: .inProgress` and follow the first root only (the one plain
/// greedy would pick).
public struct GreedyConstrainedSearch: BiasedCompletionSearching {
    public static let logProbFloor: Float = -100
    /// Upper bound on `DecodeConfig.firstTokenFanout` (design §5.2: k ≤ 3).
    public static let maxFanout = 3

    public init() {}

    public func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                       onPartial: (Candidate) -> Void) throws -> [Candidate] {
        try searchScored(in: session, requiredPrefix: requiredPrefix, config: config, bias: LearnedBias(),
                         onPartial: onPartial).map(\.candidate)
    }

    public func searchScored(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                             bias: LearnedBias, onPartial: (Candidate) -> Void) throws -> [ScoredCandidate] {
        // A session holding a pre-decoded draft is wrapped so the draft is consumed transparently;
        // the wrapper settles (trims the unused draft from the KV cache) however the search ends.
        let drafting = config.firstTokenFanout <= 1 ? DraftingSession(session) : nil
        defer { drafting?.settle() }
        let run = SearchRun(session: drafting ?? session, config: config, required: requiredPrefix[...], bias: bias)
        return try run.execute(onPartial: onPartial)
    }
}

// MARK: - One search

final class SearchRun {
    let session: any LanguageModelSession
    let vocabulary: any VocabularyTable
    let classes: TokenClasses
    let config: DecodeConfig
    let required: ArraySlice<UInt8>
    let bias: CompiledBias?
    let biasStrength: Float
    /// Trie of blocked words (nil when none); its progress deltas are subtracted, scaled by the penalty.
    let avoid: CompiledBias?
    let avoidPenalty: Float
    /// Learned phrases anchored at the start of the stream (required prefix included), nil when off.
    let phrases: CompiledBias?
    let phraseStrength: Float

    init(session: any LanguageModelSession, config: DecodeConfig, required: ArraySlice<UInt8>,
         bias learned: LearnedBias = LearnedBias()) {
        self.session = session
        self.vocabulary = session.vocabulary
        self.classes = TokenClassCache.shared.classes(for: session.vocabulary)
        self.config = config
        self.required = required
        if learned.entries.isEmpty || learned.strength <= 0 {
            self.bias = nil
        } else {
            self.bias = CompiledBias.make(vocabulary: session.vocabulary, classes: classes, entries: learned.entries)
        }
        self.biasStrength = learned.strength
        if learned.avoid.isEmpty || learned.avoidPenalty <= 0 {
            self.avoid = nil
        } else {
            self.avoid = CompiledBias.make(vocabulary: session.vocabulary, classes: classes,
                                           entries: CompiledBias.avoidEntries(learned.avoid), avoid: true)
        }
        self.avoidPenalty = learned.avoidPenalty
        if learned.phrases.isEmpty || learned.phraseStrength <= 0 {
            self.phrases = nil
        } else {
            // Phrase texts continue the typed text at the caret; the stream starts with the
            // required prefix (healed spaces and partial word), so each entry is that plus the text.
            let lead = String(decoding: required, as: UTF8.self)
            self.phrases = CompiledBias.make(vocabulary: session.vocabulary, classes: classes,
                                             entries: learned.phrases.map { .init(text: lead + $0.text, weight: $0.weight) },
                                             anchored: true)
        }
        self.phraseStrength = learned.phraseStrength
    }

    /// Bias added to candidate next tokens given the match state (empty without a learned bias).
    /// Blocked words contribute negative values that telescope like the positive bonus. Learned
    /// phrases add theirs only to tokens the model itself gives at least
    /// `LearnedBias.phraseMinLogProb` in `logProbs` (no phrase bonus without them). While the
    /// typed prefix is being forced, `condition` is the log of the admissible pool's total mass,
    /// so the floor applies to the probability given the typed letters (" bed" after "b").
    func biasMap(_ state: BiasState, logProbs: [Float]? = nil, condition: Float = 0) -> [TokenID: Float] {
        var out = bias?.map(state, strength: biasStrength) ?? [:]
        if let phrases, let logProbs, !state.phrase.nodes.isEmpty || state.phrase.previous == nil {
            for (id, extra) in phrases.map(state.phrase, strength: phraseStrength)
            where extra > 0 && clamp(logProbs, id) - condition >= LearnedBias.phraseMinLogProb {
                out[id, default: 0] += extra
            }
        }
        if let avoid {
            for (id, penalty) in avoid.map(state.avoid, strength: avoidPenalty) where penalty > 0 {
                out[id, default: 0] -= penalty
            }
        }
        return out
    }

    /// Log of the total probability of `pool` (log-sum-exp of its log-probs).
    func poolMass(_ logProbs: [Float], _ pool: [TokenID]) -> Float {
        guard phrases != nil, !pool.isEmpty else { return 0 }
        let top = pool.map { clamp(logProbs, $0) }.max() ?? 0
        var sum: Float = 0
        for id in pool { sum += expf(clamp(logProbs, id) - top) }
        return top + logf(sum)
    }

    /// Advances both match states over the bytes of a chosen token.
    func advanceBias(_ state: inout BiasState, _ bytes: ArraySlice<UInt8>) {
        bias?.advance(&state, bytes)
        avoid?.advance(&state.avoid, bytes)
        phrases?.advance(&state.phrase, bytes)
    }

    func execute(onPartial: (Candidate) -> Void) throws -> [ScoredCandidate] {
        if session.isCancellationRequested { throw CancellationError() }
        var root: [Float] = []
        try session.logProbs(.primary, into: &root)
        var branches = try RootPlanner(run: self).roots(rootLogProbs: root)
        root = []
        if let first = branches.first, !first.text.isEmpty { onPartial(first.candidate(stop: .inProgress)) }

        var buffer: [Float] = []
        while true {
            if session.isCancellationRequested { throw CancellationError() }
            for index in branches.indices where branches[index].stop == nil && branches[index].pending == nil {
                if let preloaded = branches[index].preloaded {
                    buffer = preloaded
                    branches[index].preloaded = nil
                } else {
                    try session.logProbs(branches[index].seq, into: &buffer)
                }
                let before = branches[index].text
                branches[index].pending = advance(&branches[index], logProbs: buffer)
                if index == 0, branches[index].text != before {
                    onPartial(branches[index].candidate(stop: .inProgress))
                }
            }
            let appends: [(SeqID, TokenID)] = branches.compactMap { branch in
                guard branch.stop == nil, let token = branch.pending else { return nil }
                return (branch.seq, token)
            }
            if appends.isEmpty { break }
            if session.isCancellationRequested { throw CancellationError() }
            try session.step(appends)
            for index in branches.indices { branches[index].pending = nil }
        }
        return try finish(branches)
    }

    private func finish(_ branches: [Branch]) throws -> [ScoredCandidate] {
        var ranked: [(candidate: ScoredCandidate, rank: Float, seq: SeqID)] = []
        for branch in branches where !branch.unsatisfiable {
            var kept = branch
            var (stop, trimmed) = judge(kept)
            // A held continuation whose added text is unsure falls back to the text before the hold
            // (where the model ended its turn). This also covers a held suggestion that fails the
            // floor: with the added text above the gate, the text before it would fail too.
            if config.holdEndBelowMinWords, let before = branch.beforeHold,
               Self.tailMean(trimmed?.spans ?? kept.spans, from: before) < config.holdTailMinLogProb {
                kept = branch.cut(toBytes: before)
                (stop, trimmed) = judge(kept)
                if stop != .lowConfidence, trimmed == nil { stop = .endOfGeneration }
            }
            // Ranking includes the learned bonus (it steers the choice); statistics stay raw.
            let rank: Float
            let steered = branch.raw + branch.bonus
            switch config.scoring {
            case .sum: rank = steered
            case .mean: rank = branch.tokens.isEmpty ? steered : steered / Float(branch.tokens.count)
            }
            ranked.append((kept.scored(stop: stop, trimmed: trimmed), rank, branch.seq))
        }
        // Stable: ties keep root order (the first root is what plain greedy would pick).
        ranked = ranked.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            let lLow = l.candidate.candidate.stop == .lowConfidence, rLow = r.candidate.candidate.stop == .lowConfidence
            if lLow != rLow { return !lLow }
            if l.rank != r.rank { return l.rank > r.rank }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let used = Set(branches.map(\.seq))
        if used.count > 1 || used.first != .primary {
            if let winner = ranked.first, winner.seq != .primary {
                try session.fork(winner.seq, into: [.primary])
            }
            session.discard(used.filter { $0 != .primary }.sorted { $0.raw < $1.raw })
        }
        return ranked.map(\.candidate)
    }

    /// Stop reason after the confidence trim and floor (`ConfidenceFloor`), and the trim (nil when nothing is cut).
    private func judge(_ branch: Branch) -> (StopReason, ConfidenceTrim.Result?) {
        let trimmed = trim(branch)
        if branch.scoredCount > 0,
           ConfidenceFloor.check(text: trimmed?.text ?? branch.text, mean: trimmed?.meanLogProb ?? branch.mean,
                                 firstLogProb: branch.spans.first?.logProb,
                                 midWord: ConfidenceFloor.isMidWord(requiredPrefix: required), config: config) != nil {
            return (.lowConfidence, trimmed)
        }
        return (trimmed != nil ? .confidenceTrim : branch.stop ?? .tokenCap, trimmed)
    }

    /// The confidence trim of a finished branch (nil when off or nothing is cut). The 2-word
    /// minimum of the app holds even under the short preset.
    private func trim(_ branch: Branch) -> ConfidenceTrim.Result? {
        guard config.trimEnabled, branch.scoredCount > 0 else { return nil }
        return ConfidenceTrim.trim(text: branch.text, spans: branch.spans, dropLogProb: config.trimDropLogProb,
                                   window: config.trimWindow, minWords: max(2, config.minWords))
    }

    // MARK: - One step of one branch

    /// Chooses (or takes `choose`) and accepts the next token for `branch`. Returns the token to
    /// decode, or nil when the branch stopped (a stopping token is not part of the candidate and
    /// is not decoded).
    func advance(_ branch: inout Branch, logProbs: [Float], choose: TokenID? = nil) -> TokenID? {
        if !branch.required.isEmpty { return advanceForced(&branch, logProbs: logProbs, choose: choose) }
        return advanceFree(&branch, logProbs: logProbs, choose: choose)
    }

    func advanceFree(_ branch: inout Branch, logProbs: [Float], choose: TokenID? = nil) -> TokenID? {
        let map = biasMap(branch.bias, logProbs: logProbs)
        guard var token = choose ?? chooseFree(logProbs, map: map) else {
            branch.stop = .endOfGeneration
            return nil
        }
        var kind = classes.kind(token)
        // Hold the end of the turn (and a newline) until the minimum word count: take the best
        // ordinary token instead. Tokens that start markup are skipped: with the end held, the model's
        // next choice is often the framer's closing tag ("</blockquote>"). Not for CJK text: judged
        // 2026-11-05, held Chinese suggestions mostly added a confident but invented second sentence.
        if choose == nil, config.holdEndBelowMinWords, kind == .endOfGeneration || kind == .newline,
           branch.finishing == nil, TextRules.wordCount(branch.text) < config.minWords,
           !branch.text.unicodeScalars.contains(where: TextRules.isCJK),
           let next = classes.top(logProbs, count: 1, include: { [vocabulary] id, k in
               k == .normal && vocabulary.bytes(id).first(where: { $0 != 0x20 }) != 0x3C
           }).first {
            if branch.beforeHold == nil { branch.beforeHold = branch.text.utf8.count }
            token = next
            kind = .normal
        }
        if let finishing = branch.finishing {
            return finishWord(&branch, finishing: finishing, logProbs: logProbs, map: map)
        }
        let pendingStop: StopReason? = branch.pendingSentenceEnd ? .sentenceEnd : nil
        if kind == .endOfGeneration {
            // Ending the turn on a half-word ("thes"): take the best token that continues it instead.
            // Only when the model itself thinks the word goes on (more probability on continuing it
            // than on any boundary): after a whole word ("update") it would otherwise turn it into
            // another one ("updates").
            if pendingStop == nil, Self.endsMidWord(branch.text), wordGoesOn(logProbs),
               let next = bestContinuation(logProbs) {
                branch.finishing = (0, .endOfGeneration)
                return finishWord(&branch, finishing: (0, .endOfGeneration), logProbs: logProbs, map: map, choose: next)
            }
            branch.stop = pendingStop ?? .endOfGeneration
            return nil
        }
        let bytes = vocabulary.bytes(token)
        if kind == .newline, !config.allowNewline {
            branch.stop = pendingStop ?? .newline
            return nil
        }
        if branch.pendingSentenceEnd, let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A {
            branch.stop = .sentenceEnd
            return nil
        }
        let score = clamp(logProbs, token)
        let before = branch.tokens.count
        let result = accept(&branch, token: token, tail: bytes, score: score, raw: score, mayReject: true)
        if branch.tokens.count > before {
            branch.bonus += map[token] ?? 0
            advanceBias(&branch.bias, bytes)
        }
        return result
    }

    /// Mean log-prob of the spans that start at or after byte `from` (0 when there are none).
    static func tailMean(_ spans: [TokenSpan], from: Int) -> Float {
        var offset = 0
        var tail: [Float] = []
        for span in spans {
            if offset >= from { tail.append(span.logProb) }
            offset += span.byteCount
        }
        return tail.isEmpty ? 0 : tail.reduce(0, +) / Float(tail.count)
    }

    /// Extra tokens allowed past the token cap (or the end of the turn) to finish a half-word.
    static let maxWordFinishTokens = 3

    /// True when the text ends inside a word: its last character is a letter of an alphabetic
    /// script (not CJK, which has no word ends to finish) or an apostrophe.
    static func endsMidWord(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        if last == "'" || last == "\u{2019}" { return true }
        return last.properties.isAlphabetic && !TextRules.isCJK(last)
    }

    /// True when the model puts more probability on continuing the current word than on ending it
    /// (a space, punctuation, newline or the end of the turn).
    private func wordGoesOn(_ logProbs: [Float]) -> Bool {
        let mass = classes.boundaryMass(logProbs)
        return mass.continues > mass.ends
    }

    /// The best ordinary token that continues the current word.
    private func bestContinuation(_ logProbs: [Float]) -> TokenID? {
        classes.top(logProbs, count: 1, include: { [classes] id, k in k == .normal && classes.continuesWord(id) }).first
    }

    /// One step of finishing a cut word: while the model thinks the word goes on, its best
    /// continuation is taken (up to `maxWordFinishTokens`); otherwise the word is complete and the
    /// branch stops. A word still unfinished at the limit is dropped, with its statistics.
    private func finishWord(_ branch: inout Branch, finishing: (extra: Int, stop: StopReason), logProbs: [Float],
                            map: [TokenID: Float], choose: TokenID? = nil) -> TokenID? {
        guard let token = choose ?? (wordGoesOn(logProbs) ? bestContinuation(logProbs) : nil) else {
            branch.stop = finishing.stop
            return nil
        }
        guard finishing.extra < Self.maxWordFinishTokens else {
            let text = branch.text
            let wordStart = text.lastIndex(where: \.isWhitespace) ?? text.startIndex
            let stop = finishing.stop
            branch = branch.cut(toBytes: text.utf8.distance(from: text.utf8.startIndex, to: wordStart))
            branch.stop = stop
            return nil
        }
        branch.finishing = (finishing.extra + 1, finishing.stop)
        let bytes = vocabulary.bytes(token)
        let score = clamp(logProbs, token)
        let before = branch.tokens.count
        let result = accept(&branch, token: token, tail: bytes, score: score, raw: score, mayReject: false)
        if branch.tokens.count > before {
            branch.bonus += map[token] ?? 0
            advanceBias(&branch.bias, bytes)
        }
        return result
    }

    /// Argmax of log-prob plus learned bias. Biased tokens are sparse, so this is the plain argmax
    /// compared against each biased token (ties go to the lower id).
    private func chooseFree(_ logProbs: [Float], map: [TokenID: Float]) -> TokenID? {
        biasedArgmax(logProbs, map: map)
    }

    /// Argmax of log-prob plus `map`. Without penalties the plain argmax only needs comparing
    /// against the (sparse) boosted tokens. A penalized token can lose to ANY unbiased one, so
    /// when the map has a negative value the best token outside the map is found too.
    func biasedArgmax(_ logProbs: [Float], map: [TokenID: Float]) -> TokenID? {
        guard var best = classes.argmax(logProbs) else { return nil }
        if map.isEmpty { return best }
        var bestValue = clamp(logProbs, best) + (map[best] ?? 0)
        if map.values.contains(where: { $0 < 0 }), map[best] != nil,
           let free = classes.top(logProbs, count: 1, include: { id, _ in map[id] == nil }).first {
            best = free
            bestValue = clamp(logProbs, free)
        }
        for (id, extra) in map where id != best && Int(id) >= 0 && Int(id) < logProbs.count {
            let value = clamp(logProbs, id) + extra
            if value > bestValue || (value == bestValue && id < best) {
                best = id
                bestValue = value
            }
        }
        return best
    }

    /// Admissible tokens for the remaining required bytes: regular tokens (newline tokens only when
    /// the requirement itself has a newline); byte-fallback tokens only when nothing else fits.
    func forcedPool(_ required: ArraySlice<UInt8>, limit: Int) -> [TokenID] {
        let requiredHasNewline = required.contains(0x0A) || required.contains(0x0D)
        let candidates = vocabulary.admissible(forRequired: required)
        let admissible = candidates.filter { id in
            guard Int(id) >= 0, Int(id) < limit, !vocabulary.bytes(id).isEmpty else { return false }
            switch classes.kind(id) {
            case .normal: return true
            case .newline: return requiredHasNewline
            case .byteFallback, .blocked, .endOfGeneration: return false
            }
        }
        if !admissible.isEmpty { return admissible }
        return candidates.filter { classes.kind($0) == .byteFallback && Int($0) >= 0 && Int($0) < limit }
    }

    func advanceForced(_ branch: inout Branch, logProbs: [Float], choose: TokenID? = nil) -> TokenID? {
        let required = branch.required
        let pool = forcedPool(required, limit: logProbs.count)
        guard !pool.isEmpty else {
            branch.stop = .endOfGeneration
            branch.unsatisfiable = true
            return nil
        }
        let map = biasMap(branch.bias, logProbs: logProbs, condition: poolMass(logProbs, pool))
        var best = pool[0]
        var maxValue = -Float.infinity
        var bestSteered = -Float.infinity
        for id in pool {
            let value = clamp(logProbs, id)
            if value > maxValue { maxValue = value }
            let steered = value + (map[id] ?? 0)
            if steered > bestSteered {
                bestSteered = steered
                best = id
            }
        }
        if let choose { best = choose }
        let raw = clamp(logProbs, best)
        let bytes = vocabulary.bytes(best)
        let consumed = min(required.count, bytes.count)
        branch.required = required.dropFirst(consumed)
        let extensionBytes = bytes.dropFirst(consumed)
        if extensionBytes.isEmpty {
            branch.tokens.append(best)
            branch.raw += raw
            branch.bonus += map[best] ?? 0
            advanceBias(&branch.bias, bytes)
            if branch.tokens.count >= config.maxTokens { branch.stop = .tokenCap; return nil }
            return best
        }
        // Log-sum-exp over the admissible pool: the score is conditional on the forced bytes.
        var sum: Float = 0
        for id in pool { sum += expf(clamp(logProbs, id) - maxValue) }
        let conditional = raw - (maxValue + logf(sum))
        let result = accept(&branch, token: best, tail: extensionBytes, score: conditional, raw: raw, mayReject: false)
        branch.bonus += map[best] ?? 0
        advanceBias(&branch.bias, bytes)
        return result
    }

    /// Adds `token` (whose post-prefix bytes are `added`) and applies the stop rules.
    private func accept(_ branch: inout Branch, token: TokenID, tail added: ArraySlice<UInt8>, score: Float,
                        raw: Float, mayReject: Bool) -> TokenID? {
        var output = branch.output
        output.append(contentsOf: added)
        let text = output.text
        if mayReject, branch.scoredCount > 0, TextRules.wordCount(text) > config.maxWords {
            branch.stop = .wordBudget
            return nil
        }
        let previousCount = branch.text.count
        branch.output = output
        branch.tokens.append(token)
        branch.scoredCount += 1
        branch.total += score
        branch.raw += raw
        branch.text = text
        branch.spans.append(TokenSpan(byteCount: added.count, logProb: score))

        if config.stopAtComma,
           let comma = text.dropFirst(previousCount).firstIndex(where: { TextRules.commas.contains($0) }) {
            // Keep the text through the comma; anything after it in the same token is dropped.
            branch.text = String(text[...comma])
            branch.stop = .comma
            return nil
        }
        let words = TextRules.wordCount(text)
        branch.pendingSentenceEnd = false
        if config.stopAtSentenceEnd, words >= config.minWords {
            switch TextRules.sentenceState(text) {
            case .definite: branch.stop = .sentenceEnd; return nil
            case .tentative: branch.pendingSentenceEnd = true
            case .none: break
            }
        }
        if branch.tokens.count >= config.maxTokens {
            if branch.finishing != nil { return token }
            if Self.endsMidWord(branch.text) {
                branch.finishing = (0, .tokenCap)
                return token
            }
            branch.stop = .tokenCap
            return nil
        }
        return token
    }

    func clamp(_ logProbs: [Float], _ id: TokenID) -> Float {
        let i = Int(id)
        guard i >= 0, i < logProbs.count else { return GreedyConstrainedSearch.logProbFloor }
        let value = logProbs[i]
        return value.isFinite ? value : GreedyConstrainedSearch.logProbFloor
    }
}

// MARK: - Branch state

struct Branch {
    var seq: SeqID
    var required: ArraySlice<UInt8>
    var tokens: [TokenID] = []
    var output = UTF8Accumulator()
    var text = ""
    var scoredCount = 0
    /// Sum of the candidate statistics (forced tokens excluded, crossing token conditional).
    var total: Float = 0
    /// Sum of raw log-probs of every token in `tokens` (ranking between branches).
    var raw: Float = 0
    var pendingSentenceEnd = false
    /// Sum of the learned bias of the chosen tokens (ranking between branches only).
    var bonus: Float = 0
    /// Learned-entry match state over the bytes generated so far (including the required prefix).
    var bias = BiasState()
    /// Per visible token: bytes it added to the output and its raw (renormalized if it crossed the
    /// required prefix) log-prob. Forced tokens that add no text are not listed.
    var spans: [TokenSpan] = []
    var stop: StopReason?
    var unsatisfiable = false
    /// Accepted token not yet decoded into `seq`.
    var pending: TokenID?
    /// Log-probs already read for `seq` (the root logits), used instead of a new read.
    var preloaded: [Float]?
    /// Set while finishing a word cut by the token cap or the end of the model's turn: extra tokens
    /// taken so far, and the stop to report once the word is done.
    var finishing: (extra: Int, stop: StopReason)?
    /// UTF-8 length of the text when the end of the turn was first held (`holdEndBelowMinWords`).
    var beforeHold: Int?

    /// The branch with its text cut to its first `count` UTF-8 bytes; statistics cover the spans
    /// that fit. Tokens stay the whole decoded path.
    func cut(toBytes count: Int) -> Branch {
        var copy = self
        copy.text = String(decoding: Array(text.utf8).prefix(count), as: UTF8.self)
        var used = 0
        copy.spans = spans.prefix { span in
            used += span.byteCount
            return used <= count
        }
        copy.scoredCount = copy.spans.count
        copy.total = copy.spans.reduce(0) { $0 + $1.logProb }
        return copy
    }

    init(seq: SeqID, required: ArraySlice<UInt8>, preloaded: [Float]? = nil) {
        self.seq = seq
        self.required = required
        self.preloaded = preloaded
    }

    var mean: Float { scoredCount > 0 ? total / Float(scoredCount) : 0 }

    /// With a confidence trim, the candidate carries the kept text and its statistics; its tokens
    /// stay the whole decoded path (that is what the KV cache holds), and `spans` stay complete
    /// (spans past the kept text are ignored by `WordScoring`).
    func scored(stop: StopReason, trimmed: ConfidenceTrim.Result? = nil) -> ScoredCandidate {
        guard let trimmed else { return ScoredCandidate(candidate: candidate(stop: stop), spans: spans) }
        return ScoredCandidate(candidate: Candidate(text: trimmed.text, tokens: tokens, meanLogProb: trimmed.meanLogProb,
                                                    totalLogProb: trimmed.totalLogProb, stop: stop),
                               spans: spans, untrimmedText: text)
    }

    func candidate(stop: StopReason) -> Candidate {
        Candidate(text: text, tokens: tokens, meanLogProb: mean, totalLogProb: total, stop: stop,
                  firstLogProb: spans.first?.logProb)
    }
}

// MARK: - Token classes

/// Per-search classification of the vocabulary, computed once so the argmax loop is a flat scan.
/// Building `TokenClasses` walks the whole vocabulary (~262k tokens for Gemma 4), which is too
/// costly per keystroke. Vocabulary tables that are classes (the llama runtime's) live as long as
/// the loaded model, so the classes are cached per instance. The cache keeps a strong reference,
/// so an address can't be reused by a different vocabulary while cached. Value-type vocabularies
/// (test fakes) are rebuilt every time.
final class TokenClassCache: @unchecked Sendable {
    static let shared = TokenClassCache()
    private let lock = NSLock()
    private var cached: (vocabulary: AnyObject, classes: TokenClasses)?

    func classes(for vocabulary: any VocabularyTable) -> TokenClasses {
        guard type(of: vocabulary) is AnyClass else { return TokenClasses(vocabulary) }
        let object = vocabulary as AnyObject
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.vocabulary === object { return cached.classes }
        let classes = TokenClasses(vocabulary)
        cached = (object, classes)
        return classes
    }
}

struct TokenClasses {
    enum Kind: UInt8 { case normal, newline, endOfGeneration, byteFallback, blocked }

    private let kinds: [Kind]
    /// Whether the token's first character would continue a word (see `WordBoundary`).
    private let continuesWord: [Bool]

    init(_ vocabulary: any VocabularyTable) {
        var kinds = [Kind](repeating: .blocked, count: vocabulary.count)
        var continues = [Bool](repeating: false, count: vocabulary.count)
        for i in 0..<vocabulary.count {
            let traits = vocabulary.traits(TokenID(i))
            let bytes = vocabulary.bytes(TokenID(i))
            if traits.contains(.endOfGeneration) {
                kinds[i] = .endOfGeneration
            } else if traits.contains(.control) || traits.contains(.unused) {
                kinds[i] = .blocked
            } else if traits.contains(.byteFallback) {
                kinds[i] = .byteFallback
            } else if bytes.isEmpty {
                kinds[i] = .blocked
            } else if traits.contains(.containsNewline) {
                kinds[i] = .newline
            } else {
                kinds[i] = .normal
                continues[i] = WordBoundary.continuesWord(bytes)
            }
        }
        self.kinds = kinds
        self.continuesWord = continues
    }

    func kind(_ id: TokenID) -> Kind {
        let i = Int(id)
        return i >= 0 && i < kinds.count ? kinds[i] : .blocked
    }

    func continuesWord(_ id: TokenID) -> Bool {
        let i = Int(id)
        return i >= 0 && i < continuesWord.count ? continuesWord[i] : false
    }

    private static func value(_ x: Float) -> Float { x.isFinite ? x : GreedyConstrainedSearch.logProbFloor }

    private func emittable(_ i: Int) -> Bool {
        switch kinds[i] {
        case .normal, .newline, .endOfGeneration: return true
        case .byteFallback, .blocked: return false
        }
    }

    /// Best token among normal, newline, and end-of-generation tokens (control, unused, empty,
    /// and byte-fallback tokens are masked).
    func argmax(_ logProbs: [Float]) -> TokenID? {
        var best: Int?
        var bestValue = -Float.infinity
        let n = min(logProbs.count, kinds.count)
        for i in 0..<n where emittable(i) {
            let value = Self.value(logProbs[i])
            if best == nil || value > bestValue {
                best = i
                bestValue = value
            }
        }
        return best.map { TokenID($0) }
    }

    /// Up to `count` best tokens (highest first) among emittable tokens accepted by `include`.
    func top(_ logProbs: [Float], count: Int, include: (TokenID, Kind) -> Bool) -> [TokenID] {
        guard count > 0 else { return [] }
        var best: [(id: Int, value: Float)] = []
        let n = min(logProbs.count, kinds.count)
        for i in 0..<n where emittable(i) {
            let value = Self.value(logProbs[i])
            if best.count == count, let last = best.last, value <= last.value { continue }
            guard include(TokenID(i), kinds[i]) else { continue }
            let at = best.firstIndex { value > $0.value } ?? best.count
            best.insert((i, value), at: at)
            if best.count > count { best.removeLast() }
        }
        return best.map { TokenID($0.id) }
    }

    /// Log of the total probability of emittable next tokens that continue a word vs. those that
    /// mark a boundary (whitespace, punctuation, newline, end of generation, CJK, ...).
    func boundaryMass(_ logProbs: [Float]) -> (continues: Float, ends: Float) {
        let n = min(logProbs.count, kinds.count)
        var maxValue = -Float.infinity
        for i in 0..<n where emittable(i) { maxValue = max(maxValue, Self.value(logProbs[i])) }
        guard maxValue.isFinite else { return (-.infinity, -.infinity) }
        var word: Float = 0
        var boundary: Float = 0
        for i in 0..<n where emittable(i) {
            let p = expf(Self.value(logProbs[i]) - maxValue)
            if continuesWord[i] { word += p } else { boundary += p }
        }
        return (maxValue + logf(word), maxValue + logf(boundary))
    }
}
