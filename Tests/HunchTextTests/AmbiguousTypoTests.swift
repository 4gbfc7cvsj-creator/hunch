import Foundation
import Testing
@testable import HunchText

/// The system as probed for "fo": no confident correction, guesses "to", "of", "do", "go".
private struct OptionsSuggester: CorrectionSuggesting {
    var table: [String: CorrectionOptions] = [
        "fo": CorrectionOptions(confident: nil, guesses: ["to", "of", "do", "go"]),
        "ot": CorrectionOptions(confident: "to", guesses: ["to", "or", "it"]),
        "teh": CorrectionOptions(confident: "the", guesses: ["the", "ten"]),
        "thier": CorrectionOptions(confident: nil, guesses: ["their", "thieve"]),
        "zzq": CorrectionOptions(confident: nil, guesses: []),
    ]
    /// Like the system suggester: the confident correction, else the first guess.
    func correction(for word: String, context: String, languages: [String]) -> String? {
        table[word]?.confident ?? table[word]?.guesses.first
    }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
}

private let words = ["to", "of", "do", "go", "for", "fox", "foe", "the", "their", "ten", "or", "it", "i", "need",
                     "a", "cup", "tea", "thanks", "ui", "is", "so"]
private let spell = FakeSpell(words)
private let common: Set<String> = ["to", "of", "do", "go", "for", "fox", "the", "their", "ten", "or", "it", "so"]

private func finder(known: Set<String> = []) -> CorrectionFinder {
    CorrectionFinder(spellChecker: spell, suggester: OptionsSuggester(), languages: ["en"], knownWords: known,
                     guesser: StubGuesser([:], default: ("en", 0.9)), isCommonWord: { common.contains($0) })
}

struct AmbiguousTypoFindingTests {
    @Test func twoLetterWordWaitsWithGuessesAndOneEditWords() throws {
        guard case .ambiguous(let typo) = finder().finding(before: "I need fo ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.misspelled == "fo")
        #expect(Array(typo.candidates.prefix(4)) == ["to", "of", "do", "go"])
        #expect(typo.candidates.contains("for"))
        #expect(!typo.candidates.contains("fo"))
        #expect(!typo.candidates.contains("foe"))  // not common
        #expect(typo.fallback == "to")
        #expect(typo.deleteCount == 3)
        #expect(typo.trailing == " ")
    }

    @Test func withoutDeferringTwoLetterWordsAreStillIgnored() {
        #expect(finder().finding(before: "I need fo ", deferAmbiguous: false) == nil)
        #expect(finder().proposal(before: "I need fo ") == nil)
    }

    @Test func confidentCorrectionWithAnEquallyLikelyRivalWaitsWithItAsTheDefault() {
        // "ten" (h for its neighbour n) is as cheap a slip as "the" (swap): the model chooses,
        // "the" unless it clearly prefers another word.
        guard case .ambiguous(let typo) = finder().finding(before: "say teh ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.preferred == "the")
        #expect(typo.candidates.first == "the")
        #expect(typo.candidates.contains("ten"))
        // Without deferring it is fixed at once, as before.
        #expect(finder().proposal(before: "say teh ")?.replacement == "the")
    }

    @Test func confidentCorrectionOfTwoLetterWordStillWaitsButGoesFirst() {
        guard case .ambiguous(let typo) = finder().finding(before: "go ot ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.candidates.first == "to")
        #expect(typo.fallback == "to")
    }

    @Test func guessesOnlyLongerWordWaits() {
        guard case .ambiguous(let typo) = finder().finding(before: "with thier ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.candidates.first == "their")
        // Without deferring the first plausible guess is fixed right away, as before.
        #expect(finder().proposal(before: "with thier ")?.replacement == "their")
    }

    @Test func nothingToChooseIsNothing() {
        #expect(finder().finding(before: "a zzq ", deferAmbiguous: true) == nil)
    }

    @Test func caseFollowsSentenceStart() {
        guard case .ambiguous(let typo) = finder().finding(before: "Fo ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.misspelled == "Fo")
        #expect(typo.candidates.contains("For"))
    }

    @Test func editCandidatesCoverTheUsualSlips() {
        let f = CorrectionFinder(spellChecker: spell, suggester: OptionsSuggester(), languages: ["en"],
                                 knownWords: [], guesser: StubGuesser([:], default: ("en", 0.9)))
        let edits = f.editCandidates(for: "fo")
        #expect(edits.contains("for"))   // left out
        #expect(edits.contains("of"))    // swapped
        #expect(edits.contains("do"))    // neighbouring key
        #expect(!edits.contains("so"))   // s is not next to f
    }
}

struct TypoChoiceTests {
    @Test func clearWinnerIsFixed() {
        #expect(TypoChoice.decide(candidates: ["for", "of"], scores: [-20, -5, -9]) == .fix("for"))
    }

    @Test func closeCallIsOnlyOffered() {
        #expect(TypoChoice.decide(candidates: ["for", "of"], scores: [-20, -5, -6]) == .unsure("for"))
    }

    @Test func typedWordCloseToWinnerIsOnlyOffered() {
        #expect(TypoChoice.decide(candidates: ["for"], scores: [-6, -5]) == .unsure("for"))
    }

    @Test func typedWordWinningIsKept() {
        #expect(TypoChoice.decide(candidates: ["for", "of"], scores: [-3, -5, -9]) == .keep)
    }

    @Test func mismatchedScoresKeep() {
        #expect(TypoChoice.decide(candidates: ["for", "of"], scores: [-3]) == .keep)
    }
}

/// Undo a fix later: the menu under a fixed word offers the other words it could have been.
struct FixAlternativesTests {
    @Test func otherCandidatesLeaveOutTheFixAndTheTypedWord() {
        let others = finder().alternatives(for: "fo", head: "I need ", current: "to")
        #expect(!others.isEmpty)
        #expect(!others.contains("to"))
        #expect(!others.contains("fo"))
        #expect(others.first == "of")
        #expect(others.count <= 4)
    }

    @Test func confidentFixStillOffersTheSystemsGuesses() {
        let others = finder().alternatives(for: "teh", head: "a cup of ", current: "the")
        #expect(others.contains("ten"))
        #expect(!others.contains("the"))
    }

    @Test func casingFollowsTheTypedWord() {
        let others = finder().alternatives(for: "Teh", head: "", current: "The")
        #expect(others.contains("Ten"))
    }

    @Test func noAlternativesForAStretch() {
        #expect(finder().alternatives(for: "fo teh", head: "", current: "of the").isEmpty)
    }
}
