import HunchCore

/// Modifier masking and chord comparison. Only command/option/control/shift take part in
/// matching; Caps Lock, Fn, numeric-pad and device-specific bits are ignored.
public enum ChordMatcher {
    public static let shift: UInt64 = 0x20000
    public static let control: UInt64 = 0x40000
    public static let option: UInt64 = 0x80000
    public static let command: UInt64 = 0x100000
    public static let modifierMask: UInt64 = shift | control | option | command

    public static let tabKeyCode: UInt16 = 48
    public static let escapeKeyCode: UInt16 = 53

    /// Reduces raw `CGEventFlags.rawValue` to the four modifiers that matter.
    @inlinable
    public static func mask(_ rawFlags: UInt64) -> UInt64 { rawFlags & modifierMask }

    /// Builds a chord from a raw key code and raw event flags.
    public static func chord(keyCode: UInt16, rawFlags: UInt64) -> KeyChord {
        KeyChord(keyCode: keyCode, modifiers: mask(rawFlags))
    }

    /// True when `event` is the same key with exactly the same (masked) modifiers as `binding`.
    public static func matches(_ event: KeyChord, _ binding: KeyChord?) -> Bool {
        guard let binding else { return false }
        return event.keyCode == binding.keyCode && mask(event.modifiers) == mask(binding.modifiers)
    }

    public static func isTabBased(_ chord: KeyChord) -> Bool { chord.keyCode == tabKeyCode }

    /// The Tab key with no modifier: what "Accept with Tab: off" hands back to the app.
    public static func isPlainTab(_ chord: KeyChord) -> Bool { isTabBased(chord) && mask(chord.modifiers) == 0 }

    public static let backspaceKeyCode: UInt16 = 51

    /// Backspace (Delete) with no modifier: the key that undoes an automatic fix.
    public static func isPlainBackspace(_ chord: KeyChord) -> Bool {
        chord.keyCode == backspaceKeyCode && mask(chord.modifiers) == 0
    }
}
