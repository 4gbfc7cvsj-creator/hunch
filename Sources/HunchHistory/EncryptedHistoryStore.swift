import CryptoKit
import Foundation
import Security

/// Why a key could not be returned.
public enum KeyProviderError: Error, Equatable, Sendable {
    /// No key exists (never created, or deleted). Distinct from a failure to read an existing key.
    case notFound
}

/// Supplies the 256-bit key that encrypts the history file.
public protocol KeyProviding: Sendable {
    /// The existing key. Throws `KeyProviderError.notFound` when none exists; any other error
    /// means the key could not be read right now (locked or denied Keychain, I/O) and says
    /// nothing about whether one exists.
    func loadKey() throws -> SymmetricKey
    /// Creates, stores, and returns a new random key (replacing any existing one).
    func createKey() throws -> SymmetricKey
    func deleteKey() throws
}

/// In-memory key for tests and previews. Never touches the Keychain.
public final class InMemoryKeyProvider: KeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    public init(key: SymmetricKey? = nil) { self.key = key }
    public func loadKey() throws -> SymmetricKey {
        guard let k = lock.withLock({ key }) else { throw KeyProviderError.notFound }
        return k
    }
    public func createKey() throws -> SymmetricKey {
        lock.withLock {
            let k = SymmetricKey(size: .bits256)
            key = k
            return k
        }
    }
    public func deleteKey() throws { lock.withLock { key = nil } }
}

/// Keychain-backed key: a generic password marked this-device-only and never synchronized.
///
/// Caveat: without `kSecUseDataProtectionKeychain` this uses the file-based login keychain, which
/// does not actually enforce `...ThisDeviceOnly` accessibility. What is guaranteed is that the item
/// is not synchronizable (`kSecAttrSynchronizable = false`), so it does not go to iCloud Keychain.
public struct KeychainKeyProvider: KeyProviding {
    public struct KeychainError: Error { public let status: OSStatus }
    public let service: String
    public let account: String

    public init(service: String = "local.ghosttype.history", account: String = "history-key") { // LEGACY_GHOSTTYPE: only read to migrate old keys
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func loadKey() throws -> SymmetricKey {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { throw KeyProviderError.notFound }
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else {
            throw KeychainError(status: status)
        }
        return SymmetricKey(data: data)
    }

    public func createKey() throws -> SymmetricKey {
        try? deleteKey()
        let key = SymmetricKey(size: .bits256)
        var attrs = baseQuery
        attrs[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// How the last `EncryptedHistoryStore.loadResult()` went.
public enum HistoryLoadState: Sendable, Equatable {
    /// No history file yet.
    case noFile
    /// Read and decrypted.
    case loaded
    /// Read fine, but written by an older build without authenticated data; the next save upgrades it.
    case loadedLegacyFormat
    /// A file exists but is corrupt, or cannot be decrypted because the key is gone or does not
    /// match. It can never be read again, so starting empty and overwriting it is fine.
    case discardedUnreadable
    /// The key could not be read (Keychain locked or erroring). The file may be perfectly good, so
    /// the session starts empty and read-only: nothing may overwrite the file.
    case readOnlyKeyUnavailable
    /// The file exists but the OS refused to read it. Same read-only treatment.
    case readOnlyFileUnreadable

    public var isReadOnly: Bool { self == .readOnlyKeyUnavailable || self == .readOnlyFileUnreadable }
}

/// Persists a `VocabularyModel` as one AES-GCM encrypted file (mode 0600, atomic replace). The
/// file's magic header is passed as authenticated data (older files without it still load).
/// Loading never throws: see `HistoryLoadState` for what an empty result means.
public struct EncryptedHistoryStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hunch/history.bin")
    }

    private static let magic = Data("HNH1".utf8)
    /// The header files had under the app's first name. Still read; the next save writes `magic`.
    private static let legacyMagic = Data("GTH1".utf8) // LEGACY_GHOSTTYPE

    public let url: URL
    private let keys: any KeyProviding

    public init(url: URL = EncryptedHistoryStore.defaultURL, keys: any KeyProviding = FileKeyProvider()) {
        self.url = url
        self.keys = keys
    }

    public func load() -> VocabularyModel { loadResult().model }

    public func loadResult() -> (model: VocabularyModel, state: HistoryLoadState) {
        let empty = VocabularyModel()
        let blob: Data
        do {
            blob = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            let missing = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
                || !FileManager.default.fileExists(atPath: url.path)
            return (empty, missing ? .noFile : .readOnlyFileUnreadable)
        }
        guard blob.count > Self.magic.count,
              let header = [Self.magic, Self.legacyMagic].first(where: { blob.prefix(Self.magic.count) == $0 })
        else {
            return (empty, .discardedUnreadable)
        }
        let key: SymmetricKey
        do {
            key = try keys.loadKey()
        } catch KeyProviderError.notFound {
            return (empty, .discardedUnreadable)
        } catch {
            return (empty, .readOnlyKeyUnavailable)
        }
        guard let box = try? AES.GCM.SealedBox(combined: blob.dropFirst(header.count)) else {
            return (empty, .discardedUnreadable)
        }
        var legacy = header != Self.magic
        var plain = try? AES.GCM.open(box, using: key, authenticating: header)
        if plain == nil {
            plain = try? AES.GCM.open(box, using: key)
            legacy = plain != nil
        }
        guard let bytes = plain, let model = try? JSONDecoder().decode(VocabularyModel.self, from: bytes) else {
            return (empty, .discardedUnreadable)
        }
        return (model, legacy ? .loadedLegacyFormat : .loaded)
    }

    /// Writes the model. A key that fails to load for any reason other than "not found" aborts the
    /// save, so a Keychain hiccup never creates a second key over the first.
    public func save(_ model: VocabularyModel) throws {
        let key: SymmetricKey
        do {
            key = try keys.loadKey()
        } catch KeyProviderError.notFound {
            key = try keys.createKey()
        }
        let plain = try JSONEncoder().encode(model)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: Self.magic)
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }
        let blob = Self.magic + combined

        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: blob, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Removes the file, any leftover `.history-*.tmp` files beside it, and the key. Attempts
    /// every step and rethrows the first error.
    public func deleteAll() throws {
        let fm = FileManager.default
        var firstError: Error?
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { if firstError == nil { firstError = error } }
        }
        attempt {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        attempt {
            let dir = url.deletingLastPathComponent()
            guard fm.fileExists(atPath: dir.path) else { return }
            for name in try fm.contentsOfDirectory(atPath: dir.path)
            where name.hasPrefix(".history-") && name.hasSuffix(".tmp") {
                // A save finishing meanwhile renames its temp file away; gone is fine.
                do { try fm.removeItem(at: dir.appendingPathComponent(name)) }
                catch CocoaError.fileNoSuchFile {}
            }
        }
        attempt { try keys.deleteKey() }
        if let e = firstError { throw e }
    }
}
