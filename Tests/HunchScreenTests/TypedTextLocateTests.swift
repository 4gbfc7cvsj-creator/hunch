import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import HunchScreen

private func system(_ size: CGFloat) -> CTFont { CTFontCreateUIFontForLanguage(.system, size, nil)! }

/// A fake single-line field capture (an address bar): an icon on the left, then text runs drawn
/// one after another from `start` (pixels), baseline mid-field.
private func field(_ runs: [String], start: Double = 90, size: CGFloat = 14, width: Int = 1200, height: Int = 56,
                   scale: CGFloat = 2, dark: Bool = false, icon: Bool = true, noise: Int = 0) -> [UInt8] {
    let font = system(size)
    var coverage = [Float](repeating: 0, count: width * height)
    var pen = start
    for run in runs {
        let advance = TemplateMatch.lineWidth(run, font: font) * Double(scale)
        let c = TemplateMatch.render(run, font: font, width: width, height: height, scale: scale,
                                     rightEdge: pen + advance, baselineRow: 36)!
        for i in 0..<c.count { coverage[i] = max(coverage[i], c[i]) }
        pen += advance
    }
    if icon {
        for y in 16..<40 { for x in 24..<48 { coverage[y * width + x] = 255 } }
    }
    let (bg, fg): (Double, Double) = dark ? (38, 235) : (250, 20)
    var rng = SystemRandomNumberGenerator()
    return coverage.map { cov in
        let v = bg + (fg - bg) * Double(cov) / 255 + Double(noise > 0 ? Int.random(in: -noise...noise, using: &rng) : 0)
        return UInt8(max(0, min(255, v.rounded())))
    }
}

private func locate(_ gray: [UInt8], _ text: String, width: Int = 1200, height: Int = 56) -> TextLocation? {
    TemplateMatch.locate(gray: gray, width: width, height: height, scale: 2, text: text,
                         sizes: TemplateMatch.locateSizes(fieldHeight: CGFloat(height) / 2), font: system)
}

@Suite struct TypedTextLocateTests {
    @Test func findsTypedLineAfterAnIcon() {
        for dark in [false, true] {
            let text = "how to make sourdough"
            let gray = field([text], dark: dark, noise: 5)
            let found = locate(gray, text)
            let expectedEnd = 90 + TemplateMatch.lineWidth(text, font: system(14)) * 2
            #expect(found?.isConfident == true, "dark=\(dark) score=\(found?.score ?? -1) trailing=\(found?.trailingInk ?? -1)")
            #expect(abs((found?.startColumn ?? 0) - 90) <= 2, "start=\(found?.startColumn ?? -1)")
            #expect(abs((found?.endColumn ?? 0) - expectedEnd) <= 3, "end=\(found?.endColumn ?? -1) want \(expectedEnd)")
            #expect(abs((found?.baselineRow ?? 0) - 36) <= 1.0)
            #expect(found.map { abs($0.pointSize - 14) <= 0.6 } == true, "size=\(found?.pointSize ?? -1)")
        }
    }

    @Test func otherSizesAndPositions() {
        for (size, start) in [(12.0, 70.0), (13.0, 140.0), (16.0, 60.0)] as [(CGFloat, Double)] {
            let text = "github.com/settings"
            let found = locate(field([text], start: start, size: size), text)
            #expect((found?.score ?? 0) >= TemplateMatch.minimumScore, "size \(size) score=\(found?.score ?? -1)")
            #expect(abs((found?.startColumn ?? 0) - start) <= 2, "size \(size) start=\(found?.startColumn ?? -1)")
        }
    }

    /// Text shown right after the typed text (a host's own inline completion): the caret isn't
    /// at the end of what's painted, so no confident fit.
    @Test func textRightAfterTypedTextIsRejected() {
        let gray = field(["how to make sour", "dough bread recipe"])
        let found = locate(gray, "how to make sour")
        #expect(found?.isConfident != true, "score=\(found?.score ?? -1) trailing=\(found?.trailingInk ?? -1)")
    }

