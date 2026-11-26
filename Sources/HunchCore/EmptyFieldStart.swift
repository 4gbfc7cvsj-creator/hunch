import CoreGraphics
import Foundation

/// Where the first line's text starts in a field, relative to the field's top-left corner (AppKit
/// space, y up). Hosts that give no caret position in an empty field (Chromium and Electron apps)
/// still give one once there is text, so it is learned while typing the first line and used to
/// place dictation's effect in that field once it is empty again.
public struct EmptyFieldStart: Codable, Equatable, Sendable {
    /// From the field's left edge to the first character.
    public var left: CGFloat
    /// From the field's top edge to the top of the caret.
    public var top: CGFloat
    public var caretHeight: CGFloat
    /// From the host's position of the first character (else measured, a little less exact).
    public var fromHost: Bool?

    public init(left: CGFloat, top: CGFloat, caretHeight: CGFloat) {
        self.left = left
        self.top = top
        self.caretHeight = caretHeight
    }

    /// Learned from an exact caret `lineWidth` points after the start of the field's first line (the
    /// text before the caret has no line break). Nil when that start falls outside the field: the
    /// text wrapped, so the caret is on a later line.
    public static func learn(caret: CGRect, field: CGRect, lineWidth: CGFloat) -> EmptyFieldStart? {
        guard caret.height > 1, field.width > 1, field.height > 1, lineWidth >= 0 else { return nil }
        // A few points outside the edge is measuring error: the text starts at the edge.
        let left = caret.minX - lineWidth - field.minX
        let top = field.maxY - caret.maxY
        guard left >= -3, left < field.width / 2, top >= 0, top + caret.height <= field.height + 1 else { return nil }
        return EmptyFieldStart(left: max(0, left), top: top, caretHeight: caret.height)
    }

    /// The caret in an empty `field`.
    public func caret(in field: CGRect) -> CGRect {
        CGRect(x: field.minX + left, y: field.maxY - top - caretHeight, width: 1, height: caretHeight)
    }
}
