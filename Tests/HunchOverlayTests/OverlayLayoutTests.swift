import XCTest
import HunchCore
@testable import HunchOverlay

final class OverlayLayoutTests: XCTestCase {
    let vis = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func geo(_ q: GeometryQuality) -> CaretGeometry { CaretGeometry(caretRect: .zero, quality: q) }

    func testChooserForced() {
        let c = DefaultGhostModeChooser()
        XCTAssertEqual(c.mode(for: geo(.none), caretAtLineEnd: false, preference: .inline), .inline)
        XCTAssertEqual(c.mode(for: geo(.exact), caretAtLineEnd: true, preference: .card), .card)
    }
    func testChooserAutomatic() {
        let c = DefaultGhostModeChooser()
        XCTAssertEqual(c.mode(for: geo(.derived), caretAtLineEnd: true, preference: .automatic), .inline)
        XCTAssertEqual(c.mode(for: geo(.exact), caretAtLineEnd: true, preference: .automatic), .inline)
        XCTAssertEqual(c.mode(for: geo(.estimated), caretAtLineEnd: true, preference: .automatic), .card)
        XCTAssertEqual(c.mode(for: geo(.exact), caretAtLineEnd: false, preference: .automatic), .card)
    }
    func testFontSizeFromCaret() {
        XCTAssertEqual(OverlayLayout.fontSize(hint: nil, caretHeight: 20), 15.6, accuracy: 0.001)
    }
    func testFontSizeHintWins() { XCTAssertEqual(OverlayLayout.fontSize(hint: 14, caretHeight: 40), 14) }
    func testFontSizeClamps() {
        XCTAssertEqual(OverlayLayout.fontSize(hint: nil, caretHeight: 5), 9)
        XCTAssertEqual(OverlayLayout.fontSize(hint: 100, caretHeight: 5), 40)
        XCTAssertEqual(OverlayLayout.fontSize(hint: 0, caretHeight: 0), 9)
    }
    func testBaselineMath() {
        let caret = CGRect(x: 10, y: 100, width: 1, height: 18)
        let b = OverlayLayout.baselineY(caretRect: caret, descender: -3)
        XCTAssertEqual(b, 103)
        XCTAssertEqual(OverlayLayout.panelOriginY(baseline: b, fontDescent: 3), 100)
    }
    func testBaselineSplitsExtraLeading() {
        // 22 pt web line box around a 16 pt font (ascender 15 + descender 4 = 19): 1.5 pt each side.
        let caret = CGRect(x: 0, y: 100, width: 1, height: 22)
        XCTAssertEqual(OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15), 105.5)
        // A box no taller than the font adds nothing.
        let tight = CGRect(x: 0, y: 100, width: 1, height: 18)
        XCTAssertEqual(OverlayLayout.baselineY(caretRect: tight, descender: -4, ascender: 15), 104)
    }
    func testInlineX() { XCTAssertEqual(OverlayLayout.inlineX(caretRect: CGRect(x: 10, y: 0, width: 2, height: 10)), 12.5) }
    func testAvailableWidth() {
        XCTAssertEqual(OverlayLayout.availableWidth(fromX: 900, visibleFrame: vis), 100)
        XCTAssertEqual(OverlayLayout.availableWidth(fromX: 1200, visibleFrame: vis), 0)
    }
    func testAvailableWidthStopsAtField() {
        let field = CGRect(x: 100, y: 0, width: 500, height: 40)
        let caret = CGRect(x: 400, y: 10, width: 1, height: 18)
        XCTAssertEqual(OverlayLayout.availableWidth(fromX: 401, visibleFrame: vis, fieldFrame: field, caretRect: caret), 199)
        // Screen edge still wins when nearer.
        let wide = CGRect(x: 100, y: 0, width: 2000, height: 40)
        XCTAssertEqual(OverlayLayout.availableWidth(fromX: 401, visibleFrame: vis, fieldFrame: wide, caretRect: caret), 599)
        // Caret outside the reported field (bad frame): the field is ignored.
        let off = CGRect(x: 700, y: 10, width: 1, height: 18)
        XCTAssertEqual(OverlayLayout.availableWidth(fromX: 701, visibleFrame: vis, fieldFrame: field, caretRect: off), 299)
        XCTAssertEqual(OverlayLayout.availableWidth(fromX: 401, visibleFrame: vis, fieldFrame: nil, caretRect: caret), 599)
    }
    func testFitWholeWords() {
        let m: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        XCTAssertEqual(OverlayLayout.fitWholeWords(" it just cuts off", maxWidth: 100, measure: m), " it just")
        XCTAssertEqual(OverlayLayout.fitWholeWords(" it just cuts off", maxWidth: 1000, measure: m), " it just cuts off")
        // Cut right at a space keeps the words before it.
        XCTAssertEqual(OverlayLayout.fitWholeWords("ab cd ef", maxWidth: 50, measure: m), "ab cd")
        // No break in the part that fits: by character.
        XCTAssertEqual(OverlayLayout.fitWholeWords("ffff, which", maxWidth: 30, measure: m), "fff")
        XCTAssertEqual(OverlayLayout.fitWholeWords(" itsuggestion", maxWidth: 40, measure: m), " its")
        XCTAssertEqual(OverlayLayout.fitWholeWords("我們明天見面吧", maxWidth: 30, measure: m), "我們明")
        XCTAssertEqual(OverlayLayout.fitWholeWords("hi there", maxWidth: 0, measure: m), "")
    }
    func testCardBelow() {
        let f = OverlayLayout.cardFrame(caretRect: CGRect(x: 100, y: 300, width: 1, height: 18), size: CGSize(width: 200, height: 24), visible: vis)
        XCTAssertEqual(f.minY, 300 - 8 - 24)
        XCTAssertEqual(f.minX, 100)
    }
    func testCardFlipsAbove() {
        let f = OverlayLayout.cardFrame(caretRect: CGRect(x: 100, y: 20, width: 1, height: 18), size: CGSize(width: 200, height: 24), visible: vis)
        XCTAssertEqual(f.minY, 20 + 18 + 8)
    }
    func testCardClampsRight() {
        let f = OverlayLayout.cardFrame(caretRect: CGRect(x: 950, y: 300, width: 1, height: 18), size: CGSize(width: 200, height: 24), visible: vis)
        XCTAssertEqual(f.maxX, 1000)
    }
    func testClampShrinksOversized() {
        let r = OverlayLayout.clamp(CGRect(x: -50, y: -50, width: 2000, height: 10), into: vis)
        XCTAssertEqual(r.width, 1000)
        XCTAssertEqual(r.minX, 0)
        XCTAssertEqual(r.minY, 0)
    }
    func testScreenIndex() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        XCTAssertEqual(OverlayLayout.screenIndex(for: CGRect(x: 150, y: 10, width: 1, height: 10), frames: frames), 1)
        XCTAssertNil(OverlayLayout.screenIndex(for: CGRect(x: 500, y: 500, width: 1, height: 10), frames: frames))
    }
    func testTruncate() {
        let m: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        XCTAssertEqual(OverlayLayout.truncate("hello world", maxWidth: 55, measure: m), "hello")
        XCTAssertEqual(OverlayLayout.truncate("hi", maxWidth: 100, measure: m), "hi")
        XCTAssertEqual(OverlayLayout.truncate("hi", maxWidth: 0, measure: m), "")
        XCTAssertEqual(OverlayLayout.truncate("hi", maxWidth: 5, measure: m), "")
    }
}

