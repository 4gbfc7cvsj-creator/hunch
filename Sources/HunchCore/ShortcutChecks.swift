extension KeyChord {
    /// Keys that type nothing, so they can be a shortcut on their own (or with only Shift).
    private static let nonTypingKeys: Set<UInt16> = [
        48, 53,                                   // Tab, Esc
        123, 124, 125, 126,                       // arrows
        114, 115, 116, 117, 119, 121,             // Help, Home, Page Up, ⌦, End, Page Down
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,       // F13–F20
    ]

    /// True when the chord would swallow ordinary typing: a letter, digit, symbol, Space, Return or
    /// Delete with no Control, Option or Command ("A", "⇧A", "Space").
    public var typesText: Bool {
        modifiers & (0x40000 | 0x80000 | 0x100000) == 0 && !Self.nonTypingKeys.contains(keyCode)
    }
}

extension HunchSettings {
    /// The shortcuts Settings → Shortcuts lists, by the names it shows.
    public static let namedShortcuts: [(name: String, keyPath: KeyPath<HunchSettings, KeyChord?> & Sendable)] = [
        ("Accept next word", \.bindings.word),
        ("Accept whole suggestion", \.bindings.full),
        ("Next suggestion style", \.bindings.styleNext),
        ("Previous suggestion style", \.bindings.stylePrevious),
        ("Write for me", \.bindings.writeForMe),
        ("Dictation", \.dictation.shortcut),
        ("Voice instruction", \.voiceInstruction.shortcut),
    ]

    /// Names of the other listed shortcuts set to the same chord as `keyPath` (empty when unset or unique).
    /// The voice instruction shortcut only counts while that experiment is on.
    public func shortcutConflicts(for keyPath: KeyPath<HunchSettings, KeyChord?>) -> [String] {
        guard let chord = self[keyPath: keyPath] else { return [] }
        return Self.namedShortcuts.compactMap { entry in
            guard entry.keyPath != keyPath, self[keyPath: entry.keyPath] == chord else { return nil }
            if entry.keyPath == \HunchSettings.voiceInstruction.shortcut || keyPath == \HunchSettings.voiceInstruction.shortcut,
               !experimentalVoiceInstructions { return nil }
            return entry.name
        }
    }
}
