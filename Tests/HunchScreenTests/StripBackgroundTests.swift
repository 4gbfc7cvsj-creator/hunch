import HunchCore
import Testing
@testable import HunchScreen

/// The field's background from the calibration strip's first and last columns (mirror mode).
@Suite struct StripBackgroundTests {
    /// A width × height RGBX strip filled with `fill`.
    private func strip(width: Int = 40, height: Int = 20, fill: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = fill.0
            px[i + 1] = fill.1
            px[i + 2] = fill.2
        }
        return px
    }

    private func set(_ px: inout [UInt8], width: Int, column: Int, row: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (row * width + column) * 4
        px[i] = c.0
        px[i + 1] = c.1
        px[i + 2] = c.2
    }

    @Test func uniformBackground() throws {
        let px = strip(fill: (30, 32, 36))
        let c = try #require(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0, 39], rows: 0..<20))
        #expect(abs(c.red * 255 - 30) < 0.01 && abs(c.green * 255 - 32) < 0.01 && abs(c.blue * 255 - 36) < 0.01)
        #expect(c.alpha == 1)
    }

    @Test func glyphPixelsInTheLastColumnDontWin() throws {
        // A light field; the last column (just left of the caret) crosses a dark glyph on some rows.
        var px = strip(fill: (250, 250, 250))
        for row in 6..<12 { set(&px, width: 40, column: 39, row: row, (20, 20, 20)) }
        let c = try #require(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0, 39], rows: 0..<20))
        #expect(abs(c.red * 255 - 250) < 0.01)
    }

    @Test func nearlyEqualShadesShareABin() throws {
        // Antialiasing noise of a level or two still counts as the background, averaged.
        var px = strip(fill: (200, 200, 200))
        for row in 0..<10 { set(&px, width: 40, column: 0, row: row, (201, 201, 201)) }
        let c = try #require(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0, 39], rows: 0..<20))
        #expect(abs(c.red * 255 - 200.25) < 0.01)
    }

    @Test func onlyTheCaretRowsAreSampled() throws {
        // Rows outside the caret's line (another color above, a border below) are ignored.
        var px = strip(fill: (255, 255, 255))
        for row in 0..<8 { for col in [0, 39] { set(&px, width: 40, column: col, row: row, (0, 0, 255)) } }
        let c = try #require(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0, 39], rows: 8..<20))
        #expect(c.blue == 1 && c.red == 1)
    }

    @Test func noDominantColorGivesNil() {
        // A gradient down the columns: no color covers half the samples.
        var px = strip(fill: (0, 0, 0))
        for row in 0..<20 {
            for col in [0, 39] { set(&px, width: 40, column: col, row: row, (UInt8(row * 12), 0, 0)) }
        }
        #expect(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0, 39], rows: 0..<20) == nil)
    }

    @Test func outOfRangeInputIsSafe() {
        let px = strip(fill: (9, 9, 9))
        #expect(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [-1, 40], rows: 0..<20) == nil)
        #expect(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0], rows: 30..<40) == nil)
        #expect(StripBackground.modalColor(rgba: [], width: 40, height: 20, columns: [0], rows: 0..<20) == nil)
        // Rows past the edges are clamped.
        #expect(StripBackground.modalColor(rgba: px, width: 40, height: 20, columns: [0], rows: -5..<50) != nil)
    }
}
