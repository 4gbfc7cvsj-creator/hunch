import CoreGraphics

/// Pure geometry for mirror mode: an opaque panel over the caret's line that redraws the typed
/// text and continues it with the ghost. All rects are AppKit global coordinates (origin
/// bottom-left). Text is measured through the caller's `measure`, so the math needs no fonts.
public enum MirrorLayout {
    /// Stands in for the typed text's dropped head on a line too long to show whole.
    public static let ellipsis = "\u{2026}"
    /// Share of the line the typed tail keeps when a long ghost needs room: the ghost is cut at
    /// the right before the typed text loses more than this.
    public static let minTailShare: CGFloat = 0.5
    /// Room kept after the last glyph for the drawn caret.
    public static let caretRoom: CGFloat = 2
    /// The panel starts this far left of the first character, covering its antialiased edge.
    public static let leadingBleed: CGFloat = 1

    /// The caret line's typed text: everything after the last line break in `before`.
    public static func lastLine(of before: String) -> String {
        guard let i = before.lastIndex(where: \.isNewline) else { return before }
        return String(before[before.index(after: i)...])
    }

    /// Baseline of the mirrored line. Same inputs as the inline ghost's: the calibrated height
    /// above the caret bottom when measured, else `OverlayLayout.baselineY` from the font's
    /// metrics; `offset` is a per-app shift in points (positive = up).
    public static func baselineY(caretRect: CGRect, measuredBaseline: CGFloat?, descender: CGFloat,
                                 ascender: CGFloat, offset: CGFloat = 0) -> CGFloat {
        if let measuredBaseline { return caretRect.minY + measuredBaseline + offset }
        return OverlayLayout.baselineY(caretRect: caretRect, descender: descender, ascender: ascender) + offset
    }

    /// The font's line height: ascender, descender depth, and leading.
    public static func lineHeight(ascender: CGFloat, descender: CGFloat, leading: CGFloat) -> CGFloat {
        max(0, ascender) + abs(descender) + max(0, leading)
    }

    /// Panel frame: one line tall around `baseline` (leading split above and below), from just left
    /// of the line's first character to the field's right edge. Without a field frame it ends past
    /// the typed text (the host's or ours, whichever is longer) plus the ghost. Kept inside `visible`.
    public static func frame(lineStartX: CGFloat, baseline: CGFloat, ascender: CGFloat, descender: CGFloat,
                             leading: CGFloat, fieldFrame: CGRect?, caretRect: CGRect, typedWidth: CGFloat,
                             ghostWidth: CGFloat, visible: CGRect) -> CGRect {
        let height = lineHeight(ascender: ascender, descender: descender, leading: leading)
        let minY = baseline - abs(descender) - max(0, leading) / 2
        var minX = lineStartX - leadingBleed
        var maxX: CGFloat
        if let field = fieldFrame, field.width > 0 {
            if lineStartX >= field.minX { minX = max(minX, field.minX) }
            // A field frame that ends before the caret is wrong; the host's typed text is covered anyway.
            // Our own text running wider than the host's is truncated to fit, not given more room.
            maxX = max(field.maxX, caretRect.maxX + caretRoom)
        } else {
            maxX = max(caretRect.maxX, lineStartX + typedWidth) + ghostWidth + caretRoom
        }
        minX = max(minX, visible.minX)
        maxX = min(maxX, visible.maxX)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: height)
    }

    /// `rect` grown to whole points (the window server places panels on whole points); the text is
    /// then drawn at its exact offset inside.
    public static func snappedOutward(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(.down), minY = rect.minY.rounded(.down)
        return CGRect(x: minX, y: minY, width: rect.maxX.rounded(.up) - minX, height: rect.maxY.rounded(.up) - minY)
    }

    /// What fits on the mirrored line.
    public struct Line: Sendable, Equatable {
        /// The typed text's head was dropped; `ellipsis` is drawn before `typed`.
        public var truncatedHead: Bool
        /// The typed text shown (all of it, or its tail).
        public var typed: String
        /// The ghost shown (all of it, or the prefix that fits).
        public var ghost: String
        public init(truncatedHead: Bool, typed: String, ghost: String) {
            self.truncatedHead = truncatedHead
            self.typed = typed
            self.ghost = ghost
        }
    }

    /// Fits the typed text and the ghost into `maxWidth`. A line too long loses the typed text's
    /// head first (from the left, behind an ellipsis), so the text just before the caret and the
    /// ghost stay visible; the typed tail keeps at least `minTailShare` of the width (or all of
    /// itself when shorter), and a ghost still too long is cut at the right.
    public static func fit(typed: String, ghost: String, maxWidth: CGFloat,
                           measure: (String) -> CGFloat) -> Line {
        guard maxWidth > 0 else { return Line(truncatedHead: !typed.isEmpty, typed: "", ghost: "") }
        let typedWidth = typed.isEmpty ? 0 : measure(typed)
        let ghostWidth = ghost.isEmpty ? 0 : measure(ghost)
        if typedWidth + ghostWidth <= maxWidth { return Line(truncatedHead: false, typed: typed, ghost: ghost) }
        let tailBudget = max(maxWidth - ghostWidth, min(typedWidth, maxWidth * minTailShare))
        var shown = typed
        var used = typedWidth
        var head = false
        if typedWidth > tailBudget {
            shown = tail(of: typed, maxWidth: tailBudget, measure: measure)
            used = measure(ellipsis + shown)
            head = true
        }
        let ghostShown = OverlayLayout.truncate(ghost, maxWidth: maxWidth - used, measure: measure)
        return Line(truncatedHead: head, typed: shown, ghost: ghostShown)
    }

    /// Longest suffix (by Character) that fits `maxWidth` behind the ellipsis; empty when not even
    /// the ellipsis fits.
    public static func tail(of text: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        let chars = Array(text)
        guard measure(ellipsis) <= maxWidth else { return "" }
        var lo = 0, hi = chars.count  // invariant: the last `lo` characters fit
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(ellipsis + String(chars[(chars.count - mid)...])) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        return String(chars[(chars.count - lo)...])
    }
}
