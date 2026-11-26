import XCTest
import HunchCore
@testable import HunchOverlay

final class MirrorLayoutTests: XCTestCase {
    let vis = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// 10 pt per character, the ellipsis included.
    let m: (String) -> CGFloat = { CGFloat($0.count) * 10 }
    let caret = CGRect(x: 160, y: 200, width: 1, height: 18)

    func testLastLine() {
        XCTAssertEqual(MirrorLayout.lastLine(of: "first line\nsecond line"), "second line")
        XCTAssertEqual(MirrorLayout.lastLine(of: "only line"), "only line")
        XCTAssertEqual(MirrorLayout.lastLine(of: "ends with a break\n"), "")
        XCTAssertEqual(MirrorLayout.lastLine(of: "windows\r\nline"), "line")
        XCTAssertEqual(MirrorLayout.lastLine(of: "para\u{2029}graph"), "graph")
    }

    func testBaselineUsesMeasurementThenFontMetrics() {
        XCTAssertEqual(MirrorLayout.baselineY(caretRect: caret, measuredBaseline: 4.5, descender: -4, ascender: 15), 204.5)
        // Unmeasured: the same baseline as the inline ghost.
        XCTAssertEqual(MirrorLayout.baselineY(caretRect: caret, measuredBaseline: nil, descender: -4, ascender: 15),
                       OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15))
        // A per-app offset moves either one up.
        XCTAssertEqual(MirrorLayout.baselineY(caretRect: caret, measuredBaseline: 4.5, descender: -4, ascender: 15,
                                              offset: 1.5), 206)
        XCTAssertEqual(MirrorLayout.baselineY(caretRect: caret, measuredBaseline: nil, descender: -4, ascender: 15, offset: -1),
                       OverlayLayout.baselineY(caretRect: caret, descender: -4, ascender: 15) - 1)
    }

    func testLineHeight() {
        XCTAssertEqual(MirrorLayout.lineHeight(ascender: 15, descender: -4, leading: 0), 19)
        XCTAssertEqual(MirrorLayout.lineHeight(ascender: 15, descender: -4, leading: 2), 21)
        XCTAssertEqual(MirrorLayout.lineHeight(ascender: 15, descender: 4, leading: -1), 19)
    }

    func testFrameCoversLineToFieldEdge() {
        let field = CGRect(x: 90, y: 190, width: 310, height: 40)
        let f = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                   fieldFrame: field, caretRect: caret, typedWidth: 60, ghostWidth: 80, visible: vis)
        XCTAssertEqual(f, CGRect(x: 99, y: 200, width: 301, height: 19))
        // Leading is split above and below the glyphs.
        let led = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 2,
                                     fieldFrame: field, caretRect: caret, typedWidth: 60, ghostWidth: 80, visible: vis)
        XCTAssertEqual(led.minY, 199)
        XCTAssertEqual(led.height, 21)
    }

    func testFrameNeverStartsLeftOfTheField() {
        let field = CGRect(x: 100, y: 190, width: 300, height: 40)
        let f = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                   fieldFrame: field, caretRect: caret, typedWidth: 60, ghostWidth: 80, visible: vis)
        XCTAssertEqual(f.minX, 100)
        XCTAssertEqual(f.maxX, 400)
    }

    func testFrameWithoutFieldEndsAfterTypedTextAndGhost() {
        // The host's caret (161) is past our typed text's end (100 + 50): the longer one counts.
        let f = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                   fieldFrame: nil, caretRect: caret, typedWidth: 50, ghostWidth: 80, visible: vis)
        XCTAssertEqual(f.minX, 99)
        XCTAssertEqual(f.maxX, 161 + 80 + MirrorLayout.caretRoom)
        // Our typed text running past the host's caret.
        let wide = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                      fieldFrame: nil, caretRect: caret, typedWidth: 70, ghostWidth: 80, visible: vis)
        XCTAssertEqual(wide.maxX, 170 + 80 + MirrorLayout.caretRoom)
    }

    func testFrameStaysOnScreenAndCoversTheCaret() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 800)
        let f = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                   fieldFrame: nil, caretRect: caret, typedWidth: 60, ghostWidth: 500, visible: narrow)
        XCTAssertEqual(f.maxX, 200)
        // A field frame that ends before the caret is wrong: the typed text is still covered.
        let short = CGRect(x: 90, y: 190, width: 60, height: 40)
        let g = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                   fieldFrame: short, caretRect: caret, typedWidth: 60, ghostWidth: 80, visible: vis)
        XCTAssertEqual(g.maxX, 161 + MirrorLayout.caretRoom)
        // Our typed text running wider than the host's doesn't push past the field's edge.
        let wider = MirrorLayout.frame(lineStartX: 100, baseline: 204, ascender: 15, descender: -4, leading: 0,
                                       fieldFrame: CGRect(x: 90, y: 190, width: 110, height: 40), caretRect: caret,
                                       typedWidth: 300, ghostWidth: 80, visible: vis)
        XCTAssertEqual(wider.maxX, 200)
    }

    func testSnappedOutward() {
        let r = MirrorLayout.snappedOutward(CGRect(x: 10.3, y: 20.7, width: 5.2, height: 3.1))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 6, height: 4))
        let whole = CGRect(x: 10, y: 20, width: 5, height: 3)
        XCTAssertEqual(MirrorLayout.snappedOutward(whole), whole)
    }

    func testFitKeepsEverythingThatFits() {
        XCTAssertEqual(MirrorLayout.fit(typed: "hello", ghost: " world", maxWidth: 200, measure: m),
                       MirrorLayout.Line(truncatedHead: false, typed: "hello", ghost: " world"))
        XCTAssertEqual(MirrorLayout.fit(typed: "hello", ghost: " world", maxWidth: 110, measure: m),
                       MirrorLayout.Line(truncatedHead: false, typed: "hello", ghost: " world"))
    }

    func testFitCutsALongGhostAtTheRightWhileTheTypedTextIsShort() {
        let line = MirrorLayout.fit(typed: "hi", ghost: String(repeating: "g", count: 30), maxWidth: 100, measure: m)
        XCTAssertFalse(line.truncatedHead)
        XCTAssertEqual(line.typed, "hi")
        XCTAssertEqual(line.ghost, String(repeating: "g", count: 8))
    }

    func testFitDropsTheTypedHeadFromTheLeft() {
        let typed = "abcdefghijklmnopqrst"  // 200
        let line = MirrorLayout.fit(typed: typed, ghost: " end", maxWidth: 150, measure: m)
        // The tail right before the caret and the whole ghost stay; "…" + 10 characters = 110.
        XCTAssertTrue(line.truncatedHead)
        XCTAssertEqual(line.typed, "klmnopqrst")
        XCTAssertEqual(line.ghost, " end")
    }

    func testFitKeepsAMinimumTailWhenBothAreLong() {
        let typed = "abcdefghijklmnopqrst"  // 200
        let ghost = String(repeating: "g", count: 30)  // 300
        let line = MirrorLayout.fit(typed: typed, ghost: ghost, maxWidth: 100, measure: m)
        // Half the line for "…" + tail, the rest for the ghost's start.
        XCTAssertTrue(line.truncatedHead)
        XCTAssertEqual(line.typed, "qrst")
        XCTAssertEqual(line.ghost, "ggggg")
    }

    func testFitWithNoRoom() {
        XCTAssertEqual(MirrorLayout.fit(typed: "abc", ghost: "def", maxWidth: 0, measure: m),
                       MirrorLayout.Line(truncatedHead: true, typed: "", ghost: ""))
        XCTAssertEqual(MirrorLayout.fit(typed: "", ghost: "def", maxWidth: 20, measure: m),
                       MirrorLayout.Line(truncatedHead: false, typed: "", ghost: "de"))
    }

    func testTail() {
        XCTAssertEqual(MirrorLayout.tail(of: "abcdef", maxWidth: 40, measure: m), "def")
        XCTAssertEqual(MirrorLayout.tail(of: "abcdef", maxWidth: 10, measure: m), "")
        XCTAssertEqual(MirrorLayout.tail(of: "abcdef", maxWidth: 5, measure: m), "")
        XCTAssertEqual(MirrorLayout.tail(of: "ab", maxWidth: 100, measure: m), "ab")
    }
}

