/// Decides whether a key event typed a visible character, from its UTF-16 payload. The payload
/// is examined in place and never stored.
public enum PrintableDetector {
    public static func isPrintable(utf16 units: UnsafeBufferPointer<UInt16>, modifiers: UInt64) -> Bool {
        // Command/Control chords are shortcuts, not typing.
        if modifiers & (ChordMatcher.command | ChordMatcher.control) != 0 { return false }
        if units.isEmpty { return false }
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
            if !isPrintableScalar(scalar) { return false }
        }
        return true
    }

    public static func isPrintable(utf16 units: [UInt16], modifiers: UInt64) -> Bool {
        units.withUnsafeBufferPointer { isPrintable(utf16: $0, modifiers: modifiers) }
    }

    static func isPrintableScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return false }       // C0, DEL, C1 controls
        if (0xF700...0xF8FF).contains(v) { return false }                // AppKit function-key range
        if v == 0xFFFD { return false }                                  // decoding failure
        return true
    }
}
