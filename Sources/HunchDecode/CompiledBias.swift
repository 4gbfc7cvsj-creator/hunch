import Foundation
import HunchCore

/// Match state of one branch against the learned entries: the trie nodes reached by the bytes
/// generated so far (one per alignment of an entry start), and the last byte (for the rule that
/// an entry may only start at a word boundary).
struct BiasState: Equatable, MatchTracking {
    var nodes: [Int32] = []
    var previous: UInt8?
    /// Entry-end nodes already reached by this branch: a finished entry earns no second bonus
    /// ("Kubernetes Kubernetes Kubernetes").
    var finished: Set<Int32> = []
    /// Highest entry progress (in weight units) already paid along the alignments still alive. A
    /// path never earns more than this high-water mark's ceiling, the best single entry's weight.
    var paid: Float = 0
    /// Match state against the blocked (avoid) entries, tracked by a second compiled trie.
    var avoid = AvoidState()
    /// Match state against the learned phrases (anchored at the caret), a third trie.
    var phrase = PhraseState()
}

/// Same match bookkeeping as `BiasState`, for the learned-phrase trie.
struct PhraseState: Equatable, MatchTracking {
    var nodes: [Int32] = []
    var previous: UInt8?
    var finished: Set<Int32> = []
    var paid: Float = 0
}

/// Same match bookkeeping as `BiasState`, for the avoid trie.
struct AvoidState: Equatable, MatchTracking {
    var nodes: [Int32] = []
    var previous: UInt8?
    var finished: Set<Int32> = []
    var paid: Float = 0
}

protocol MatchTracking {
    var nodes: [Int32] { get set }
    var previous: UInt8? { get set }
    var finished: Set<Int32> { get set }
    var paid: Float { get set }
}

/// Learned entries compiled against one vocabulary: a byte trie of the entries plus the list of
/// vocabulary tokens that can take part in a match, found by one scan of the vocabulary.
///
/// Matching rule for a token appended to a branch whose state is `s`: the token's bytes must
/// follow the trie from some node in `s` (or from the trie root when an entry may start here:
/// start of the stream, after a non-word byte, or when the token starts with whitespace), or
/// run through the end of an entry and then continue with a byte that is a word boundary
/// ("Kubernetes" + ","). The bias is the best weight among the entries still consistent.
/// Entries given with a leading space are also inserted without it, so they apply at the very
/// start of a stream and after punctuation. Entries are matched byte-wise; tokens are only
/// considered at their first byte for a new entry start (an entry starting in the middle of a
/// token is not recognised).
///
/// Immutable after construction except for a lock-protected expansion memo.
final class CompiledBias: @unchecked Sendable {
    struct Node {
        var next: [UInt8: Int32] = [:]
        /// Highest weight of an entry ending exactly here, or -1.
        var terminalWeight: Float = -1
        var depth: Int32 = 0
        /// Highest weight / length over the entries through this node. Progress along an entry
        /// earns `depth * ratio` at a node: the best entry's weight in proportion to how much of
        /// it is matched (its full weight at its end). Because the same entry supplies both the
        /// weight and the length, nested entries ("Kube", "Kubernetes") can't pair a heavy
        /// entry's weight with a lighter entry's closeness, and the value never exceeds the
        /// weight of the best entry reachable.
        var ratio: Float = 0
        /// Anchored tries (learned phrases): the progress value set directly, front-loaded (see
        /// `PhraseBiasTuning`); -1 elsewhere.
        var fixed: Float = -1
        /// Progress value earned by having matched this node's path.
        func progress() -> Float { fixed >= 0 ? fixed : Float(depth) * ratio }
    }
    struct Item {
        var token: TokenID
        var firstByte: UInt8
        /// Progress value of the node the token ends on (see `Node.progress`).
        var endProgress: Float
        /// Trie node the token ends on (the entry-end node when the entry ends inside the token).
        var endNode: Int32
    }

    private var nodes: [Node] = [Node()]
    private var matched: [(id: TokenID, bytes: [UInt8])] = []
    private let lock = NSLock()
    private var memo: [Int32: [Item]] = [:]
    let entries: [LearnedBias.Entry]
    /// Entries may only start at the very start of the stream (learned phrases: they continue
    /// the text at the caret, not any word boundary), and are matched exactly as given.
    let anchored: Bool

