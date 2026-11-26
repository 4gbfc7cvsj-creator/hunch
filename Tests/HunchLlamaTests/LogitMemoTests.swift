import Testing
import HunchCore
@testable import HunchLlama

@Suite struct LogitMemoTests {
    @Test func storesRowsByExactPath() {
        var memo = LogitMemo(capacity: 4)
        memo.record(path: [1, 2], row: [0.5], held: [[1, 2]])
        #expect(memo.row(after: [1, 2][...]) == [0.5])
        #expect(memo.row(after: [1][...]) == nil)
        #expect(memo.row(after: [1, 2, 3][...]) == nil)
        #expect(memo.row(after: [9, 2][...]) == nil)
        // A path already recorded keeps its first row.
        memo.record(path: [1, 2], row: [9], held: [[1, 2]])
        #expect(memo.row(after: [1, 2][...]) == [0.5] && memo.count == 1)
        // Empty paths and rows are ignored.
        memo.record(path: [], row: [1], held: [])
        memo.record(path: [3], row: [], held: [[3]])
        #expect(memo.count == 1)
    }

    @Test func evictsUnheldPathsFirstThenTheLongest() {
        var memo = LogitMemo(capacity: 3)
        let held: [TokenID] = [1, 2, 3, 4]
        memo.record(path: [1, 2], row: [2], held: [held])
        memo.record(path: [1, 2, 3], row: [3], held: [held])
        memo.record(path: [7, 7], row: [7], held: [held])          // a branch no sequence holds any more
        memo.record(path: [1, 2, 3, 4], row: [4], held: [held])
        #expect(memo.count == 3)
        #expect(memo.row(after: [7, 7][...]) == nil)
        #expect(memo.row(after: [1, 2, 3, 4][...]) == [4])
        // Full and all held: the longest path goes, the rows nearest the prompt stay.
        memo.record(path: [1], row: [1], held: [held])
        #expect(memo.count == 3)
        #expect(memo.row(after: [1][...]) == [1])
        #expect(memo.row(after: [1, 2, 3, 4][...]) == nil)
        #expect(!memo.wouldKeep(pathLength: 5, held: [held]))
        #expect(memo.wouldKeep(pathLength: 1, held: [held]))
        #expect(memo.wouldKeep(pathLength: 5, held: [[9]]))       // nothing held: room after pruning
    }

    @Test func keepHeldDropsPathsNoSequenceHolds() {
        var memo = LogitMemo(capacity: 8)
        memo.record(path: [1, 2], row: [1], held: [])
        memo.record(path: [1, 3], row: [2], held: [])
        memo.record(path: [1, 2, 5], row: [3], held: [])
        memo.keepHeld(by: [[1, 2]])
        #expect(memo.count == 1 && memo.row(after: [1, 2][...]) == [1])
        memo.keepHeld(by: [])
        #expect(memo.count == 0)
    }

    @Test func walkFollowsHeldDraftTokensWithRecordedRows() {
        var memo = LogitMemo(capacity: 8)
        let held: [TokenID] = [10, 11, 20, 21, 22]
        for n in 2...4 { memo.record(path: Array(held.prefix(n)), row: [Float(n)], held: [held]) }
        // Prompt only.
        #expect(memo.walk(prompt: [10, 11], held: held, draft: []) == [[2]])
        // The draft goes on as held: rows after the prompt and after each held, recorded token.
        #expect(memo.walk(prompt: [10, 11], held: held, draft: [20, 21, 22, 23]) == [[2], [3], [4]])
        // A draft that leaves the held path stops there.
        #expect(memo.walk(prompt: [10, 11], held: held, draft: [20, 99]) == [[2], [3]])
        #expect(memo.walk(prompt: [10, 11], held: held, draft: [99]) == [[2]])
        // A longer prompt along the held path.
        #expect(memo.walk(prompt: [10, 11, 20], held: held, draft: [21]) == [[3], [4]])
        // Not held, or no row for the prompt: nothing.
        #expect(memo.walk(prompt: [10, 12], held: held, draft: []) == nil)
        #expect(memo.walk(prompt: [10], held: held, draft: [11]) == nil)
        #expect(memo.walk(prompt: [], held: held, draft: []) == nil)
    }

    @Test func capacityFollowsTheByteBudget() {
        #expect(LogitMemo(vocabularySize: 262_144).capacity == 16)
        #expect(LogitMemo(vocabularySize: 32_000).capacity == LogitMemo.maximumRows)
        #expect(LogitMemo(vocabularySize: 8_000_000).capacity == 2)
        #expect(LogitMemo(vocabularySize: 262_144, byteBudget: 0).capacity == 0)
        var off = LogitMemo(vocabularySize: 100, byteBudget: 0)
        off.record(path: [1], row: [1], held: [[1]])
        #expect(off.count == 0)
    }
}
