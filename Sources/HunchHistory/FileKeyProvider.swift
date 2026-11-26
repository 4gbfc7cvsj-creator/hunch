import CryptoKit
import Foundation

/// The history key in a private file beside the history (`history.key`, mode 0600, excluded
/// from backups so a backed-up `history.bin` can't be decrypted from the backup alone).
///
/// Why not the Keychain: the app is signed with a self-signed identity that has no Team ID, so
/// the login keychain ties "Always Allow" to each build's code hash and asked for the keychain
/// password after every rebuild. Any process running as the user can read this file, but such
/// a process can already read the history file and watch typing, so little protection is lost.
///
/// Migration: the first load with no key file reads the old Keychain item once (the last
/// prompt), writes it here and deletes the item. A marker file records that the Keychain was
/// checked, so a missing key afterwards (Delete All, fresh install) never touches it again.
public struct FileKeyProvider: KeyProviding {
    public let url: URL
    let legacy: (any KeyProviding)?

    public init(url: URL = FileKeyProvider.defaultURL, legacy: (any KeyProviding)? = KeychainKeyProvider()) {
        self.url = url
        self.legacy = legacy
    }

    public static var defaultURL: URL {
        EncryptedHistoryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("history.key")
    }

    var markerURL: URL { url.appendingPathExtension("migrated") }

    public func loadKey() throws -> SymmetricKey {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            return SymmetricKey(data: data)
        }
        guard let legacy, !fm.fileExists(atPath: markerURL.path) else { throw KeyProviderError.notFound }
        do {
            let key = try legacy.loadKey()
            try write(key)
            try? legacy.deleteKey()
            try markMigrated()
            return key
        } catch KeyProviderError.notFound {
            try? markMigrated()
            throw KeyProviderError.notFound
        }
        // Any other error (keychain locked or denied) propagates: the key may exist, so the
        // next launch tries again rather than replacing it.
    }

    public func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try write(key)
        try? markMigrated()
        return key
    }

    public func deleteKey() throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
    }

    /// Writes to a 0600 temp file, then renames over the key file.
    private func write(_ key: SymmetricKey) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".key-\(UUID().uuidString).tmp")
        let data = key.withUnsafeBytes { Data($0) }
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: url) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    private func markMigrated() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: markerURL.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
    }
}
