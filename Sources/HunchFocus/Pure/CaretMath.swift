import CoreGraphics
import HunchCore

/// Pure geometry helpers for the caret ladder. AX rects use a top-left origin on the primary
/// display with y growing down; AppKit uses a bottom-left origin with y growing up.
public enum CaretMath {
    /// Converts an AX (top-left) rect to AppKit global coordinates.
    public static func flipToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Rejects the bogus rects some hosts return (zero, NaN, huge, or far outside the field).
    public static func isPlausible(_ rect: CGRect, fieldFrame: CGRect?) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite) else { return false }
        guard rect.height > 0, rect.height <= 400, rect.width >= 0, rect.width <= 2000 else { return false }
        if rect.origin == .zero { return false }
        if let frame = fieldFrame, frame.width > 0, frame.height > 0 {
            let slack = max(rect.height * 2, 24)
            let tolerant = frame.insetBy(dx: -slack, dy: -slack)
            guard tolerant.contains(CGPoint(x: rect.minX, y: rect.midY)) else { return false }
        }
        return true
    }

    /// Exact caret rect from a zero-length range: keep position and height, at least 1 pt wide.
    public static func caretFromInsertionBounds(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
    }

    /// Derived caret rect from the bounds of the character before the caret (its right edge).
    public static func caretAfterCharacter(_ charRect: CGRect) -> CGRect {
        CGRect(x: charRect.maxX, y: charRect.minY, width: 1, height: charRect.height)
    }

    /// Derived caret rect from the bounds of the character after the caret (its left edge).
    public static func caretBeforeCharacter(_ charRect: CGRect) -> CGRect {
        CGRect(x: charRect.minX, y: charRect.minY, width: 1, height: charRect.height)
    }

    /// UTF-16 offset of the caret line's first character: the caret minus the text after the last
    /// line break in `before`. Nil when the line is empty (no first character), or when `before`
    /// holds no line break and doesn't reach the start of the field (the line may begin earlier).
    public static func lineStartUTF16(before: String, caretUTF16: Int, beforeReachesStart: Bool) -> Int? {
        let line: Substring
        if let i = before.lastIndex(where: \.isNewline) {
            line = before[before.index(after: i)...]
        } else if beforeReachesStart {
            line = before[...]
        } else {
            return nil
        }
        let count = line.utf16.count
        guard count > 0, caretUTF16 >= count else { return nil }
        return caretUTF16 - count
    }

    /// The line's start x from the bounds of its first character, when those sit on the caret's own
    /// row (a soft-wrapped line starts on an earlier one), not right of the caret, and inside the
    /// field (a field scrolled sideways has its line start out of view). All rects in one space.
    public static func lineStartX(firstCharacter r: CGRect, caretRect: CGRect, fieldFrame: CGRect?) -> CGFloat? {
        guard r.height > 0, caretRect.height > 0, abs(r.midY - caretRect.midY) < caretRect.height / 2,
              r.minX <= caretRect.minX + 0.5 else { return nil }
        if let f = fieldFrame, f.width > 0, r.minX < f.minX - 1 || r.minX > f.maxX { return nil }
        return r.minX
    }

    /// Estimated caret from the field frame alone: near the leading edge of the first line.
    public static func estimatedCaret(fieldFrame frame: CGRect) -> CGRect {
        let lineHeight = min(max(frame.height, 1), 18)
        let inset = min(4, frame.width / 2)
        let y: CGFloat = frame.height <= 40 ? frame.midY - lineHeight / 2 : frame.minY + 4
        return CGRect(x: frame.minX + inset, y: y, width: 1, height: lineHeight)
    }
}

/// Builds a `FontHint` from an AX font attribute dictionary (`AXFontFamily`, `AXFontName`, `AXFontSize`).
public enum FontHintParser {
    static let monoMarkers = ["mono", "menlo", "courier", "consolas", "monaco", "code", "fixed"]

    public static func hint(family: String?, name: String?, size: Double?, textColor: RGBAColor? = nil,
                            backgroundColor: RGBAColor? = nil) -> FontHint? {
        if family == nil, name == nil, size == nil, textColor == nil, backgroundColor == nil { return nil }
        let haystack = ((family ?? "") + " " + (name ?? "")).lowercased()
        let mono = monoMarkers.contains { haystack.contains($0) }
        return FontHint(family: family ?? name, name: name, pointSize: size.map { CGFloat($0) }, isMonospaced: mono,
                        textColor: textColor, backgroundColor: backgroundColor)
    }
}
