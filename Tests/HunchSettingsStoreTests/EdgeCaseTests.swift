import Foundation
import Testing
import HunchCore
@testable import HunchSettingsStore

private func tempFile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-settings-edge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("settings.json")
}

private func writeJSON(_ url: URL, _ object: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}

private func eventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(4)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func diskSettings(_ url: URL) -> HunchSettings? {
    if case .settings(let s) = JSONSettingsStore.read(url) { return s }
    return nil
}

@Suite struct EdgeCaseTests {
    @Test func editsWhileUnparseableSurviveReload() throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { s in s.length = .short }
        let broken = Data("{ length: ".utf8)
        try broken.write(to: url)
        try store.update { s in s.length = .long }
        #expect(store.current().length == .long)
        #expect(try Data(contentsOf: url) == broken)
        #expect(!store.reloadFromDisk())
        #expect(try Data(contentsOf: url) == broken)

        try writeJSON(url, ["length": "short", "schemaVersion": 2])
        _ = store.reloadFromDisk()
        #expect(store.current().length == .long)
        #expect(diskSettings(url)?.length == .long)
    }

    @Test func updateAfterRecoveryKeepsPendingEdit() throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try Data("garbage".utf8).write(to: url)
        try store.update { s in s.length = .long }
        try writeJSON(url, ["length": "short"])
        try store.update { _ in }
        #expect(diskSettings(url)?.length == .long)
    }

    @Test func unparseableAtStartIsNotOverwritten() throws {
        let url = try tempFile()
        let broken = Data("{ nope".utf8)
        try broken.write(to: url)
        let store = JSONSettingsStore(fileURL: url)
        try store.update { s in s.length = .long }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func watcherSurvivesSettingsFolderDeletion() async throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { s in s.length = .short }
        store.startWatching()
        defer { store.stopWatching() }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: dir)
        try await Task.sleep(for: .milliseconds(400))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeJSON(url, ["length": "long"])
        #expect(await eventually { store.current().length == .long })
        try writeJSON(url, ["length": "short"])
        #expect(await eventually { store.current().length == .short })
    }

    @Test func writeAfterFolderDeletionRecreatesFromMemory() throws {
        let url = try tempFile()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { s in s.length = .long }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try store.update { s in s.length = .short }
        #expect(diskSettings(url)?.length == .short)
    }
}

@Test func settingsWithRemovedLearnedPhrasesSwitchStillLoad() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HunchSettings())) as! [String: Any]
    json["experimentalLearnedPhrases"] = true
    json["length"] = "long"
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let store = JSONSettingsStore(fileURL: url)
    #expect(store.current().length == .long)
}
