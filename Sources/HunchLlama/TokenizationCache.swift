// Executor-confined LRU of tokenizer results, so text the framer re-measures on every keystroke
// (Budget's binary search, the stable prompt segments) does not cross the llama.cpp FFI again.
import HunchCore

/// Keyed by (text, parseSpecial, splitsMarkers), LRU-bounded by entry count and total key bytes.
///
/// Not Sendable and unlocked: it lives inside one `LlamaSession` and, like the session, is only
/// touched on the generation executor thread. A session belongs to one loaded model, so a model
/// change starts with an empty cache; the session also clears it in `close()`.
///
/// Keys are the text's UTF-8 bytes, not `String`: Swift string equality is canonical, and two
/// canonically equal spellings (e.g. precomposed vs decomposed accents) can tokenize differently.
/// Token storage is at most 4 bytes per key byte
/// for real vocabularies (a token covers at least one byte), so memory stays a small multiple of
/// `maxBytes`. Never logs or exposes the cached text.
struct TokenizationCache {
    struct Key: Hashable {
        var bytes: [UInt8]
        var parseSpecial: Bool
        /// Content tokenization (`tokenizeContent`), whose marker splitting can give a different
        /// result than a plain `parseSpecial: false` tokenize of the same bytes.
        var splitsMarkers = false
    }

    let maxEntries: Int
    let maxBytes: Int
    private(set) var totalBytes = 0

    /// Slot storage with an intrusive doubly linked list in recency order (head = most recent).
    private struct Node {
        var key: Key
        var tokens: [TokenID]
        var prev: Int
        var next: Int
    }
    private var nodes: [Node] = []
    private var free: [Int] = []
    private var index: [Key: Int] = [:]
    private var head = -1
    private var tail = -1

    init(maxEntries: Int = 512, maxBytes: Int = 2 << 20) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    var count: Int { index.count }

    /// The cached tokens for `key`, marking it most recently used.
    mutating func value(for key: Key) -> [TokenID]? {
        guard let slot = index[key] else { return nil }
        moveToFront(slot)
        return nodes[slot].tokens
    }

    /// Stores `tokens` for `key` as most recently used, evicting least recently used entries
    /// until both caps hold. A single entry larger than the byte cap is not stored.
    mutating func store(_ tokens: [TokenID], for key: Key) {
        let size = key.bytes.count
        if let slot = index[key] {
            nodes[slot].tokens = tokens
            moveToFront(slot)
            return
        }
        guard maxEntries > 0, size <= maxBytes else { return }
        while let last = tail.nonNegative, index.count >= maxEntries || totalBytes + size > maxBytes {
            remove(last)
        }
        let node = Node(key: key, tokens: tokens, prev: -1, next: head)
        let slot: Int
        if let reused = free.popLast() {
            nodes[reused] = node
            slot = reused
        } else {
            nodes.append(node)
            slot = nodes.count - 1
        }
        if head >= 0 { nodes[head].prev = slot }
        head = slot
        if tail < 0 { tail = slot }
        index[key] = slot
        totalBytes += size
    }

    mutating func removeAll() {
        nodes.removeAll()
        free.removeAll()
        index.removeAll()
        head = -1
        tail = -1
        totalBytes = 0
    }

    /// Keys from most to least recently used (tests only).
    var keysByRecency: [Key] {
        var out: [Key] = []
        var slot = head
        while slot >= 0 {
            out.append(nodes[slot].key)
            slot = nodes[slot].next
        }
        return out
    }

    private mutating func unlink(_ slot: Int) {
        let (prev, next) = (nodes[slot].prev, nodes[slot].next)
        if prev >= 0 { nodes[prev].next = next } else { head = next }
        if next >= 0 { nodes[next].prev = prev } else { tail = prev }
    }

    private mutating func moveToFront(_ slot: Int) {
        guard slot != head else { return }
        unlink(slot)
        nodes[slot].prev = -1
        nodes[slot].next = head
        if head >= 0 { nodes[head].prev = slot }
        head = slot
        if tail < 0 { tail = slot }
    }

    private mutating func remove(_ slot: Int) {
        unlink(slot)
        let key = nodes[slot].key
        index[key] = nil
        totalBytes -= key.bytes.count
        // Drop the payload now; the slot itself is reused by the next store.
        nodes[slot].key = Key(bytes: [], parseSpecial: false)
        nodes[slot].tokens = []
        free.append(slot)
    }
}

private extension Int {
    var nonNegative: Int? { self >= 0 ? self : nil }
}