/// Mirror mode is strictly opt-in: only a `.mirror` preference with every precondition met gets it,
/// and each failed precondition gets the card, never the inline ghost.
final class MirrorChooserTests: XCTestCase {
    let c = DefaultGhostModeChooser()

    func geo(_ q: GeometryQuality = .exact, lineStartX: CGFloat? = 40) -> CaretGeometry {
        CaretGeometry(caretRect: CGRect(x: 100, y: 100, width: 1, height: 18), quality: q, lineStartX: lineStartX)
    }

    func mirror(_ g: CaretGeometry, lineEnd: Bool = true, selection: Bool = false, marked: Bool = false) -> GhostMode {
        c.mode(for: g, caretAtLineEnd: lineEnd, preference: .mirror, hasSelection: selection, hasMarkedText: marked)
    }

    func testAllPreconditionsMet() { XCTAssertEqual(mirror(geo()), .mirror) }
    func testNotExactGeometryFallsBackToCard() {
        for q in [GeometryQuality.none, .estimated, .derived] { XCTAssertEqual(mirror(geo(q)), .card) }
    }
    func testCaretNotAtLineEndFallsBackToCard() { XCTAssertEqual(mirror(geo(), lineEnd: false), .card) }
    func testSelectionFallsBackToCard() { XCTAssertEqual(mirror(geo(), selection: true), .card) }
    func testMarkedTextFallsBackToCard() { XCTAssertEqual(mirror(geo(), marked: true), .card) }
    func testUnknownLineStartFallsBackToCard() { XCTAssertEqual(mirror(geo(lineStartX: nil)), .card) }

    func testWithoutSelectionStateMirrorIsCard() {
        // The older entry point can't tell whether text is selected or marked.
        XCTAssertEqual(c.mode(for: geo(), caretAtLineEnd: true, preference: .mirror), .card)
    }

    func testOtherPreferencesNeverMirror() {
        for pref in [OverlayPreference.automatic, .inline, .card] {
            for q in [GeometryQuality.none, .estimated, .derived, .exact] {
                for lineEnd in [true, false] {
                    for flags in [(false, false), (true, false), (false, true)] {
                        let mode = c.mode(for: geo(q), caretAtLineEnd: lineEnd, preference: pref,
                                          hasSelection: flags.0, hasMarkedText: flags.1)
                        XCTAssertNotEqual(mode, .mirror, "\(pref) \(q) lineEnd=\(lineEnd)")
                        XCTAssertNotEqual(c.mode(for: geo(q), caretAtLineEnd: lineEnd, preference: pref), .mirror)
                    }
                }
            }
        }
    }

    func testOtherPreferencesUnchangedByTheNewState() {
        // Selection and marked text only matter to the mirror.
        XCTAssertEqual(c.mode(for: geo(.derived), caretAtLineEnd: true, preference: .automatic,
                              hasSelection: true, hasMarkedText: true), .inline)
        XCTAssertEqual(c.mode(for: geo(.none), caretAtLineEnd: false, preference: .inline,
                              hasSelection: true, hasMarkedText: false), .inline)
    }
}
