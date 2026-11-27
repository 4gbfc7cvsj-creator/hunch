import Foundation

/// Writes files only the user can read: the file 0600, a folder it creates 0700.
/// Atomic: a 0600 temp file next to the target is renamed over it, so the live file is never
/// world-readable, not even for a moment, and file watchers see one replace.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Tightens an existing folder to 0700 (for data folders made before files were private).
    public static func restrictFolder(_ dir: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}
