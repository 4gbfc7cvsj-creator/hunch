import HunchCore
import Testing
@testable import HunchDecode

@Suite struct ReusePlannerTests {
    let planner = DefaultReusePlanner()

    @Test func appendOnlyWhenCachedIsAPrefix() {
        let plan = planner.plan(cached: [1, 2, 3], next: [1, 2, 3, 4, 5], capability: .trimSuffix)
        #expect(plan == ReusePlan(action: .appendOnly(keep: 3), tokensToDecode: 2))
        let same = planner.plan(cached: [1, 2], next: [1, 2], capability: .trimSuffix)
        #expect(same == ReusePlan(action: .appendOnly(keep: 2), tokensToDecode: 0))
        let shiftable = planner.plan(cached: [1, 2, 3], next: [1, 2, 3, 4], capability: .trimAndShift)
        #expect(shiftable == ReusePlan(action: .appendOnly(keep: 3), tokensToDecode: 1))
    }

    @Test func trimAndAppendAtTheCommonPrefix() {
        let plan = planner.plan(cached: [1, 2, 3, 9], next: [1, 2, 3, 4, 5], capability: .trimSuffix)
        #expect(plan == ReusePlan(action: .trimAndAppend(keep: 3), tokensToDecode: 2))
        let shorter = planner.plan(cached: [1, 2, 3, 4], next: [1, 2], capability: .trimSuffix)
        #expect(shorter == ReusePlan(action: .trimAndAppend(keep: 2), tokensToDecode: 0))
    }

