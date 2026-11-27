import Foundation
import HunchCore
import Testing

@Suite struct PrivateFileTests {
    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("privatefile-\(UUID().uuidString)")
    }

    @Test func newFileAndFolderAreOwnerOnly() throws {
        let dir = tempDir().appendingPathComponent("Hunch")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let file = dir.appendingPathComponent("settings.json")
        try PrivateFile.write(Data("{}".utf8), to: file)
        #expect(try mode(file) == 0o600)
        #expect(try mode(dir) == 0o700)
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
    }

    @Test func replacingAWorldReadableFileMakesItPrivate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("places.json")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try PrivateFile.write(Data("new".utf8), to: file)
        #expect(try mode(file) == 0o600)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func restrictFolderTightensAnExistingFolder() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        PrivateFile.restrictFolder(dir)
        #expect(try mode(dir) == 0o700)
    }
}
