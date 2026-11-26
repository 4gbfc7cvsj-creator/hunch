// Saved recurrent states of sequence 0 for hybrid models (see `ReuseCapability.checkpoint`).
import Foundation

/// Snapshots of sequence 0's partial (recurrent) state, each taken right after the first
/// `position` tokens were decoded. Positions are unique and ascending. Pure bookkeeping: the
/// session captures and restores the bytes.
///
/// Over the byte budget, the store thins out its densest region: it drops the entry closest to
/// the one before it, never the newest insert. Recent prompt ends therefore stay close together
/// (backspace, a re-tokenized last word) while older ones spread out (a moved context window).
struct CheckpointStore {
    struct Entry: Equatable {
        let position: Int
        let data: [UInt8]
    }

    /// 256 MB holds about ten states of a 4B hybrid model.
    static let defaultByteBudget = 256 << 20
    /// Kept whatever the budget says, so going back always has somewhere to land.
    static let minimumCount = 2

    private(set) var entries: [Entry] = []
    private(set) var bytes = 0
    let byteBudget: Int

    init(byteBudget: Int = CheckpointStore.defaultByteBudget) {
        self.byteBudget = byteBudget
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Newest-position entry at or before `limit` (position > 0).
    func latest(atMost limit: Int) -> Entry? {
        entries.last { $0.position <= limit && $0.position > 0 }
    }

    func contains(position: Int) -> Bool { entries.contains { $0.position == position } }

    mutating func insert(position: Int, data: [UInt8]) {
        guard position > 0 else { return }
        if let i = entries.firstIndex(where: { $0.position == position }) {
            bytes -= entries[i].data.count
            entries.remove(at: i)
        }
        let index = entries.firstIndex { $0.position > position } ?? entries.count
        entries.insert(Entry(position: position, data: data), at: index)
        bytes += data.count
        while bytes > byteBudget, entries.count > Self.minimumCount, let victim = thinningVictim(sparing: position) {
            bytes -= entries[victim].data.count
            entries.remove(at: victim)
        }
    }

    /// Forgets every entry past `length` (the tokens after it changed).
    mutating func drop(after length: Int) {
        while let last = entries.last, last.position > length {
            bytes -= last.data.count
            entries.removeLast()
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        bytes = 0
    }

    /// The entry with the smallest gap to its predecessor (position 0 for the first), other than `sparing`.
    private func thinningVictim(sparing position: Int) -> Int? {
        var best: Int?
        var bestGap = Int.max
        for (i, entry) in entries.enumerated() where entry.position != position {
            let gap = entry.position - (i == 0 ? 0 : entries[i - 1].position)
            if gap < bestGap { best = i; bestGap = gap }
        }
        return best
    }
}
