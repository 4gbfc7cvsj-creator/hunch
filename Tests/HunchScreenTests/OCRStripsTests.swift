import CoreGraphics
import Testing
@testable import HunchScreen

@Suite struct OCRStripsTests {
    @Test func aSmallCaptureIsReadWhole() {
        #expect(OCRStrips.plan(width: 1600, height: 1200) == [OCRStrip(top: 0, height: 1200, keepFrom: 0, keepTo: 1200)])
    }

    @Test func aTallWindowIsCoveredByOverlappingStripsThatSplitEachLineOnce() {
        let strips = OCRStrips.plan(width: 2880, height: 5060)
        #expect(strips.count == 4)
        #expect(strips.first?.top == 0)
        #expect(strips.last.map { $0.top + $0.height } == 5060)
        for (a, b) in zip(strips, strips.dropFirst()) {
            #expect(b.top < a.top + a.height - 100)          // they overlap by more than half a big line
            #expect(a.keepTo == b.keepFrom)                   // every row kept by exactly one strip
            #expect(a.keepTo > b.top + 50 && a.keepTo < a.top + a.height - 50)
        }
        #expect(strips.first?.keepFrom == 0)
        #expect(strips.last?.keepTo == 5060)
        #expect(strips.allSatisfy { $0.height <= OCRStrips.maxHeight })
    }

    @Test func wideImagesGetShorterStrips() {
        #expect(OCRStrips.stripHeight(width: 2880) == 1600)
        #expect(OCRStrips.stripHeight(width: 5120) == 900)
        #expect(OCRStrips.stripHeight(width: 40_000) == OCRStrips.minHeight)
    }

    @Test func aStripBoxMapsBackOntoTheWholeImage() {
        let strip = OCRStrip(top: 1400, height: 1600, keepFrom: 1500, keepTo: 2900)
        // A line in the strip's top half: rows 1400+400 ... 1400+440 from the image top.
        let inStrip = CGRect(x: 0.1, y: 1 - 440.0 / 1600, width: 0.5, height: 40.0 / 1600)
        let whole = OCRStrips.wholeImageBox(inStrip, strip: strip, imageHeight: 5000)
        #expect(abs((1 - whole.maxY) * 5000 - 1800) < 0.01)
        #expect(abs(whole.height * 5000 - 40) < 0.01)
        #expect(whole.minX == 0.1 && whole.width == 0.5)
        #expect(OCRStrips.keeps(whole, strip: strip, imageHeight: 5000))
        // The same row range in the overlap above belongs to the strip above.
        let high = OCRStrips.wholeImageBox(CGRect(x: 0, y: 1 - 60.0 / 1600, width: 1, height: 40.0 / 1600),
                                           strip: strip, imageHeight: 5000)
        #expect(!OCRStrips.keeps(high, strip: strip, imageHeight: 5000))
    }
}
