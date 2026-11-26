import CoreGraphics
import HunchCore
import Testing

@Suite struct EmptyFieldStartTests {
    let field = CGRect(x: 100, y: 500, width: 600, height: 60)

    @Test func learnsTheStartAndPlacesTheEmptyCaretThere() throws {
        // Caret 50 points into the first line; text starts 16 in, 12 below the top.
        let caret = CGRect(x: 166, y: 528, width: 1, height: 20)
        let start = try #require(EmptyFieldStart.learn(caret: caret, field: field, lineWidth: 50))
        #expect(start == EmptyFieldStart(left: 16, top: 12, caretHeight: 20))
        #expect(start.caret(in: CGRect(x: 0, y: 0, width: 400, height: 44)) == CGRect(x: 16, y: 12, width: 1, height: 20))
    }

    @Test func wrappedTextIsNotLearned() {
        // The typed line is wider than the caret is from the field's edge: it wrapped.
        let caret = CGRect(x: 160, y: 508, width: 1, height: 20)
        #expect(EmptyFieldStart.learn(caret: caret, field: field, lineWidth: 300) == nil)
    }

    @Test func aStartJustOutsideTheEdgeIsTheEdge() {
        let caret = CGRect(x: 148, y: 538, width: 1, height: 20)
        #expect(EmptyFieldStart.learn(caret: caret, field: field, lineWidth: 50)?.left == 0)
    }

    @Test func caretOutsideTheFieldIsNotLearned() {
        let caret = CGRect(x: 166, y: 600, width: 1, height: 20)
        #expect(EmptyFieldStart.learn(caret: caret, field: field, lineWidth: 50) == nil)
    }
}
