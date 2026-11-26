import Foundation
import Testing
@testable import HunchText

/// Autocorrect mechanism: words on screen are not "fixed", and a garbled one finds its screen word.

private let dict: Set<String> = ["the", "and", "we", "need", "to", "export", "a", "file", "as", "please", "send", "it",
                                 "monday", "receive", "about", "think", "this", "is", "for", "css", "style", "web", "hook"]
private func rejected(_ w: String) -> Bool { !dict.contains(w) }

private struct Guesses: CorrectionSuggesting {
    let table: [String: CorrectionOptions]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word]?.confident }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
}

private func finder(_ screen: ScreenWords) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: FakeSpell(Array(dict)), suggester: Guesses(table: [
        "csv": CorrectionOptions(confident: nil, guesses: ["css"]),
        "kuberentes": CorrectionOptions(confident: nil, guesses: []),
    ]), languages: ["en"], knownWords: [], guesser: StubGuesser([:], default: ("en", 0.9)),
                            isCommonWord: { dict.contains($0) }, isEverydayWord: { dict.contains($0) })
    f.screenWords = screen
    return f
}

struct ScreenWordsExtractionTests {
    @Test func keepsNamesAndTermsDropsEverydayWords() {
        let w = ScreenWords(text: "Can you send the report to Alex Morgan? We use Kubernetes and GitHub, ping @alex about k8s and #release.",
                            isMisspelled: rejected)
        for expected in ["alex", "morgan", "kubernetes", "github", "k8s", "release"] { #expect(w.contains(expected), "\(expected)") }
        #expect(!w.contains("send"))
        #expect(!w.contains("can"))   // sentence start, not a name
    }

    @Test func aCapitalAtASentenceStartIsNotAName() {
        let w = ScreenWords(text: "Zorblax is here. Then Quimby left.", isMisspelled: rejected)
        #expect(!w.contains("zorblax"))
        #expect(w.contains("quimby"))
    }

    @Test func aPlainUnknownLowercaseWordNeedsTwoSightings() {
        let once = ScreenWords(text: "please send the csv file", isMisspelled: rejected)
        #expect(!once.contains("csv"))
        let twice = ScreenWords(text: "please send the csv file. the csv is big", isMisspelled: rejected)
        #expect(twice.contains("csv"))
    }

    @Test func aQuotedTypoDoesNotProtectItself() {
        let w = ScreenWords(text: "you wrote \"recieve\" but it is spelled differently", isMisspelled: rejected)
        #expect(!w.contains("recieve"))
    }

    @Test func dictionaryWordsAreNeverKept() {
        let w = ScreenWords(text: "see you on Monday about this", isMisspelled: rejected)
        #expect(w.isEmpty)
    }

    @Test func candidatesAreNearScreenWordsOnly() {
        let w = ScreenWords(text: "we run Kubernetes here", isMisspelled: rejected)
        #expect(w.candidates(for: "kuberentes") == ["kubernetes"])
        #expect(w.candidates(for: "banana").isEmpty)
    }
}

struct ScreenWordsFinderTests {
    @Test func aWordOnScreenIsLeftAlone() {
        let screen = ScreenWords(text: "export the csv. the csv is big", isMisspelled: rejected)
        #expect(finder(screen).finding(before: "we need a csv ", deferAmbiguous: true) == nil)
    }

    @Test func withoutScreenWordsTheWordGoesToTheModel() {
        guard case .ambiguous(let t)? = finder(.empty).finding(before: "we need a csv ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.contains("css"))
    }

    @Test func aGarbledNameGetsItsScreenWordAsCandidate() {
        let screen = ScreenWords(text: "we run Kubernetes here", isMisspelled: rejected)
        guard case .ambiguous(let t)? = finder(screen).finding(before: "we need kuberentes ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.first == "kubernetes")
        #expect(finder(.empty).finding(before: "we need kuberentes ", deferAmbiguous: true) == nil)
    }
}
