import Foundation

/// Classifies the first character of a byte string as continuing a word or not. Used at the end
/// of a healed required prefix: " an" followed by "other" continues the word, " an" followed by
/// " apple" / "," / end of text completes it. Pure.
enum WordBoundary {
    /// True when `bytes` start with a character that would extend a Latin-style word: an ASCII
    /// letter or digit, an apostrophe, or a non-CJK letter/number/mark. Whitespace, punctuation,
    /// symbols, CJK, emoji, and the empty string mark a boundary.
    static func continuesWord<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        guard let first = bytes.first else { return false }
        if first < 0x80 {
            switch first {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x27: return true
            default: return false
            }
        }
        if let scalar = firstScalar(bytes) {
            if scalar.value == 0x2019 { return true }   // right single quote used as an apostrophe
            if TextRules.isCJK(scalar) { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || scalar.properties.generalCategory == .nonspacingMark
        }
        // Incomplete multi-byte sequence inside one token: two-byte leads are mostly Latin,
        // Greek, and Cyrillic letters; longer ones are mostly CJK, punctuation, and emoji.
        return (0xC2...0xDF).contains(first)
    }

    /// The first Unicode scalar of `bytes`, or nil when the bytes start with an incomplete or
    /// invalid sequence.
    static func firstScalar<C: Collection>(_ bytes: C) -> Unicode.Scalar? where C.Element == UInt8 {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar): return scalar
        case .emptyInput, .error: return nil
        }
    }

    /// True when the last character of `bytes` is a word character, i.e. the required prefix
    /// ends inside or at the end of a word (so "is the word complete?" is a real question).
    static func endsInWord(_ bytes: ArraySlice<UInt8>) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let last = text.unicodeScalars.last else { return false }
        if last.value == 0x27 || last.value == 0x2019 { return false }   // "James'" is complete
        if last.isASCII { return continuesWord([UInt8(last.value)]) }
        if TextRules.isCJK(last) { return false }
        return last.properties.isAlphabetic || last.properties.numericType != nil
    }
}
