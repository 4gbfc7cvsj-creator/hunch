import Foundation
import Testing
@testable import HunchText

private let spell = FakeSpell(["so", "it", "the", "this", "then", "hello", "please", "meeting", "monday"])

private func finder(caps: Bool = true, known: Set<String> = []) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: PlainSuggester(), languages: ["en"], knownWords: known,
                             guesser: StubGuesser([:], default: ("en", 0.9)))
    f.fixesCapitals = caps
    return f
}

private struct PlainSuggester: CorrectionSuggesting {
    func correction(for word: String, context: String, languages: [String]) -> String? { nil }
}

/// The replacement a finder would apply for the word just typed, on both paths.
private func fix(_ before: String, _ f: CorrectionFinder = finder()) -> String? {
    let tab = f.proposal(before: before)?.replacement
    if case .fix(let p)? = f.finding(before: before, deferAmbiguous: true) { #expect(p.replacement == tab); return p.replacement }
    #expect(tab == nil)
    return nil
}

struct CapitalFixTests {
    @Test func twoLetterWordsGetTheSentenceCapital() {
        #expect(fix("so ") == "So")
        #expect(fix("That works. so ") == "So")
        #expect(fix("Done!\nit ") == "It")
        #expect(fix("I said so ") == nil)
        #expect(fix("That works. xq ") == nil)  // not a word
        #expect(fix("That works. SO ") == nil)
    }

    @Test func twoCapitalsAtTheStart() {
        #expect(fix("so THe ") == "The")
        #expect(fix("THis ") == "This")
        #expect(fix("please wait, THen ") == "Then")
    }

    @Test func capsLockLeftOn() {
        #expect(fix("ok tHIS ") == "This")
        #expect(fix("hELLO ") == "Hello")
    }

    @Test func loneIAndContractions() {
        #expect(fix("then i ") == "I")
        #expect(fix("then i, ") == "I")
        #expect(fix("so i'm ") == "I'm")
        #expect(fix("so i'll ") == "I'll")
        #expect(fix("so i\u{2019}ve ") == "I\u{2019}ve")
        #expect(fix("I ") == nil)
    }

    @Test func dayAndMonthNames() {
        #expect(fix("see you monday ") == "Monday")
        #expect(fix("on friday, ") == "Friday")
        #expect(fix("in december ") == "December")
        #expect(fix("Monday ") == nil)
        // Ordinary words that are also names stay.
        #expect(fix("may ") == nil)
        #expect(fix("the march ") == nil)
    }

    @Test func brands() {
        #expect(fix("my iphone ") == "iPhone")
        #expect(fix("on macos ") == "macOS")
        #expect(fix("watch youtube ") == "YouTube")
        #expect(fix("an Iphone ") == "iPhone")
        #expect(fix("an IPhone ") == "iPhone")
        #expect(fix("my iPhone ") == nil)
        #expect(fix("the IOS ") == nil)
    }

    @Test func neverTouches() {
        #expect(fix("use the API ") == nil)
        #expect(fix("by NASA ") == nil)
        #expect(fix("a mRNA ") == nil)            // not a dictionary word
        #expect(fix("see www.iphone ") == nil)
        #expect(fix("mail @monday ") == nil)
        #expect(fix("tag #monday ") == nil)
        #expect(fix("path /monday ") == nil)
        #expect(fix("alex@iphone ") == nil)
        #expect(fix("run `i ") == nil)
        #expect(fix("run `git i ") == nil)
        #expect(fix("item i. ") == nil)           // list number
        #expect(fix("(i ") == nil)
        #expect(fix("camelCase ") == nil)
        #expect(fix("go to the tHIS2 ") == nil)
    }

    @Test func offWhenTheSwitchIsOff() {
        let off = finder(caps: false)
        #expect(fix("so THe ", off) == nil)
        #expect(fix("then i ", off) == nil)
        #expect(fix("my iphone ", off) == nil)
        #expect(fix("see you monday ", off) == nil)
    }

    @Test func respectsTextReplacementsAndTheUsersOwnWords() {
        var f = finder(known: ["iphone", "GHz"])
        f.screenWords = ScreenWords(words: ["monday"])
        #expect(fix("see you monday ", f) == nil)
        #expect(fix("tHIS ", finder(known: ["tHIS"])) == nil)  // a taught spelling stays
        #expect(fix("my iphone ", f) == "iPhone")
    }

    @Test func deleteCountCoversTheWordAndWhatFollows() throws {
        let p = try #require(finder().proposal(before: "so THe, "))
        #expect(p.misspelled == "THe" && p.replacement == "The" && p.trailing == ", " && p.deleteCount == 5)
    }
}

struct SentenceStartCapitalTests {
    @Test func startOfFieldAndAfterStops() {
        #expect(fix("hello ") == "Hello")
        #expect(fix("Please wait. then ") == "Then")
        #expect(fix("Really! this ") == "This")
        #expect(fix("Really? this ") == "This")
        #expect(fix("Please wait.\nthis ") == "This")
        #expect(fix("Please wait.\n\nthis ") == "This")
        #expect(fix("\"hello ") == "Hello")
        #expect(fix("He said \"go.\" then ") == "Then")
        #expect(fix("Hello, then ") == nil)
        #expect(fix("Hello then ") == nil)
    }

    @Test func leftAlone() {
        #expect(fix("Ask Dr. this ") == nil)
        #expect(fix("Ask Mr. this ") == nil)
        #expect(fix("Use it, i.e. this ") == nil)
        #expect(fix("Some, e.g. this ") == nil)
        #expect(fix("tea, coffee, etc. this ") == nil)
        #expect(fix("this vs. then ") == nil)
        #expect(fix("It took 3.5 then ") == nil)
        #expect(fix("It is wait... then ") == nil)
        #expect(fix("Wait\u{2026} then ") == nil)
        #expect(fix("See example.com. then ") == nil)
        #expect(fix("Open notes.txt. then ") == nil)
        #expect(fix("See https://a.com/x. then ") == nil)
        #expect(fix("Meet J. then ") == nil)
        #expect(fix("end.then ") == nil)
        #expect(fix("`code. then ") == nil)
    }

    @Test func switchOffAndUnknownWords() {
        #expect(fix("hello ", finder(caps: false)) == nil)
        #expect(fix("Wait. qwzx ") == nil)
        #expect(fix("Wait. Then ") == nil)
    }
}
