import HunchCore
import Testing
@testable import HunchText

@Suite struct QuoteStyleTests {
    @Test func detectsTheFieldsStyle() {
        #expect(QuoteStyle.detect(in: "I don\u{2019}t know") == .curly)
        #expect(QuoteStyle.detect(in: "I don't know") == .straight)
        #expect(QuoteStyle.detect(in: "No quotes here") == nil)
        // Mixed: the most recent one wins.
        #expect(QuoteStyle.detect(in: "it's \u{201C}fine\u{201D}") == .curly)
        #expect(QuoteStyle.detect(in: "\u{201C}fine\u{201D} it's") == .straight)
    }

    @Test func straightBecomesCurlyInSmartQuoteFields() {
        let before = "Thanks, I\u{2019}ll check. "
        #expect(QuoteStyle.match("We can't make it", before: before) == "We can\u{2019}t make it")
        #expect(QuoteStyle.match("she said \"yes\" today", before: before) == "she said \u{201C}yes\u{201D} today")
        #expect(QuoteStyle.match("the 'final' draft", before: before) == "the \u{2018}final\u{2019} draft")
        #expect(QuoteStyle.match("the students' work", before: before) == "the students\u{2019} work")
        // Opening right after the caret depends on what's before it.
        #expect(QuoteStyle.match("\"Hi", before: "He said ") == "\"Hi")   // straight field context
        #expect(QuoteStyle.match("\"Hi\"", before: "I\u{2019}m ") == "\u{201C}Hi\u{201D}")
        #expect(QuoteStyle.match("s great", before: "That\u{2019}") == "s great")
    }

    @Test func curlyBecomesStraightInPlainFields() {
        let before = "I don't think so. "
        #expect(QuoteStyle.match("It\u{2019}s \u{201C}done\u{201D}", before: before) == "It's \"done\"")
    }

    @Test func forcedStraightIgnoresTheFieldsStyle() {
        // Smart quotes off for the app or site: curly marks become straight even in a curly field.
        let curlyField = "Thanks, I\u{2019}ll check. "
        #expect(QuoteStyle.match("It\u{2019}s \u{201C}done\u{201D}", before: curlyField, preference: .straight)
                == "It's \"done\"")
        #expect(QuoteStyle.match("the \u{2018}final\u{2019} draft", before: "No quotes yet ", preference: .straight)
                == "the 'final' draft")
        // Straight text stays straight (never curled).
        #expect(QuoteStyle.match("We can't make it", before: curlyField, preference: .straight) == "We can't make it")
        #expect(QuoteStyle.match("plain words", before: curlyField, preference: .straight) == "plain words")
    }

    @Test func matchFieldIsTheDefault() {
        let curlyField = "Thanks, I\u{2019}ll check. "
        for (text, before) in [("We can't make it", curlyField), ("It\u{2019}s \u{201C}done\u{201D}", "I don't think so. "),
                               ("can't stop", "Hello there "), ("\u{201C}Hi\u{201D}", "Hello ")] {
            #expect(QuoteStyle.match(text, before: before, preference: .matchField) == QuoteStyle.match(text, before: before))
        }
        #expect(QuoteStyle.match("\u{201C}Hi\u{201D}", before: "Hello ", preference: .matchField) == "\u{201C}Hi\u{201D}")
    }

    @Test func postProcessorAppliesTheContextsPreference() {
        let before = "Thanks, I\u{2019}ll check. "
        func show(_ q: QuotePreference) -> PostOutcome {
            DefaultPostProcessor().process("She said \u{201C}we\u{2019}re ready\u{201D} today", meanLogProb: nil,
                                           context: PostContext(before: before, after: "", requiredPrefix: "",
                                                                allowNewlines: false, maxWords: 10, quoteStyle: q))
        }
        #expect(show(.straight) == .show("She said \"we're ready\" today"))
        #expect(show(.matchField) == .show("She said \u{201C}we\u{2019}re ready\u{201D} today"))
    }

    @Test func untouchedWithoutQuotesOrStyle() {
        #expect(QuoteStyle.match("can't stop", before: "Hello there ") == "can't stop")
        #expect(QuoteStyle.match("plain words", before: "It\u{2019}s ") == "plain words")
    }
}
