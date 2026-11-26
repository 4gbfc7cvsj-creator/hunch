import Foundation
import HunchCore

/// How much the user has written on the caret's line, for the "complete, don't propose" gate.
public enum TypedWords {
    /// Words on the caret's line as `surface` counts them: code buffers count tokens and
    /// characters (`codeUnitsOnCurrentLine`), everything else prose words.
    public static func onCurrentLine(_ before: String, surface: SurfaceKind) -> Int {
        surface == .code ? codeUnitsOnCurrentLine(before) : onCurrentLine(before)
    }

    /// Code floor: prose words are the wrong unit (`x =`, `if (` are two tokens, `return` is one
    /// keyword). A unit is a token (a run of identifier characters, or a run of other symbols) or
    /// three non-whitespace characters, whichever counts more, so `return`, `x =` and `if (` all
    /// reach the default floor of two while `(` or `x` alone do not.
    public static func codeUnitsOnCurrentLine(_ before: String) -> Int {
        let line = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        var tokens = 0
        var characters = 0
        var previous: Bool?   // true = identifier character, false = symbol, nil = whitespace
        for c in line {
            if c.isWhitespace {
                previous = nil
                continue
            }
            characters += 1
            let identifier = c.isLetter || c.isNumber || c == "_"
            if previous != identifier { tokens += 1 }
            previous = identifier
        }
        return max(tokens, characters / 3)
    }

    /// Words on the line that ends at the caret: whitespace-separated tokens containing a letter or
    /// digit (a half-typed word counts). Scripts written without spaces (CJK) count one word per two
    /// characters.
    public static func onCurrentLine(_ before: String) -> Int {
        let line = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        var words = 0
        var unspaced = 0
        for token in line.split(whereSeparator: \.isWhitespace) {
            var hasSpacedWordChar = false
            for scalar in token.unicodeScalars {
                if isUnspacedScript(scalar) {
                    unspaced += 1
                } else if CharacterSet.alphanumerics.contains(scalar) {
                    hasSpacedWordChar = true
                }
            }
            if hasSpacedWordChar { words += 1 }
        }
        return words + unspaced / 2
    }

    static func isUnspacedScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x0E00...0x0E7F: true
        default: false
        }
    }
}
