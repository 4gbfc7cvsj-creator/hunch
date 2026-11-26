import CoreGraphics
import CoreText
import Foundation

/// Where the host painted its text, found by drawing the text we know was typed and sliding the
/// drawing over a capture of the screen until it lines up. Unlike reading ink density alone, a
/// fit is checked against what the text should look like, so a capture of the wrong window, a
/// separator line, or another line of text scores low and is rejected.
public struct TextFit: Sendable, Equatable {
    /// Font size of the best fit, in points.
    public var pointSize: CGFloat
    /// Baseline, in pixel rows from the top of the capture (sub-pixel).
    public var baselineRow: Double
    /// Horizontal shift of the drawn text from the caret, in pixels (positive = right).
    public var shiftColumns: Int
    /// Normalized cross-correlation of the drawn text with the capture's ink, 0...1.
    public var score: Double
    /// x-height of the fitted font, in pixels.
    public var xHeightPixels: Double
}

/// Where a field's whole typed line was found in a capture (`TemplateMatch.locate`).
public struct TextLocation: Sendable, Equatable {
    /// Font size of the best fit, in points.
    public var pointSize: CGFloat
    /// Pen x where the text starts, in pixel columns from the capture's left edge.
    public var startColumn: Double
    /// Pen x after the last character (where the caret sits), in pixel columns.
    public var endColumn: Double
    /// Baseline, in pixel rows from the top of the capture (sub-pixel).
    public var baselineRow: Double
    /// Normalized cross-correlation over the text and the gap after it, 0...1.
    public var score: Double
    /// Ink in the gap after the text ÷ ink over the text (`TemplateMatch.maximumTrailingInk`).
    public var trailingInk: Double

    /// A fit good enough to place a caret by: the whole line matched and nothing right after it.
    public var isConfident: Bool {
        score >= TemplateMatch.minimumLocateScore && trailingInk <= TemplateMatch.maximumTrailingInk
    }
}

public enum TemplateMatch {
    /// Fits below this score are not trusted (tuned with the tests: the same text in a different
    /// face scores ~0.8+, different text or the wrong window well under 0.5).
    public static let minimumScore = 0.6
    /// Horizontal search around the caret, in pixels each way: caret rects are often a pixel or
    /// two off, and the host's kerning differs slightly from ours.
    static let shiftRange = 6

    /// - Parameters:
    ///   - gray: capture luminance, `width * height`, row-major from the top.
    ///   - scale: pixels per point of the capture.
    ///   - text: the text just before the caret on its line (only the part that fits is used).
    ///   - caretColumn: x of the caret in capture pixels; the drawn text ends here.
    ///   - sizes: candidate font sizes in points.
    ///   - font: builds the font to draw with at a size.
    public static func fit(gray: [UInt8], width: Int, height: Int, scale: CGFloat, text: String,
                           caretColumn: Double, sizes: [CGFloat], font: (CGFloat) -> CTFont) -> TextFit? {
        guard width > 8, height > 8, gray.count == width * height else { return nil }
        let visible = String(text.suffix(200)).replacingOccurrences(of: "\t", with: " ")
        guard visible.contains(where: { !$0.isWhitespace }) else { return nil }

        // Ink map of the capture: distance from the background, so dark and light themes look alike.
        let background = Int(InkBaseline.median(gray))
        var ink = [Float](repeating: 0, count: width * height)
        for i in 0..<ink.count { ink[i] = Float(abs(Int(gray[i]) - background)) }
        let inkRows = rowSums(ink, width: width, height: height)

        // Coarse pass over every other size, then the neighbours of the best one.
        let coarse = stride(from: 0, to: sizes.count, by: 2).map { sizes[$0] }
        var best: TextFit?
        func consider(_ size: CGFloat) {
            guard size > 3, let fit = fitOne(size: size, font: font(size), text: visible, ink: ink, inkRows: inkRows,
                                             width: width, height: height, scale: scale, caretColumn: caretColumn)
            else { return }
            if best == nil || fit.score > best!.score { best = fit }
        }
        coarse.forEach(consider)
        if let b = best, let i = sizes.firstIndex(of: b.pointSize) {
            for j in [i - 1, i + 1] where j >= 0 && j < sizes.count { consider(sizes[j]) }
        }
        return best
    }

