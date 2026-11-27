import CoreGraphics
import HunchCore

/// Pure geometry helpers. All rects are AppKit global coordinates (origin bottom-left).
public enum OverlayLayout {
    public static let minFontSize: CGFloat = 9
    public static let maxFontSize: CGFloat = 40
    public static let cardFontSize: CGFloat = 13
    public static let cardGap: CGFloat = 8
    public static let cardPaddingX: CGFloat = 6
    public static let cardPaddingY: CGFloat = 4
    public static let cardMaxWidth: CGFloat = 480
    public static let inlineXOffset: CGFloat = 0.5

    /// Hinted point size when present, else caret height * 0.78; always clamped to 9...40.
    public static func fontSize(hint: CGFloat?, caretHeight: CGFloat) -> CGFloat {
        let raw: CGFloat
        if let hint, hint > 0 { raw = hint } else { raw = max(caretHeight, 0) * 0.78 }
        return min(max(raw, minFontSize), maxFontSize)
    }

    /// `fontSize(hint:caretHeight:)` multiplied by a per-app adjustment, still clamped to 9...40.
    public static func fontSize(hint: CGFloat?, caretHeight: CGFloat, adjustment: CGFloat) -> CGFloat {
        adjustedFontSize(fontSize(hint: hint, caretHeight: caretHeight), factor: adjustment)
    }

    /// `size` times a per-app factor, clamped to 9...40. A factor of 1 returns `size` untouched (the
    /// width-scaled size is not clamped today, so apps without a tweak keep exactly that size).
    public static func adjustedFontSize(_ size: CGFloat, factor: CGFloat) -> CGFloat {
        guard factor != 1 else { return size }
        return min(max(size * factor, minFontSize), maxFontSize)
    }

    /// Caret baseline: caret bottom, plus half of any line-box height beyond the font's own
    /// ascender + descender (web engines split that leading above and below the glyphs; TextKit's
    /// boxes are close to the natural height, so the term is ~0 there), plus the descender depth.
    /// `offset` is a per-app shift in points, positive = up.
    public static func baselineY(caretRect: CGRect, descender: CGFloat, ascender: CGFloat = 0,
                                 offset: CGFloat = 0) -> CGFloat {
        let natural = ascender + abs(descender)
        let halfLeading = ascender > 0 ? max(0, caretRect.height - natural) / 2 : 0
        return caretRect.minY + halfLeading + abs(descender) + offset
    }

    /// Inline baseline: the calibrated height above the caret bottom when measured, else
    /// `baselineY`; the per-app `offset` (positive = up) is added on top, so the two compose.
    public static func inlineBaselineY(caretRect: CGRect, measuredBaseline: CGFloat?, descender: CGFloat,
                                       ascender: CGFloat, offset: CGFloat = 0) -> CGFloat {
        if let measuredBaseline { return caretRect.minY + measuredBaseline + offset }
        return baselineY(caretRect: caretRect, descender: descender, ascender: ascender, offset: offset)
    }

    /// The color the ghost is tinted from: the host's text color, or nil (the default grey) when
    /// the app forces grey or reports none.
    public static func ghostColorSource(textColor: RGBAColor?, greyForced: Bool) -> RGBAColor? {
        greyForced ? nil : textColor
    }

    /// Panel origin Y so the text baseline lands on `baseline`, given the font's descent below it.
    public static func panelOriginY(baseline: CGFloat, fontDescent: CGFloat) -> CGFloat {
        baseline - abs(fontDescent)
    }

    /// Point size whose x-height equals a measured host x-height, or nil when that would differ from
    /// `current` by more than the plausible range (a mismeasurement).
    public static func sizeMatching(xHeight: CGFloat, fontXHeightPerPoint: CGFloat, current: CGFloat) -> CGFloat? {
        guard fontXHeightPerPoint > 0.2, xHeight > 0 else { return nil }
        let size = xHeight / fontXHeightPerPoint
        guard size >= current * 0.75, size <= current * 1.35 else { return nil }
        return min(max(size, minFontSize), maxFontSize)
    }

