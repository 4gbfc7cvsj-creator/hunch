// macOS Text Replacements (System Settings → Keyboard → Text Replacements) as autocorrect sees them:
// a shortcut ("omw") is never a typo, and where the host app doesn't apply replacements itself
// Hunch may type the replacement. Entries are the user's own data: never logged, never stored.
import Foundation

public struct TextReplacements: Sendable, Equatable {
    /// Shortcut → replacement, exactly as the system stores them (matching is case-sensitive there).
    public private(set) var entries: [String: String]
    private let lowerShortcuts: Set<String>

    public static let empty = TextReplacements([:])

    public init(_ entries: [String: String]) {
        let usable = entries.filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.key != $0.value }
        self.entries = usable
        self.lowerShortcuts = Set(usable.keys.map { $0.lowercased() })
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Longest replacement Hunch types itself; longer text stays the host's job.
    public static let maxApplied = 200

    /// True for a shortcut in any letter case ("Omw" after a sentence start): never a typo.
    public func protects(_ word: String) -> Bool {
        !lowerShortcuts.isEmpty && lowerShortcuts.contains(word.lowercased())
    }

    /// What the system replaces `typed` with, or nil. Case-sensitive, like the system. Replacements
    /// with a line break or very long ones are not applied by Hunch.
    public func replacement(for typed: String) -> String? {
        guard let with = entries[typed], with.count <= Self.maxApplied,
              !with.contains(where: \.isNewline) else { return nil }
        return with
    }

    /// Reads the items of the `NSUserDictionaryReplacementItems` default: dictionaries with `on`
    /// (enabled), `replace` (the shortcut) and `with`. Disabled or malformed items are skipped.
    public static func parse(items: [[String: Any]]) -> TextReplacements {
        var entries: [String: String] = [:]
        for item in items {
            if let on = item["on"] as? NSNumber, !on.boolValue { continue }
            guard let shortcut = item["replace"] as? String, let with = item["with"] as? String else { continue }
            entries[shortcut] = with
        }
        return TextReplacements(entries)
    }

    /// The user's system list. The default is read live (no restart needed after an edit); the app is
    /// not sandboxed, so the global domain is readable. Cached for a few seconds: this is asked on
    /// every typed word.
    public static func system() -> TextReplacements { SystemTextReplacements.shared.current() }
}

private final class SystemTextReplacements: @unchecked Sendable {
    static let shared = SystemTextReplacements()
    private let lock = NSLock()
    private var cached: (at: Date, value: TextReplacements)?
    private let ttl: TimeInterval = 5

    func current() -> TextReplacements {
        lock.lock(); defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < ttl { return cached.value }
        let items = UserDefaults.standard.array(forKey: "NSUserDictionaryReplacementItems") as? [[String: Any]] ?? []
        let value = TextReplacements.parse(items: items)
        cached = (Date(), value)
        return value
    }
}

/// Apps whose text views apply system Text Replacements themselves (Cocoa's automatic text
/// replacement, WebKit): Hunch leaves the replacing to them, so a shortcut is never replaced
/// twice. Everywhere else (Chromium, Electron, terminals, custom editors) the host ignores them.
public enum HostTextReplacements {
    public static let nativeApps: Set<String> = [
        "com.apple.TextEdit", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.iChat",
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.apple.Stickies",
        "com.apple.reminders", "com.apple.Safari", "com.apple.freeform", "com.apple.Journal",
    ]

    public static func appliesItself(bundleID: String) -> Bool { nativeApps.contains(bundleID) }
}
