import CryptoKit
import Foundation
import Testing
@testable import HunchHistory

private func tempKeyURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-key-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("history.key")
}

private func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

/// Counts keychain reads so tests can check the old store is touched once at most.
private final class CountingKeys: KeyProviding, @unchecked Sendable {
    let inner: InMemoryKeyProvider
    var loads = 0
    var failWith: Error?
    init(_ inner: InMemoryKeyProvider) { self.inner = inner }
    func loadKey() throws -> SymmetricKey {
        loads += 1
        if let failWith { throw failWith }
        return try inner.loadKey()
    }
    func createKey() throws -> SymmetricKey { try inner.createKey() }
    func deleteKey() throws { try inner.deleteKey() }
}

@Suite struct FileKeyProviderTests {
    @Test func createLoadDelete() throws {
        let url = tempKeyURL()
        let p = FileKeyProvider(url: url, legacy: nil)
        #expect(throws: KeyProviderError.notFound) { try p.loadKey() }
        let k = try p.createKey()
        #expect(bytes(try p.loadKey()) == bytes(k))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // createKey replaces.
        let k2 = try p.createKey()
        #expect(bytes(try p.loadKey()) == bytes(k2))
        try p.deleteKey()
        try p.deleteKey()
        #expect(throws: KeyProviderError.notFound) { try p.loadKey() }
    }

    @Test func migratesOldKeychainKeyOnce() throws {
        let url = tempKeyURL()
        let mem = InMemoryKeyProvider()
        let old = try mem.createKey()
        let legacy = CountingKeys(mem)
        let p = FileKeyProvider(url: url, legacy: legacy)
        #expect(bytes(try p.loadKey()) == bytes(old))
        #expect(legacy.loads == 1)
        // Moved: the old item is gone and later loads read the file.
        #expect(throws: KeyProviderError.notFound) { try mem.loadKey() }
        #expect(bytes(try p.loadKey()) == bytes(old))
        #expect(legacy.loads == 1)
        // After Delete All the old store is never consulted again.
        try p.deleteKey()
        #expect(throws: KeyProviderError.notFound) { try p.loadKey() }
        #expect(legacy.loads == 1)
    }

    @Test func noOldKeyChecksOnce() throws {
        let legacy = CountingKeys(InMemoryKeyProvider())
        let p = FileKeyProvider(url: tempKeyURL(), legacy: legacy)
        #expect(throws: KeyProviderError.notFound) { try p.loadKey() }
        #expect(throws: KeyProviderError.notFound) { try p.loadKey() }
        #expect(legacy.loads == 1)
    }

    @Test func deniedKeychainRetriesLater() throws {
        let mem = InMemoryKeyProvider()
        let old = try mem.createKey()
        let legacy = CountingKeys(mem)
        legacy.failWith = KeychainKeyProvider.KeychainError(status: -128)  // user cancelled
        let p = FileKeyProvider(url: tempKeyURL(), legacy: legacy)
        #expect(throws: KeychainKeyProvider.KeychainError.self) { try p.loadKey() }
        legacy.failWith = nil
        #expect(bytes(try p.loadKey()) == bytes(old))
        #expect(legacy.loads == 2)
    }

    @Test func storeRoundTripsWithFileKey() async throws {
        let dir = tempKeyURL().deletingLastPathComponent()
        let keys = FileKeyProvider(url: dir.appendingPathComponent("history.key"), legacy: nil)
        let store = EncryptedHistoryStore(url: dir.appendingPathComponent("history.bin"), keys: keys)
        try store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: keys.url.path))
    }
}
