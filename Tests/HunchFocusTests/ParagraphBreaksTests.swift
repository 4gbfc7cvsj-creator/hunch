import XCTest
@testable import HunchFocus

/// Marker reads in Chromium/Electron hosts drop paragraph breaks; AXValue keeps them. The reads
/// below are what a probe of a contenteditable in Claude desktop returned (2026-11-20).
final class ParagraphBreaksTests: XCTestCase {
    private let value = "Task:\nDo this\n1. First item\n2. Second\nLast para"
    private let mid = ParagraphBreaks.CaretLine(atLineStart: false, emptyLine: false)
    private let start = ParagraphBreaks.CaretLine(atLineStart: true, emptyLine: false)

    func testBreaksPutBackAroundTheCaret() {
        let r = ParagraphBreaks.restore(before: "Task:Do th", selected: "", after: "is1. First item2. SecondLast para",
                                        value: value, caretLine: mid)
        XCTAssertEqual(r?.before, "Task:\nDo th")
        XCTAssertEqual(r?.after, "is\n1. First item\n2. Second\nLast para")
    }

    /// The reported case: "Task:" ⏎ "Do this" read as "Task:Do this".
    func testNewParagraphAfterAColon() {
        let r = ParagraphBreaks.restore(before: "Task:Do this", selected: "", after: "", value: "Task:\nDo this",
                                        caretLine: mid)
        XCTAssertEqual(r?.before, "Task:\nDo this")
        XCTAssertEqual(r?.after, "")
    }

    func testBreakAtTheCaretGoesBySideOfTheLine() {
        // Caret at the start of "Do this": the break is behind it.
        let atStart = ParagraphBreaks.restore(before: "Task:", selected: "", after: "Do this", value: "Task:\nDo this",
                                              caretLine: start)
        XCTAssertEqual(atStart?.before, "Task:\n")
        XCTAssertEqual(atStart?.after, "Do this")
        // Caret at the end of "Task:": the break is ahead of it.
        let atEnd = ParagraphBreaks.restore(before: "Task:", selected: "", after: "Do this", value: "Task:\nDo this",
                                            caretLine: mid)
        XCTAssertEqual(atEnd?.before, "Task:")
        XCTAssertEqual(atEnd?.after, "\nDo this")
        // No line information: ahead of it.
        XCTAssertEqual(ParagraphBreaks.restore(before: "Task:", selected: "", after: "Do this", value: "Task:\nDo this",
                                               caretLine: nil)?.before, "Task:")
    }

    /// Return just pressed: the new paragraph is empty and AXValue leaves it out entirely.
    func testEmptyNewParagraph() {
        let r = ParagraphBreaks.restore(before: "Task:", selected: "", after: "", value: "Task:",
                                        caretLine: .init(atLineStart: true, emptyLine: true))
        XCTAssertEqual(r?.before, "Task:\n")
        // Between two paragraphs, the one break the value has goes behind the caret; no second one added.
        let between = ParagraphBreaks.restore(before: "Task:", selected: "", after: "Do this", value: "Task:\nDo this",
                                              caretLine: .init(atLineStart: true, emptyLine: true))
        XCTAssertEqual(between?.before, "Task:\n")
        XCTAssertEqual(between?.after, "Do this")
    }

    func testListNumbersOnlyInTheValueAreSkipped() {
        // Hosts whose marker text leaves the list numbers out.
        let r = ParagraphBreaks.restore(before: "Tasks:First", selected: "", after: "", value: "Tasks:\n1. First",
                                        caretLine: mid)
        XCTAssertEqual(r?.before, "Tasks:\nFirst")
    }

    func testSelectionKeepsItsBreaks() {
        let r = ParagraphBreaks.restore(before: "Ta", selected: "sk:Do", after: " this", value: "Task:\nDo this",
                                        caretLine: mid)
        XCTAssertEqual(r?.before, "Ta")
        XCTAssertEqual(r?.selected, "sk:\nDo")
        XCTAssertEqual(r?.after, " this")
    }

    func testNothingToDoOrNoMatch() {
        // Already has its breaks (WebKit, native fields).
        XCTAssertNil(ParagraphBreaks.restore(before: "Task:\nDo", selected: "", after: " this", value: "Task:\nDo this",
                                             caretLine: mid))
        // A value that isn't this text: the read is kept.
        XCTAssertNil(ParagraphBreaks.restore(before: "Task:Do", selected: "", after: " this", value: "Something\nelse",
                                             caretLine: mid))
        // Soft-wrapped line start (no break in the value): nothing added.
        XCTAssertNil(ParagraphBreaks.restore(before: "one two ", selected: "", after: "three", value: "one two three",
                                             caretLine: start))
    }

    func testBlankLineBetweenParagraphs() {
        let r = ParagraphBreaks.restore(before: "Done.Task B: ", selected: "", after: "", value: "Done.\n\nTask B: ",
                                        caretLine: mid)
        XCTAssertEqual(r?.before, "Done.\n\nTask B: ")
    }
}
