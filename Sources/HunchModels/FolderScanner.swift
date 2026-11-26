import Foundation
import HunchCore

/// Recursive, bounded-depth `.gguf` scan. Reads headers only, via the injected inspector.
public struct FolderScanner: Sendable {
    public let maxDepth: Int
    public let inspector: any GGUFInspecting

    public init(maxDepth: Int = 3, inspector: any GGUFInspecting = GGUFInspector()) {
        self.maxDepth = maxDepth
        self.inspector = inspector
    }

    struct CacheKey: Hashable { var path: String; var size: Int64; var modified: Date }
    typealias Cache = [CacheKey: (GGUFValidity, GGUFSummary?)]

    /// Hidden entries, packages, and symlinks that leave the folder are skipped; auxiliary
    /// files (mmproj) are not listed.
    public func scan(root: URL) -> [ModelEntry] {
        var cache: Cache = [:]
        return scan(root: root, cache: &cache)
    }

    func scan(root: URL, cache: inout Cache) -> [ModelEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey,
                                      .contentModificationDateKey, .isSymbolicLinkKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                     errorHandler: { _, _ in true }) else { return [] }
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootReal.hasSuffix("/") ? rootReal : rootReal + "/"
        var out: [ModelEntry] = []
        var newCache: Cache = [:]

        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if en.level >= maxDepth { en.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "gguf" else { continue }
            if v.isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard target.hasPrefix(rootPrefix) else { continue }
            }
            let target = v.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
            let tv = (try? target.resourceValues(forKeys: Set(keys))) ?? v
            guard tv.isRegularFile == true else { continue }
            let size = Int64(tv.fileSize ?? 0)
            let modified = tv.contentModificationDate ?? .distantPast
            let key = CacheKey(path: url.path, size: size, modified: modified)
            let result = cache[key] ?? inspector.inspect(url)
            newCache[key] = result
            if case .auxiliary = result.0 { continue }

            let full = url.standardizedFileURL.path
            let prefix = root.standardizedFileURL.path
            var rel = full
            if full.hasPrefix(prefix) { rel = String(full.dropFirst(prefix.count)) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            out.append(ModelEntry(id: ModelEntryID(relativePath: rel), url: url, byteSize: size,
                                  modified: modified, validity: result.0, summary: result.1))
        }
        cache = newCache
        return SplitModelGrouping.collapse(out).sorted { $0.id.relativePath.localizedStandardCompare($1.id.relativePath) == .orderedAscending }
    }

    /// Entries for files added from outside the folder, by absolute path, in the given order. Their
    /// IDs are the absolute paths; a missing file is listed as unreadable so the user can remove it.
    func entries(forFiles paths: [String], cache: inout Cache) -> [ModelEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var newCache: Cache = [:]
        let out = paths.map { path -> ModelEntry in
            let url = URL(fileURLWithPath: path)
            let id = ModelEntryID(relativePath: path)
            guard let v = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys), v.isRegularFile == true else {
                return ModelEntry(id: id, url: url, byteSize: 0, modified: .distantPast,
                                  validity: .unreadable("file not found"), summary: nil)
            }
            let size = Int64(v.fileSize ?? 0)
            let modified = v.contentModificationDate ?? .distantPast
            let key = CacheKey(path: path, size: size, modified: modified)
            let result = cache[key] ?? inspector.inspect(url)
            newCache[key] = result
            return ModelEntry(id: id, url: url, byteSize: size, modified: modified, validity: result.0,
                              summary: result.1)
        }
        cache = newCache
        return out
    }

    /// Cheap change fingerprint: the `.gguf` names, sizes and modification times, without reading
    /// any file. Used by the polling fallback where FSEvents is unreliable (exFAT, external drives).
    public func signature(root: URL) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else { return 0 }
        var h = Hasher()
        var items: [String] = []
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if en.level >= maxDepth { en.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "gguf" else { continue }
            items.append("\(url.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        for i in items.sorted() { h.combine(i) }
        return h.finalize()
    }
}
