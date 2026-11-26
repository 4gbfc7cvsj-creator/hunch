import CoreGraphics
import HunchCore

/// The field's background color from the calibration strip: the most common color in a few pixel
/// columns (the strip's first and last) across the caret's line. Typed glyphs cover only a little
/// of those columns, so the background dominates; a strip with no dominant color (a gradient, an
/// image) gives nil.
public enum StripBackground {
    /// Colors closer than this per channel (of 255) count as the same: 3 low bits are ignored.
    static let binShift = 3
    /// The winning color must cover at least this share of the sampled pixels.
    public static let minimumShare = 0.5

    /// - Parameters:
    ///   - rgba: tightly packed 8-bit RGBA (or RGBX) pixels, rows from the top, sRGB.
    ///   - columns: pixel columns to sample; out-of-range ones are skipped.
    ///   - rows: pixel rows to sample, clamped to the image.
    public static func modalColor(rgba: [UInt8], width: Int, height: Int, columns: [Int],
                                  rows: Range<Int>) -> RGBAColor? {
        let top = max(0, rows.lowerBound), bottom = min(height, rows.upperBound)
        guard width > 0, height > 0, rgba.count >= width * height * 4, top < bottom else { return nil }
        let rowRange = top..<bottom
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        var total = 0
        for column in Set(columns) where column >= 0 && column < width {
            for row in rowRange {
                let i = (row * width + column) * 4
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                let key = (r >> binShift) << 10 | (g >> binShift) << 5 | (b >> binShift)
                var bin = bins[key] ?? (0, 0, 0, 0)
                bin.count += 1
                bin.r += r
                bin.g += g
                bin.b += b
                bins[key] = bin
                total += 1
            }
        }
        guard total > 0, let best = bins.values.max(by: { $0.count < $1.count }),
              Double(best.count) >= Double(total) * minimumShare else { return nil }
        let n = CGFloat(best.count) * 255
        return RGBAColor(red: CGFloat(best.r) / n, green: CGFloat(best.g) / n, blue: CGFloat(best.b) / n)
    }
}
