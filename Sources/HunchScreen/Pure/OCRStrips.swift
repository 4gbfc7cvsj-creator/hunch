import CoreGraphics

/// Text recognition shrinks a large image before reading it: a tall window captured at 2x (a chat on
/// a portrait display, 2880×5060 pixels) came out as garbage ("Parning the baseline on the curreat
/// prompt") and lost most of its lines, while the same window read in 1,600-pixel strips was word
/// for word. So a big capture is read in horizontal strips that overlap a little; each line is kept
/// from the one strip whose middle part holds its centre, so a line in an overlap is read once and
/// never cut in half.
public struct OCRStrip: Equatable, Sendable {
    /// Pixel rows from the image's top.
    public var top: Int
    public var height: Int
    /// A line belongs to this strip when its centre row (from the top) is in `keepFrom..<keepTo`.
    public var keepFrom: Int
    public var keepTo: Int

    public init(top: Int, height: Int, keepFrom: Int, keepTo: Int) {
        self.top = top
        self.height = height
        self.keepFrom = keepFrom
        self.keepTo = keepTo
    }
}

public enum OCRStrips {
    /// Tallest strip, and most pixels per strip (a 2880-wide strip of 1,600 rows; wider images get
    /// shorter strips: a 5120-wide one at 1,600 rows still misread a few words, at 900 it didn't).
    public static let maxHeight = 1600
    public static let maxPixels = 2880 * 1600
    public static let minHeight = 600
    /// Rows two strips share: taller than a line of large text at 2x, so every line fits whole in
    /// the strip that keeps it.
    public static let overlap = 200

    public static func stripHeight(width: Int) -> Int {
        min(maxHeight, max(minHeight, maxPixels / max(1, width)))
    }

    /// The strips that cover an image, top to bottom; one strip (the whole image) when it is small
    /// enough to read at once.
    public static func plan(width: Int, height: Int) -> [OCRStrip] {
        let size = stripHeight(width: width)
        guard height > size else { return [OCRStrip(top: 0, height: max(0, height), keepFrom: 0, keepTo: max(0, height))] }
        var tops: [Int] = []
        var top = 0
        while top + size < height {
            tops.append(top)
            top += size - overlap
        }
        // The last strip ends at the bottom edge (it may share more than `overlap` with the one above).
        tops.append(height - size)
        var strips: [OCRStrip] = []
        for (index, top) in tops.enumerated() {
            // Lines split at the middle of each overlap.
            let from = index == 0 ? 0 : (top + tops[index - 1] + size) / 2
            let to = index == tops.count - 1 ? height : (tops[index + 1] + top + size) / 2
            strips.append(OCRStrip(top: top, height: size, keepFrom: from, keepTo: to))
        }
        return strips
    }

    /// A box Vision gave for a strip (normalized, origin bottom-left) as a box on the whole image
    /// (same convention), so `CaptureGeometry.screenRect` can place it.
    public static func wholeImageBox(_ box: CGRect, strip: OCRStrip, imageHeight: Int) -> CGRect {
        let h = CGFloat(max(1, imageHeight)), stripH = CGFloat(strip.height)
        let bottomFromImageBottom = h - CGFloat(strip.top) - stripH
        return CGRect(x: box.minX, y: (bottomFromImageBottom + box.minY * stripH) / h,
                      width: box.width, height: box.height * stripH / h)
    }

    /// Whether `strip` keeps a line at `box` (whole-image normalized, origin bottom-left).
    public static func keeps(_ box: CGRect, strip: OCRStrip, imageHeight: Int) -> Bool {
        let centre = (1 - box.midY) * CGFloat(imageHeight)
        return centre >= CGFloat(strip.keepFrom) && centre < CGFloat(strip.keepTo)
    }
}
