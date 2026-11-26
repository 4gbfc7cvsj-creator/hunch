import CoreGraphics
import CoreText
import Foundation

/// Where a field's typed line sits, found on screen (`TypedTextLocator`) for fields that report no
/// text positions. Kept relative to the field frame, so it survives the window moving; the caret
/// for any later text on that line is the line start plus the text's width at the matched size.
public struct TypedTextAnchor: Sendable, Equatable, Codable {
    /// Pen x where the line starts, from the field's left edge (points).
    public var startOffset: CGFloat
    /// Baseline above the field's bottom edge (AppKit, points).
    public var baselineOffset: CGFloat
    /// Font size the typed text matched at.
    public var pointSize: CGFloat
    /// Rightmost caret x, from the field's right edge (negative = inside): past it the host scrolls
    /// or cuts the line. Kept from the right edge so one anchor fits the field at any width.
    /// Nil: the field's own right edge (less 2 pt).
    public var rightLimitMargin: CGFloat?

    public init(startOffset: CGFloat, baselineOffset: CGFloat, pointSize: CGFloat, rightLimitMargin: CGFloat? = nil) {
        self.startOffset = startOffset
        self.baselineOffset = baselineOffset
        self.pointSize = pointSize
        self.rightLimitMargin = rightLimitMargin
    }

    /// Finite numbers and a positive size (a saved anchor from a damaged file is dropped).
    public var isValid: Bool {
        startOffset.isFinite && baselineOffset.isFinite && pointSize.isFinite && pointSize > 0
            && (rightLimitMargin?.isFinite ?? true)
    }

    /// Fewest visible characters worth matching: shorter text fits too many places on screen.
    public static let minimumCharacters = 4

    /// True when `before` can be located on screen: one line, the whole field text (so it starts
    /// at the line start), and enough of it to match.
    public static func isEligible(before: String) -> Bool {
        isPlaceable(before: before) && before.filter { !$0.isWhitespace }.count >= minimumCharacters
    }

    /// True when a caret can be placed after `before` from a known anchor: one line, not empty.
    public static func isPlaceable(before: String) -> Bool {
        !before.isEmpty && !before.contains(where: \.isNewline)
    }

    /// Caret rect (AppKit global) after `text` drawn in `font` (at `pointSize`), or nil when the
    /// text is a different line or would run past the right limit (a host scrolls it then, and
    /// the line no longer starts where it was found).
    public func caret(after text: String, fieldFrame frame: CGRect, font: CTFont) -> CGRect? {
        guard frame.width > 0, frame.height > 0, !text.contains(where: \.isNewline) else { return nil }
        let x = frame.minX + startOffset + CGFloat(TemplateMatch.lineWidth(text, font: font))
        guard x <= frame.maxX + (rightLimitMargin ?? -2) else { return nil }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baseline = frame.minY + baselineOffset
        return CGRect(x: x, y: baseline - descent, width: 1, height: ascent + descent)
    }
}
