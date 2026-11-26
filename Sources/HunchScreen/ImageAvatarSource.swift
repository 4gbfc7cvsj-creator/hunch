import CoreGraphics
import Foundation
import HunchCore

/// Reads avatar fingerprints (`AvatarFinder`) out of a captured window image, for patches given in
/// screen points. Used only while the capture is in hand; holds the image no longer than that.
public struct ImageAvatarSource: @unchecked Sendable {
    let image: CGImage
    /// The screen rect (points, top-left origin) the image shows.
    let band: CGRect
    /// Debug logging only: per patch read, where the avatar was found (screen points) or that none was.
    public final class Notes: @unchecked Sendable { public var lines: [String] = [] }
    public let notes: Notes?

    public init(image: CGImage, band: CGRect, notes: Notes? = nil) {
        self.image = image
        self.band = band
        self.notes = notes
    }

    /// Patches are scaled down to at most this many pixels on a side before searching.
    static let maxPatch = 220

    /// The avatar in `patch` (screen points), sized `minSide...maxSide` points; nil when none is clear.
    public func print(in patch: CGRect, minSide: CGFloat, maxSide: CGFloat) -> AvatarPrint? {
        let scale = CGFloat(image.width) / max(1, band.width)
        let px = CGRect(x: (patch.minX - band.minX) * scale, y: (patch.minY - band.minY) * scale,
                        width: patch.width * scale, height: patch.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !px.isNull, px.width >= 4, px.height >= 4, let crop = image.cropping(to: px) else { return nil }
        let shrink = min(1, CGFloat(Self.maxPatch) / max(px.width, px.height))
        let w = max(1, Int(px.width * shrink)), h = max(1, Int(px.height * shrink))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let k = scale * shrink
        let found = AvatarFinder.find(rgba: bytes, width: w, height: h,
                                      minSide: Int(minSide * k), maxSide: Int((maxSide * k).rounded(.up)))
        if let notes {
            func pt(_ r: CGRect) -> String {
                "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))"
            }
            let box = found.map { b in
                CGRect(x: px.minX / scale + b.box.minX / k + band.minX, y: px.minY / scale + b.box.minY / k + band.minY,
                       width: b.box.width / k, height: b.box.height / k)
            }
            notes.lines.append("avatar patch=\(pt(patch)) side=\(Int(minSide))-\(Int(maxSide)) "
                               + (box.map { "box=\(pt($0))" } ?? "none"))
        }
        return found?.print
    }
}
