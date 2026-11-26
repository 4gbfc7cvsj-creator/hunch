import Foundation
import Testing
@testable import HunchText

private struct NoSuggester: CorrectionSuggesting {
    func correction(for word: String, context: String, languages: [String]) -> String? { nil }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        CorrectionOptions(confident: nil, guesses: [])
    }
}

private let spell = FakeSpell(["the", "end", "next", "word", "that", "we", "do", "it", "site", "file", "meet", "today",
                               "see", "you", "hello", "i", "am", "here", "okay", "thanks", "from", "us"])

private func finder(on: Bool = true, doubleSpace: PunctuationFixer.DoubleSpace = .period,
                    languages: [String] = ["en"]) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: NoSuggester(), languages: languages, knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)))
    f.fixesPunctuation = on
    f.doubleSpace = doubleSpace
    return f
}

private func fix(_ text: String, on: Bool = true, doubleSpace: PunctuationFixer.DoubleSpace = .period,
                 auto: Bool = false, languages: [String] = ["en"]) -> String? {
    guard case .fix(let p)? = finder(on: on, doubleSpace: doubleSpace, languages: languages)
        .finding(before: text, deferAmbiguous: auto) else { return nil }
    // What the text becomes after the fix is applied.
    return String(text.dropLast(p.deleteCount)) + p.replacement + p.trailing
}

struct PunctuationFixerTests {
    @Test func spaceBeforePunctuation() {
        #expect(fix("We meet today . ") == "We meet today. ")
        #expect(fix("Hello , ") == "Hello, ")
        #expect(fix("Are we here ? ") == "Are we here? ")
        #expect(fix("Hello ! ", auto: true) == "Hello! ")
        // Struck-through path and automatic path agree.
        #expect(fix("We meet today . ", auto: true) == "We meet today. ")
    }

    @Test func spaceBeforePunctuationLeavesLookalikes() {
        #expect(fix("We meet today ... ") == nil)            // ellipsis
        #expect(fix("We meet today .. ") == nil)
        #expect(fix("page 3 . ") == nil)                     // number / list marker
        #expect(fix("Hello :) ") == nil)                     // emoticon
        #expect(fix("Hello ; ") == nil)
        #expect(fix("see https://example.com/a . ") == nil)  // link
        #expect(fix("mail alex@example.com . ") == nil)      // email
        #expect(fix("open ~/notes/a_b . ") == nil)           // path
        #expect(fix("run `ls . ") == nil)                    // inside backticks
        #expect(fix("Bonjour ! ", languages: ["fr"]) == nil) // French keeps the space
        #expect(fix("We meet today . ", on: false) == nil)
    }

    @Test func missingSpaceAfterFullStop() {
        #expect(fix("That is the end.Next ") == "That is the end. Next ")
        #expect(fix("We meet today.See ", auto: true) == "We meet today. See ")
    }

    @Test func missingSpaceLeavesNeverTouchCases() {
        #expect(fix("version v1.2 ") == nil)
        #expect(fix("it costs 3.5 ") == nil)
        #expect(fix("for example e.g. ") == nil)
        #expect(fix("in the U.S. ") == nil)
        #expect(fix("open site.Com ") == nil)                // domain ending
        #expect(fix("open file.Txt ") == nil)
        #expect(fix("see end.Next.Door ") == nil)            // two dots
        #expect(fix("open xyzzy.Next ") == nil)              // not a word before the stop
        #expect(fix("see https://x.example/end.Next ") == nil)
        #expect(fix("that is the end.Next ", on: false) == nil)
        #expect(fix("wait... Next ") == nil)
    }

    @Test func doubledSpace() {
        #expect(fix("That is the end  ", doubleSpace: .period) == "That is the end. ")
        #expect(fix("That is the end  ", doubleSpace: .collapse) == "That is the end ")
        // After punctuation it is only collapsed, whatever the mode.
        #expect(fix("That is the end.  ", doubleSpace: .period) == "That is the end. ")
        #expect(fix("Hello,  ", doubleSpace: .period) == "Hello, ")
        // Native apps do it themselves (macOS shortcut): never applied twice.
        #expect(fix("That is the end  ", doubleSpace: .off) == nil)
        // Three spaces, indentation and a bare line are left alone.
        #expect(fix("That is the end   ") == nil)
        #expect(fix("    ") == nil)
        #expect(fix("a line\n  ") == nil)
        #expect(fix("That is the end  ", on: false) == nil)
    }

    @Test func contractions() {
        #expect(fix("I dont ") == "I don't ")
        #expect(fix("Dont ") == "Don't ")
        #expect(fix("Hi, im, ") == "Hi, I'm, ")
        #expect(fix("well im ") == "well I'm ")
        #expect(fix("youre ") == "you're ")
        #expect(fix("Ok thats ") == "Ok that's ")
        #expect(fix("we cant, ") == "we can't, ")
        #expect(fix("I ive ") == "I I've ")
        #expect(fix("I dont ", auto: true) == "I don't ")
        // Real words are never fixed blindly.
        for word in ["its", "well", "were", "wed", "ill", "hell", "shell", "id", "lets"] {
            #expect(PunctuationFixer.contraction(for: word) == nil, "\(word)")
        }
        // Shouting and odd casing stay.
        #expect(fix("I DONT ") == nil)
        #expect(fix("I dOnt ") == nil)
        #expect(fix("I dont ", on: false) == nil)
    }

    @Test func contractionsNeverInsideCodeLinksOrPaths() {
        #expect(fix("see /usr/dont ") == nil)
        #expect(fix("ping @dont ") == nil)
        #expect(fix("tag #dont ") == nil)
        #expect(fix("example.dont ") == nil)
        #expect(fix("set a_dont ") == nil)
        #expect(fix("run `echo dont ") == nil)
    }

    @Test func typographicApostropheFollowsTheText() {
        #expect(fix("It\u{2019}s fine, I dont ") == "It\u{2019}s fine, I don\u{2019}t ")
    }

    @Test func screenWordProtectsAContraction() {
        var f = finder()
        f.screenWords = ScreenWords(words: ["dont"])
        #expect(f.finding(before: "I dont ", deferAmbiguous: false) == nil)
    }
}
