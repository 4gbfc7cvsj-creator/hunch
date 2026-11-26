import HunchCore

/// KV-cache reuse planning from the longest common token prefix (design §5.3). Pure.
///
/// - Cached is a prefix of next (any capability, but `.none` requires a STRICT prefix):
///   `appendOnly(keep: cached.count)`.
/// - `.trimAndShift`: when the before-caret window slid, the tokens after the common prefix are
///   mostly the same as before, just earlier in `next`: `removeAndShift` moves that run instead of
///   re-decoding it (see `findShift`).
/// - `.trimSuffix`, `.checkpoint` (and `.trimAndShift` without a worthwhile run):
///   `trimAndAppend(keep: lcp)` when lcp > 0.
/// - Otherwise `coldPrefill`.
///
/// When next equals cached, nothing needs decoding (`tokensToDecode` 0); the session is
/// responsible for keeping or recomputing the last logits.
public struct DefaultReusePlanner: ReusePlanning {
    /// Shortest moved run worth a shift. The shift's fixed cost is one K-shift pass over the
    /// retained cells (a RoPE re-rotation of the K cache, applied inside the next decode) and, when
    /// boundary tokens are skipped, one extra tiny decode; together these cost about as much as
    /// prefilling a handful of tokens, so 64 saved tokens leave a margin of several times.
    public static let defaultMinimumShiftMatch = 64
    /// Farthest the window may have moved (tokens dropped at the front of the run) for a shift.
    public static let maximumShiftDistance = 512
    /// Re-tokenization at the new window start changes at most this many leading tokens of
    /// `next[lcp...]`; the search tolerates skipping them.
    public static let maximumBoundarySkip = 2
    /// Upper bound on token comparisons spent per plan (the search stops with the best run so far),
    /// so a repetitive 2048-token prompt cannot stall the generation executor.
    public static let defaultShiftSearchBudget = 32_768

    public let minimumShiftMatch: Int
    public let shiftSearchBudget: Int

    public init(minimumShiftMatch: Int = DefaultReusePlanner.defaultMinimumShiftMatch,
                shiftSearchBudget: Int = DefaultReusePlanner.defaultShiftSearchBudget) {
        self.minimumShiftMatch = minimumShiftMatch
        self.shiftSearchBudget = shiftSearchBudget
    }

    public func plan(cached: [TokenID], next: [TokenID], capability: ReuseCapability) -> ReusePlan {
        let lcp = Self.commonPrefixLength(cached, next)
        let cachedIsPrefix = lcp == cached.count && !cached.isEmpty
        let strict = cachedIsPrefix && next.count > cached.count

        if capability == .none {
            return strict ? ReusePlan(action: .appendOnly(keep: lcp), tokensToDecode: next.count - lcp) : cold(next)
        }
        if cachedIsPrefix {
            return ReusePlan(action: .appendOnly(keep: lcp), tokensToDecode: next.count - lcp)
        }
        switch capability {
        case .trimAndShift:
            if let shift = Self.findShift(cached: cached, next: next, prefix: lcp, budget: shiftSearchBudget).shift,
               shift.matched >= minimumShiftMatch {
                return ReusePlan(action: .removeAndShift(keep: lcp, drop: shift.drop, matched: shift.matched,
                                                         skip: shift.skip),
                                 tokensToDecode: next.count - lcp - shift.matched)
            }
            return lcp > 0 ? ReusePlan(action: .trimAndAppend(keep: lcp), tokensToDecode: next.count - lcp) : cold(next)
        case .trimSuffix where lcp > 0, .checkpoint where lcp > 0:
            // With checkpoints the session may keep less than `lcp` (back to its nearest saved state).
            return ReusePlan(action: .trimAndAppend(keep: lcp), tokensToDecode: next.count - lcp)
        default:
            return cold(next)
        }
    }

    private func cold(_ next: [TokenID]) -> ReusePlan {
        ReusePlan(action: .coldPrefill, tokensToDecode: next.count)
    }

    static func commonPrefixLength(_ a: [TokenID], _ b: [TokenID]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    struct Shift: Equatable {
        var drop: Int
        var matched: Int
        var skip: Int
    }

    /// The longest run `cached[prefix+drop...]` == `next[prefix+skip...]` over drop in 0...512 and
    /// skip in 0...2 (drop and skip not both 0), leaving at least one token of `next` to decode so
    /// the last logits exist. Each candidate is compared token by token and abandoned at the first
    /// mismatch, so a candidate whose first token differs costs one comparison; the search ends
    /// early when a run reaches the end of `next` (nothing longer exists) or when `budget`
    /// comparisons have been spent. Returns the comparisons made for the bound test.
    static func findShift(cached: [TokenID], next: [TokenID], prefix: Int, budget: Int) -> (shift: Shift?, work: Int) {
        var best: Shift?
        var work = 0
        let cachedTail = cached.count - prefix
        let nextTail = next.count - prefix
        guard cachedTail > 0, nextTail > 1 else { return (nil, 0) }
        let maxDrop = min(maximumShiftDistance, cachedTail - 1)
        search: for skip in 0...maximumBoundarySkip {
            // The last token of next is always decoded, hence the -1.
            let nextLimit = nextTail - skip - 1
            if nextLimit < 1 { break }
            for drop in 0...maxDrop where drop > 0 || skip > 0 {
                let limit = min(cachedTail - drop, nextLimit)
                if let best, limit <= best.matched { continue }
                var m = 0
                let c = prefix + drop, n = prefix + skip
                while m < limit, cached[c + m] == next[n + m] { m += 1 }
                work += min(m + 1, limit)
                if best.map({ m > $0.matched }) ?? (m > 0) { best = Shift(drop: drop, matched: m, skip: skip) }
                if m == nextLimit || work >= budget { break search }
            }
        }
        return (best, work)
    }
}
