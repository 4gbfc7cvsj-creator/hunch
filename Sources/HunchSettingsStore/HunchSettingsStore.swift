// HunchSettingsStore: persistence for HunchSettings (design §4, track E).
import Foundation
import HunchCore
import Synchronization

public enum HunchSettingsStoreModule {
    /// `~/Library/Application Support/Hunch/settings.json` (same location as the M1 file).
    public static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Hunch/settings.json")
    }
}

/// JSON file store. The file holds the `HunchSettings` keys at top level plus `schemaVersion`,
/// so M1 files (no version key) load unchanged. Missing or malformed keys fall back to defaults.
///
/// External edits: `startWatching()` follows the file (in-place writes and atomic replaces) and
/// reloads it into the store, yielding through `changes()`. Before every write the store checks
/// whether the file changed since it last read or wrote it; if so it re-reads it and applies the
/// mutation on top of the edited contents, so a concurrent external edit is never clobbered.
///
/// Unparseable file (the user is mid-edit): the file is never overwritten while it is unparseable.
/// Edits made in the app meanwhile stay in memory, and the settings from before the first such
/// edit are remembered (`pendingBase`). Once the file parses again (next reload or write), each
/// top-level key the app changed since then is applied on top of the user's file, so key by key
/// neither side's change is lost (if both touched the same key, the app's value wins), and the
/// merged result is written. If the file stays broken it is left exactly as the user has it.
/// If the settings folder or file disappears, the next write recreates both from memory.
///
/// Newer schema: a file written by a newer Hunch is never overwritten. The store keeps working
/// in memory (`isReadOnly` is true) until the file is replaced by one it understands.
public final class JSONSettingsStore: SettingsStoring {
    public static let schemaVersion = 2
    private static let versionKey = "schemaVersion"

    /// What the file currently holds.
    enum DiskContents: Equatable {
        case missing
        /// Not a JSON object (garbage, or an editor's half-written save).
        case unreadable
        case newerSchema(Int)
        case settings(HunchSettings)
    }

    private struct State {
        var settings: HunchSettings
        var continuations: [UUID: AsyncStream<HunchSettings>.Continuation] = [:]
        /// The file as this store last read or wrote it; nil when it didn't exist.
        var fingerprint: FileFingerprint?
        /// Set while the file on disk has a newer schema than this build supports.
        var newerSchemaVersion: Int?
        /// Settings before the first in-app edit made while the file was unparseable.
        var pendingBase: HunchSettings?
    }

    private let url: URL
    private let state: Mutex<State>
    private let watcher = Mutex<SettingsFileWatcher?>(nil)

    /// - Parameter freshDefaults: used when no readable file exists, or the file is from a newer schema.
    public init(fileURL: URL, freshDefaults: HunchSettings = HunchSettings()) {
        self.url = fileURL
        let fingerprint = FileFingerprint(path: fileURL.path)
        var initial = State(settings: freshDefaults, fingerprint: fingerprint)
        switch Self.read(fileURL) {
        case .settings(let loaded): initial.settings = loaded
        case .newerSchema(let version): initial.newerSchemaVersion = version
        case .missing: break
        case .unreadable: initial.fingerprint = nil  // never mistaken for a file we wrote
        }
        self.state = Mutex(initial)
    }

    deinit { stopWatching() }

    public func current() -> HunchSettings { state.withLock { $0.settings } }

    /// True while the file has a newer schema: changes apply in memory but are not saved.
    public var isReadOnly: Bool { state.withLock { $0.newerSchemaVersion != nil } }

    /// The schema version of the file when it is newer than this build supports.
    public var newerSchemaVersion: Int? { state.withLock { $0.newerSchemaVersion } }

    public func update(_ mutate: @Sendable (inout HunchSettings) -> Void) throws {
        try state.withLock { s in
            var base = s.settings
            var canWrite = s.newerSchemaVersion == nil
            var needsWrite = false
            let onDisk = FileFingerprint(path: url.path)
            if onDisk != s.fingerprint {
                // Edited behind our back since we last looked: build on the edit, don't clobber it.
                switch Self.read(url) {
                case .settings(let edited):
                    base = Self.applyPending(edited, in: &s)
                    needsWrite = base != edited
                    publish(base, in: &s)  // the edit stands even if our write below fails
                    s.newerSchemaVersion = nil
                    s.fingerprint = onDisk
                    canWrite = true
                case .newerSchema(let version):
                    s.newerSchemaVersion = version
                    s.fingerprint = onDisk
                    canWrite = false
                case .missing:
                    s.newerSchemaVersion = nil
                    s.fingerprint = nil
                    canWrite = true
                    needsWrite = s.pendingBase != nil
                    s.pendingBase = nil
                case .unreadable:
                    // Probably mid-save in an editor: keep the change in memory only (see type docs).
                    if s.pendingBase == nil { s.pendingBase = s.settings }
                    canWrite = false
                }
            }
            var next = base
            mutate(&next)
            if canWrite, next != base || needsWrite {
                try write(next)
                s.fingerprint = FileFingerprint(path: url.path)
            }
            publish(next, in: &s)
        }
    }