    static let maxTokenBytes = 32

    // MARK: Cache (one slot: the user's entries rarely change between keystrokes)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (vocabulary: AnyObject, bias: CompiledBias)?
    /// A second slot for the blocked-word trie, so the two never evict each other.
    nonisolated(unsafe) private static var cachedAvoid: (vocabulary: AnyObject, bias: CompiledBias)?
    /// A third slot for learned phrases (they change with the text, but repeat on cache misses,
    /// prewarm and re-requests at the same caret).
    nonisolated(unsafe) private static var cachedPhrases: (vocabulary: AnyObject, bias: CompiledBias)?

    /// Entries for the avoid trie: every blocked word in the spellings a model may produce (as
    /// typed, lowercase, capitalized, uppercase), each with a leading space and weight 1.
    static func avoidEntries(_ words: [String]) -> [LearnedBias.Entry] {
        var seen = Set<String>()
        var out: [LearnedBias.Entry] = []
        for word in words.prefix(500) {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { continue }
            let capitalized = w.prefix(1).uppercased() + w.dropFirst()
            for variant in [w, w.lowercased(), capitalized, w.uppercased()] where seen.insert(variant).inserted {
                out.append(.init(text: " " + variant, weight: 1))
            }
        }
        return out
    }

    static func make(vocabulary: any VocabularyTable, classes: TokenClasses, entries: [LearnedBias.Entry],
                     avoid: Bool = false, anchored: Bool = false) -> CompiledBias? {
        let usable = entries.filter { $0.weight > 0 && !$0.text.isEmpty }
        guard !usable.isEmpty else { return nil }
        let isClass = type(of: vocabulary) is AnyClass
        if isClass {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let cached = anchored ? cachedPhrases : avoid ? cachedAvoid : cached,
               cached.vocabulary === (vocabulary as AnyObject),
               cached.bias.entries == entries {
                return cached.bias.matched.isEmpty ? nil : cached.bias
            }
        }
        let compiled = CompiledBias(vocabulary: vocabulary, classes: classes, entries: entries, usable: usable,
                                    anchored: anchored)
        if isClass {
            cacheLock.lock()
            if anchored {
                cachedPhrases = (vocabulary as AnyObject, compiled)
            } else if avoid {
                cachedAvoid = (vocabulary as AnyObject, compiled)
            } else {
                cached = (vocabulary as AnyObject, compiled)
            }
            cacheLock.unlock()
        }
        return compiled.matched.isEmpty ? nil : compiled
    }

    private init(vocabulary: any VocabularyTable, classes: TokenClasses, entries: [LearnedBias.Entry],
                 usable: [LearnedBias.Entry], anchored: Bool) {
        self.entries = entries
        self.anchored = anchored
        var substrings = Set<UInt64>()
        var anchoredTexts: [[UInt8]] = []
        for entry in usable.prefix(4000) {
            var bytes = Array(entry.text.utf8)
            while let last = bytes.last, Self.isSpace(last) { bytes.removeLast() }
            guard !bytes.isEmpty else { continue }
            let weight = min(entry.weight, 1)
            var variants = [bytes]
            if !anchored, Self.isSpace(bytes[0]) {
                let stripped = Array(bytes.drop { Self.isSpace($0) })
                if !stripped.isEmpty { variants.append(stripped) }
            }
            for variant in variants {
                insert(variant, weight: weight)
                if anchored { anchoredTexts.append(variant); continue }
                for i in variant.indices {
                    var hash = Self.hashSeed
                    for j in i..<min(variant.count, i + Self.maxTokenBytes) {
                        hash = Self.mix(hash, variant[j])
                        substrings.insert(hash)
                    }
                }
            }
        }
        if anchored {
            // Learned phrases change with every keystroke: instead of scanning the vocabulary, look
            // up the tokens that start with each position's bytes (index built once per vocabulary).
            let index = TokenStartIndex.shared(for: vocabulary, classes: classes)
            var seen = Set<TokenID>()
            for text in anchoredTexts {
                for i in text.indices {
                    for id in index.candidates(text[i...]) where !seen.contains(id) {
                        let bytes = vocabulary.bytes(id)
                        var j = 0
                        while j < bytes.count, i + j < text.count, bytes[bytes.startIndex + j] == text[i + j] { j += 1 }
                        if j == bytes.count || (j > 0 && i + j == text.count && Self.isBoundaryByte(bytes[bytes.startIndex + j])) {
                            seen.insert(id)
                            matched.append((id, Array(bytes)))
                        }
                    }
                }
            }
            return
        }
        // One scan: keep tokens whose bytes (or whose bytes up to a following boundary byte) occur
        // inside some entry.
        for index in 0..<vocabulary.count {
            let id = TokenID(index)
            guard classes.kind(id) == .normal else { continue }
            let bytes = vocabulary.bytes(id)
            guard !bytes.isEmpty, bytes.count <= Self.maxTokenBytes else { continue }
            var hash = Self.hashSeed
            var offset = 0
            let base = bytes.startIndex
            for byte in bytes {
                hash = Self.mix(hash, byte)
                offset += 1
                let atEnd = offset == bytes.count
                if substrings.contains(hash), atEnd || Self.isBoundaryByte(bytes[base + offset]) {
                    matched.append((id, Array(bytes)))
                    break
                }
            }
        }
    }