    /// Best placement of the text drawn at one size.
    static func fitOne(size: CGFloat, font f: CTFont, text: String, ink: [Float], inkRows: [Float],
                       width: Int, height: Int, scale: CGFloat, caretColumn: Double) -> TextFit? {
        // Draw with the baseline at a reference row; vertical placement is found by sliding.
        let referenceBaseline = Double(height) * 0.5
        guard let drawn = render(text, font: f, width: width, height: height, scale: scale,
                                 rightEdge: caretColumn, baselineRow: referenceBaseline),
              let box = Box(drawn, width: width, height: height) else { return nil }
        let drawnRows = rowSums(drawn, width: width, height: height)

        // 1. Vertical candidates: the best few peaks of the row-profile match (another line of
        //    text nearby can make a wrong peak the highest).
        var bestScore = -Double.infinity, bestDX = 0, bestDY = 0, bestFraction = 0.0
        for peak in shiftPeaks(drawnRows, inkRows, range: height / 2, count: 3) {
            // 2. Horizontal: coarse steps of 2 px, then the neighbours.
            var localDX = 0, localScore = -Double.infinity
            for dx in stride(from: -shiftRange, through: shiftRange, by: 2) {
                let s = correlation(drawn, ink, width: width, height: height, box: box, dx: dx, dy: peak.shift)
                if s > localScore { localScore = s; localDX = dx }
            }
            for dx in [localDX - 1, localDX + 1] where abs(dx) <= shiftRange {
                let s = correlation(drawn, ink, width: width, height: height, box: box, dx: dx, dy: peak.shift)
                if s > localScore { localScore = s; localDX = dx }
            }
            // 3. One row either way in 2D.
            var localDY = peak.shift, fraction = peak.fraction
            for d in [peak.shift - 1, peak.shift + 1] {
                let s = correlation(drawn, ink, width: width, height: height, box: box, dx: localDX, dy: d)
                if s > localScore { localScore = s; localDY = d; fraction = 0 }
            }
            if localScore > bestScore {
                bestScore = localScore; bestDX = localDX; bestDY = localDY; bestFraction = fraction
            }
        }
        guard bestScore > -Double.infinity else { return nil }
        return TextFit(pointSize: size, baselineRow: referenceBaseline + Double(bestDY) + bestFraction,
                       shiftColumns: bestDX, score: max(0, bestScore),
                       xHeightPixels: Double(CTFontGetXHeight(f)) * Double(scale))
    }

    // MARK: Locating text with no caret

    /// Finds where `text` was painted anywhere across the capture, for fields that report no
    /// text positions at all: unlike `fit`, nothing says where the text ends, so the drawn text is
    /// slid across the whole width (column profiles pick a few candidates, each then scored in 2D).
    /// The match also covers a short gap after the text, so a size too small to cover all the
    /// typed text, or other text right after it (a host's own completion), scores low.
    /// - Parameters:
    ///   - text: the field's whole text before the caret, one line (only a fit of all of it counts).
    public static func locate(gray: [UInt8], width: Int, height: Int, scale: CGFloat, text: String,
                              sizes: [CGFloat], font: (CGFloat) -> CTFont) -> TextLocation? {
        guard width > 8, height > 8, gray.count == width * height else { return nil }
        let visible = text.replacingOccurrences(of: "\t", with: " ")
        guard visible.contains(where: { !$0.isWhitespace }), !visible.contains(where: \.isNewline) else { return nil }

        let background = Int(InkBaseline.median(gray))
        var ink = [Float](repeating: 0, count: width * height)
        for i in 0..<ink.count { ink[i] = Float(abs(Int(gray[i]) - background)) }
        let inkRows = rowSums(ink, width: width, height: height)
        let inkColumns = columnSums(ink, width: width, height: height)

        let coarse = stride(from: 0, to: sizes.count, by: 2).map { sizes[$0] }
        var best: TextLocation?
        func consider(_ size: CGFloat) {
            guard size > 3, let found = locateOne(size: size, font: font(size), text: visible, ink: ink, inkRows: inkRows,
                                                  inkColumns: inkColumns, width: width, height: height, scale: scale)
            else { return }
            if best == nil || found.score > best!.score { best = found }
        }
        coarse.forEach(consider)
        if let b = best, let i = sizes.firstIndex(of: b.pointSize) {
            for j in [i - 1, i + 1] where j >= 0 && j < sizes.count { consider(sizes[j]) }
        }
        // Fine pass in quarter points: the whole line's width depends on the size, so a size a few
        // percent off lands the start or the end pixels away.
        if let b = best {
            let i = sizes.firstIndex(of: b.pointSize) ?? 0
            let lo = i > 0 ? sizes[i - 1] : b.pointSize, hi = i < sizes.count - 1 ? sizes[i + 1] : b.pointSize
            var s = (lo * 4).rounded(.up) / 4
            while s <= hi + 0.001 {
                if !sizes.contains(s) { consider(s) }
                s += 0.25
            }
        }
        return best
    }