    /// Yields the current value first, then every later change.
    public func changes() -> AsyncStream<HunchSettings> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            state.withLock { s in
                s.continuations[id] = continuation
                continuation.yield(s.settings)
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: External edits

    /// Re-reads the file if it changed since the store last read or wrote it. A missing or
    /// half-written file leaves the settings alone; a newer-schema file makes the store read-only.
    /// Returns true when the settings changed.
    @discardableResult
    public func reloadFromDisk() -> Bool {
        state.withLock { s in
            let onDisk = FileFingerprint(path: url.path)
            guard onDisk != s.fingerprint else { return false }
            switch Self.read(url) {
            case .missing:
                s.fingerprint = nil
                s.newerSchemaVersion = nil
                if s.pendingBase != nil {  // folder/file gone: recreate it from memory
                    s.pendingBase = nil
                    if (try? write(s.settings)) != nil { s.fingerprint = FileFingerprint(path: url.path) }
                }
                return false
            case .unreadable:
                return false  // not recorded, so the next event or write looks again
            case .newerSchema(let version):
                s.fingerprint = onDisk
                s.newerSchemaVersion = version
                return false
            case .settings(let edited):
                s.fingerprint = onDisk
                s.newerSchemaVersion = nil
                let hadPending = s.pendingBase != nil
                let merged = Self.applyPending(edited, in: &s)
                let changed = merged != s.settings
                publish(merged, in: &s)
                if hadPending, merged != edited {
                    if (try? write(merged)) != nil {
                        s.fingerprint = FileFingerprint(path: url.path)
                    } else {
                        s.pendingBase = s.settings  // retry later; nothing is dropped
                        s.fingerprint = nil
                    }
                }
                return changed
            }
        }
    }

    /// Follows the file for external edits (including atomic replaces) until `stopWatching()`.
    public func startWatching() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = SettingsFileWatcher(fileURL: url) { [weak self] in self?.reloadFromDisk() }
        let old = watcher.withLock { w -> SettingsFileWatcher? in
            let previous = w
            w = fresh
            return previous
        }
        old?.stop()
        fresh.start()
        // Catch anything written between init and now.
        reloadFromDisk()
    }

    public func stopWatching() {
        let old = watcher.withLock { w -> SettingsFileWatcher? in
            let previous = w
            w = nil
            return previous
        }
        old?.stop()
    }

    /// Writes the current settings when there is no file yet (so there's something to open).
    /// Does nothing for a read-only store.
    public func ensureFileExists() throws {
        try state.withLock { s in
            guard s.newerSchemaVersion == nil, !FileManager.default.fileExists(atPath: url.path) else { return }
            try write(s.settings)
            s.fingerprint = FileFingerprint(path: url.path)
        }
    }

