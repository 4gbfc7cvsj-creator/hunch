import Foundation
import HunchCore

/// A split-GGUF file name in llama.cpp's convention: `<base>-00001-of-00003.gguf`.
struct SplitName: Equatable {
    var base: String
    var index: Int
    var total: Int

    init?(fileName: String) {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".gguf") else { return nil }
        let stem = String(fileName.dropLast(5))
        guard let r = stem.lowercased().range(of: "-of-", options: .backwards) else { return nil }
        let left = stem[stem.startIndex..<r.lowerBound]
        let right = stem[r.upperBound...]
        guard !right.isEmpty, right.allSatisfy({ $0.isASCII && $0.isNumber }), let total = Int(right) else { return nil }
        let digits = left.reversed().prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let index = Int(String(digits.reversed())) else { return nil }
        let base = left.dropLast(digits.count)
        guard base.hasSuffix("-"), base.count > 1, total >= 1, index >= 1 else { return nil }
        self.base = String(base.dropLast())
        self.index = index
        self.total = total
    }
}

/// Collapses the parts of split models into one entry each.
enum SplitModelGrouping {
    /// The entry for a complete set is its first part (the file llama.cpp loads; it finds the rest
    /// next to it), valid, with the parts' sizes summed. An incomplete set stays one entry for its
    /// lowest present part, marked `.splitPart` (unusable). Other entries pass through unchanged.
    static func collapse(_ entries: [ModelEntry]) -> [ModelEntry] {
        struct Key: Hashable { var dir: String; var base: String; var total: Int }
        var groups: [Key: [(ModelEntry, SplitName)]] = [:]
        for e in entries {
            guard case .splitPart = e.validity,
                  let n = SplitName(fileName: e.url.lastPathComponent) else { continue }
            groups[Key(dir: e.url.deletingLastPathComponent().path, base: n.base.lowercased(), total: n.total), default: []]
                .append((e, n))
        }
        if groups.isEmpty { return entries }

        var keep: [String: ModelEntry] = [:]  // representative id -> replacement
        var drop = Set<ModelEntryID>()
        for (_, members) in groups {
            let sorted = members.sorted { $0.1.index < $1.1.index }
            let indices = Set(sorted.map { $0.1.index })
            let total = sorted[0].1.total
            let complete = indices.count == total && indices.allSatisfy { $0 <= total }
            var rep = sorted[0].0
            rep.byteSize = sorted.reduce(0) { $0 + $1.0.byteSize }
            rep.modified = sorted.map { $0.0.modified }.max() ?? rep.modified
            if complete {
                rep.validity = .valid
            } else {
                rep.validity = .splitPart(index: sorted[0].1.index, of: total)
            }
            keep[rep.id.relativePath] = rep
            for (e, _) in sorted.dropFirst() { drop.insert(e.id) }
        }
        return entries.compactMap { e in
            if drop.contains(e.id) { return nil }
            return keep[e.id.relativePath] ?? e
        }
    }
}
