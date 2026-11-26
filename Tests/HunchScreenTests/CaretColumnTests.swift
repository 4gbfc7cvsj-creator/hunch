import CoreGraphics
import Testing
@testable import HunchScreen

@Suite struct CaretColumnTests {
    private let window = CGRect(x: 404, y: 30, width: 1104, height: 1244)

    @Test func anEmptyFieldGetsAColumnFromTheCaretToTheWindowEdge() {
        let caret = CGRect(x: 812, y: 1238, width: 2, height: 18)
        let column = CaptureGeometry.caretColumn(caret: caret, window: window, lineBefore: "")
        #expect(column == CGRect(x: 772, y: 1238, width: 1508 - 772, height: 18))
        // A new line after text counts as the line's start too.
        #expect(CaptureGeometry.caretColumn(caret: caret, window: window, lineBefore: "hi there\n") != nil)
    }

    @Test func midLineOrOutsideTheWindowGetsNone() {
        let caret = CGRect(x: 900, y: 1238, width: 2, height: 18)
        #expect(CaptureGeometry.caretColumn(caret: caret, window: window, lineBefore: "sounds good") == nil)
        #expect(CaptureGeometry.caretColumn(caret: CGRect(x: 2000, y: 10, width: 2, height: 18), window: window,
                                            lineBefore: "") == nil)
    }

    /// Messages with its conversation list on the left (rects from a real capture, in points): read
    /// with no field frame, the list's previews were interleaved and merged with the chat and nothing
    /// was labeled. With the caret's column, the list goes and both sides are labeled.
    @Test func theConversationListIsCutOutWithoutAFieldFrame() {
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> OCRLine {
            OCRLine(text: text, confidence: 0.9, rect: CGRect(x: x, y: y, width: w, height: 13))
        }
        let lines = [
            line("Scott Lime", 477, 235, 72), line("10:08 PM", 679, 235, 57),
            line("Scott loved \"yeah so don't worry about", 477, 253, 223),
            line("hi yes we're hiring for the semester again. what's your availability like?", 1049, 183, 428),
            line("im still finalizing my class schedule & will be moving in next week, so ill", 785, 245, 430),
            line("Buff CAKIE", 477, 395, 75), line("i'm back home lmk when you're here", 482, 414, 207),
            line("i think we do but it depends one what time you're available. for now in", 1042, 1064, 435),
            line("Maya", 477, 1118, 36), line("i'm looking for someone to take my tuesday", 482, 1137, 243),
            line("Ah okie i see! Let me get back to you on this but thank you for", 785, 1190, 400),
        ]
        let caret = CGRect(x: 812, y: 1238, width: 2, height: 18)
        let column = CaptureGeometry.caretColumn(caret: caret, window: window, lineBefore: "")
        let out = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 813, y: 1247), field: column,
                                             maxCharacters: 4000, chatSides: true)
        let text = out?.text ?? ""
        #expect(!text.contains("Scott"))
        #expect(!text.contains("Maya"))
        #expect(!text.contains("back home"))
        #expect(text.contains("Me: hi yes we're hiring"))
        #expect(text.contains("Them: Ah okie i see!"))
        #expect(out?.outsideColumn == 7)
    }
}
