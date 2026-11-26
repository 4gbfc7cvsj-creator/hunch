import Foundation
import Testing
@testable import HunchText

/// Stage 4b: long garbled words found by a dictionary search, and spaces moved across several words.

private struct CompletingSuggester: CorrectionSuggesting {
    let table: [String: CorrectionOptions] = [
        "therea": CorrectionOptions(confident: "there", guesses: ["theres", "there"]),
    ]
    let completionTable: [String: [String]] = [
        "pu": ["put", "public", "push"],
        "pun": ["punch", "punctuation", "punish", "pun"],
        "ca": ["can", "call"],
        "cap": ["capital", "cap", "captain"],
        "capi": ["capital", "capitalism", "capitalize", "capitalization"],
    ]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word]?.confident }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
    func completions(forPrefix prefix: String, languages: [String]) -> [String] { completionTable[prefix] ?? [] }
}

private let dictionary = FakeSpell([
    "fix", "the", "and", "punctuation", "punctuations", "punch", "punish", "pun", "put", "public", "push",
    "capital", "capitalism", "capitalize", "capitalization", "cap", "captain", "can", "call",
    "there", "theres", "are", "still", "res", "till", "i", "think", "now", "rest", "ill", "a", "here", "re",
    "do", "should", "integration", "integrations", "marketplace", "some", "so", "me", "words",
])
private let everyday: Set<String> = ["fix", "the", "and", "there", "are", "still", "i", "think", "now", "till",
                                     "rest", "ill", "a", "can", "call", "put", "push", "here", "do", "should", "some", "so", "me"]

private func finder(lexicon: FuzzyLexicon? = nil) -> CorrectionFinder {
    CorrectionFinder(spellChecker: dictionary, suggester: CompletingSuggester(), languages: ["en"], knownWords: [],
                     guesser: StubGuesser([:], default: ("en", 0.9)),
                     isCommonWord: { everyday.contains($0) || $0 == "theres" },
                     isEverydayWord: { everyday.contains($0) }, lexicon: lexicon)
}

