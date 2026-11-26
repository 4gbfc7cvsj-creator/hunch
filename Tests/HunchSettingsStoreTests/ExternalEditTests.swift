import Foundation
import Testing
import HunchCore
@testable import HunchSettingsStore

private func tempFile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-settings-ext-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("settings.json")
}

/// Writes settings the way a person editing the file would (no help from the store).
private func externalWrite(_ url: URL, atomic: Bool, _ edit: (inout [String: Any]) -> Void) throws {
    var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    edit(&object)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    if atomic {
        // Editor-style save: write a sibling temp file, then rename it over the original.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".settings.json.tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } else if !FileManager.default.fileExists(atPath: url.path) {
        try data.write(to: url)
    } else {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}

private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite struct ExternalEditTests {
    @Test func reloadPicksUpExternalEditAndYields() async throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.length = .short }
        var it = store.changes().makeAsyncIterator()
        #expect(await it.next()?.length == .short)

        try externalWrite(url, atomic: false) { $0["length"] = "long" }
        #expect(store.reloadFromDisk())
        #expect(store.current().length == .long)
        #expect(await it.next()?.length == .long)
        // Nothing changed since: a second reload is a no-op.
        #expect(!store.reloadFromDisk())
    }

    @Test func halfWrittenFileIsIgnored() throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.length = .short }
        try Data("{ \"length\": ".utf8).write(to: url)
        #expect(!store.reloadFromDisk())
        #expect(store.current().length == .short)
        // A write while the file is unparseable stays in memory and leaves the user's file alone.
        try store.update { $0.debugLogging = true }
        #expect(store.current().debugLogging)
        #expect(try Data(contentsOf: url) == Data("{ \"length\": ".utf8))
    }

    @Test func writeNeverClobbersUnseenExternalEdit() throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.length = .short }
        // Edited on disk; the store hasn't been told.
        try externalWrite(url, atomic: true) { $0["customInstructions"] = "edited by hand" }
        try store.update { $0.debugLogging = true }
        let reread = JSONSettingsStore(fileURL: url).current()
        #expect(reread.customInstructions == "edited by hand")
        #expect(reread.debugLogging)
        #expect(reread.length == .short)
        #expect(store.current() == reread)
    }

    @Test func newerSchemaFileIsNeverOverwritten() throws {
        let url = try tempFile()
        let original = Data(#"{"schemaVersion": 99, "enabled": false, "futureKey": [1, 2]}"#.utf8)
        try original.write(to: url)
        var fresh = HunchSettings()
        fresh.modelsFolderPath = "/fresh"
        let store = JSONSettingsStore(fileURL: url, freshDefaults: fresh)
        #expect(store.isReadOnly)
        #expect(store.newerSchemaVersion == 99)
        #expect(store.current() == fresh)

        try store.update { $0.length = .long }
        #expect(store.current().length == .long)  // applied in memory
        try store.ensureFileExists()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func externalSwitchToNewerSchemaStopsWrites() throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.length = .short }
        try externalWrite(url, atomic: true) { $0["schemaVersion"] = 7 }
        let newer = try Data(contentsOf: url)
        try store.update { $0.debugLogging = true }
        #expect(store.isReadOnly)
        #expect(try Data(contentsOf: url) == newer)

        // Replaced by a file this build understands: writable again.
        try externalWrite(url, atomic: true) { $0["schemaVersion"] = 2 }
        store.reloadFromDisk()
        #expect(!store.isReadOnly)
        try store.update { $0.length = .long }
        #expect(JSONSettingsStore(fileURL: url).current().length == .long)
    }

    @Test func watcherFollowsInPlaceAndAtomicEdits() async throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.length = .short }
        store.startWatching()
        defer { store.stopWatching() }

        try externalWrite(url, atomic: false) { $0["length"] = "long" }
        #expect(await eventually { store.current().length == .long })

        // Atomic replace: the original inode goes away; the watcher must re-arm on the new file.
        try externalWrite(url, atomic: true) { $0["customInstructions"] = "one" }
        #expect(await eventually { store.current().customInstructions == "one" })

        // In-place edit of the replacement proves the file source now tracks the new inode.
        try externalWrite(url, atomic: false) { $0["customInstructions"] = "two" }
        #expect(await eventually { store.current().customInstructions == "two" })

        // Deleted then recreated.
        try FileManager.default.removeItem(at: url)
        try externalWrite(url, atomic: false) { $0["length"] = "ultra" }
        #expect(await eventually { store.current().length == .ultra })

        // The store's own writes don't bounce back as changes.
        try store.update { $0.debugLogging = true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.current().debugLogging)
        #expect(store.current().length == .ultra)
    }

    @Test func watcherDeliversThroughChanges() async throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.ensureFileExists()
        store.startWatching()
        defer { store.stopWatching() }
        var it = store.changes().makeAsyncIterator()
        _ = await it.next()
        try externalWrite(url, atomic: true) { $0["enabled"] = false }
        #expect(await it.next()?.enabled == false)
    }
}
