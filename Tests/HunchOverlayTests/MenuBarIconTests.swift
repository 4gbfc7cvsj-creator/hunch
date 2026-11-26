import AppKit
import HunchCore
import Testing
@testable import HunchOverlay

@MainActor
@Suite struct MenuBarIconTests {
    /// Renders `choice` at 4x into a bitmap 8 points wider than the icon on every side, and returns
    /// the inked pixels' bounds in points relative to the 18-point square (nil if nothing was drawn).
    private func inkBounds(_ choice: MenuBarIconChoice) -> CGRect? {
        let scale = 4, margin = 8
        let px = (18 + 2 * margin) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.cgContext.translateBy(x: CGFloat(margin), y: CGFloat(margin))
        MenuBarIcon.draw(choice, color: .black)
        NSGraphicsContext.restoreGraphicsState()
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<px { for x in 0..<px where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return nil }
        let s = CGFloat(scale), m = CGFloat(margin)
        // Bitmap rows run top-down.
        return CGRect(x: CGFloat(minX) / s - m, y: CGFloat(px - 1 - maxY) / s - m,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    @Test(arguments: MenuBarIconChoice.allCases)
    func glyphFillsMostOfTheSquareWithoutSpilling(_ choice: MenuBarIconChoice) throws {
        let ink = try #require(inkBounds(choice))
        #expect(ink.minX >= -0.25 && ink.minY >= -0.25 && ink.maxX <= 18.25 && ink.maxY <= 18.25, "\(ink)")
        // Big enough to read next to the system icons.
        #expect(max(ink.width, ink.height) >= 14, "\(ink)")
    }

    @Test(arguments: MenuBarIconChoice.allCases)
    func imageIsATemplate(_ choice: MenuBarIconChoice) {
        let image = MenuBarIcon.image(choice)
        #expect(image.isTemplate)
        #expect(image.size == MenuBarIcon.size)
    }
}
