import CoreText
import CoreGraphics
import HunchCore

/// Where the host actually painted its text, measured from a grayscale strip of already-typed text
/// just left of the caret. Rows are counted from the top of the strip, in pixels.
public struct InkMetrics: Sendable, Equatable {
    /// Bottom edge of the last dense row: the text baseline.
    public var baselineRow: Int
    /// Top edge of the dense lowercase band: the x-height line.
    public var xHeightTopRow: Int
    public var xHeightPixels: Int { baselineRow - xHeightTopRow }
    /// Sub-pixel baseline, in rows from the top: anti-aliased edge rows count by how much of them is
    /// inked, so a half-covered last row adds half a row instead of a whole one.
    public var baseline: Double
    /// Sub-pixel x-height line, in rows from the top.
    public var xHeightTop: Double
    public var xHeight: Double { baseline - xHeightTop }

    public init(baselineRow: Int, xHeightTopRow: Int, baseline: Double? = nil, xHeightTop: Double? = nil) {
        self.baselineRow = baselineRow
        self.xHeightTopRow = xHeightTopRow
        self.baseline = baseline ?? Double(baselineRow)
        self.xHeightTop = xHeightTop ?? Double(xHeightTopRow)
    }
}

/// Pure ink analysis. Descenders (g, p, y) and ascenders are sparse compared with the x-height band,
/// so the baseline is where row ink density falls off sharply going down, and the x-height line is
/// where it rises sharply going down.
public enum InkBaseline {
    /// Minimum gray difference from the background that counts as ink.
    public static let inkThreshold = 60
    /// A row belongs to the x-height band when it has at least this share of the densest row's ink.
    public static let bandShare = 0.35

    /// `gray` is `width * height` luminance bytes, row-major from the top.
    public static func measure(gray: [UInt8], width: Int, height: Int) -> InkMetrics? {
        guard width > 0, height > 2, gray.count == width * height else { return nil }
        let background = Int(median(gray))
        var counts = [Int](repeating: 0, count: height)
        var weights = [Int](repeating: 0, count: height)   // summed contrast: partial coverage counts partly
        for row in 0..<height {
            var n = 0, w = 0
            let base = row * width
            for col in 0..<width {
                let d = abs(Int(gray[base + col]) - background)
                w += d
                if d >= inkThreshold { n += 1 }
            }
            counts[row] = n
            weights[row] = w
        }
        guard let peak = counts.max(), peak >= 3 else { return nil }
        let cut = Int((Double(peak) * bandShare).rounded(.up))
        // The densest row anchors the band; walk outwards while rows stay dense.
        guard let anchor = counts.firstIndex(of: peak) else { return nil }
        var top = anchor
        while top > 0, counts[top - 1] >= cut { top -= 1 }
        var bottom = anchor
        while bottom < height - 1, counts[bottom + 1] >= cut { bottom += 1 }
        // A band touching the strip edge means the text was cut off: not trustworthy.
        guard top > 0, bottom < height - 1, bottom - top >= 2 else { return nil }
        // Edge rows are often anti-aliased: weigh them against the band's inner rows.
        let inner = bottom - top >= 2 ? Array(weights[(top + 1)...(bottom - 1)]) : [weights[anchor]]
        let reference = Double(inner.reduce(0, +)) / Double(max(inner.count, 1))
        func coverage(_ row: Int) -> Double { reference > 0 ? min(1, Double(weights[row]) / reference) : 1 }
        return InkMetrics(baselineRow: bottom + 1, xHeightTopRow: top,
                          baseline: Double(bottom) + coverage(bottom), xHeightTop: Double(top) + 1 - coverage(top))
    }

    static func median(_ values: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for v in values { histogram[Int(v)] += 1 }
        var seen = 0
        for (value, n) in histogram.enumerated() {
            seen += n
            if seen * 2 >= values.count { return UInt8(value) }
        }
        return 0
    }
}

/// The correction learned for one line style, relative to the caret rect it was measured against.
public struct TextCalibration: Sendable, Equatable {
    /// Measured baseline minus the caret rect's bottom (AppKit points, up is positive).
    public var baselineAboveCaretBottom: CGFloat
    /// Measured x-height in points (nil when it looked implausible).
    public var xHeight: CGFloat?
    /// Font size of the matched text, in points (nil from the older ink-density measurement).
    public var pointSize: CGFloat?
    /// How well the drawn text matched the capture, 0...1 (nil when not matched).
    public var score: Double?
    /// The field's background behind the caret's line, sampled from the same strip (sRGB). Nil when
    /// the strip showed no dominant color, and in saved measurements (backgrounds aren't kept).
    public var backgroundColor: RGBAColor?
    /// The host's x-height read from the ink of its own text (points), independent of our fonts.
    public var hostXHeight: CGFloat?
    /// Size the candidate x-heights below were measured at: the reported size, else the fit's.
    public var measuredAtSize: CGFloat?
    /// x-height of the same text drawn in each face at `measuredAtSize`, measured from its ink the
    /// same way as `hostXHeight`: `FaceMatch.candidates`, plus `hostFontKey` when the host's own
    /// font loads.
    public var faceXHeights: [String: CGFloat]
    /// This measurement's size correction for a loaded host font (`FaceMatch.suggestedSizeFactor`).
    public var sizeSuggestion: CGFloat?
    /// The size correction in force after this measurement (1 = none; confirmed by two in a row).
    public var sizeFactor: CGFloat
    /// The face picked for a host font that can't be loaded (nil = system face).
    public var pickedFamily: String?

