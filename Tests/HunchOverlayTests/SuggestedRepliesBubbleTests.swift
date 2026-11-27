import AppKit
import Testing
@testable import HunchOverlay
import HunchCore

@Suite struct SuggestedRepliesBubbleTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 300, height: 90)

    @Test func placementChangedFollowsTheBoxAndCaret() {
        let caret = CGRect(x: 200, y: 100, width: 1, height: 18)
        let box = CGRect(x: 100, y: 80, width: 600, height: 50)
        let a = CaretGeometry(caretRect: caret, fieldFrame: box, quality: .derived)
        #expect(!SuggestedRepliesBubble.placementChanged(a, a))
        let jitter = CaretGeometry(caretRect: caret, fieldFrame: box.offsetBy(dx: 0.3, dy: 0), quality: .derived)
        #expect(!SuggestedRepliesBubble.placementChanged(a, jitter))
        let settled = CaretGeometry(caretRect: caret, fieldFrame: box.offsetBy(dx: 0, dy: -30), quality: .derived)
        #expect(SuggestedRepliesBubble.placementChanged(a, settled))
        let noBox = CaretGeometry(caretRect: caret, fieldFrame: nil, quality: .derived)
        #expect(SuggestedRepliesBubble.placementChanged(a, noBox))
    }

    @Test func sitsAboveTheCaret() {
        let caret = CGRect(x: 200, y: 100, width: 1, height: 18)
        let f = SuggestedRepliesBubble.placement(size: size, caret: caret, visible: screen)
        #expect(f.minY == caret.maxY + SuggestedRepliesBubble.gap)
        #expect(f.minX == caret.minX - 6)
    }

    @Test func goesBelowWhenThereIsNoRoomAbove() {
        let caret = CGRect(x: 200, y: 860, width: 1, height: 18)
        let f = SuggestedRepliesBubble.placement(size: size, caret: caret, visible: screen)
        #expect(f.maxY == caret.minY - SuggestedRepliesBubble.gap)
    }

    @Test func staysOnScreenAtTheRightEdge() {
        let caret = CGRect(x: 1430, y: 100, width: 1, height: 18)
        let f = SuggestedRepliesBubble.placement(size: size, caret: caret, visible: screen)
        #expect(f.maxX <= screen.maxX)
    }

    @MainActor @Test func showsAndHighlights() {
        let bubble = SuggestedRepliesBubble()
        bubble.show(["Yes, Thursday works.", "No, I'm away."], highlighted: nil,
                    caret: CGRect(x: 200, y: 200, width: 1, height: 18))
        #expect(bubble.isVisible)
        bubble.setHighlight(1)
        bubble.hide()
        #expect(!bubble.isVisible)
    }

    // MARK: Chip layouts

    @Test func flowWrapsAtTheRightLimitAndStartsNewLinesAtLineStart() {
        let p = SuggestedRepliesBubble.flow(widths: [100, 100, 100], firstStart: 50, lineStart: 10, maxX: 300, spacing: 6)
        #expect(p.map(\.line) == [0, 0, 1])
        #expect(p[0].x == 50 && p[1].x == 156)
        #expect(p[2].x == 10)
    }

    @Test func flowNarrowsAChipWiderThanItsLine() {
        let p = SuggestedRepliesBubble.flow(widths: [500], firstStart: 10, lineStart: 10, maxX: 300, spacing: 6)
        #expect(p[0].line == 0 && p[0].width == 290)
    }

    @Test func rowSitsAboveAMessageBox() {
        let field = CGRect(x: 400, y: 100, width: 500, height: 36)
        let caret = CGRect(x: 410, y: 108, width: 1, height: 18)
        let f = SuggestedRepliesBubble.chipFrames(widths: [120, 120, 120], height: 26, caret: caret, field: field,
                                                  layout: .rowAboveField, visible: screen)
        #expect(f.allSatisfy { $0.minY == field.maxY + SuggestedRepliesBubble.gap })
        #expect(f[0].minX == field.minX)
        #expect(f[1].minX > f[0].maxX && f[2].minX > f[1].maxX)
    }

    @Test func rowUsesTheCaretInATallDocument() {
        let field = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let caret = CGRect(x: 300, y: 400, width: 1, height: 18)
        let f = SuggestedRepliesBubble.chipFrames(widths: [120], height: 26, caret: caret, field: field,
                                                  layout: .rowAboveField, visible: screen)
        #expect(f[0].minY == caret.maxY + SuggestedRepliesBubble.gap)
    }

    @Test func inlineStartsAtTheCaretAndWrapsBelowIt() {
        let field = CGRect(x: 400, y: 100, width: 400, height: 60)
        let caret = CGRect(x: 410, y: 130, width: 1, height: 18)
        let f = SuggestedRepliesBubble.chipFrames(widths: [150, 150, 150], height: 22, caret: caret, field: field,
                                                  layout: .inlineAtCaret, visible: screen)
        #expect(f[0].minX == caret.maxX + 4)
        #expect(abs(f[0].midY - caret.midY) < 0.01)
        #expect(f[2].minX == caret.minX && f[2].maxY < f[0].minY)
    }

    @MainActor @Test func showsChipLayoutsAndHighlights() {
        let bubble = SuggestedRepliesBubble()
        let geometry = CaretGeometry(caretRect: CGRect(x: 200, y: 200, width: 1, height: 18), quality: .exact)
        for layout in [SuggestedRepliesLayout.rowAboveField, .inlineAtCaret] {
            bubble.show(["Yes, Thursday works.", "No, I'm away that whole week, sorry about that!"], highlighted: nil,
                        geometry: geometry, layout: layout)
            #expect(bubble.isVisible)
            bubble.setHighlight(1)
            bubble.hide()
            #expect(!bubble.isVisible)
        }
    }

    @Test func arrangementFollowsTheLines() {
        let a = CGRect(x: 0, y: 0, width: 50, height: 20), b = CGRect(x: 60, y: 0, width: 50, height: 20)
        let c = CGRect(x: 0, y: -26, width: 50, height: 20)
        #expect(SuggestedRepliesBubble.arrangement(of: [a, b]) == (false, true))
        #expect(SuggestedRepliesBubble.arrangement(of: [a, c]) == (true, false))
        #expect(SuggestedRepliesBubble.arrangement(of: [a, b, c]) == (true, true))
    }
}

