import ApplicationServices
import CoreGraphics
import Foundation
import HunchCore
import Testing
@testable import HunchFocus

// Mirror mode's line start: the caret line's first character, found in the before-text and asked
// for its bounds through the AX client (faked here), and the background color read with the font.

/// Stands in for the host: answers `AXBoundsForRange` from a table and records what was asked.
private final class FakeBoundsClient: TextBoundsReading {
    var rects: [Int: CGRect]
    private(set) var asked: [(location: Int, length: Int)] = []
    init(_ rects: [Int: CGRect]) { self.rects = rects }
    func bounds(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        asked.append((location, length))
        return rects[location]
    }
}

/// Any element: the fake client ignores it.
private var element: AXUIElement { AXUIElementCreateSystemWide() }
/// AX coordinates (top-left origin): a field at x 90...400, the caret after "hello world" on its line.
private let field = CGRect(x: 90, y: 300, width: 310, height: 60)
private let caret = CGRect(x: 160, y: 320, width: 1, height: 18)

// MARK: Line start offset

@Test func lineStartFollowsTheLastLineBreak() {
    // "first\nhello" with the caret at the end (11): the line starts at 6.
    #expect(CaretMath.lineStartUTF16(before: "first\nhello", caretUTF16: 11, beforeReachesStart: false) == 6)
    // A windowed read: `before` is the tail of a longer text, the caret offset is the field's.
    #expect(CaretMath.lineStartUTF16(before: "st\nhello", caretUTF16: 5006, beforeReachesStart: false) == 5001)
}

@Test func lineStartCountsUTF16Units() {
    // "👍🏽 ok" is 7 UTF-16 units.
    #expect(CaretMath.lineStartUTF16(before: "a\n👍🏽 ok", caretUTF16: 9, beforeReachesStart: true) == 2)
}

@Test func lineStartWithoutBreakNeedsTheFieldStart() {
    #expect(CaretMath.lineStartUTF16(before: "hello", caretUTF16: 5, beforeReachesStart: true) == 0)
    // Truncated before-text with no line break: the line may start earlier.
    #expect(CaretMath.lineStartUTF16(before: "hello", caretUTF16: 9000, beforeReachesStart: false) == nil)
}

@Test func emptyLineHasNoStart() {
    #expect(CaretMath.lineStartUTF16(before: "first\n", caretUTF16: 6, beforeReachesStart: true) == nil)
    #expect(CaretMath.lineStartUTF16(before: "", caretUTF16: 0, beforeReachesStart: true) == nil)
    // Offsets that don't add up (a caret before the text it follows) give nothing.
    #expect(CaretMath.lineStartUTF16(before: "hello", caretUTF16: 3, beforeReachesStart: true) == nil)
}

// MARK: Line start x through the AX client

@Test func lineStartXFromTheFirstCharactersBounds() {
    let client = FakeBoundsClient([6: CGRect(x: 100.5, y: 320, width: 8, height: 18)])
    let x = ContextReader.lineStartX(element, client: client, lineStartUTF16: 6, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field)
    #expect(x == 100.5)
    // Exactly one character at the line start was asked for.
    #expect(client.asked.count == 1)
    #expect(client.asked.first?.location == 6 && client.asked.first?.length == 1)
}

@Test func softWrappedLineHasNoStartX() {
    // The paragraph's first character sits a row above the caret: the line wrapped.
    let client = FakeBoundsClient([6: CGRect(x: 100, y: 302, width: 8, height: 18)])
    #expect(ContextReader.lineStartX(element, client: client, lineStartUTF16: 6, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field) == nil)
}

@Test func scrolledFieldHasNoStartX() {
    // A single-line field scrolled sideways: the line's start is left of the field.
    let client = FakeBoundsClient([0: CGRect(x: 60, y: 320, width: 8, height: 18)])
    #expect(ContextReader.lineStartX(element, client: client, lineStartUTF16: 0, caretUTF16: 30,
                                     caretRect: caret, fieldFrame: field) == nil)
}

