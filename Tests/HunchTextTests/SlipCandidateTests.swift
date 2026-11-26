import Foundation
import Testing
@testable import HunchText

/// Stage 3 of fast-typing autocorrect: more kinds of slips reach the model as candidates.
private struct TableSuggester: CorrectionSuggesting {
    var table: [String: CorrectionOptions] = [
        "deember": CorrectionOptions(confident: nil, guesses: ["december"]),
        "i'l": CorrectionOptions(confident: "i'll", guesses: ["i'll"]),
        "autocrereect": CorrectionOptions(confident: nil, guesses: []),
        "thebcat": CorrectionOptions(confident: nil, guesses: []),
        "ofc": CorrectionOptions(confident: "of", guesses: ["of"]),
    ]
    func correction(for word: String, context: String, languages: [String]) -> String? {
        table[word]?.confident ?? table[word]?.guesses.first
    }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
}

private let spell = FakeSpell([
    // everyday
    "the", "they", "when", "switch", "with", "work", "for", "an", "so", "is", "it", "be", "off", "i", "i'll", "cat",
    "from", "form", "see", "you", "if", "of", "stage",
    // common, not everyday
    "thee", "thy", "december", "autocorrect", "fits",
    // accepted by the checker, not common
    "wrk", "wth", "na", "iff", "mp",
])
private let everyday: Set<String> = ["the", "they", "when", "switch", "with", "work", "for", "an", "so", "is", "it",
                                     "be", "off", "i", "i'll", "cat", "from", "form", "see", "you", "if", "of"]
private let common = everyday.union(["thee", "thy", "december", "autocorrect", "fits", "stage"])

private func finder(realWords: Bool = true) -> CorrectionFinder {
    let isEveryday: (@Sendable (String) -> Bool)? = realWords ? { @Sendable w in everyday.contains(w) } : nil
    return CorrectionFinder(spellChecker: spell, suggester: TableSuggester(), languages: ["en"], knownWords: [],
                            guesser: StubGuesser([:], default: ("en", 0.9)), isCommonWord: { common.contains($0) },
                            isEverydayWord: isEveryday)
}

private func ambiguous(_ before: String, _ f: CorrectionFinder = finder()) -> AmbiguousTypo? {
    if case .ambiguous(let typo)? = f.finding(before: before, deferAmbiguous: true) { return typo }
    return nil
}

struct RealWordSlipTests {
    @Test func uncommonDictionaryWordIsAskedWithAStrictMargin() throws {
        let typo = try #require(ambiguous("lots of wrk "))
        #expect(typo.candidates.contains("work"))
        #expect(typo.margin == CorrectionFinder.strictMargin)
        #expect(typo.fallback == nil)
        #expect(try #require(ambiguous("na ")).candidates.contains("an"))
    }

    @Test func commonRealWordGetsOnlyEverydayCandidatesAndTheStrictestMargin() throws {
        let typo = try #require(ambiguous("go to thee "))
        #expect(typo.candidates.contains("the"))
        #expect(typo.candidates.allSatisfy { everyday.contains($0) })
        #expect(typo.margin == CorrectionFinder.realWordMargin)
    }

    @Test func everydayWordsAreNeverQuestioned() {
        #expect(finder().finding(before: "taken form ", deferAmbiguous: true) == nil)
        #expect(finder().finding(before: "the cat ", deferAmbiguous: true) == nil)
    }

    @Test func offWithoutEverydayListOrOutsideFixAutomatically() {
        #expect(finder(realWords: false).finding(before: "lots of wrk ", deferAmbiguous: true) == nil)
        #expect(finder().finding(before: "lots of wrk ", deferAmbiguous: false) == nil)
    }

    @Test func formsOfTheSameWordAndLongerWordsWithAnExtraLetterAreNotSlips() {
        // Stage 5: the real-word path broke "fully", "starter", "totals", "slide".
        #expect(!CorrectionFinder.plausibleRealWordSlip(typed: "fully", meant: "full"))
        #expect(!CorrectionFinder.plausibleRealWordSlip(typed: "starter", meant: "started"))
        #expect(!CorrectionFinder.plausibleRealWordSlip(typed: "totals", meant: "total"))
        #expect(!CorrectionFinder.plausibleRealWordSlip(typed: "slide", meant: "side"))
        // Still slips: "thee", "wee", "tim", "writ", "clint", "greta".
        for (typed, meant) in [("thee", "the"), ("wee", "we"), ("tim", "time"), ("writ", "write"), ("clint", "client"),
                               ("greta", "great"), ("wrk", "work")] {
            #expect(CorrectionFinder.plausibleRealWordSlip(typed: typed, meant: meant), "\(typed) → \(meant)")
        }
    }

    @Test func dictionaryWordWithNoCommonNeighbourStays() {
        #expect(finder().finding(before: "the mp ", deferAmbiguous: true) == nil)
    }
}

