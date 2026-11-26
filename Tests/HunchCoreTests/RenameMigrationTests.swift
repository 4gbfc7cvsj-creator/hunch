import Foundation
import Testing
@testable import HunchCore

@Suite struct RenameMigrationTests {
    private let oldest = RenameMigration.oldNames.last!   // the first name
    private let recent = RenameMigration.oldNames.first!  // the name just before Hunch

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in home: URL) -> String? {
        (try? Data(contentsOf: home.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func movesTheFirstNamesFoldersToHunch() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", "Library/Application Support/\(oldest)/settings.json", in: home)
        try write("key", "Library/Application Support/\(oldest)/history.key", in: home)
        try write("line", "Library/Logs/\(oldest)/perf.log", in: home)

        #expect(RenameMigration.moveFolders(home: home) == [.moved(from: oldest), .moved(from: oldest)])
        #expect(read("Library/Application Support/Hunch/settings.json", in: home) == "{}")
        #expect(read("Library/Application Support/Hunch/history.key", in: home) == "key")
        #expect(read("Library/Logs/Hunch/perf.log", in: home) == "line")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Logs/\(oldest)").path))

        // A second launch finds nothing left to move.
        #expect(RenameMigration.moveFolders(home: home) == [.nothingToMove, .nothingToMove])
    }

    @Test func prefersTheMostRecentOldName() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("first", "Library/Application Support/\(oldest)/settings.json", in: home)
        try write("recent", "Library/Application Support/\(recent)/settings.json", in: home)

        #expect(RenameMigration.moveFolders(home: home) == [.moved(from: recent), .nothingToMove])
        #expect(read("Library/Application Support/Hunch/settings.json", in: home) == "recent")
        #expect(read("Library/Application Support/\(oldest)/settings.json", in: home) == "first")
    }

    @Test func neverOverwritesAnExistingHunchFolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("old", "Library/Application Support/\(oldest)/settings.json", in: home)
        try write("new", "Library/Application Support/Hunch/settings.json", in: home)

        #expect(RenameMigration.moveFolders(home: home) == [.keptNew, .nothingToMove])
        #expect(read("Library/Application Support/Hunch/settings.json", in: home) == "new")
        #expect(read("Library/Application Support/\(oldest)/settings.json", in: home) == "old")
    }

    @Test func copiesPreferencesOnceWithoutReplacingNewOnes() throws {
        let suite = "rename-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("model", forKey: "settingsPane")

        let copied = RenameMigration.copyPreferences(
            from: [["pace": "recent"], ["settingsPane": "general", "pace": "first", "emptyFieldStarts": Data([1, 2])]],
            into: defaults)
        #expect(copied == 2)
        #expect(defaults.string(forKey: "settingsPane") == "model")
        #expect(defaults.string(forKey: "pace") == "recent")
        #expect(defaults.data(forKey: "emptyFieldStarts") == Data([1, 2]))

        // Runs only once.
        #expect(RenameMigration.copyPreferences(from: [["other": 1]], into: defaults) == 0)
        #expect(defaults.object(forKey: "other") == nil)
    }
}
