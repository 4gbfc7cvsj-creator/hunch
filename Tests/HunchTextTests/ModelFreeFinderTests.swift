import Foundation
import Testing
@testable import HunchText

private struct OptionsSuggester: CorrectionSuggesting {
    var table: [String: CorrectionOptions] = [
        // One obvious fix: confident, no equally cheap rival.
        "recieve": CorrectionOptions(confident: "receive", guesses: ["receive"]),
        // Confident, but another likely word is as cheap a slip (the model would choose).
        "teh": CorrectionOptions(confident: "the", guesses: ["the", "ten"]),
        // Only guesses.
        "thier": CorrectionOptions(confident: nil, guesses: ["their", "thieve"]),
        "fo": CorrectionOptions(confident: nil, guesses: ["to", "of", "do", "go"]),
    ]
    func correction(for word: String, context: String, languages: [String]) -> String? {
        table[word]?.confident ?? table[word]?.guesses.first
    }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
}

private let spell = FakeSpell(["receive", "the", "ten", "their", "to", "of", "do", "go", "i", "need", "there", "here",
                               "weird"])
private let common: Set<String> = ["receive", "the", "ten", "their", "to", "of", "do", "go", "there", "weird"]

private func finder(modelFree: Bool) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: OptionsSuggester(), languages: ["en"], knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)), isCommonWord: { common.contains($0) },
                             isEverydayWord: { common.contains($0) })
    f.modelFree = modelFree
    return f
}

/// Strength Light: the finder never hands anything to the model (no `.ambiguous`).
struct ModelFreeFinderTests {
    @Test func oneObviousFixIsStillMade() {
        for deferred in [true, false] {
            guard case .fix(let p)? = finder(modelFree: true).finding(before: "I recieve ", deferAmbiguous: deferred) else {
                Issue.record("expected a fix"); return
            }
            #expect(p.replacement == "receive")
        }
    }

    @Test func wordsTheModelWouldChooseForAreLeftAlone() {
        let f = finder(modelFree: true)
        // Several equally likely fixes, only guesses, and a two-letter word.
        #expect(f.finding(before: "say teh ", deferAmbiguous: true) == nil)
        #expect(f.finding(before: "with thier ", deferAmbiguous: true) == nil)
        #expect(f.finding(before: "I need fo ", deferAmbiguous: true) == nil)
        // Balanced still hands these to the model.
        let b = finder(modelFree: false)
        for text in ["say teh ", "with thier ", "I need fo "] {
            guard case .ambiguous? = b.finding(before: text, deferAmbiguous: true) else {
                Issue.record("balanced should be ambiguous for \(text)"); continue
            }
        }
    }

    @Test func confusedWordsAndRealWordSlipsAreNotScored() {
        var f = finder(modelFree: true)
        f.fixesConfusedWords = true
        // "their" is a real word; Balanced would score it against "there" at the end of a clause.
        for text in ["put it over their ", "I need to go to the ", "weird ", "I need the "] {
            if case .ambiguous? = f.finding(before: text, deferAmbiguous: true) { Issue.record("model work for \(text)") }
        }
    }

    @Test func nonFixKindsKeepTheirOwnSwitches() {
        var f = finder(modelFree: true)
        f.fixesCapitals = true
        guard case .fix(let p)? = f.finding(before: "I said THe ", deferAmbiguous: true) else {
            Issue.record("capital fix should still apply"); return
        }
        #expect(p.replacement == "The")
    }
}
