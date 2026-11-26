import HunchCore
import Testing
@testable import HunchSession

@Suite struct WordUnitsTests {
    let plain = WordUnitOptions()

    @Test func englishWordsCarryLeadingSpace() {
        #expect(WordUnits.next(in: "hello world", options: plain) == "hello")
        #expect(WordUnits.next(in: " world again", options: plain) == " world")
        #expect(WordUnits.next(in: "   ", options: plain) == "   ")
        #expect(WordUnits.next(in: "", options: plain) == "")
    }

    @Test func trailingPunctuationOption() {
        #expect(WordUnits.next(in: "world, and more", options: plain) == "world")
        #expect(WordUnits.next(in: ", and more", options: plain) == ",")
        let keep = WordUnitOptions(includeTrailingPunctuation: true)
        #expect(WordUnits.next(in: "world, and more", options: keep) == "world,")
        #expect(WordUnits.next(in: " done.", options: keep) == " done.")
    }

    @Test func trailingSpaceOption() {
        let space = WordUnitOptions(includeTrailingSpace: true)
        #expect(WordUnits.next(in: "hello world", options: space) == "hello ")
        #expect(WordUnits.next(in: "last", options: space) == "last")
        let both = WordUnitOptions(includeTrailingSpace: true, includeTrailingPunctuation: true)
        #expect(WordUnits.next(in: "end. Next", options: both) == "end. ")
    }

    @Test func chineseUsesTokenizer() {
        let unit = WordUnits.next(in: "今天天气很好", options: plain)
        #expect(!unit.isEmpty)
        #expect(unit.count < "今天天气很好".count)
        #expect("今天天气很好".hasPrefix(unit))
        #expect(unit.allSatisfy(WordUnits.isCJK))
    }

    @Test func chinesePunctuationOption() {
        let keep = WordUnitOptions(includeTrailingPunctuation: true)
        #expect(WordUnits.next(in: "好，然后", options: keep) == "好，")
        #expect(WordUnits.next(in: "好，然后", options: plain) == "好")
        #expect(WordUnits.next(in: "，然后", options: plain) == "，")
    }

    @Test func mixedScripts() {
        #expect(WordUnits.next(in: "Swift写代码", options: plain) == "Swift")
        let cjk = WordUnits.next(in: "用Swift写代码", options: plain)
        #expect(cjk == "用")
        #expect(WordUnits.next(in: " 我们 go", options: plain).hasPrefix(" 我"))
    }

    @Test func countStopsAtLimit() {
        #expect(WordUnits.count(in: "one two three") == 3)
        #expect(WordUnits.count(in: "one two three", limit: 2) == 2)
        #expect(WordUnits.count(in: " last") == 1)
        #expect(WordUnits.count(in: "   ") == 0)
    }
}

@Suite struct AnchorMatcherTests {
    @Test func exactExtension() {
        #expect(AnchorMatcher.match(before: "Hello wo", anchor: "Hello", continuation: " world") == .extended(delta: " wo"))
        #expect(AnchorMatcher.match(before: "Hello", anchor: "Hello", continuation: " world") == .extended(delta: ""))
        #expect(AnchorMatcher.match(before: "Hello x", anchor: "Hello", continuation: " world") == .diverged)
    }

    @Test func slidingWindowStillMatches() {
        let body = String(repeating: "abcdefghij", count: 400) // 4000 chars
        let anchor = body
        // The window dropped 3 chars at the front and the user typed " wo".
        let before = String(body.dropFirst(3)) + " wo"
        #expect(AnchorMatcher.match(before: before, anchor: anchor, continuation: " world") == .extended(delta: " wo"))
        #expect(AnchorMatcher.match(before: String(body.dropFirst(3)), anchor: anchor, continuation: " world")
            == .extended(delta: ""))
        #expect(AnchorMatcher.match(before: String(body.dropFirst(3)) + " xy", anchor: anchor, continuation: " world")
            == .diverged)
    }

    @Test func slidingWindowUsesOnlyTheTail() {
        let anchor = String(repeating: "x", count: 1000) + "The quick brown"
        // The front moved past everything but the last 300 chars.
        let before = String(anchor.suffix(300)) + " fox"
        #expect(AnchorMatcher.match(before: before, anchor: anchor, continuation: " fox jumps") == .extended(delta: " fox"))
    }
}
