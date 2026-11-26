import Testing
@testable import HunchFocus

@Test func caretSelectionRangeSpansBothSides() {
    let r = CaretSelection.range(caret: 10, backward: 4, forward: 3)
    #expect(r?.location == 6)
    #expect(r?.length == 7)
}

@Test func caretSelectionRangeRejectsStartBeforeField() {
    #expect(CaretSelection.range(caret: 2, backward: 3, forward: 0) == nil)
    #expect(CaretSelection.range(caret: -1, backward: 0, forward: 0) == nil)
}

@Test func caretSelectionCountsUTF16ForEmojiAndChinese() {
    // The controller passes UTF-16 lengths: an emoji is two units, a CJK character one.
    let text = "好的👍"
    #expect(text.utf16.count == 4)
    #expect(CaretSelection.range(caret: 4, backward: text.utf16.count, forward: 0)?.location == 0)
}

@Test func caretSelectionMatchesAcrossLineEndsAndNBSP() {
    #expect(CaretSelection.matches("a\r\nb\u{00A0}c", expected: "a\nb c"))
    #expect(CaretSelection.matches("第一段\r第二段", expected: "第一段\n第二段"))
    #expect(!CaretSelection.matches("hello", expected: "hello "))
    #expect(!CaretSelection.matches("hell", expected: "hello"))
}