    /// Applies the app's top-level key changes since `pendingBase` on top of `edited` and clears it.
    private static func applyPending(_ edited: HunchSettings, in s: inout State) -> HunchSettings {
        guard let pendingBase = s.pendingBase else { return edited }
        s.pendingBase = nil
        func object(_ v: HunchSettings) -> [String: Any] {
            (try? JSONEncoder().encode(v))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let base = object(pendingBase), mine = object(s.settings)
        var result = object(edited)
        for (key, value) in mine where !((value as? NSObject)?.isEqual(base[key]) ?? false) {
            result[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let merged = try? JSONDecoder().decode(HunchSettings.self, from: data) else { return s.settings }
        return merged
    }

    private func publish(_ next: HunchSettings, in s: inout State) {
        guard next != s.settings else { return }
        s.settings = next
        for c in s.continuations.values { c.yield(next) }
    }

    // MARK: Disk

    private func write(_ settings: HunchSettings) throws {
        let data = try Self.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) -> DiskContents {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        if let v = file[versionKey] as? Int, v > schemaVersion { return .newerSchema(v) }
        return decodeTolerant(data).map { .settings($0) } ?? .unreadable
    }

    static func encode(_ settings: HunchSettings) throws -> Data {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any] ?? [:]
        object[versionKey] = schemaVersion
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Returns nil when the data isn't a JSON object or comes from a newer schema.
    static func decodeTolerant(_ data: Data) -> HunchSettings? {
        guard var file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let v = file[versionKey] as? Int, v > schemaVersion { return nil }
        let decoder = JSONDecoder()
        guard let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(HunchSettings())) as? [String: Any]
        else { return nil }
        var merged = defaults
        if let bindings = file["bindings"] as? [String: Any] { file["bindings"] = migrateBindings(bindings) }
        file = migrateWriteSource(file)
        file = migrateLanguageModel(file)
        file = migrateAppearanceColor(file)
        for (key, value) in file where key != versionKey {
            var candidate = merged
            candidate[key] = merge(defaults[key], value)
            if let d = try? JSONSerialization.data(withJSONObject: candidate),
               (try? decoder.decode(HunchSettings.self, from: d)) != nil {
                merged = candidate
            }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? decoder.decode(HunchSettings.self, from: d)
    }

    /// Files from before write for me: Shift+Option+Tab was the default "pause in current app" key and
    /// is now write for me's. A file with no write-for-me key that still has the old default for the
    /// pause unbinds the pause, so the write key takes the chord without a clash.
    static func migrateBindings(_ bindings: [String: Any]) -> [String: Any] {
        guard bindings["writeForMe"] == nil,
              let toggle = bindings["toggleCurrentApp"] as? [String: Any],
              (toggle["keyCode"] as? Int) == Int(KeyChord.optionShiftTab.keyCode),
              (toggle["modifiers"] as? Int) == Int(KeyChord.optionShiftTab.modifiers) else { return bindings }
        var out = bindings
        out["toggleCurrentApp"] = NSNull()
        return out
    }

    /// Files from before per-category sources: Write for me used the endpoint whenever one was
    /// configured. Such a file gets the endpoint copied to Writing, with Writing set to use it.
    static func migrateWriteSource(_ file: [String: Any]) -> [String: Any] {
        guard file["writeEngine"] == nil, let endpoint = file["endpoint"] as? [String: Any] else { return file }
        var out = file
        out["writeEngine"] = EngineKind.endpoint.rawValue
        if out["writeEndpoint"] == nil { out["writeEndpoint"] = endpoint }
        return out
    }

    /// Files from before the Language Model (autocomplete on instruct models): the separate writing
    /// model goes off (Write for me then shares the loaded Language Model), and a base autocomplete
    /// choice is switched to an instruct model once (`instructSwitchPending`, done by the app).
    static func migrateLanguageModel(_ file: [String: Any]) -> [String: Any] {
        guard file["instructSwitchPending"] == nil else { return file }
        var out = file
        out["useWritingModel"] = false
        out["instructSwitchPending"] = true
        return out
    }

    /// Appearance from before Follow effect (no `version`): the old default color (Match text)
    /// switches to Follow effect once, and slider edits to built-in styles get the style's final
    /// color, so they don't lose it for having been saved first.
    static func migrateAppearanceColor(_ file: [String: Any]) -> [String: Any] {
        guard var appearance = file["appearance"] as? [String: Any], appearance["version"] == nil else { return file }
        if (appearance["color"] as? String) == SuggestionColorChoice.matchText.rawValue {
            appearance["color"] = SuggestionColorChoice.followEffect.rawValue
        }
        if var tuning = appearance["presetTuning"] as? [String: Any] {
            for (style, value) in tuning {
                guard var recipe = value as? [String: Any], recipe["finalColorOn"] == nil,
                      let animation = PopInAnimation(rawValue: style),
                      let data = try? JSONEncoder().encode(PopInRecipe.preset(animation)),
                      let preset = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                recipe["finalColorOn"] = preset["finalColorOn"]
                recipe["finalColor"] = preset["finalColor"]
                tuning[style] = recipe
            }
            appearance["presetTuning"] = tuning
        }
        appearance["version"] = AppearanceSettings.currentVersion
        var out = file
        out["appearance"] = appearance
        return out
    }

    /// Nested objects get missing keys filled from the defaults.
    private static func merge(_ base: Any?, _ override: Any) -> Any {
        guard let b = base as? [String: Any], let o = override as? [String: Any] else { return override }
        var out = b
        for (k, v) in o { out[k] = merge(b[k], v) }
        return out
    }
}

/// Identity and modification state of a file, used to notice edits made by someone else.
/// The inode changes on an atomic replace; size, mtime and ctime change on in-place writes.
struct FileFingerprint: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mtimeSec: Int
    let mtimeNsec: Int
    let ctimeSec: Int
    let ctimeNsec: Int

    /// nil when the file doesn't exist (or can't be stat'ed).
    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
        mtimeSec = st.st_mtimespec.tv_sec
        mtimeNsec = st.st_mtimespec.tv_nsec
        ctimeSec = st.st_ctimespec.tv_sec
        ctimeNsec = st.st_ctimespec.tv_nsec
    }
}