@Test func startRightOfTheCaretIsRejected() {
    let client = FakeBoundsClient([6: CGRect(x: 170, y: 320, width: 8, height: 18)])
    #expect(ContextReader.lineStartX(element, client: client, lineStartUTF16: 6, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field) == nil)
}

@Test func missingOrBogusBoundsGiveNoStartX() {
    // The host doesn't answer.
    let silent = FakeBoundsClient([:])
    #expect(ContextReader.lineStartX(element, client: silent, lineStartUTF16: 6, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field) == nil)
    // A zero rect (some hosts' "don't know").
    let zero = FakeBoundsClient([6: .zero])
    #expect(ContextReader.lineStartX(element, client: zero, lineStartUTF16: 6, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field) == nil)
}

@Test func unknownLineStartAsksNothing() {
    let client = FakeBoundsClient([0: CGRect(x: 100, y: 320, width: 8, height: 18)])
    #expect(ContextReader.lineStartX(element, client: client, lineStartUTF16: nil, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field) == nil)
    // A start at (or past) the caret is no character before it.
    #expect(ContextReader.lineStartX(element, client: client, lineStartUTF16: 17, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: field) == nil)
    #expect(client.asked.isEmpty)
}

@Test func lineStartXWithoutFieldFrame() {
    let client = FakeBoundsClient([6: CGRect(x: 40, y: 321, width: 8, height: 16)])
    #expect(ContextReader.lineStartX(element, client: client, lineStartUTF16: 6, caretUTF16: 17,
                                     caretRect: caret, fieldFrame: nil) == 40)
}

// MARK: Background color

private func axColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

private func axString(_ attributes: [String: Any]) -> NSAttributedString {
    NSAttributedString(string: "x", attributes: Dictionary(uniqueKeysWithValues: attributes.map {
        (NSAttributedString.Key($0.key), $0.value)
    }))
}

@Test func backgroundColorIsReadWithTheFont() throws {
    let font: [String: Any] = ["AXFontFamily": "Helvetica Neue", "AXFontName": "HelveticaNeue", "AXFontSize": 13]
    let s = axString(["AXFont": font, "AXForegroundColor": axColor(0.1, 0.1, 0.1),
                      "AXBackgroundColor": axColor(1, 0.98, 0.9)])
    let hint = try #require(ContextReader.fontHint(from: s))
    #expect(hint.name == "HelveticaNeue" && hint.pointSize == 13)
    let text = try #require(hint.textColor)
    #expect(abs(text.red - 0.1) < 0.001 && abs(text.blue - 0.1) < 0.001)
    let background = try #require(hint.backgroundColor)
    #expect(abs(background.red - 1) < 0.001 && abs(background.green - 0.98) < 0.001
        && abs(background.blue - 0.9) < 0.001 && background.alpha == 1)
}

@Test func backgroundColorIsOptional() throws {
    let font: [String: Any] = ["AXFontName": "Menlo-Regular", "AXFontSize": 12]
    let hint = try #require(ContextReader.fontHint(from: axString(["AXFont": font, "AXForegroundColor": axColor(0, 0, 0)])))
    #expect(hint.backgroundColor == nil)
    #expect(hint.textColor != nil)
}

@Test func backgroundColorInOtherColorSpacesIsConverted() throws {
    let gray = CGColor(gray: 0.2, alpha: 1)
    let color = try #require(ContextReader.rgba(gray))
    #expect(abs(color.red - color.green) < 0.001 && abs(color.green - color.blue) < 0.001)
    // Not a CGColor: ignored.
    #expect(ContextReader.rgba("white") == nil)
}

@Test func noFontAttributeNoHint() {
    #expect(ContextReader.fontHint(from: axString(["AXBackgroundColor": axColor(1, 1, 1)])) == nil)
    #expect(ContextReader.fontHint(from: NSAttributedString(string: "")) == nil)
}

@Test func fontHintParserKeepsTheBackground() {
    let bg = RGBAColor(red: 0.1, green: 0.2, blue: 0.3)
    #expect(FontHintParser.hint(family: nil, name: nil, size: nil, backgroundColor: bg)?.backgroundColor == bg)
    #expect(FontHintParser.hint(family: nil, name: nil, size: nil) == nil)
}
