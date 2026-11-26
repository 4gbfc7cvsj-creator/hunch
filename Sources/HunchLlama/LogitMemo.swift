// Executor-confined memo of raw logits rows the session already computed, keyed by the exact token
// path they follow, so a request that keeps those tokens in the KV cache gets them back without a
// decode (a keystroke inside a word keeps the healed prompt; typing along with a suggestion keeps
// its first tokens).
import HunchCore

/// Raw (pre-softmax) logits after a token path. A row depends only on the tokens before it, so an
/// entry stays correct for as long as some sequence still holds its path; it is only useful while
/// one does (decoding after it needs that KV state), so entries whose path no sequence holds are
/// dropped first, then the longest paths (the rows nearest the prompt are the ones reused most).
///
/// Not Sendable and unlocked: it lives inside one `LlamaSession` and is only touched on the
/// generation executor thread. Holds numbers only, never text.
struct LogitMemo {
    struct Entry {
        let path: [TokenID]
        let row: [Float]
    }

    /// Bytes of rows kept at most (Gemma 4's 262k vocabulary: 16 rows).
    static let defaultByteBudget = 16 << 20
    /// More rows than one suggestion's tokens plus its prompt row are never useful.
    static let maximumRows = 25

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// Capacity for rows of `vocabularySize` floats within `byteBudget` (at least 2: the prompt row
    /// and one more, unless the budget is 0).
    init(vocabularySize: Int, byteBudget: Int = LogitMemo.defaultByteBudget) {
        let rowBytes = max(1, vocabularySize * MemoryLayout<Float>.size)
        self.init(capacity: byteBudget <= 0 ? 0 : min(Self.maximumRows, max(2, byteBudget / rowBytes)))
    }

    var count: Int { entries.count }

    /// The row after exactly `path`, if recorded.
    func row(after path: ArraySlice<TokenID>) -> [Float]? {
        entries.first { $0.path.count == path.count && $0.path[...] == path }?.row
    }

    /// Whether `record` would store a new row after a path of `length` tokens, given the sequences
    /// that hold tokens now (lets the caller skip copying a row that would be dropped at once).
    func wouldKeep(pathLength length: Int, held: [[TokenID]]) -> Bool {
        guard capacity > 0, length > 0 else { return false }
        if entries.count < capacity { return true }
        if entries.contains(where: { !Self.isHeld($0.path, by: held) }) { return true }
        return entries.contains { $0.path.count > length }
    }

    /// Stores `row` as the logits after `path` (a path already recorded keeps its first row).
    /// `held`: the token lists the sequences hold now, used to evict entries no one can use.
    mutating func record(path: [TokenID], row: [Float], held: [[TokenID]]) {
        guard capacity > 0, !path.isEmpty, !row.isEmpty, self.row(after: path[...]) == nil else { return }
        entries.append(Entry(path: path, row: row))
        guard entries.count > capacity else { return }
        keepHeld(by: held)
        while entries.count > capacity,
              let longest = entries.indices.max(by: { entries[$0].path.count < entries[$1].path.count }) {
            entries.remove(at: longest)
        }
    }

    /// Drops every entry whose path none of `held` starts with.
    mutating func keepHeld(by held: [[TokenID]]) {
        entries.removeAll { !Self.isHeld($0.path, by: held) }
    }

    mutating func removeAll() { entries.removeAll() }

    /// Rows for a prompt sync without decoding: `rows[0]` is the row after `prompt`, and `rows[i]`
    /// the row after `prompt + draft[0..<i]`, for as long as `held` (what sequence 0 holds) goes on
    /// with the draft's tokens and their rows are recorded. Nil when `held` doesn't start with
    /// `prompt` or the prompt's row is unknown.
    func walk(prompt: [TokenID], held: [TokenID], draft: [TokenID]) -> [[Float]]? {
        guard !prompt.isEmpty, held.count >= prompt.count, held.starts(with: prompt),
              let root = row(after: prompt[...]) else { return nil }
        var rows = [root]
        var index = 0
        while index < draft.count, prompt.count + index < held.count, held[prompt.count + index] == draft[index],
              let next = row(after: held[..<(prompt.count + index + 1)]) {
            rows.append(next)
            index += 1
        }
        return rows
    }

    private static func isHeld(_ path: [TokenID], by held: [[TokenID]]) -> Bool {
        held.contains { $0.count >= path.count && $0.starts(with: path) }
    }
}