    /// Ink in the gap after a located line, as a fraction of the ink over the line itself, above
    /// which something else is painted right after the typed text (a host's inline completion, a
    /// selection highlight) and the caret can't be at the end of what's shown.
    public static let maximumTrailingInk = 0.25
    /// `locate` searches the whole width, so more places can line up by chance than in `fit`: live
    /// in Chrome, the right line scored 0.85-0.9 and a wrong spot 0.70.
    public static let minimumLocateScore = 0.78

    /// Sizes for `locate` with no reported size: 9 pt up to what fits the field, about 4% apart.
    public static func locateSizes(fieldHeight: CGFloat) -> [CGFloat] {
        let top = max(10, min(28, fieldHeight * 0.9))
        var out: [CGFloat] = [], s: CGFloat = 9
        while s <= top + 0.001 { out.append((s * 4).rounded() / 4); s *= 1.04 }
        return Array(Set(out)).sorted()
    }

    /// Pen x where drawn text starts in `locate`'s canvas, in pixels (room for a negative bearing).
    static let locatePad = 2.0

    static func locateOne(size: CGFloat, font f: CTFont, text: String, ink: [Float], inkRows: [Float],
                          inkColumns: [Float], width: Int, height: Int, scale: CGFloat) -> TextLocation? {
        let advance = lineWidth(text, font: f) * Double(scale)
        let referenceBaseline = Double(height) * 0.5
        guard advance > 0, locatePad + advance < Double(width) - 1,
              let drawn = render(text, font: f, width: width, height: height, scale: scale,
                                 rightEdge: locatePad + advance, baselineRow: referenceBaseline),
              let tight = Box(tight: drawn, width: width, height: height) else { return nil }
        // Scored columns: the text plus a gap after it about half an em wide.
        let trail = max(4, Int((Double(size) * 0.5 * Double(scale)).rounded()))
        let margin = max(2, (tight.maxY - tight.minY) / 3)
        let penEnd = Int((locatePad + advance).rounded())
        let box = Box(minX: max(0, tight.minX - 1), maxX: min(width - 1, max(tight.maxX, penEnd) + trail),
                      minY: max(0, tight.minY - margin), maxY: min(height - 1, tight.maxY + margin))
        // The whole box must stay inside the capture: a fit that pushes text off either side
        // can't have matched all of it.
        let maxShift = width - 1 - box.maxX, minShift = -box.minX
        guard maxShift >= minShift else { return nil }

        let drawnRows = rowSums(drawn, width: width, height: height)
        let drawnColumns = columnSums(drawn, width: width, height: height)
        let columnPeaks = columnShiftPeaks(drawnColumns, inkColumns, lo: box.minX, hi: box.maxX,
                                           shifts: minShift...maxShift, count: 3)
        let rowPeaks = shiftPeaks(drawnRows, inkRows, range: height / 2, count: 3)
        var bestScore = -Double.infinity, bestDX = 0, bestDY = 0, bestFraction = 0.0
        for column in columnPeaks {
            for row in rowPeaks {
                var dx = column, dy = row.shift, fraction = row.fraction
                var score = correlation(drawn, ink, width: width, height: height, box: box, dx: dx, dy: dy)
                for (cx, cy) in [(column - 1, row.shift), (column + 1, row.shift),
                                 (column, row.shift - 1), (column, row.shift + 1)]
                where cx >= minShift && cx <= maxShift {
                    let s = correlation(drawn, ink, width: width, height: height, box: box, dx: cx, dy: cy)
                    if s > score { score = s; dx = cx; dy = cy; fraction = cy == row.shift ? row.fraction : 0 }
                }
                if score > bestScore { bestScore = score; bestDX = dx; bestDY = dy; bestFraction = fraction }
            }
        }
        guard bestScore > -Double.infinity else { return nil }
        let start = locatePad + Double(bestDX)
        // Mean ink over the text's own pixels vs the gap after it (skipping the host's caret,
        // a pixel or two right of the text).
        let rows = max(0, tight.minY + bestDY)...min(height - 1, tight.maxY + bestDY)
        let textInk = meanInk(ink, width: width, rows: rows, columns: (tight.minX + bestDX)...(tight.maxX + bestDX))
        let gapStart = penEnd + bestDX + Int((1.5 * Double(scale)).rounded()) + 1
        let gapEnd = min(width - 1, penEnd + bestDX + trail * 2)
        let trailing = gapStart <= gapEnd && textInk > 0
            ? meanInk(ink, width: width, rows: rows, columns: gapStart...gapEnd) / textInk : 0
        return TextLocation(pointSize: size, startColumn: start, endColumn: start + advance,
                            baselineRow: referenceBaseline + Double(bestDY) + bestFraction, score: max(0, bestScore),
                            trailingInk: trailing)
    }

