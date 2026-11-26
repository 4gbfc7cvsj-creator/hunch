import CoreGraphics
import Foundation
import HunchCore

/// Finds the avatar in a patch of pixels left of a chat header and fingerprints it (`AvatarPrint`).
/// Pure, on RGBA bytes.
///
/// The patch is searched generously (it may hold the reply connector line above the avatar, a
/// mention highlight's edge bar, or a short name and emoji to its right), so the avatar is the
/// biggest solid shape: the longest run of rows with plenty of foreground, then within those rows
/// the longest run of such columns. Thin lines and small glyphs fall below the cut.
public enum AvatarFinder {
    /// A pixel is foreground when its color differs from the background by more than this
    /// (sum over R, G, B). Low enough for a dark avatar on Discord's near-black background, or inside
    /// a mention highlight (a navy bot avatar differed by about 45).
    static let foregroundDifference = 40
    /// A row (or column) is part of a shape when its foreground count is at least this share of the
    /// busiest row's (column's).
    static let runShare = 0.3
    /// Rows or columns below the cut inside a run, up to this many, don't end it (a thin gap in a
    /// picture).
    static let runGapAllowance = 2
    /// The avatar's box must be about square.
    static let maxAspect = 1.5

    /// - Parameters:
    ///   - rgba: `width * height * 4` bytes, row by row from the top.
    ///   - minSide/maxSide: the avatar's side in pixels must fall in this range.
    public static func print(rgba: [UInt8], width: Int, height: Int, minSide: Int, maxSide: Int) -> AvatarPrint? {
        find(rgba: rgba, width: width, height: height, minSide: minSide, maxSide: maxSide)?.print
    }

    /// The fingerprint and the avatar's box in the patch's pixels, or the box tried and why it failed.
    public static func find(rgba: [UInt8], width: Int, height: Int, minSide: Int, maxSide: Int)
        -> (print: AvatarPrint, box: CGRect)? {
        guard width > 2, height > 2, rgba.count >= width * height * 4 else { return nil }
        let bg = background(rgba, width: width, height: height)
        var fg = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let rowBG = rowBackground(rgba, width: width, y: y)
            for x in 0..<width {
                let p = (y * width + x) * 4
                let d = abs(Int(rgba[p]) - rowBG.0) + abs(Int(rgba[p + 1]) - rowBG.1) + abs(Int(rgba[p + 2]) - rowBG.2)
                fg[y * width + x] = d > foregroundDifference
            }
        }
        var rowCounts = [Int](repeating: 0, count: height)
        for y in 0..<height { for x in 0..<width where fg[y * width + x] { rowCounts[y] += 1 } }
        guard let rows = longestRun(rowCounts) else { return nil }
        var colCounts = [Int](repeating: 0, count: width)
        for y in rows { for x in 0..<width where fg[y * width + x] { colCounts[x] += 1 } }
        guard let cols = longestRun(colCounts) else { return nil }
        let w = cols.count, h = rows.count
        guard min(w, h) >= minSide, max(w, h) <= maxSide,
              Double(max(w, h)) <= Double(min(w, h)) * maxAspect else { return nil }

        // The square around the box's center, cut into cells of average color.
        let side = max(w, h)
        let cx = Double(cols.lowerBound) + Double(w) / 2, cy = Double(rows.lowerBound) + Double(h) / 2
        let n = AvatarPrint.side
        var cells = [UInt8](repeating: 0, count: n * n * 3)
        for cy0 in 0..<n {
            for cx0 in 0..<n {
                let x0 = Int(cx - Double(side) / 2 + Double(side * cx0) / Double(n))
                let x1 = Int(cx - Double(side) / 2 + Double(side * (cx0 + 1)) / Double(n))
                let y0 = Int(cy - Double(side) / 2 + Double(side * cy0) / Double(n))
                let y1 = Int(cy - Double(side) / 2 + Double(side * (cy0 + 1)) / Double(n))
                var sum = (0, 0, 0), count = 0
                for y in max(0, y0)..<min(height, max(y0 + 1, y1)) {
                    for x in max(0, x0)..<min(width, max(x0 + 1, x1)) {
                        let p = (y * width + x) * 4
                        sum.0 += Int(rgba[p]); sum.1 += Int(rgba[p + 1]); sum.2 += Int(rgba[p + 2])
                        count += 1
                    }
                }
                let c = (cy0 * n + cx0) * 3
                if count > 0 {
                    cells[c] = UInt8(sum.0 / count); cells[c + 1] = UInt8(sum.1 / count); cells[c + 2] = UInt8(sum.2 / count)
                } else {
                    cells[c] = UInt8(bg.0); cells[c + 1] = UInt8(bg.1); cells[c + 2] = UInt8(bg.2)
                }
            }
        }
        return (AvatarPrint(cells: cells), CGRect(x: cols.lowerBound, y: rows.lowerBound, width: w, height: h))
    }

    /// Share of the patch's width, at its right end, read as the row's background: the gap between the
    /// avatar and the message text is always background, also on a message lit up under the mouse or
    /// highlighted for a mention, which lights up the avatar's side of the row too.
    static let rowBackgroundShare = 0.06

    /// The row's background: the median color of the patch's right end in that row.
    static func rowBackground(_ rgba: [UInt8], width: Int, y: Int) -> (Int, Int, Int) {
        let n = max(3, Int(Double(width) * rowBackgroundShare))
        var r: [Int] = [], g: [Int] = [], b: [Int] = []
        for x in max(0, width - n)..<width {
            let p = (y * width + x) * 4
            r.append(Int(rgba[p])); g.append(Int(rgba[p + 1])); b.append(Int(rgba[p + 2]))
        }
        r.sort(); g.sort(); b.sort()
        return (r[r.count / 2], g[g.count / 2], b[b.count / 2])
    }

    /// The most common color on the patch's border (colors binned by their top 4 bits), averaged.
    static func background(_ rgba: [UInt8], width: Int, height: Int) -> (Int, Int, Int) {
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        func add(_ x: Int, _ y: Int) {
            let p = (y * width + x) * 4
            let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let e = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (e.count + 1, e.r + r, e.g + g, e.b + b)
        }
        for x in 0..<width { add(x, 0); add(x, height - 1) }
        for y in 1..<(height - 1) { add(0, y); add(width - 1, y) }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return (0, 0, 0) }
        return (top.r / top.count, top.g / top.count, top.b / top.count)
    }

    /// The longest run of indices whose count reaches `runShare` of the largest, allowing short gaps.
    static func longestRun(_ counts: [Int]) -> Range<Int>? {
        guard let peak = counts.max(), peak > 0 else { return nil }
        let cut = max(2, Int((Double(peak) * runShare).rounded(.up)))
        var best: Range<Int>?
        var start: Int?, lastIn = -1
        for (i, c) in counts.enumerated() {
            if c >= cut {
                if start == nil || i - lastIn - 1 > runGapAllowance { start = i }
                lastIn = i
                let run = start!..<(i + 1)
                if run.count > (best?.count ?? 0) { best = run }
            }
        }
        return best
    }
}
