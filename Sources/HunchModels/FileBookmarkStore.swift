import Foundation
import HunchCore

/// Persists the models-folder bookmark as JSON (default: `~/Library/Application Support/Hunch/folder.json`).
///
/// Chosen over UserDefaults because the file is shared by every process that uses the same
/// location (the app, the `hunch-eval` CLI, tests with a temp path), is not tied to a bundle
/// identifier, is trivially inspectable, and is written atomically.
public struct FileBookmarkStore: BookmarkStoring {
    public let fileURL: URL

    public init(fileURL: URL = FileBookmarkStore.defaultFileURL) { self.fileURL = fileURL }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Hunch", isDirectory: true).appendingPathComponent("folder.json")
    }

    public func load() -> FolderBookmark? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FolderBookmark.self, from: data)
    }

    public func save(_ bookmark: FolderBookmark?) throws {
        let fm = FileManager.default
        guard let bookmark else {
            if fm.fileExists(atPath: fileURL.path) { try fm.removeItem(at: fileURL) }
            return
        }
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(bookmark).write(to: fileURL, options: .atomic)
    }
}