// Discord reports only its text color: light text means a dark box, so the chips' fill goes dark.
@MainActor @Test func chipFillFollowsTheTextWhenTheBackgroundIsUnknown() {
    #expect(SuggestedRepliesBubble.backdropShade(forText: RGBAColor(red: 0.86, green: 0.87, blue: 0.88)) == .dark)
    #expect(SuggestedRepliesBubble.backdropShade(forText: RGBAColor(red: 0.1, green: 0.1, blue: 0.1)) == .light)
    #expect(SuggestedRepliesBubble.backdropShade(forText: RGBAColor(red: 0.5, green: 0.5, blue: 0.5)) == nil)
}

// Reply lines pop in exactly as the bubble breaks them.
@MainActor @Test func popInLinesMatchHowTheReplyIsDrawn() {
    let font = NSFont.systemFont(ofSize: 13)
    let text = "Done testing, looks good"
    let exact = ceil((text as NSString).size(withAttributes: [.font: font]).width)
    // A chip sized to its text plays it as one line: no word left over to show up late.
    #expect(SuggestedRepliesBubble.drawnLines(text, font: font, width: exact, maxLines: 1) == [text])
    // A cut chip plays the words that show before the ellipsis.
    let cut = SuggestedRepliesBubble.drawnLines(text, font: font, width: exact * 0.6, maxLines: 1)
    #expect(cut.count == 1 && text.hasPrefix(cut[0]) && cut[0].count < text.count)
    // A wrapping row plays its lines as drawn.
    let rows = SuggestedRepliesBubble.drawnLines(text, font: font, width: exact * 0.6, maxLines: 3)
    #expect(rows.count == 2 && rows.joined(separator: " ") == text)
}