    static func meanInk(_ ink: [Float], width: Int, rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Double {
        let c0 = max(0, columns.lowerBound), c1 = min(width - 1, columns.upperBound)
        guard c0 <= c1 else { return 0 }
        var sum = 0.0
        for y in rows { for x in c0...c1 { sum += Double(ink[y * width + x]) } }
        return sum / Double(rows.count * (c1 - c0 + 1))
    }

    /// Typographic width of `text` in points.
    static func lineWidth(_ text: String, font: CTFont) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }

    static func columnSums(_ values: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width)
        for row in 0..<height {
            let base = row * width
            for col in 0..<width { out[col] += values[base + col] }
        }
        return out
    }

    /// The `count` best local maxima of the column-profile match of `drawn[lo...hi]` shifted by
    /// each of `shifts` onto `ink`.
    static func columnShiftPeaks(_ drawn: [Float], _ ink: [Float], lo: Int, hi: Int, shifts: ClosedRange<Int>,
                                 count: Int) -> [Int] {
        // The drawn side's sums don't depend on the shift.
        let n = Double(hi - lo + 1)
        var sx = 0.0, sxx = 0.0
        for x in lo...hi { let a = Double(drawn[x]); sx += a; sxx += a * a }
        let vx = sxx - sx * sx / n
        let scores = drawn.withUnsafeBufferPointer { d in
            ink.withUnsafeBufferPointer { k in
                shifts.map { dx -> Double in
                    var sy = 0.0, syy = 0.0, sxy = 0.0
                    for x in lo...hi {
                        let a = Double(d[x]), b = Double(k[x + dx])
                        sy += b; syy += b * b; sxy += a * b
                    }
                    let cov = sxy - sx * sy / n, vy = syy - sy * sy / n
                    return vx > 0 && vy > 0 ? cov / (vx * vy).squareRoot() : 0
                }
            }
        }
        var peaks: [(shift: Int, score: Double)] = []
        for i in scores.indices {
            let l = i > 0 ? scores[i - 1] : -Double.infinity
            let r = i < scores.count - 1 ? scores[i + 1] : -Double.infinity
            if scores[i] >= l, scores[i] >= r { peaks.append((shifts.lowerBound + i, scores[i])) }
        }
        return peaks.sorted { $0.score > $1.score }.prefix(count).map(\.shift)
    }

    /// Candidate sizes: ±25% around the reported size (or one derived from the caret height),
    /// in steps of about 2%.
    public static func candidateSizes(reported: CGFloat?, caretHeight: CGFloat) -> [CGFloat] {
        let center = reported.flatMap { $0 > 3 ? $0 : nil } ?? max(6, caretHeight * 0.8)
        var out: [CGFloat] = [(center * 4).rounded() / 4]
        var s = center * 0.75
        while s <= center * 1.25 + 0.001 {
            out.append((s * 4).rounded() / 4)
            s *= 1.02
        }
        return Array(Set(out)).sorted()
    }

    // MARK: Drawing

    /// Coverage (0...255) of `text` drawn so that it ends at `rightEdge`, baseline at `baselineRow`
    /// (both in pixels from the top-left), anti-aliased like the host's text.
    static func render(_ text: String, font: CTFont, width: Int, height: Int, scale: CGFloat,
                       rightEdge: Double, baselineRow: Double) -> [Float]? {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.scaleBy(x: scale, y: scale)
            // CoreGraphics' origin is bottom-left: baseline row from the top -> y from the bottom.
            let x = rightEdge / Double(scale) - lineWidth
            let y = (Double(height) - baselineRow) / Double(scale)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
            return true
        }
        guard ok else { return nil }
        return pixels.map(Float.init)
    }

    // MARK: Scoring

    static func rowSums(_ values: [Float], width: Int, height: Int) -> [Float] {
        (0..<height).map { row in
            var s: Float = 0
            let base = row * width
            for col in 0..<width { s += values[base + col] }
            return s
        }
    }

    /// The `count` best local maxima of the row-profile match of `a` (drawn) shifted onto `b`
    /// (captured), each with a parabolic sub-row refinement.
    static func shiftPeaks(_ a: [Float], _ b: [Float], range: Int, count: Int) -> [(shift: Int, fraction: Double)] {
        let shifts = Array(-range...range)
        let scores = shifts.map { profileCorrelation(a, b, shift: $0) }
        var peaks: [(shift: Int, fraction: Double, score: Double)] = []
        for i in scores.indices {
            let l = i > 0 ? scores[i - 1] : -Double.infinity
            let r = i < scores.count - 1 ? scores[i + 1] : -Double.infinity
            guard scores[i] >= l, scores[i] >= r else { continue }
            var fraction = 0.0
            if l.isFinite, r.isFinite {
                let denom = l - 2 * scores[i] + r
                if denom < 0 { fraction = max(-0.5, min(0.5, 0.5 * (l - r) / denom)) }
            }
            peaks.append((shifts[i], fraction, scores[i]))
        }
        return peaks.sorted { $0.score > $1.score }.prefix(count).map { ($0.shift, $0.fraction) }
    }

    /// Pearson correlation of `a` shifted down by `shift` rows against `b`.
    static func profileCorrelation(_ a: [Float], _ b: [Float], shift: Int) -> Double {
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<a.count {
            let j = i + shift
            guard j >= 0, j < b.count else { continue }
            xs.append(Double(a[i])); ys.append(Double(b[j]))
        }
        return pearson(xs, ys)
    }

    /// The rows of the drawn text plus a margin, across the strip's full width: every size is
    /// scored over the same columns, so a size too small to cover all the typed text is penalized
    /// for the ink it leaves unmatched (scoring only its own box made smaller sizes win).
    struct Box {
        let minX: Int, maxX: Int, minY: Int, maxY: Int
        init?(_ drawn: [Float], width: Int, height: Int) {
            var x0 = width, x1 = -1, y0 = height, y1 = -1
            for y in 0..<height {
                for x in 0..<width where drawn[y * width + x] > 0 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            guard x1 >= x0, y1 >= y0 else { return nil }
            let margin = max(2, (y1 - y0) / 3)
            minX = 0; maxX = width - 1
            minY = max(0, y0 - margin); maxY = min(height - 1, y1 + margin)
        }

        /// The drawn ink's own bounds, no margin.
        init?(tight drawn: [Float], width: Int, height: Int) {
            var x0 = width, x1 = -1, y0 = height, y1 = -1
            for y in 0..<height {
                for x in 0..<width where drawn[y * width + x] > 0 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            guard x1 >= x0, y1 >= y0 else { return nil }
            minX = x0; maxX = x1; minY = y0; maxY = y1
        }

        init(minX: Int, maxX: Int, minY: Int, maxY: Int) {
            self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
        }
    }

    /// Normalized cross-correlation of the drawn image shifted by (dx, dy) against the ink map,
    /// over the drawn text's box.
    static func correlation(_ drawn: [Float], _ ink: [Float], width: Int, height: Int, box: Box, dx: Int, dy: Int) -> Double {
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        drawn.withUnsafeBufferPointer { d in
            ink.withUnsafeBufferPointer { k in
                for y in box.minY...box.maxY {
                    let ty = y + dy
                    guard ty >= 0, ty < height else { continue }
                    let x0 = max(box.minX, -dx), x1 = min(box.maxX, width - 1 - dx)
                    guard x0 <= x1 else { continue }
                    let row = y * width, trow = ty * width + dx
                    var rsx: Float = 0, rsy: Float = 0, rsxx: Float = 0, rsyy: Float = 0, rsxy: Float = 0
                    for x in x0...x1 {
                        let a = d[row + x], b = k[trow + x]
                        rsx += a; rsy += b; rsxx += a * a; rsyy += b * b; rsxy += a * b
                    }
                    n += Double(x1 - x0 + 1)
                    sx += Double(rsx); sy += Double(rsy); sxx += Double(rsxx); syy += Double(rsyy); sxy += Double(rsxy)
                }
            }
        }
        guard n > 2 else { return 0 }
        let cov = sxy - sx * sy / n, vx = sxx - sx * sx / n, vy = syy - sy * sy / n
        guard vx > 0, vy > 0 else { return 0 }
        return cov / (vx * vy).squareRoot()
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
        let n = Double(xs.count)
        guard n > 2 else { return 0 }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<xs.count {
            let a = xs[i] - mx, b = ys[i] - my
            sxy += a * b; sxx += a * a; syy += b * b
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }
}
