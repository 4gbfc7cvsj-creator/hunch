import Foundation
import HunchCore

/// Chooses the first-token roots of a search (see `GreedyConstrainedSearch`).
///
/// Sequence use: `SeqID.primary` holds the prompt. Roots that need their own KV state are forked
/// from it (or from the sequence holding the exact prefix token). Sequences that end up unused
/// are discarded here; the search copies the winner back to `primary` at the end.
struct RootPlanner {
    let run: SearchRun

    private var session: any LanguageModelSession { run.session }
    private var vocabulary: any VocabularyTable { run.vocabulary }
    private var classes: TokenClasses { run.classes }
    private var config: DecodeConfig { run.config }
    private var required: ArraySlice<UInt8> { run.required }

    func roots(rootLogProbs root: [Float]) throws -> [Branch] {
        let k = max(1, min(config.firstTokenFanout, GreedyConstrainedSearch.maxFanout))
        let capacity = max(1, session.maxParallelSequences)
        if !required.isEmpty, WordBoundary.endsInWord(required),
           let roots = try boundaryRoots(root, k: k, capacity: capacity) {
            return roots
        }
        if k > 1, capacity > 1, let roots = try fanoutRoots(root, k: min(k, capacity)) {
            return roots
        }
        return [Branch(seq: .primary, required: required, preloaded: root)]
    }

    // MARK: - Plain fan-out

    /// The k best first tokens, each on its own sequence. The first is the plain greedy choice;
    /// the others are restricted to tokens that add text (no end-of-generation, no stopping newline).
    private func fanoutRoots(_ root: [Float], k: Int) throws -> [Branch]? {
        var choices: [TokenID]
        if required.isEmpty {
            let rootBias = run.biasMap(BiasState(), logProbs: root)
            guard let top = run.biasedArgmax(root, map: rootBias) else { return nil }
            let others = classes.top(root, count: k - 1) { id, kind in
                id != top && (kind == .normal || (kind == .newline && config.allowNewline))
            }
            choices = [top] + others
        } else {
            let pool = run.forcedPool(required, limit: root.count)
            let rootBias = run.biasMap(BiasState(), logProbs: root, condition: run.poolMass(root, pool))
            choices = Array(pool
                .sorted {
                    let l = run.clamp(root, $0) + (rootBias[$0] ?? 0), r = run.clamp(root, $1) + (rootBias[$1] ?? 0)
                    return l != r ? l > r : $0 < $1
                }
                .prefix(k))
        }
        guard choices.count > 1 else { return nil }
        let seqs = (0..<choices.count).map { SeqID(Int32($0)) }
        try session.fork(.primary, into: Array(seqs.dropFirst()))
        var branches: [Branch] = []
        for (seq, token) in zip(seqs, choices) {
            var branch = Branch(seq: seq, required: required)
            branch.pending = run.advance(&branch, logProbs: root, choose: token)
            branches.append(branch)
        }
        return branches
    }

    // MARK: - Word-boundary decision

    private struct Option {
        var first: TokenID
        var second: TokenID?
        /// Sequence that already holds `first` decoded (longer tokens only).
        var seq: SeqID?
        var score: Float
        var completesWord: Bool
        var addsText: Bool
    }

