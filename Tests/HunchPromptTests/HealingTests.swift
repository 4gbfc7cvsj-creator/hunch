import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct HealingTests {
    private func check(_ before: String, _ prompt: String, _ required: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let split = Healing.split(before: before)
        #expect(split == HealingSplit(promptText: prompt, requiredPrefix: required), sourceLocation: sourceLocation)
        #expect(split.promptText + split.requiredPrefix == before, sourceLocation: sourceLocation)
    }

    @Test func designExamples() {
        check("I am a", "I am", " a")
        check("I am a ", "I am a", " ")
        check("", "", "")
        check("Hello,", "Hello,", "")
    }

    @Test func wholeTextIsOnePartialWord() {
        check("Hel", "", "Hel")
    }

    @Test func multipleSpacesAndTabsMoveTogether() {
        check("Dear  Jo", "Dear", "  Jo")
        check("Name:\tAl", "Name:", "\tAl")
        check("Ok   ", "Ok", "   ")
    }

    @Test func punctuationEndsTheSpan() {
        check("Hello, wor", "Hello,", " wor")
        check("Wait...", "Wait...", "")
        check("well-kno", "well-", "kno")
        check("(see", "(", "see")
        check("Hi!", "Hi!", "")
    }

    @Test func apostrophesStayInsideWords() {
        check("I don'", "I", " don'")
        check("we can\u{2019}t", "we", " can\u{2019}t")
    }

    @Test func digitsArePartOfWords() {
        check("Room 4", "Room", " 4")
        check("pi is 3.1", "pi is 3.", "1")
    }

    @Test func accentedLettersPrecomposedAndDecomposed() {
        check("Je suis all\u{E9}", "Je suis", " all\u{E9}")
        check("caf" + "e\u{301}", "", "caf" + "e\u{301}")
        check("Stra\u{DF}e na", "Stra\u{DF}e", " na")
        check("\u{41F}\u{440}\u{438}\u{432}\u{435}\u{442} \u{43C}\u{438}", "\u{41F}\u{440}\u{438}\u{432}\u{435}\u{442}", " \u{43C}\u{438}")
    }

    @Test func newlinesStayInThePrompt() {
        check("Hello\nwor", "Hello\n", "wor")
        check("Hello\n", "Hello\n", "")
        check("Hello \n", "Hello \n", "")
        check("Line\n  ind", "Line\n", "  ind")
    }

    @Test func emojiIsNotAWordCharacter() {
        check("Great \u{1F600}", "Great \u{1F600}", "")
        check("\u{1F600} ok", "\u{1F600}", " ok")
        check("Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ", "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", " ")
    }

    @Test func chineseIsNeverHealed() {
        check("我今天很", "我今天很", "")
        check("我喜欢", "我喜欢", "")
        check("你好，", "你好，", "")
        check("你好。", "你好。", "")
    }

    @Test func latinAfterChineseHealsOnlyTheLatinRun() {
        check("我用iPh", "我用", "iPh")
        check("我喜欢 App", "我喜欢", " App")
        check("我喜欢 ", "我喜欢", " ")
    }

    @Test func japaneseKanaIsNotHealed() {
        check("ありがとう", "ありがとう", "")
        check("カタカナ", "カタカナ", "")
    }

    @Test func veryLongRunsAreNotHealed() {
        let token = String(repeating: "x", count: Healing.maxPartialWordLength + 1)
        check("key " + token, "key " + token, "")
        let ok = String(repeating: "x", count: Healing.maxPartialWordLength)
        check("key " + ok, "key", " " + ok)
    }
}
