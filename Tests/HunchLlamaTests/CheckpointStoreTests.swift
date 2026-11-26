// CheckpointStore bookkeeping (pure, no model).
import Testing
@testable import HunchLlama

@Suite struct CheckpointStoreTests {
    private func bytes(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    @Test func latestAtMostPicksTheNearestEarlierEntry() {
        var store = CheckpointStore(byteBudget: 1_000)
        store.insert(position: 256, data: bytes(10))
        store.insert(position: 100, data: bytes(10))
        store.insert(position: 300, data: bytes(10))
        #expect(store.entries.map(\.position) == [100, 256, 300])
        #expect(store.latest(atMost: 299)?.position == 256)
        #expect(store.latest(atMost: 300)?.position == 300)
        #expect(store.latest(atMost: 99) == nil)
    }

    @Test func dropAfterForgetsLaterEntriesAndBytes() {
        var store = CheckpointStore(byteBudget: 1_000)
        for p in [50, 100, 150] { store.insert(position: p, data: bytes(10)) }
        store.drop(after: 100)
        #expect(store.entries.map(\.position) == [50, 100])
        #expect(store.bytes == 20)
        store.removeAll()
        #expect(store.isEmpty && store.bytes == 0)
    }

    @Test func sameEntryPositionReplacesIt() {
        var store = CheckpointStore(byteBudget: 1_000)
        store.insert(position: 10, data: bytes(10))
        store.insert(position: 10, data: bytes(30))
        #expect(store.entries.count == 1 && store.bytes == 30)
        store.insert(position: 0, data: bytes(10)) // position 0 is never stored
        #expect(store.entries.count == 1)
    }

    @Test func overBudgetThinsTheDensestRegionButKeepsTheNewest() {
        // Room for 4 entries.
        var store = CheckpointStore(byteBudget: 40)
        for p in [256, 512, 768, 800] { store.insert(position: p, data: bytes(10)) }
        store.insert(position: 805, data: bytes(10))
        // 805 is the newest insert (kept); the smallest gap among the others is 768 -> 800.
        #expect(store.entries.map(\.position) == [256, 512, 768, 805])
        #expect(store.bytes == 40)
    }

    @Test func keepsTheMinimumCountEvenOverBudget() {
        var store = CheckpointStore(byteBudget: 5)
        store.insert(position: 10, data: bytes(10))
        store.insert(position: 20, data: bytes(10))
        store.insert(position: 30, data: bytes(10))
        #expect(store.entries.count == CheckpointStore.minimumCount)
        #expect(store.entries.last?.position == 30)
    }
}