    private func insert(_ bytes: [UInt8], weight: Float) {
        let ratio = weight / Float(bytes.count)
        var node = 0
        for byte in bytes {
            if let child = nodes[node].next[byte] {
                node = Int(child)
            } else {
                var fresh = Node()
                fresh.depth = nodes[node].depth + 1
                nodes.append(fresh)
                nodes[node].next[byte] = Int32(nodes.count - 1)
                node = nodes.count - 1
            }
            nodes[node].ratio = max(nodes[node].ratio, ratio)
            if anchored {
                let fraction = Float(nodes[node].depth) / Float(bytes.count)
                nodes[node].fixed = max(nodes[node].fixed, weight * powf(fraction, PhraseBiasTuning.exponent))
            }
        }
        nodes[node].terminalWeight = max(nodes[node].terminalWeight, weight)
    }

    // MARK: Matching

    /// Consumes `bytes` (a whole chosen token, required-prefix part included).
    func advance<S: MatchTracking>(_ state: inout S, _ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            var next: [Int32] = []
            for node in state.nodes {
                if let child = nodes[Int(node)].next[byte], !next.contains(child) { next.append(child) }
            }
            // No alignment survived this byte: whatever was paid belonged to a finished or dead match.
            if next.isEmpty { state.paid = 0 }
            if mayStart(after: state.previous, firstByte: byte), let child = nodes[0].next[byte],
               !next.contains(child) {
                next.append(child)
            }
            if next.count > 32 { next.removeFirst(next.count - 32) }
            state.nodes = next
            for node in next {
                if nodes[Int(node)].terminalWeight >= 0 { state.finished.insert(node) }
                state.paid = max(state.paid, nodes[Int(node)].progress())
            }
            state.previous = byte
        }
    }

    /// Bias per candidate token for the next step. The bonus is amortized over the entry: a token
    /// earns `strength * (progress after - progress already paid)`, where progress is
    /// `weight * matched fraction` of the best entry through the node (see `Node.progress`). A token
    /// that only starts an entry ("K" of "Kubernetes") earns a small share, so it can't pull the
    /// choice away from an unrelated word, while completing the entry earns the full amount in
    /// total. The total along any path never exceeds `strength * max entry weight`, nested
    /// entries included (the payment is measured against the path's high-water mark).
    func map<S: MatchTracking>(_ state: S, strength: Float) -> [TokenID: Float] {
        var out: [TokenID: Float] = [:]
        func offer(_ item: Item, from startProgress: Float) {
            if state.finished.contains(item.endNode) { return }
            let value = strength * max(0, item.endProgress - startProgress)
            if value > (out[item.token] ?? 0) { out[item.token] = value }
        }
        for node in state.nodes {
            let start = max(nodes[Int(node)].progress(), state.paid)
            for item in expansion(of: node) { offer(item, from: start) }
        }
        for item in expansion(of: 0) where mayStart(after: state.previous, firstByte: item.firstByte) {
            offer(item, from: 0)
        }
        return out
    }

    private func expansion(of node: Int32) -> [Item] {
        lock.lock()
        if let hit = memo[node] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        var items: [Item] = []
        for token in matched {
            if let (progress, end) = walk(from: Int(node), token.bytes) {
                items.append(Item(token: token.id, firstByte: token.bytes[0], endProgress: progress, endNode: end))
            }
        }
        lock.lock()
        memo[node] = items
        lock.unlock()
        return items
    }

    /// The progress value and end node reached if `bytes` keep an entry consistent from `start`.
    private func walk(from start: Int, _ bytes: [UInt8]) -> (Float, Int32)? {
        var node = start
        var fallback: (Float, Int32)?
        for (i, byte) in bytes.enumerated() {
            // An entry that ends inside the token is fine when the rest begins at a word boundary.
            if i > 0, nodes[node].terminalWeight >= 0, !WordBoundary.continuesWord(bytes[i...]) {
                fallback = (nodes[node].progress(), Int32(node))
            }
            guard let child = nodes[node].next[byte] else { return fallback }
            node = Int(child)
        }
        return (nodes[node].progress(), Int32(node))
    }

    // MARK: Byte classes

    private static let hashSeed: UInt64 = 0xcbf29ce484222325
    private static func mix(_ hash: UInt64, _ byte: UInt8) -> UInt64 { (hash ^ UInt64(byte)) &* 0x100000001b3 }
    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
    private static func isWordByte(_ b: UInt8) -> Bool {
        b >= 0x80 || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x27
    }
    /// ASCII byte that is not part of a word.
    private static func isBoundaryByte(_ b: UInt8) -> Bool { b < 0x80 && !isWordByte(b) }
    private func mayStart(after previous: UInt8?, firstByte: UInt8) -> Bool {
        guard let previous else { return true }
        if anchored { return false }
        return !Self.isWordByte(previous) || Self.isSpace(firstByte)
    }
}

