import Foundation
import HunchCore

/// Saved typed-line anchors (`TypedTextAnchor`), one per app and field height, so after a relaunch a
/// field with no text positions gets its caret placed from the first letter instead of after the
/// next look. `TypedAnchorBook` still forgets a saved anchor that stops matching. Holds bundle IDs
/// and numbers only, never text. Main-thread use only.
public final class TypedAnchorStore {
    /// The field's height, not its width: an app draws its line at the same offsets in a field of
    /// any width (Chrome's address bar as its window is resized), so one look covers them all.
    public struct Key: Hashable, Codable, Sendable {
        public var bundleID: String
        public var height: Int
        public init(bundleID: String, height: Int) {
            self.bundleID = bundleID
            self.height = height
        }
    }

    private struct Entry: Codable {
        var key: Key
        var anchor: TypedTextAnchor
        var savedAt: Date
    }

    /// Oldest entries are dropped beyond this.
    public static let capacity = 64

    private let fileURL: URL?
    private var entries: [Key: Entry] = [:]

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in list where entry.anchor.isValid { entries[entry.key] = entry }
    }

    /// Every saved anchor, to seed a `TypedAnchorBook`.
    public var anchors: [Key: TypedTextAnchor] { entries.mapValues(\.anchor) }

    /// Saves `anchor` for `key`; nil removes it. Writes only when something changed.
    public func set(_ anchor: TypedTextAnchor?, for key: Key, at date: Date = Date()) {
        guard entries[key]?.anchor != anchor else { return }
        if let anchor {
            entries[key] = Entry(key: key, anchor: anchor, savedAt: date)
            if entries.count > Self.capacity {
                let oldest = entries.values.sorted { $0.savedAt < $1.savedAt }.prefix(entries.count - Self.capacity)
                for e in oldest { entries[e.key] = nil }
            }
        } else {
            entries[key] = nil
        }
        write()
    }

    private func write() {
        guard let fileURL else { return }
        let list = entries.values.sorted { $0.savedAt < $1.savedAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? PrivateFile.write(data, to: fileURL)
    }
}