struct FuzzyCandidateTests {
    @Test func aLongGarbledWordFindsTheMeantWord() {
        guard case .ambiguous(let t)? = finder().finding(before: "fix the pucntioans ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.contains("punctuations"))  // a plural of a completion
        guard case .ambiguous(let c)? = finder().finding(before: "and capitlaizoain ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(c.candidates.first == "capitalization")
        #expect(c.preferred == nil)  // the model decides, the word as typed scored too
    }

    @Test func theLexiconFillsInWhatCompletionsMiss() {
        let lexicon = FuzzyLexicon(words: ["capitalization", "capitulation", "caterpillar", "cap"])
        #expect(lexicon.nearest("capitlaizoain").first == "capitalization")
        #expect(lexicon.nearest("cxyzqwvbn").isEmpty)
        let f = CorrectionFinder(spellChecker: dictionary, suggester: OnlyOptions(), languages: ["en"], knownWords: [],
                                 guesser: StubGuesser([:], default: ("en", 0.9)), lexicon: lexicon)
        #expect(f.fuzzyCandidates(for: "capitlaizoain").first == "capitalization")
    }

    @Test func aCandidateKeepsMostOfTheTypedLetters() {
        #expect(CorrectionFinder.lettersMissing(from: "punctuations", typed: "pucntioans") == 0)
        #expect(CorrectionFinder.lettersMissing(from: "bastion", typed: "banneton") == 3)
        let lexicon = FuzzyLexicon(words: ["bastion"])
        let f = CorrectionFinder(spellChecker: FakeSpell(["bastion"]), suggester: OnlyOptions(), languages: ["en"],
                                 knownWords: [], guesser: StubGuesser([:], default: ("en", 0.9)), lexicon: lexicon)
        #expect(f.fuzzyCandidates(for: "banneton").isEmpty)
    }

    @Test func aCapitalizedWordMidSentenceIsNotSearched() {
        #expect(finder().finding(before: "and Pucntioans ", deferAmbiguous: true) == nil)
    }

    @Test func shortWordsAreNotSearched() {
        #expect(finder().fuzzyCandidates(for: "pucnts").isEmpty)
    }

    @Test func fastCostMatchesSlipCost() {
        var scratch: [Float] = []
        for (a, b) in [("pucntioans", "punctuations"), ("teh", "the"), ("riught", "right"), ("sammple", "sample")] {
            let fast = FuzzyLexicon.cost(Array(a.utf8), Array(b.utf8), limit: 99, scratch: &scratch)
            #expect(abs(fast - SlipCost.cost(typed: a, candidate: b)) < 0.001)
        }
    }
}

private struct OnlyOptions: CorrectionSuggesting {
    func correction(for word: String, context: String, languages: [String]) -> String? { nil }
}

struct ResegmentTests {
    @Test func everySpaceOneLetterLate() {
        // "therea res" waits (it may continue into the next word); with "till" it splits again.
        let f = finder()
        guard case .ambiguous(let wait)? = f.finding(before: "i think therea res ", deferAmbiguous: true) else {
            Issue.record("expected the two words to wait"); return
        }
        #expect(wait.misspelled == "therea res")
        guard case .ambiguous(let t)? = f.finding(before: "i think therea res till ", deferAmbiguous: true) else {
            Issue.record("expected a re-split"); return
        }
        #expect(t.misspelled == "therea res till")
        #expect(t.candidates.first == "there are still")
        #expect(t.deleteCount == "therea res till ".count)
    }

    @Test func aSplitWhoseLeftoverIsTheLastWordKeepsThatWordsFixes() {
        // "stilld o th": "still do" + "th", which is itself a slip for "the".
        guard case .ambiguous(let t)? = finder().finding(before: "should i stilld o th ", deferAmbiguous: true) else {
            Issue.record("expected the group to wait"); return
        }
        #expect(t.misspelled == "stilld o th")
        #expect(t.candidates.prefix(3).contains("still do the"))
        #expect(t.candidates.contains("still do th"))
    }

    @Test func anEverydayLastWordIsNotCutInTwo() {
        // From a saved typing sample: "therea res till some" is not "there are still so me".
        #expect(finder().finding(before: "therea res till some ", deferAmbiguous: true) == nil)
        guard case .ambiguous(let three)? = finder().finding(before: "therea res till ", deferAmbiguous: true) else {
            Issue.record("expected a re-split"); return
        }
        #expect(three.candidates.first == "there are still")
        // In the span: the three words are decided with "some" after them.
        let f = finder()
        var span = UnsettledSpan<Int>()
        var step: UnsettledSpan<Int>.Step?
        for r in ["therea", "therea res ", "therea res till ", "therea res till some ", "therea res till some words "]
        where step == nil {
            step = span.read(field: 1, before: r) { f.finding(before: $0, deferAmbiguous: true) }
        }
        guard case .choose(let trigger)? = step else { Issue.record("expected a choice"); return }
        #expect(trigger.slots.map(\.misspelled) == ["therea res till"])
        #expect(trigger.gaps == [" some"])
    }

    @Test func quotedWordsAreNotReSpaced() {
        // From a saved sample: a typo quoted on purpose ("the "therea res till" in the beginning").
        for before in ["note that the \"therea res ", "note that the \"therea res till "] {
            if case .ambiguous(let t)? = finder().finding(before: before, deferAmbiguous: true) {
                #expect(!t.misspelled.contains(" "), "\(before)")
            }
        }
    }

    @Test func twoGoodWordsAreNotFixedByMovingASpaceAndALetter() {
        // "integrations marketplace" is not "integration smarketplace" → integration marketplace.
        // "marketplace" common but not everyday (a space may move before it), "integrations" not common.
        let f = CorrectionFinder(spellChecker: dictionary, suggester: CompletingSuggester(), languages: ["en"],
                                 knownWords: [], guesser: StubGuesser([:], default: ("en", 0.9)),
                                 isCommonWord: { everyday.contains($0) || $0 == "integration" || $0 == "marketplace" },
                                 isEverydayWord: { everyday.contains($0) })
        #expect(f.finding(before: "the integrations marketplace ", deferAmbiguous: true) == nil)
    }

    @Test func theStretchDecidesTheWholeGroup() {
        let f = finder()
        var span = UnsettledSpan<Int>()
        var step: UnsettledSpan<Int>.Step?
        for r in ["i think", "i think therea ", "i think therea res ", "i think therea res till ", "i think therea res till now "]
        where step == nil {
            step = span.read(field: 1, before: r) { f.finding(before: $0, deferAmbiguous: true) }
        }
        guard case .choose(let trigger)? = step else { Issue.record("expected a choice"); return }
        #expect(trigger.slots.map(\.misspelled) == ["therea res till"])
        #expect(trigger.head == "i think ")
        #expect(trigger.gaps == [" now"])
        #expect(SlipCost.cost(typed: "therea res till", candidate: "there are still") <= 3 * SlipCost.space + 0.01)
    }

    @Test func aSpaceOneLetterLateBeforeAShortWord() {
        guard case .ambiguous(let t)? = finder().finding(before: "and herea re ", deferAmbiguous: true) else {
            Issue.record("expected a two-word slip"); return
        }
        #expect(t.candidates.contains("here are"))
    }

    @Test func aWordStartingInsideAWaitingGroupWaitsForItsChoice() {
        // "ye spklease" waits as a pair; "spklease go" would split it: the pair is chosen first.
        let f: (String) -> CorrectionFinding? = { stem in
            if stem.hasSuffix("ye spklease ") {
                return .ambiguous(AmbiguousTypo(misspelled: "ye spklease", candidates: ["yes please"], fallback: nil,
                                                deleteCount: 12, trailing: " "))
            }
            if stem.hasSuffix("spklease go ") {
                return .ambiguous(AmbiguousTypo(misspelled: "spklease go", candidates: ["spk lease go"], fallback: nil,
                                                deleteCount: 12, trailing: " "))
            }
            return nil
        }
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "ok", finding: f)
        _ = span.read(field: 1, before: "ok ye spklease ", finding: f)
        guard case .choose(let t)? = span.read(field: 1, before: "ok ye spklease go ", finding: f) else {
            Issue.record("expected a choice"); return
        }
        #expect(t.slots.map(\.misspelled) == ["ye spklease"])
        #expect(t.gaps == [" go"])
    }

    @Test func aGroupThatOnlyTookAFineWordAlongGivesWay() {
        let f: (String) -> CorrectionFinding? = { stem in
            if stem.hasSuffix("note th ") {
                return .ambiguous(AmbiguousTypo(misspelled: "note th", candidates: ["not the"], fallback: nil,
                                                deleteCount: 8, trailing: " ", leadIsSlip: false))
            }
            if stem.hasSuffix("th at ") {
                return .ambiguous(AmbiguousTypo(misspelled: "th at", candidates: ["that"], fallback: nil,
                                                deleteCount: 6, trailing: " "))
            }
            return nil
        }
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "a", finding: f)
        _ = span.read(field: 1, before: "a note th ", finding: f)
        #expect(span.read(field: 1, before: "a note th at ", finding: f) == nil)
        #expect(span.waitingWords == ["th at"])
    }

    @Test func cleanTextIsNeverResplit() {
        #expect(finder().finding(before: "there are still ", deferAmbiguous: true) == nil)
        #expect(finder().finding(before: "the rest ill ", deferAmbiguous: true) == nil)
    }

    @Test func segmentationsUseWordsOnly() {
        let words: Set<String> = ["there", "are", "still", "the", "rear", "a"]
        let s = CorrectionFinder.segmentations("therearestill", counts: 2...4, isWord: { words.contains($0) })
        #expect(s.contains(["there", "are", "still"]))
        #expect(s.allSatisfy { $0.joined() == "therearestill" })
    }
}