/// Normal tokens of a vocabulary by their first one or two bytes, for learned phrases. Built once
/// per vocabulary object (one scan); value-type vocabularies (tests) get a fresh index.
final class TokenStartIndex: @unchecked Sendable {
    private var byTwo: [UInt16: [TokenID]] = [:]
    private var byOne: [UInt8: [TokenID]] = [:]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (vocabulary: AnyObject, index: TokenStartIndex)?

    static func shared(for vocabulary: any VocabularyTable, classes: TokenClasses) -> TokenStartIndex {
        guard type(of: vocabulary) is AnyClass else { return TokenStartIndex(vocabulary, classes) }
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.vocabulary === (vocabulary as AnyObject) { return cached.index }
        let index = TokenStartIndex(vocabulary, classes)
        cached = (vocabulary as AnyObject, index)
        return index
    }

    private init(_ vocabulary: any VocabularyTable, _ classes: TokenClasses) {
        for i in 0..<vocabulary.count {
            let id = TokenID(i)
            guard classes.kind(id) == .normal else { continue }
            let bytes = vocabulary.bytes(id)
            guard !bytes.isEmpty, bytes.count <= CompiledBias.maxTokenBytes else { continue }
            let b0 = bytes[bytes.startIndex]
            if bytes.count == 1 {
                byOne[b0, default: []].append(id)
            } else {
                byTwo[UInt16(b0) << 8 | UInt16(bytes[bytes.startIndex + 1]), default: []].append(id)
            }
        }
    }

    /// Tokens that could start at the beginning of `text`: one-byte tokens equal to its first byte
    /// and longer tokens sharing its first two bytes (or, at its last byte, its first byte).
    func candidates(_ text: ArraySlice<UInt8>) -> [TokenID] {
        guard let b0 = text.first else { return [] }
        var out = byOne[b0] ?? []
        if text.count >= 2 {
            out += byTwo[UInt16(b0) << 8 | UInt16(text[text.startIndex + 1])] ?? []
        } else {
            // The phrase ends after one byte: a token may run on past it (" a," after "a").
            for low in 0...UInt16(255) { out += byTwo[UInt16(b0) << 8 | low] ?? [] }
        }
        return out
    }
}

/// How a learned phrase's bonus is spread along it. Progress at a matched fraction f of the phrase
/// is `weight * f^exponent`: 1 spreads it evenly (like learned words), 0.5 (the default) pays most
/// of it on the first token, where the choice between continuations is made. The total is the
/// phrase's weight either way. Eval-only knob (`hunch-eval --phrase-curve`); the app keeps the default.
public enum PhraseBiasTuning {
    nonisolated(unsafe) public static var exponent: Float = 0.5
}
