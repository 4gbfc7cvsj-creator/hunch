import CoreFoundation
import Foundation

/// One-time move of the user's files and preferences from the app's earlier names to Hunch.
/// Runs at launch before anything opens a file under the new folders.
///
/// - Folders: `~/Library/Application Support/<old>` and `~/Library/Logs/<old>` are moved to the new
///   names when the new folder doesn't exist yet. The most recent old name that has a folder wins;
///   when the new folder already exists nothing is merged or overwritten.
/// - Preferences: keys from the old bundle IDs' domains are copied into the new one, once, without
///   replacing a key the new domain already has (the most recent old name first).
public enum RenameMigration {
    /// Earlier names, most recent first.
    public static let oldNames = ["GhostWriter", "GhostType"] // LEGACY_GHOSTTYPE
    public static let newName = "Hunch"
    /// Earlier bundle IDs, most recent first.
    public static let oldBundleIDs = ["local.ghostwriter.app", "local.ghosttype.app"] // LEGACY_GHOSTTYPE
    static let doneKey = "renamedFromOldNameMigrated"

    /// Folders under the home folder, by their parent ("Library/Logs"); each holds one folder per app name.
    public static let parents = ["Library/Application Support", "Library/Logs"]

    public enum FolderResult: Equatable, Sendable {
        case moved(from: String), nothingToMove, keptNew, failed(String)
    }

    /// Moves the old folders under `home` to the new name. Never deletes or overwrites anything.
    @discardableResult
    public static func moveFolders(home: URL, fileManager fm: FileManager = .default) -> [FolderResult] {
        parents.map { parent in
            let base = home.appendingPathComponent(parent, isDirectory: true)
            let new = base.appendingPathComponent(newName, isDirectory: true)
            let existing = oldNames.first { name in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: base.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
            }
            guard let name = existing else { return .nothingToMove }
            guard !fm.fileExists(atPath: new.path) else { return .keptNew }
            do {
                try fm.moveItem(at: base.appendingPathComponent(name, isDirectory: true), to: new)
                return .moved(from: name)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Copies the old domains' keys into `defaults` once, keeping any key `defaults` already holds.
    /// `old` is most recent first, so its earlier entries win. Returns the number of keys copied.
    @discardableResult
    public static func copyPreferences(from old: [[String: Any]], into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        var copied = 0
        for domain in old {
            for (key, value) in domain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: doneKey)
        return copied
    }

    /// The keys stored in one bundle ID's own preferences domain (not the global domain).
    public static func preferences(ofDomain id: String) -> [String: Any] {
        let domain = id as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty,
              let values = CFPreferencesCopyMultiple(keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any]
        else { return [:] }
        return values
    }

    /// Everything, for the app's launch: folders under the real home, then preferences.
    public static func runAtLaunch() {
        moveFolders(home: FileManager.default.homeDirectoryForCurrentUser)
        copyPreferences(from: oldBundleIDs.map(preferences(ofDomain:)), into: .standard)
    }
}
