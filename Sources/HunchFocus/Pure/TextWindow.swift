import Foundation
import HunchCore

/// Result of slicing caret-adjacent text out of a field value.
public struct TextWindowSlice: Sendable, Equatable {
    public var before: String
    public var after: String
    /// Selection length in UTF-16 units (the unit AX reports).
    public var selectionLength: Int
    /// The character right after the selection (or caret) is a newline, or there is none.
    public var caretAtLineEnd: Bool
    /// `before` or `after` contains a line break.
    public var containsNewline: Bool
    /// The selected text (empty for a plain caret), capped at `selectionTextLimit` characters.
    public var selected: String = ""
    /// `before` does not reach the start of the field (cut at the limit or by a windowed read).
    public var beforeIsCut = false
    /// `after` does not reach the end of the field.
    public var afterIsCut = false
}

/// Pure UTF-16 ↔ `String.Index` conversions and bounded slicing around the caret.
///
/// AX reports caret and selection positions in UTF-16 code units. `ContextLimits` counts
/// `Character`s (grapheme clusters), so a window never splits an emoji or a combining sequence.
public enum TextWindow {
    /// A longer selection is not kept (write for me works on at most a few thousand characters).
    public static let selectionTextLimit = 8000

    /// Converts a UTF-16 offset into a `String.Index` on a `Character` boundary.
    /// Offsets are clamped into the string; positions inside a grapheme round down (or up).
    public static func characterIndex(in text: String, utf16Offset: Int, roundingUp: Bool = false) -> String.Index {
        let units = text.utf16
        let clamped = max(0, utf16Offset)
        var index = units.index(units.startIndex, offsetBy: clamped, limitedBy: units.endIndex) ?? units.endIndex
        if roundingUp {
            while index < text.endIndex, index.samePosition(in: text) == nil {
                units.formIndex(after: &index)
            }
        } else {
            while index > text.startIndex, index.samePosition(in: text) == nil {
                units.formIndex(before: &index)
            }
        }
        return index
    }

    /// Slices `text` around a caret.
    /// - Parameters:
    ///   - caretUTF16: caret (selection start) relative to the start of `text`.
    ///   - selectionUTF16: selection length in UTF-16 units (0 for a plain caret).
    ///   - endsAtDocumentEnd: whether `text` reaches the end of the field. When it doesn't
    ///     (a windowed read), running off the end is not treated as a line end.
    ///   - startsAtDocumentStart: whether `text` begins at the start of the field.
    public static func slice(_ text: String, caretUTF16: Int, selectionUTF16: Int, limits: ContextLimits,
                             endsAtDocumentEnd: Bool = true, startsAtDocumentStart: Bool = true) -> TextWindowSlice {
        let caret = characterIndex(in: text, utf16Offset: caretUTF16)
        var selectionEnd = caret
        if selectionUTF16 > 0 {
            let selEndOffset = max(caretUTF16, 0) + selectionUTF16
            selectionEnd = max(caret, characterIndex(in: text, utf16Offset: selEndOffset, roundingUp: true))
        }

        let beforeStart = text.index(caret, offsetBy: -max(0, limits.beforeChars), limitedBy: text.startIndex)
            ?? text.startIndex
        let afterEnd = text.index(selectionEnd, offsetBy: max(0, limits.afterChars), limitedBy: text.endIndex)
            ?? text.endIndex

        let before = String(text[beforeStart..<caret])
        let after = String(text[selectionEnd..<afterEnd])
        let selectionLength = text.utf16.distance(from: caret, to: selectionEnd)

        let atLineEnd: Bool
        if selectionEnd == text.endIndex {
            atLineEnd = endsAtDocumentEnd
        } else {
            atLineEnd = text[selectionEnd].isNewline
        }
        let containsNewline = before.contains(where: \.isNewline) || after.contains(where: \.isNewline)
        let selected = text[caret..<selectionEnd]
        return TextWindowSlice(before: before, after: after, selectionLength: selectionLength,
                               caretAtLineEnd: atLineEnd, containsNewline: containsNewline,
                               selected: selected.count <= selectionTextLimit ? String(selected) : "",
                               beforeIsCut: beforeStart > text.startIndex || !startsAtDocumentStart,
                               afterIsCut: afterEnd < text.endIndex || !endsAtDocumentEnd)
    }

    /// Whether the character ending at `caretUTF16` is a newline (or the caret is at the start).
    public static func previousCharacterIsNewlineOrStart(_ text: String, caretUTF16: Int) -> Bool {
        let caret = characterIndex(in: text, utf16Offset: caretUTF16)
        guard caret > text.startIndex else { return true }
        return text[text.index(before: caret)].isNewline
    }

    /// UTF-16 range to request when reading only a window of a large field.
    /// Over-fetches (4 units per allowed character) so grapheme-heavy text still fills the limits.
    public static func fetchRange(caretUTF16: Int, selectionUTF16: Int, totalUTF16: Int,
                                  limits: ContextLimits) -> (location: Int, length: Int) {
        let total = max(0, totalUTF16)
        let caret = min(max(0, caretUTF16), total)
        let selEnd = min(caret + max(0, selectionUTF16), total)
        let start = max(0, caret - max(0, limits.beforeChars) * 4)
        let end = min(total, selEnd + max(0, limits.afterChars) * 4 + 1)
        return (start, end - start)
    }
}