    public static let hostFontKey = "@host"

    public init(baselineAboveCaretBottom: CGFloat, xHeight: CGFloat?, pointSize: CGFloat? = nil, score: Double? = nil,
                backgroundColor: RGBAColor? = nil, hostXHeight: CGFloat? = nil, measuredAtSize: CGFloat? = nil,
                faceXHeights: [String: CGFloat] = [:], sizeSuggestion: CGFloat? = nil, sizeFactor: CGFloat = 1,
                pickedFamily: String? = nil) {
        self.baselineAboveCaretBottom = baselineAboveCaretBottom
        self.xHeight = xHeight
        self.pointSize = pointSize
        self.score = score
        self.backgroundColor = backgroundColor
        self.hostXHeight = hostXHeight
        self.measuredAtSize = measuredAtSize
        self.faceXHeights = faceXHeights
        self.sizeSuggestion = sizeSuggestion
        self.sizeFactor = sizeFactor
        self.pickedFamily = pickedFamily
    }

    /// What the ghost should draw with after this measurement.
    public var faceChoice: FaceChoice { FaceChoice(family: pickedFamily, sizeFactor: sizeFactor) }

    /// True when this measurement suggests a size correction that isn't confirmed yet: one more
    /// measurement settles it.
    public var needsConfirmation: Bool {
        guard let s = sizeSuggestion else { return false }
        return abs(s - sizeFactor) > FaceMatch.confirmShare
    }

    /// This measurement with the face pick and size correction decided, given the one before it
    /// for the same line style (this session's, else the saved one).
    public func decided(previous: TextCalibration?) -> TextCalibration {
        var out = self
        out.sizeSuggestion = nil
        out.pickedFamily = nil
        out.sizeFactor = 1
        guard let host = hostXHeight else {
            // Nothing measured from the ink: keep what was decided before.
            out.pickedFamily = previous?.pickedFamily
            out.sizeFactor = previous?.sizeFactor ?? 1
            return out
        }
        if let drawn = faceXHeights[Self.hostFontKey] {
            // The host's font loads: only its size can be off.
            out.sizeSuggestion = FaceMatch.suggestedSizeFactor(host: host, drawn: drawn)
            out.sizeFactor = FaceMatch.nextSizeFactor(current: previous?.sizeFactor ?? 1,
                                                      previousSuggestion: previous?.sizeSuggestion,
                                                      suggestion: out.sizeSuggestion)
        } else {
            out.pickedFamily = FaceMatch.pickFace(host: host, xHeights: faceXHeights)
        }
        return out
    }
}

// MARK: x-height from ink

extension InkBaseline {
    /// The host's x-height in pixels, from the ink of the line whose baseline the match found:
    /// only rows around that baseline are read, so other lines in the strip don't count. Nil when
    /// the ink band doesn't sit on the matched baseline.
    public static func lineXHeight(gray: [UInt8], width: Int, height: Int, baselineRow: Double,
                                   caretPixels: Double) -> Double? {
        guard width > 0, height > 2, gray.count == width * height, caretPixels > 2 else { return nil }
        let top = max(0, Int((baselineRow - caretPixels * 0.85).rounded(.down)))
        let bottom = min(height, Int((baselineRow + caretPixels * 0.3).rounded(.up)))
        guard bottom - top > 4 else { return nil }
        let rows = Array(gray[(top * width)..<(bottom * width)])
        guard let m = measure(gray: rows, width: width, height: bottom - top),
              abs(Double(top) + m.baseline - baselineRow) <= 1.5 else { return nil }
        return m.xHeight
    }

    /// x-height in pixels of `text` drawn in `font` on a canvas the size of the capture, ending at
    /// `rightEdge`, read from its ink exactly as `lineXHeight` reads the host's.
    public static func drawnXHeight(text: String, font: CTFont, width: Int, height: Int, scale: CGFloat,
                                    rightEdge: Double) -> Double? {
        let baselineRow = Double(height) * 0.6
        guard let ink = TemplateMatch.render(text, font: font, width: width, height: height, scale: scale,
                                             rightEdge: rightEdge, baselineRow: baselineRow) else { return nil }
        let gray = ink.map { UInt8(max(0, min(255, $0))) }
        return lineXHeight(gray: gray, width: width, height: height, baselineRow: baselineRow,
                           caretPixels: Double(CTFontGetAscent(font) + CTFontGetDescent(font)) * Double(scale))
    }
}
