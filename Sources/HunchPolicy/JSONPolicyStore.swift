import Foundation
import HunchCore
import Synchronization

/// Persists user policy patches as JSON with a schema version. Atomic writes.
///
/// Category settings (`PolicyKey.category`) are kept in their own `categories` list, so builds
/// from before categories had settings still read the app and site entries.
public final class JSONPolicyStore: AppPolicyStoring {
    public static let schemaVersion = 1

    private struct Entry: Codable { var key: PolicyKey; var patch: AppPolicyPatch }
    private struct CategoryEntry: Codable { var name: String; var patch: AppPolicyPatch }
    private struct FileFormat: Codable {
        var schemaVersion: Int
        var entries: [Entry]
        var categories: [CategoryEntry]?
        /// One-time migrations already run on this file.
        var migrations: [String]?
    }
    /// The same file read one entry at a time: an entry this build can't decode (a value from a
    /// newer build, a hand edit) is skipped instead of failing the whole file.
    private struct LenientFile: Decodable {
        var schemaVersion: Int
        var entries: [Entry]
        var categories: [CategoryEntry]
        var migrations: [String]
        var skipped: Int

        private enum Keys: String, CodingKey { case schemaVersion, entries, categories, migrations }
        private struct Skip: Decodable {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            migrations = (try? c.decodeIfPresent([String].self, forKey: .migrations)) ?? []
            var skipped = 0
            func each<T: Decodable>(_ key: Keys, _ type: T.Type) throws -> [T] {
                guard c.contains(key), try !c.decodeNil(forKey: key) else { return [] }
                var list = try c.nestedUnkeyedContainer(forKey: key)
                var out: [T] = []
                while !list.isAtEnd {
                    if let value = try? list.decode(T.self) { out.append(value) } else {
                        _ = try list.decode(Skip.self)
                        skipped += 1
                    }
                }
                return out
            }
            entries = try each(.entries, Entry.self)
            categories = try each(.categories, CategoryEntry.self)
            self.skipped = skipped
        }
    }
    private struct State {
        var patches: [PolicyKey: AppPolicyPatch] = [:]
        var migrations: Set<String> = []
    }

    private let url: URL
    private let state: Mutex<State>

    /// A missing file loads as `freshPatches` (written out when there are any) with
    /// `freshMigrations` marked as run. Entries this build can't read are skipped; when anything in
    /// an existing file can't be read (an entry, the whole file, or a newer schema), the file is
    /// first copied next to itself (`backupURL`) so the next write can't lose it for good.
    public init(fileURL: URL, freshPatches: [PolicyKey: AppPolicyPatch] = [:], freshMigrations: [String] = []) {
        self.url = fileURL
        var loaded = State()
        let isNew = !FileManager.default.fileExists(atPath: fileURL.path)
        if isNew {
            loaded.patches = freshPatches
            loaded.migrations = Set(freshMigrations)
        }
        if !isNew, let data = try? Data(contentsOf: fileURL) {
            let file = try? JSONDecoder().decode(LenientFile.self, from: data)
            if let file, file.schemaVersion <= Self.schemaVersion {
                for e in file.entries where e.key.isPlace { loaded.patches[e.key] = e.patch }
                for c in file.categories { loaded.patches[.category(name: c.name)] = c.patch }
                loaded.migrations = Set(file.migrations)
            }
            if file == nil || file!.skipped > 0 || file!.schemaVersion > Self.schemaVersion {
                Self.backUp(data, of: fileURL)
            }
        }
        self.state = Mutex(loaded)
        if isNew, !freshPatches.isEmpty { try? write(loaded) }
    }

    /// Where a file that couldn't be fully read is kept: `<name>.unreadable-<date>.json`.
    static func backupURL(for fileURL: URL, at date: Date = Date()) -> URL {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let name = fileURL.deletingPathExtension().lastPathComponent + ".unreadable-\(stamp).json"
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func backUp(_ data: Data, of fileURL: URL) {
        let backup = backupURL(for: fileURL)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? data.write(to: backup, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    public var userPatches: [PolicyKey: AppPolicyPatch] { state.withLock { $0.patches } }

    public func setPatch(_ patch: AppPolicyPatch?, for key: PolicyKey) throws {
        try replaceAll { $0[key] = patch }
    }

    /// Several changes in one write (category rename, migrations).
    public func replaceAll(_ change: (inout [PolicyKey: AppPolicyPatch]) -> Void) throws {
        try state.withLock { current in
            var next = current
            change(&next.patches)
            try write(next)
            current = next
        }
    }

    public func hasRun(_ migration: String) -> Bool { state.withLock { $0.migrations.contains(migration) } }

    /// Applies a one-time change and records it, in one write.
    public func runMigration(_ migration: String, _ change: (inout [PolicyKey: AppPolicyPatch]) -> Void) throws {
        try state.withLock { current in
            guard !current.migrations.contains(migration) else { return }
            var next = current
            change(&next.patches)
            next.migrations.insert(migration)
            try write(next)
            current = next
        }
    }

    private func write(_ s: State) throws {
        var entries: [Entry] = [], categories: [CategoryEntry] = []
        for (key, patch) in s.patches {
            if case .category(let name) = key { categories.append(CategoryEntry(name: name, patch: patch)) }
            else { entries.append(Entry(key: key, patch: patch)) }
        }
        entries.sort { String(describing: $0.key) < String(describing: $1.key) }
        categories.sort { $0.name < $1.name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = FileFormat(schemaVersion: Self.schemaVersion, entries: entries,
                              categories: categories.isEmpty ? nil : categories,
                              migrations: s.migrations.isEmpty ? nil : s.migrations.sorted())
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