final class SizeMatchingTests: XCTestCase {
    func testMatchesMeasuredXHeightWithinRange() {
        XCTAssertEqual(OverlayLayout.sizeMatching(xHeight: 8, fontXHeightPerPoint: 0.5, current: 14), 16)
        XCTAssertNil(OverlayLayout.sizeMatching(xHeight: 16, fontXHeightPerPoint: 0.5, current: 14))
        // Claude desktop reports 14 pt; a strip that caught an icon measured as if 18.24 pt.
        XCTAssertFalse(OverlayLayout.agreesWithReportedSize(18.24, reported: 14))
        XCTAssertTrue(OverlayLayout.agreesWithReportedSize(14.4, reported: 14))
        XCTAssertTrue(OverlayLayout.agreesWithReportedSize(30, reported: nil))
        XCTAssertNil(OverlayLayout.sizeMatching(xHeight: 8, fontXHeightPerPoint: 0, current: 14))
    }
}


final class GhostTweaksLayoutTests: XCTestCase {
    let caret = CGRect(x: 10, y: 100, width: 1, height: 22)

    func testFactorScalesSize() {
        XCTAssertEqual(OverlayLayout.adjustedFontSize(15, factor: 1.2), 18, accuracy: 0.0001)
        XCTAssertEqual(OverlayLayout.fontSize(hint: 14, caretHeight: 0, adjustment: 1.2), 16.8, accuracy: 0.0001)
        XCTAssertEqual(OverlayLayout.fontSize(hint: 20, caretHeight: 0, adjustment: 0.7), 14, accuracy: 0.0001)
    }
    func testFactorKeepsClamp() {
        XCTAssertEqual(OverlayLayout.fontSize(hint: 38, caretHeight: 0, adjustment: 1.5), 40)
        XCTAssertEqual(OverlayLayout.fontSize(hint: 10, caretHeight: 0, adjustment: 0.5), 9)
        XCTAssertEqual(OverlayLayout.adjustedFontSize(30, factor: 2), 40)
    }
    func testIdentityFactorLeavesSizeUntouched() {
        // Width-scaled sizes may sit outside 9...40 today; factor 1 must not clamp them.
        XCTAssertEqual(OverlayLayout.adjustedFontSize(8.1, factor: 1), 8.1)
        XCTAssertEqual(OverlayLayout.adjustedFontSize(44, factor: 1), 44)
        XCTAssertEqual(OverlayLayout.fontSize(hint: 14, caretHeight: 40, adjustment: 1),
                       OverlayLayout.fontSize(hint: 14, caretHeight: 40))
    }
    func testOffsetSign() {
        let base = OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15)
        XCTAssertEqual(OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15, offset: 2), base + 2)
        XCTAssertEqual(OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15, offset: -2), base - 2)
    }
    func testOffsetComposesWithCalibration() {
        let measured = OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: 5, descender: -4, ascender: 15)
        XCTAssertEqual(measured, 105)
        XCTAssertEqual(OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: 5, descender: -4,
                                                     ascender: 15, offset: 2), 107)
        XCTAssertEqual(OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: 5, descender: -4,
                                                     ascender: 15, offset: -2), 103)
        XCTAssertEqual(OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: nil, descender: -4,
                                                     ascender: 15, offset: 1.5), 107)
    }
    func testDefaultTweaksAreIdentity() {
        let t = GhostTweaks()
        XCTAssertEqual(t, GhostTweaks(AppPolicy.default))
        XCTAssertEqual(OverlayLayout.adjustedFontSize(13.37, factor: t.fontSizeFactor), 13.37)
        XCTAssertEqual(OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: nil, descender: -4,
                                                     ascender: 15, offset: t.verticalOffset),
                       OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15))
        XCTAssertEqual(OverlayLayout.inlineBaselineY(caretRect: caret, measuredBaseline: 3.25, descender: -4,
                                                     ascender: 15, offset: t.verticalOffset), caret.minY + 3.25)
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(OverlayLayout.ghostColorSource(textColor: red, greyForced: t.greyForced), red)
        XCTAssertEqual(GhostPresentation(text: "x", geometry: CaretGeometry(caretRect: caret, quality: .exact),
                                         mode: .inline).tweaks, t)
    }
    func testGreyForcedIgnoresTextColor() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertNil(OverlayLayout.ghostColorSource(textColor: red, greyForced: true))
        XCTAssertNil(OverlayLayout.ghostColorSource(textColor: nil, greyForced: false))
    }
    func testTweaksFromPolicyClampFactor() {
        XCTAssertEqual(GhostTweaks(AppPolicy(fontSizeAdjustmentFactor: 3)).fontSizeFactor, 2)
        XCTAssertEqual(GhostTweaks(AppPolicy(fontSizeAdjustmentFactor: 0.1)).fontSizeFactor, 0.5)
        XCTAssertEqual(GhostTweaks(AppPolicy(fontSizeAdjustmentFactor: .nan)).fontSizeFactor, 1)
        let t = GhostTweaks(AppPolicy(fontSizeAdjustmentFactor: 1.2, verticalAlignmentOffset: -1.5,
                                      greySuggestionColorEnabled: true))
        XCTAssertEqual(t, GhostTweaks(fontSizeFactor: 1.2, verticalOffset: -1.5, greyForced: true))
    }
}