    /// Nil when the question doesn't apply: no token spells the required prefix exactly, or the
    /// longer tokens would need a second sequence the session doesn't have.
    private func boundaryRoots(_ root: [Float], k: Int, capacity: Int) throws -> [Branch]? {
        let n = required.count
        let pool = run.forcedPool(required, limit: root.count)
        // Option scores steer the choice, so they include the learned bias (raw statistics don't).
        let rootBias = run.biasMap(BiasState(), logProbs: root, condition: run.poolMass(root, pool))
        let score = { (id: TokenID) in run.clamp(root, id) + (rootBias[id] ?? 0) }
        guard let exact = pool.filter({ vocabulary.bytes($0).count == n && classes.kind($0) == .normal })
            .max(by: { score($0) < score($1) }) else { return nil }
        var wordLonger: [TokenID] = []
        var boundaryLonger: [TokenID] = []
        for id in pool where vocabulary.bytes(id).count > n && classes.kind(id) == .normal {
            if WordBoundary.continuesWord(vocabulary.bytes(id).dropFirst(n)) {
                wordLonger.append(id)
            } else {
                boundaryLonger.append(id)
            }
        }
        wordLonger.sort { score($0) > score($1) }
        boundaryLonger.sort { score($0) > score($1) }
        // Shortcut (k = 1): "complete" scores at most log(P(exact) + P(longer boundary tokens)).
        // When the best longer word token already beats that bound, it wins without decoding the
        // exact token (no exact + next-token path can beat it either): take it, as plain greedy
        // would, and stream at once.
        if k == 1, let bestWord = wordLonger.first,
           score(bestWord) >= logSumExp(boundaryLonger.map(score) + [score(exact)]) {
            var branch = Branch(seq: .primary, required: required)
            branch.pending = run.advanceForced(&branch, logProbs: root, choose: bestWord)
            return [branch]
        }
        let hasLonger = !wordLonger.isEmpty || !boundaryLonger.isEmpty
        if hasLonger, capacity < 2 { return nil }

        // Speculate: the exact token on its own sequence, batched with the best longer tokens
        // (the best of each kind first) so whichever root wins is usually decoded already.
        let exactSeq: SeqID
        var speculated: [(token: TokenID, seq: SeqID)] = []
        var spare: [SeqID] = []
        if hasLonger {
            exactSeq = SeqID(1)
            var order: [TokenID] = []
            for id in [wordLonger.first, boundaryLonger.first].compactMap({ $0 })
                + (wordLonger.dropFirst() + boundaryLonger.dropFirst()).sorted(by: { score($0) > score($1) })
                where !order.contains(id) {
                order.append(id)
            }
            let slots = (2..<max(2, capacity)).map { SeqID(Int32($0)) } + [.primary]
            for (token, seq) in zip(order.prefix(max(2, k)), slots) { speculated.append((token, seq)) }
            let forks = [exactSeq] + speculated.map(\.seq).filter { $0 != .primary }
            try session.fork(.primary, into: forks)
            spare = slots.filter { slot in !speculated.contains { $0.seq == slot } }
        } else {
            exactSeq = .primary
            spare = (1..<capacity).map { SeqID(Int32($0)) }
        }
        if session.isCancellationRequested { throw CancellationError() }
        try session.step([(exactSeq, exact)] + speculated.map { ($0.seq, $0.token) })
        var next: [Float] = []
        try session.logProbs(exactSeq, into: &next)

        // Word-level comparison: P(the typed word is complete) against the single most likely
        // longer word. "Complete" sums every boundary that may follow the exact token (and longer
        // tokens that spell the word plus punctuation, " an,"), because all of them mean the same
        // word. "Continues" takes the best single word, not the sum over all longer words: summing
        // many different words against one would make "I am a" → "lready" win.
        let exactScore = score(exact)
        var afterExact = BiasState()
        run.advanceBias(&afterExact, vocabulary.bytes(exact))
        let secondBias = run.biasMap(afterExact, logProbs: next)
        let ends = logSumExp(boundaryLonger.map(score) + [exactScore + classes.boundaryMass(next).ends])
        let bestContinuation = classes.top(next, count: 1) { id, _ in classes.continuesWord(id) }.first
        let continues = max(wordLonger.first.map(score) ?? -.infinity,
                            bestContinuation.map { exactScore + run.clamp(next, $0) + (secondBias[$0] ?? 0) } ?? -.infinity)
        let completes = ends >= continues

        // Concrete options: speculated longer tokens, and the exact token plus a next token.
        var options = speculated.map { item in
            Option(first: item.token, second: nil, seq: item.seq, score: score(item.token),
                   completesWord: !WordBoundary.continuesWord(vocabulary.bytes(item.token).dropFirst(n)),
                   addsText: true)
        }
        for wantWord in [true, false] {
            let seconds = classes.top(next, count: k) { id, kind in
                classes.continuesWord(id) == wantWord && (kind != .newline || config.allowNewline || !wantWord)
            }
            for second in seconds {
                let kind = classes.kind(second)
                let adds = kind == .normal || (kind == .newline && config.allowNewline)
                options.append(Option(first: exact, second: second, seq: nil,
                                      score: exactScore + run.clamp(next, second) + (secondBias[second] ?? 0),
                                      completesWord: !wantWord, addsText: adds))
            }
        }
        let byScore = options.enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }.map(\.element)
        guard let lead = byScore.first(where: { $0.completesWord == completes }) ?? byScore.first else { return nil }
        var chosen = [lead]
        for option in byScore where chosen.count < k && option.addsText
            && !chosen.contains(where: { $0.first == option.first && $0.second == option.second }) {
            chosen.append(option)
        }

        // Assign sequences: longer tokens keep theirs; the first exact-token root takes the exact
        // sequence and later ones fork it into spare sequences.
        var exactSeqTaken = false
        var branches: [Branch] = []
        for option in chosen {
            var branch: Branch
            if let seq = option.seq {
                branch = Branch(seq: seq, required: required)
                _ = run.advanceForced(&branch, logProbs: root, choose: option.first)   // already decoded
            } else {
                let seq: SeqID
                if !exactSeqTaken {
                    seq = exactSeq
                    exactSeqTaken = true
                } else {
                    guard !spare.isEmpty else { continue }
                    seq = spare.removeFirst()
                    try session.fork(exactSeq, into: [seq])
                }
                branch = Branch(seq: seq, required: required)
                _ = run.advanceForced(&branch, logProbs: root, choose: option.first)   // already decoded
                if branch.stop == nil, let second = option.second {
                    branch.pending = run.advanceFree(&branch, logProbs: next, choose: second)
                }
            }
            branches.append(branch)
        }
        let used = Set(branches.map(\.seq))
        let unused = ([exactSeq] + speculated.map(\.seq)).filter { !used.contains($0) && $0 != .primary }
        if !unused.isEmpty { session.discard(unused) }
        return branches
    }

    private func logSumExp(_ values: [Float]) -> Float {
        guard let maxValue = values.max(), maxValue.isFinite else { return -.infinity }
        var sum: Float = 0
        for value in values { sum += expf(value - maxValue) }
        return maxValue + logf(sum)
    }
}