    @Test func differentTextIsRejected() {
        let gray = field(["weather tomorrow in Boston"])
        let found = locate(gray, "how to make sourdough")
        #expect((found?.score ?? 0) < TemplateMatch.minimumScore, "score=\(found?.score ?? -1)")
    }

    @Test func emptyFieldIsRejected() {
        let gray = field([], icon: true)
        #expect((locate(gray, "hello world")?.score ?? 0) < TemplateMatch.minimumScore)
    }

    @Test func traditionalChinese() {
        let text = "台北明天的天氣"
        let found = locate(field([text]), text)
        #expect((found?.score ?? 0) >= TemplateMatch.minimumScore, "score=\(found?.score ?? -1)")
        #expect(abs((found?.startColumn ?? 0) - 90) <= 2)
    }

    @Test func eligibility() {
        #expect(TypedTextAnchor.isEligible(before: "hello"))
        #expect(TypedTextAnchor.isEligible(before: "天氣預報"))
        #expect(!TypedTextAnchor.isEligible(before: "hi"))
        #expect(!TypedTextAnchor.isEligible(before: "first line\nsecond"))
    }

    @Test func caretFromAnchor() {
        let anchor = TypedTextAnchor(startOffset: 45, baselineOffset: 10, pointSize: 14)
        let frame = CGRect(x: 100, y: 500, width: 600, height: 28)
        let font = system(14)
        let caret = anchor.caret(after: "hello", fieldFrame: frame, font: font)
        let width = CGFloat(TemplateMatch.lineWidth("hello", font: font))
        #expect(caret.map { abs($0.minX - (145 + width)) < 0.01 } == true)
        #expect(caret.map { abs($0.minY - (510 - CTFontGetDescent(font))) < 0.01 } == true)
        // Text that would run past the right edge: the host scrolls, the anchor no longer holds.
        #expect(anchor.caret(after: String(repeating: "w", count: 80), fieldFrame: frame, font: font) == nil)
        #expect(anchor.caret(after: "a\nb", fieldFrame: frame, font: font) == nil)
        // A host whose real field lies right of its reported frame: the limit comes from the capture.
        let shifted = TypedTextAnchor(startOffset: 330, baselineOffset: -4, pointSize: 14, rightLimitMargin: 400)
        #expect(shifted.caret(after: String(repeating: "w", count: 40), fieldFrame: frame, font: font) != nil)
        #expect(shifted.caret(after: String(repeating: "w", count: 80), fieldFrame: frame, font: font) == nil)
    }

    /// One anchor serves the field at any width (Chrome's address bar as the window is resized):
    /// the start follows the left edge and the limit follows the right edge.
    @Test func anchorFitsTheFieldAtAnyWidth() {
        let anchor = TypedTextAnchor(startOffset: 0.5, baselineOffset: 7, pointSize: 14, rightLimitMargin: -2)
        let font = system(14)
        let text = String(repeating: "w", count: 30)
        let width = CGFloat(TemplateMatch.lineWidth(text, font: font))
        let narrow = CGRect(x: 400, y: 1375, width: width - 10, height: 24)
        let wide = CGRect(x: 50, y: 1375, width: width + 100, height: 24)
        #expect(anchor.caret(after: text, fieldFrame: narrow, font: font) == nil)
        let caret = anchor.caret(after: text, fieldFrame: wide, font: font)
        #expect(caret.map { abs($0.minX - (50.5 + width)) < 0.01 } == true)
    }

    @Test func speed() {
        let text = "how to make sourdough bread at home"
        let gray = field([text])
        let t0 = Date()
        _ = locate(gray, text)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("locate 1200x56: \(Int(ms)) ms")
        #expect(ms < 10000)   // debug build; release is ~18 ms
    }
}
