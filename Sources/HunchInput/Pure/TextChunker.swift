/// Splits text into chunks for Unicode keyboard events.
///
/// Chunks never split a grapheme cluster (so never a surrogate pair, an emoji ZWJ sequence, or a
/// base + combining mark) unless a single cluster is itself longer than the hard per-event limit;
/// such a cluster is split only at Unicode scalar boundaries, never inside a surrogate pair.
public enum TextChunker {
    /// CGEventKeyboardSetUnicodeString is documented to carry a short string; hosts are
    /// unreliable beyond ~20 UTF-16 units, so the requested size is clamped to this.
    public static let hardLimit = 20
    public static let defaultChunkSize = 16

    public static func effectiveSize(_ requested: Int) -> Int { min(max(requested, 1), hardLimit) }

    /// Returns UTF-16 chunks, each at most `effectiveSize(chunkSize)` units long (a lone cluster
    /// may exceed a smaller requested size, but never `hardLimit`).
    public static func chunks(_ text: String, chunkSize: Int = defaultChunkSize) -> [[UInt16]] {
        let size = effectiveSize(chunkSize)
        var result: [[UInt16]] = []
        var current: [UInt16] = []
        current.reserveCapacity(size)

        func flush() {
            if !current.isEmpty { result.append(current); current.removeAll(keepingCapacity: true) }
        }

        for cluster in text {
            let units = Array(cluster.utf16)
            if units.count > hardLimit {
                flush()
                result.append(contentsOf: splitOversizedCluster(cluster))
                continue
            }
            if !current.isEmpty && current.count + units.count > size { flush() }
            current.append(contentsOf: units)
            // A lone cluster wider than the requested size stays alone in its chunk.
            if current.count >= size { flush() }
        }
        flush()
        return result
    }

    private static func splitOversizedCluster(_ cluster: Character) -> [[UInt16]] {
        var out: [[UInt16]] = []
        var current: [UInt16] = []
        for scalar in cluster.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if !current.isEmpty && current.count + units.count > hardLimit {
                out.append(current)
                current.removeAll()
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