    @Test func checkpointCachesPlanLikeTrimmableOnes() {
        // The session decides how far back it really goes; the plan only names the common prefix.
        #expect(planner.plan(cached: [1, 2, 3, 9], next: [1, 2, 3, 4, 5], capability: .checkpoint)
                == ReusePlan(action: .trimAndAppend(keep: 3), tokensToDecode: 2))
        #expect(planner.plan(cached: [1, 2, 3], next: [1, 2, 3, 4], capability: .checkpoint)
                == ReusePlan(action: .appendOnly(keep: 3), tokensToDecode: 1))
        #expect(planner.plan(cached: [7, 8], next: [1, 2], capability: .checkpoint)
                == ReusePlan(action: .coldPrefill, tokensToDecode: 2))
    }

    @Test func coldWhenNothingShared() {
        let plan = planner.plan(cached: [7, 8], next: [1, 2], capability: .trimSuffix)
        #expect(plan == ReusePlan(action: .coldPrefill, tokensToDecode: 2))
        let empty = planner.plan(cached: [], next: [1, 2], capability: .trimSuffix)
        #expect(empty == ReusePlan(action: .coldPrefill, tokensToDecode: 2))
        #expect(planner.plan(cached: [7, 8], next: [1, 2], capability: .trimAndShift)
                == ReusePlan(action: .coldPrefill, tokensToDecode: 2))
    }

    @Test func noneCapabilityNeedsAStrictPrefix() {
        #expect(planner.plan(cached: [1, 2], next: [1, 2, 3], capability: .none)
                == ReusePlan(action: .appendOnly(keep: 2), tokensToDecode: 1))
        #expect(planner.plan(cached: [1, 2], next: [1, 2], capability: .none)
                == ReusePlan(action: .coldPrefill, tokensToDecode: 2))
        #expect(planner.plan(cached: [1, 2, 9], next: [1, 2, 3], capability: .none)
                == ReusePlan(action: .coldPrefill, tokensToDecode: 3))
    }

    // MARK: - Context shift

    /// Distinct "prose" tokens so that no run matches by accident.
    private func prose(_ range: Range<Int>) -> [TokenID] { range.map { TokenID(1_000 + $0) } }

    /// A slid window: stable blocks, then the before-caret text whose first `drop` tokens fell out
    /// of the window and `typed` new tokens arrived at the end.
    private func slide(stable: Int = 20, window: Int = 300, drop: Int, typed: Int = 3, boundary: [TokenID] = [])
        -> (cached: [TokenID], next: [TokenID]) {
        let stableTokens = (0..<stable).map { TokenID(10 + $0) }
        let text = prose(0..<(window + typed))
        let cached = stableTokens + Array(text[0..<window])
        let next = stableTokens + boundary + Array(text[drop...])
        return (cached, next)
    }

    @Test func picksRemoveAndShiftForASlidWindow() {
        let (cached, next) = slide(drop: 5)
        let plan = planner.plan(cached: cached, next: next, capability: .trimAndShift)
        // Keep the 20 stable tokens, drop 5, move the remaining 295 cached window tokens (one
        // less: the last prompt token is always decoded), decode the 3 typed tokens.
        #expect(plan.action == .removeAndShift(keep: 20, drop: 5, matched: 295, skip: 0))
        #expect(plan.tokensToDecode == 3)
        #expect(plan.tokensToDecode == next.count - 20 - 295)
    }

    @Test func shiftFindsTheFarthestDistanceSearched() {
        let far = DefaultReusePlanner.maximumShiftDistance
        let (cached, next) = slide(window: far + 200, drop: far)
        let plan = planner.plan(cached: cached, next: next, capability: .trimAndShift)
        #expect(plan.action == .removeAndShift(keep: 20, drop: far, matched: 200, skip: 0))
        let tooFar = slide(window: far + 200, drop: far + 1)
        #expect(planner.plan(cached: tooFar.cached, next: tooFar.next, capability: .trimAndShift).action
                == .trimAndAppend(keep: 20))
    }

    @Test func skipsReTokenizedBoundaryTokens() {
        for boundary in [[TokenID(7)], [TokenID(7), TokenID(8)]] {
            let (cached, next) = slide(drop: 4, boundary: boundary)
            let plan = planner.plan(cached: cached, next: next, capability: .trimAndShift)
            // The run starts after the re-tokenized boundary token(s) in `next` and the dropped
            // tokens in `cached`; boundary tokens are decoded, so they count towards the cost.
            #expect(plan.action == .removeAndShift(keep: 20, drop: 4, matched: 296, skip: boundary.count))
            #expect(plan.tokensToDecode == boundary.count + 3)
        }
        // Three unmatched boundary tokens exceed the tolerance: plain trim.
        let (cached, next) = slide(drop: 4, boundary: [7, 8, 9])
        #expect(planner.plan(cached: cached, next: next, capability: .trimAndShift).action == .trimAndAppend(keep: 20))
        // The window grew backwards by one token (nothing dropped, one inserted): a pure skip.
        let grown = slide(drop: 0, boundary: [7])
        #expect(planner.plan(cached: grown.cached, next: grown.next, capability: .trimAndShift).action
                == .removeAndShift(keep: 20, drop: 0, matched: 300, skip: 1))
    }

    @Test func respectsTheMinimumMatchFloor() {
        let floor = DefaultReusePlanner.defaultMinimumShiftMatch
        #expect(floor == 64)
        // window - drop tokens can be moved (the typed tokens include the one always decoded).
        let exact = slide(window: floor + 5, drop: 5)
        #expect(planner.plan(cached: exact.cached, next: exact.next, capability: .trimAndShift).action
                == .removeAndShift(keep: 20, drop: 5, matched: floor, skip: 0))
        let short = slide(window: floor + 4, drop: 5)
        #expect(planner.plan(cached: short.cached, next: short.next, capability: .trimAndShift).action
                == .trimAndAppend(keep: 20))
        // The floor is a tunable: a planner with a lower one takes the short run.
        let eager = DefaultReusePlanner(minimumShiftMatch: 8)
        #expect(eager.plan(cached: short.cached, next: short.next, capability: .trimAndShift).action
                == .removeAndShift(keep: 20, drop: 5, matched: floor - 1, skip: 0))
    }

    @Test func neverShiftsWithoutTheCapability() {
        let (cached, next) = slide(drop: 5)
        #expect(planner.plan(cached: cached, next: next, capability: .trimSuffix)
                == ReusePlan(action: .trimAndAppend(keep: 20), tokensToDecode: next.count - 20))
        #expect(planner.plan(cached: cached, next: next, capability: .none)
                == ReusePlan(action: .coldPrefill, tokensToDecode: next.count))
        let unshared = slide(stable: 0, drop: 5)
        #expect(planner.plan(cached: unshared.cached, next: unshared.next, capability: .trimSuffix).action == .coldPrefill)
        #expect(planner.plan(cached: unshared.cached, next: unshared.next, capability: .trimAndShift).action
                == .removeAndShift(keep: 0, drop: 5, matched: 295, skip: 0))
    }

    @Test func alwaysLeavesTheLastTokenToDecode() {
        // The whole of `next` after the prefix is in the cache (pure window slide, nothing typed).
        let (cached, next) = slide(drop: 5, typed: 0)
        let plan = planner.plan(cached: cached, next: next, capability: .trimAndShift)
        #expect(plan.action == .removeAndShift(keep: 20, drop: 5, matched: 294, skip: 0))
        #expect(plan.tokensToDecode == 1)
    }

    @Test func searchWorkStaysBoundedOnRepetitivePrompts() {
        // Every shift distance matches for ~1000 tokens: without the budget this is ~1.5M comparisons.
        let cached = [TokenID](repeating: 7, count: 1_000) + [TokenID](repeating: 3, count: 1_000)
        let next = [TokenID](repeating: 7, count: 1_000) + [TokenID](repeating: 4, count: 1_000)
        let budget = DefaultReusePlanner.defaultShiftSearchBudget
        let (shift, work) = DefaultReusePlanner.findShift(cached: cached, next: next, prefix: 0, budget: budget)
        #expect(work <= budget + 1_000)
        #expect(shift == DefaultReusePlanner.Shift(drop: 1, matched: 999, skip: 0))
        // A run that reaches the end of `next` ends the search at once.
        let same = [TokenID(9)] + [TokenID](repeating: 7, count: 2_047)
        let (full, little) = DefaultReusePlanner.findShift(cached: same, next: [8] + same.dropFirst(),
                                                           prefix: 0, budget: budget)
        #expect(full == DefaultReusePlanner.Shift(drop: 1, matched: 2_046, skip: 1) && little < 2_700)
        // Nothing in common after the prefix: one comparison per candidate.
        let (none, cheap) = DefaultReusePlanner.findShift(cached: prose(0..<2_000), next: prose(5_000..<7_000),
                                                          prefix: 0, budget: budget)
        #expect(none == nil && cheap <= 3 * (DefaultReusePlanner.maximumShiftDistance + 1))
    }
}