    /// When the host reports its font size, a size derived from measured ink must stay close to it
    /// (web fonts differ in x-height by well under 15%); a bigger gap means the measurement caught
    /// something other than the typed text (an icon, a taller line), so it is ignored.
    public static func agreesWithReportedSize(_ size: CGFloat, reported: Double?) -> Bool {
        guard let reported, reported > 0 else { return true }
        let ratio = size / CGFloat(reported)
        return ratio >= 0.85 && ratio <= 1.18
    }

    /// Inline panel origin X: just right of the caret.
    public static func inlineX(caretRect: CGRect) -> CGFloat { caretRect.maxX + inlineXOffset }

    /// Width left for inline text between `x` and the screen's right edge.
    public static func availableWidth(fromX x: CGFloat, visibleFrame: CGRect) -> CGFloat {
        max(0, visibleFrame.maxX - x)
    }

    /// Width left for ghost text starting at `x`: up to the screen's right edge, and up to the
    /// field's right edge when the caret sits inside the field (the host wraps there, so text drawn
    /// past it spills over the field's border and buttons). A field the caret is outside of (a
    /// misreported or scrolled frame) is ignored rather than hiding the suggestion.
    public static func availableWidth(fromX x: CGFloat, visibleFrame: CGRect, fieldFrame: CGRect?,
                                      caretRect: CGRect) -> CGFloat {
        let screen = availableWidth(fromX: x, visibleFrame: visibleFrame)
        guard let field = fieldFrame, field.width > 0, field.height > 0,
              caretRect.maxX >= field.minX, caretRect.maxX < field.maxX else { return screen }
        return min(screen, max(0, field.maxX - x))
    }

    /// The part of `text` that fits `maxWidth`, ending at a word break when one fits: the words
    /// that don't fit are the ones the host would wrap onto the next line, where they show once the
    /// typing gets there. Text with no break in the part that fits (one long word, Chinese or
    /// Japanese) is cut by character instead, so something always shows.
    public static func fitWholeWords(_ text: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        let prefix = truncate(text, maxWidth: maxWidth, measure: measure)
        guard prefix.count < text.count else { return text }
        let chars = Array(text)
        // The word that doesn't fit starts after the last space at or before the cut.
        var cut = prefix.count
        while cut > 0, !chars[cut].isWhitespace { cut -= 1 }
        let words = String(chars[0..<cut]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return words.contains(where: { !$0.isWhitespace }) ? words : prefix
    }

    /// Card frame below the caret with `gap`; flips above when it would leave the bottom of `visible`.
    /// X follows the caret and is clamped into `visible`.
    public static func cardFrame(caretRect: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = cardGap) -> CGRect {
        var y = caretRect.minY - gap - size.height
        if y < visible.minY { y = caretRect.maxY + gap }
        return clamp(CGRect(origin: CGPoint(x: caretRect.minX, y: y), size: size), into: visible)
    }

    /// Shifts (and, if larger than `bounds`, shrinks) `rect` to lie within `bounds`.
    public static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Index of the frame to use: the one containing the caret's midpoint, else the largest
    /// intersection, else nil.
    public static func screenIndex(for caretRect: CGRect, frames: [CGRect]) -> Int? {
        let mid = CGPoint(x: caretRect.midX, y: caretRect.midY)
        if let i = frames.firstIndex(where: { $0.contains(mid) }) { return i }
        var best: (Int, CGFloat)?
        for (i, f) in frames.enumerated() {
            let inter = f.intersection(caretRect)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > 0, area > (best?.1 ?? 0) { best = (i, area) }
        }
        return best?.0
    }

    /// Longest prefix (by Character, no ellipsis) whose measured width fits `maxWidth`.
    public static func truncate(_ text: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        if maxWidth <= 0 { return "" }
        if measure(text) <= maxWidth { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count  // invariant: prefix(lo) fits
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(String(chars[0..<mid])) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        return String(chars[0..<lo])
    }
}
