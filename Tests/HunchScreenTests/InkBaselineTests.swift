import CoreGraphics
import CoreText
@testable import HunchCore
import Testing
@testable import HunchScreen

@Suite struct InkBaselineTests {
    /// Renders a synthetic strip: background 255, a dense band of ink rows (the x-height band) and a
    /// few sparse rows above (ascenders) and below (descenders).
    private func strip(width: Int = 60, height: Int = 30, band: ClosedRange<Int>, sparse: [Int]) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height)
        for row in band { for col in stride(from: 0, to: width, by: 2) { px[row * width + col] = 20 } }
        for row in sparse { for col in stride(from: 0, to: width, by: 15) { px[row * width + col] = 20 } }
        return px
    }

    @Test func baselineIsBottomOfDenseBandIgnoringDescenders() {
        let px = strip(band: 10...19, sparse: [5, 6, 7, 20, 21, 22])
        let m = InkBaseline.measure(gray: px, width: 60, height: 30)
        #expect(m?.baselineRow == 20)
        #expect(m?.xHeightTopRow == 10)
        #expect(m?.xHeightPixels == 10)
        // Crisp edges: the sub-pixel values agree with the whole rows.
        #expect(abs((m?.baseline ?? 0) - 20) < 0.01)
        #expect(abs((m?.xHeightTop ?? 0) - 10) < 0.01)
    }

    @Test func halfCoveredEdgeRowsCountHalf() {
        // Like anti-aliased text: the first and last band rows are inked at half contrast.
        var px = strip(band: 11...18, sparse: [])
        for row in [10, 19] { for col in stride(from: 0, to: 60, by: 2) { px[row * 60 + col] = 138 } }
        let m = InkBaseline.measure(gray: px, width: 60, height: 30)
        #expect(m?.baselineRow == 20)                       // whole rows: the half row counts fully
        #expect(abs((m?.baseline ?? 0) - 19.5) < 0.05)     // sub-pixel: half a row
        #expect(abs((m?.xHeightTop ?? 0) - 10.5) < 0.05)
        #expect(abs((m?.xHeight ?? 0) - 9) < 0.1)
    }

    @Test func darkBackgroundWorksToo() {
        let px = strip(band: 8...15, sparse: []).map { 255 - $0 }
        #expect(InkBaseline.measure(gray: px, width: 60, height: 30)?.baselineRow == 16)
    }

    @Test func emptyOrCutOffStripsAreRejected() {
        #expect(InkBaseline.measure(gray: [UInt8](repeating: 255, count: 600), width: 20, height: 30) == nil)
        // Band touching the bottom edge: text cut off.
        #expect(InkBaseline.measure(gray: strip(band: 20...29, sparse: []), width: 60, height: 30) == nil)
    }
}

@Suite struct InkXHeightTests {
    private func face(_ family: String, _ size: CGFloat) -> CTFont {
        TextCalibrationProbe.installedFace(family, size: size)!
    }

    /// The host's text, painted in `family` at 16 pt on a 2x strip, read back as `measure` reads a capture.
    private func hostX(_ family: String, text: String = "seems like we might") -> CGFloat? {
        let scale: CGFloat = 2, width = 400, height = 70
        let baseline = 40.0
        guard let ink = TemplateMatch.render(text, font: face(family, 16), width: width, height: height, scale: scale,
                                             rightEdge: Double(width - 10), baselineRow: baseline) else { return nil }
        // Light text on a dark field, like Discord.
        let gray = ink.map { UInt8(max(0, min(255, 30 + $0 * 0.8))) }
        return InkBaseline.lineXHeight(gray: gray, width: width, height: height, baselineRow: baseline,
                                       caretPixels: 44).map { CGFloat($0) / scale }
    }

    private func drawnX(_ family: String, text: String = "seems like we might") -> CGFloat? {
        InkBaseline.drawnXHeight(text: text, font: face(family, 16), width: 400, height: 70, scale: 2,
                                 rightEdge: 390).map { CGFloat($0) / 2 }
    }

    @Test func sameFaceMeasuresTheSameHeight() throws {
        let host = try #require(hostX("Avenir Next"))
        let drawn = try #require(drawnX("Avenir Next"))
        #expect(abs(host - drawn) < 0.15)
    }

    @Test func systemFaceMeasuresTallerThanAvenirNext() throws {
        let system = try #require(drawnX("System"))
        let avenir = try #require(drawnX("Avenir Next"))
        #expect(system - avenir > 0.5)
    }

    @Test func pickerFindsTheFaceTheHostUsed() throws {
        let host = try #require(hostX("Avenir Next"))
        var faces: [String: CGFloat] = [:]
        for f in FaceMatch.candidates { faces[f] = drawnX(f) }
        #expect(FaceMatch.pickFace(host: host, xHeights: faces) == "Avenir Next")
        let systemHost = try #require(hostX("System"))
        #expect(FaceMatch.pickFace(host: systemHost, xHeights: faces) == nil)
    }

    @Test func ignoresInkOffTheMatchedBaseline() {
        let gray = [UInt8](repeating: 30, count: 400 * 70)
        #expect(InkBaseline.lineXHeight(gray: gray, width: 400, height: 70, baselineRow: 40, caretPixels: 44) == nil)
    }
}

@Suite struct TextCalibrationDecisionTests {
    private func cal(host: CGFloat?, faces: [String: CGFloat]) -> TextCalibration {
        TextCalibration(baselineAboveCaretBottom: 5, xHeight: nil, hostXHeight: host, measuredAtSize: 16,
                        faceXHeights: faces)
    }

    @Test func unloadableFontGetsAMeasuredFace() {
        let d = cal(host: 7.55, faces: ["System": 8.4, "Avenir Next": 7.5, "Helvetica Neue": 8.3]).decided(previous: nil)
        #expect(d.pickedFamily == "Avenir Next")
        #expect(d.sizeFactor == 1)
        #expect(!d.needsConfirmation)
    }

    @Test func loadedFontSizeNeedsTwoMeasurements() {
        let first = cal(host: 8.6, faces: [TextCalibration.hostFontKey: 8.0]).decided(previous: nil)
        #expect(first.sizeFactor == 1)
        #expect(first.needsConfirmation)
        #expect(first.pickedFamily == nil)
        let second = cal(host: 8.65, faces: [TextCalibration.hostFontKey: 8.0]).decided(previous: first)
        #expect(abs(second.sizeFactor - 1.078) < 0.005)
        #expect(!second.needsConfirmation)
        // A later measurement in agreement clears it.
        let third = cal(host: 8.05, faces: [TextCalibration.hostFontKey: 8.0]).decided(previous: second)
        #expect(third.sizeFactor == 1)
    }

    @Test func noInkMeasurementKeepsThePreviousDecision() {
        var prev = cal(host: 7.5, faces: [:])
        prev.pickedFamily = "Avenir Next"
        let d = cal(host: nil, faces: [:]).decided(previous: prev)
        #expect(d.pickedFamily == "Avenir Next")
    }
}
