import Foundation

/// Character classification shared by healing and budgeting. Pure.
enum TextClass {
    /// Scripts written without spaces between words (Han, kana). Healing never crosses them and
    /// budgeting may cut between any two of them.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,     // Hiragana, Katakana
             0x31F0...0x31FF,     // Katakana phonetic extensions
             0x3400...0x4DBF,     // CJK Extension A
             0x4E00...0x9FFF,     // CJK Unified Ideographs
             0xF900...0xFAFF,     // CJK Compatibility Ideographs
             0xFF66...0xFF9F,     // Halfwidth Katakana
             0x20000...0x323AF:   // CJK Extensions B..H
            return true
        default:
            return false
        }
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isCJK)
    }

    /// Part of a word for healing: letters (any script except CJK), digits, combining marks, apostrophes.
    static func isWordCharacter(_ character: Character) -> Bool {
        if isCJK(character) { return false }
        if character == "'" || character == "\u{2019}" { return true }
        return character.isLetter || character.isNumber
    }

    /// Horizontal whitespace only: healing keeps line breaks in the prompt.
    static func isHorizontalSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }
}