struct ChatShorthandTests {
    @Test func shorthandIsLeftAloneOnlyWhenAsked() throws {
        // "na" stands in for shorthand the checker accepts; "tbh" for shorthand it doesn't.
        #expect(ambiguous("lots of wrk ") != nil)
        var f = finder()
        f.leavesShorthand = true
        #expect(ChatShorthand.contains("TBH") && ChatShorthand.contains("ofc") && ChatShorthand.contains("id"))
        #expect(f.finding(before: "ok tbh ", deferAmbiguous: true) == nil)
        #expect(f.finding(before: "lots of wrk ", deferAmbiguous: true) != nil)
    }

    @Test func theSwitchIsPerFinderCopyAndCoversTheStruckThroughFix() {
        // The coordinator copies the shared finder and sets the flag per app: the original is unchanged.
        let base = finder()
        var chat = base
        chat.leavesShorthand = true
        #expect(!base.leavesShorthand && chat.leavesShorthand)
        // The Tab (struck-through) path honors it, and ordinary slips are still fixed in chat.
        #expect(base.proposal(before: "ok ofc ") != nil)
        #expect(chat.proposal(before: "ok ofc ") == nil)
        #expect(chat.finding(before: "ok ofc ", deferAmbiguous: true) == nil)
        #expect(chat.proposal(before: "in deember ") != nil)
    }
}

struct SymbolSlipTests {
    @Test func aDigitFarFromTheLettersBesideItIsALabel() {
        // From a saved sample: "stage2." is not "stage." (2 is above w/q, not near e).
        #expect(finder().finding(before: "or stage2. ", deferAmbiguous: true) == nil)
        #expect(finder().finding(before: "or stage2 ", deferAmbiguous: true) == nil)
    }

    @Test func digitInsideAWord() throws {
        #expect(try #require(ambiguous("ask whe4n ")).candidates == ["when"])
        #expect(try #require(ambiguous("ask whe4n ")).fallback == "when")
        #expect(try #require(ambiguous("so I9 ")).candidates == ["I"])
    }

    @Test func digitForALetterAboveIt() throws {
        // "0f": 0 sits above o/p; "8t": 8 above i/u.
        #expect(try #require(ambiguous("one 0f ")).candidates.contains("of"))
        #expect(try #require(ambiguous("is 8t ")).candidates.contains("it"))
    }

    @Test func digitAndAnotherSlip() throws {
        #expect(try #require(ambiguous("main s3with ")).candidates.contains("switch"))
    }

    @Test func shiftLetGoOnAClosingBracket() throws {
        let typo = try #require(ambiguous("turns left (off0 "))
        #expect(typo.candidates.first == "off)")
        #expect(typo.misspelled == "off0")
    }

    @Test func namesAndCodesWithDigitsStay() {
        for text in ["play the mp3 ", "use k8s ", "the 4th ", "a B2B deal ", "row a1 ", "covid19 "] {
            #expect(finder().finding(before: text, deferAmbiguous: true) == nil, "\(text)")
        }
    }

    @Test func onlyWhenFixingAutomatically() {
        #expect(finder().finding(before: "ask whe4n ", deferAmbiguous: false) == nil)
    }
}

struct CapitalMidSentenceTests {
    @Test func capitalizedTypoMidSentenceGoesToTheModelStrictly() throws {
        let typo = try #require(ambiguous("see you in Deember "))
        #expect(typo.candidates == ["December"])
        #expect(typo.margin == CorrectionFinder.strictMargin)
        #expect(typo.fallback == nil)
    }

    @Test func confidentFixOfACapitalIsNotAppliedAtOnce() throws {
        let typo = try #require(ambiguous("then I'l "))
        #expect(typo.candidates.first == "I'll")
    }

    @Test func correctlySpelledCapitalStays() {
        #expect(finder().finding(before: "see you in December ", deferAmbiguous: true) == nil)
        #expect(finder().finding(before: "ask Thy ", deferAmbiguous: true) == nil)
    }
}

struct FieldAndSpaceCandidateTests {
    @Test func garbledWordMatchesOneAlreadyInTheField() throws {
        let typo = try #require(ambiguous("autocorrect is off when autocrereect "))
        #expect(typo.candidates.first == "autocorrect")
    }

    @Test func fieldWordsNeedTheSameFirstLetterAndFewEdits() {
        #expect(finder().fieldCandidates(for: "autocrereect", in: "the switch ").isEmpty)
        #expect(finder().fieldCandidates(for: "zutocorrect", in: "autocorrect ").isEmpty)
    }

    @Test func letterNextToTheSpaceBarForASpace() throws {
        #expect(finder().spaceKeyCandidates(for: "thebcat") == ["the cat"])
        #expect(try #require(ambiguous("saw thebcat ")).candidates.contains("the cat"))
    }
}
