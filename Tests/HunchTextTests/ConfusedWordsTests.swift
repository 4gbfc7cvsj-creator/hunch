import Foundation
import Testing
@testable import HunchText

/// "Fix commonly confused words": their/there, your/you're... go to the model, strictly.
private struct NoSuggester: CorrectionSuggesting {
    func correction(for word: String, context: String, languages: [String]) -> String? { nil }
}

private let words = ConfusedWords.allWords + ["the", "is", "over", "go", "i", "want", "me", "more", "a", "car", "we"]
private let spell = FakeSpell(words)

private func finder(on: Bool = true) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: NoSuggester(), languages: ["en"], knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)),
                             isCommonWord: { words.contains($0) }, isEverydayWord: { words.contains($0) })
    f.fixesConfusedWords = on
    return f
}

private func ambiguous(_ before: String, _ f: CorrectionFinder = finder()) -> AmbiguousTypo? {
    if case .ambiguous(let typo)? = f.finding(before: before, deferAmbiguous: true) { return typo }
    return nil
}

struct ConfusedWordsTests {
    @Test func aConfusedWordGetsItsRivalsAndTheStrictMargin() throws {
        let typo = try #require(ambiguous("over their "))
        #expect(typo.candidates == ["there", "they're"])
        #expect(typo.confusable)
        #expect(typo.margin == CorrectionFinder.defaultConfusedWordMargin)
        #expect(typo.fallback == nil && typo.preferred == nil)
        #expect(try #require(ambiguous("more then ")).candidates == ["than"])
        #expect(try #require(ambiguous("is your ")).candidates == ["you're"])
    }

    @Test func apostrophesFollowTheWordAndTheField() throws {
        #expect(try #require(ambiguous("is its ")).candidates == ["it's"])
        #expect(try #require(ambiguous("we\u{2019}re here, is its ")).candidates == ["it\u{2019}s"])
        #expect(try #require(ambiguous("we\u{2019}re here, it's ")).candidates == ["its"])
        #expect(try #require(ambiguous("go. Its ")).candidates == ["It's"])
        #expect(try #require(ambiguous("is you\u{2019}re ")).candidates == ["your"])
    }

    @Test func toOnlyBeforePunctuationTooAlways() throws {
        #expect(ambiguous("i want to ") == nil)
        #expect(try #require(ambiguous("me to. ")).candidates == ["too"])
        #expect(try #require(ambiguous("want too ")).candidates == ["to"])
    }

    @Test func offByDefaultAndOutsideFixAutomatically() {
        #expect(ambiguous("over their ", finder(on: false)) == nil)
        #expect(finder().finding(before: "over their ", deferAmbiguous: false) == nil)
        #expect(ambiguous("over the ") == nil)
    }

    @Test func aCapitalizedWordMidSentenceIsLeftAlone() {
        #expect(ambiguous("a car Their ") == nil)
    }

    @Test func rivalsCostTheSameAndACloseCallIsKept() {
        var typo = AmbiguousTypo(misspelled: "their", candidates: ["there", "they're"], fallback: nil,
                                 deleteCount: 6, trailing: " ", margin: 5)
        typo.confusable = true
        #expect(JointChoice.candidateCosts(typo) == [0, 0])
        // A rival ahead, but not by the margin: left as typed (never offered).
        #expect(JointChoice.choice(typo, best: [-10, -6, -20]) == .keep)
        #expect(JointChoice.choice(typo, best: [-10, -4.9, -20]) == .fix("there"))
        // The runner-up may be the other rival.
        #expect(JointChoice.choice(typo, best: [-20, -4, -6]) == .keep)
        #expect(JointChoice.choice(typo, best: [-3, -10, -20]) == .keep)
    }
}
