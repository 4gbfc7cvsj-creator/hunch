import Foundation
import Testing
@testable import HunchText

// The personal slip list: words the user often mistypes, in whatever way, are offered and cost less.

private struct TableSuggester: CorrectionSuggesting {
    var table: [String: CorrectionOptions] = [:]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word]?.confident }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
    func completions(forPrefix prefix: String, languages: [String]) -> [String] { [] }
}

private let dictionary = FakeSpell(["i", "am", "the", "still", "till", "stage", "autocorrect", "strength", "is",
                                    "here", "and", "stall", "stole", "stile", "more", "mire", "a"])

private let profile = SlipProfile(words: ["still": [], "stage": [], "autocorrect": [], "strength": ["strenght"]])

private func finder(_ table: [String: CorrectionOptions] = [:], profile: SlipProfile? = profile) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: dictionary, suggester: TableSuggester(table: table), languages: ["en"],
                             knownWords: [], guesser: StubGuesser([:], default: ("en", 0.9)),
                             isCommonWord: { ["i", "am", "the", "still", "till", "is", "here", "and", "more", "a"].contains($0) },
                             isEverydayWord: { ["i", "am", "the", "still", "is", "here", "and", "more", "a"].contains($0) })
    f.slipProfile = profile
    return f
}

struct SlipProfileTests {
    @Test func differentGarblesOfOneTroubleWordAllReachIt() {
        for typed in ["stil", "stuioill", "sitll"] {
            #expect(profile.candidates(for: typed).first?.word == "still", "\(typed)")
        }
        #expect(profile.candidates(for: "tsage").first?.word == "stage")
        #expect(profile.candidates(for: "aotucorrec").first?.word == "autocorrect")
        #expect(profile.candidates(for: "autocroect").first?.word == "autocorrect")
    }

    @Test func farWordsAndShortWordsGetNothing() {
        #expect(profile.candidates(for: "sxqzvw").isEmpty)
        #expect(profile.candidates(for: "stl").isEmpty)  // under 4 letters
        #expect(SlipProfile(words: [:]).candidates(for: "stil").isEmpty)
    }

    @Test func aTroubleWordCostsLessAndAKnownSlipLeast() {
        let plain = SlipCost.cost(typed: "strentght", candidate: "strength")
        #expect(profile.cost(typed: "strentght", candidate: "strength") < plain)
        #expect(profile.scale(typed: "strenght", candidate: "strength") == SlipProfile.exactScale)
        #expect(profile.scale(typed: "strentght", candidate: "strength") == SlipProfile.troubleScale)
        #expect(profile.scale(typed: "teh", candidate: "the") == 1)
    }

    @Test func aGarbleNothingElseReachesBecomesAStrictModelChoice() {
        // No checker guess, no edit, under the 8-letter dictionary search: only the slip list has it.
        #expect(finder(profile: nil).finding(before: "i am stuioill ", deferAmbiguous: true) == nil)
        guard case .ambiguous(let t)? = finder().finding(before: "i am stuioill ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.first == "still")
        #expect(t.margin == CorrectionFinder.strictMargin)
        #expect(t.preferred == nil)
        #expect(t.personal == profile)
    }

    @Test func aTroubleWordJoinsTheOtherCandidatesFirst() {
        let f = finder(["stil": CorrectionOptions(confident: nil, guesses: ["stile"])])
        guard case .ambiguous(let t)? = f.finding(before: "i am stil ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.first == "still")
    }

    @Test func aTroubleWordRivalsTheConfidentFix() {
        let table = ["stil": CorrectionOptions(confident: "stile", guesses: [])]
        guard case .ambiguous(let t)? = finder(table).finding(before: "i am stil ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.prefix(2) == ["stile", "still"])  // the trouble word is the first rival
        #expect(t.preferred == "stile")
    }

    @Test func aKnownSlipIsTheDefaultFix() {
        guard case .ambiguous(let t)? = finder().finding(before: "the strenght ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.preferred == "strength")
        #expect(t.fallback == "strength")
        // Without the model, the known slip is fixed.
        let trigger = StretchTrigger(before: "the strenght ", head: "the ", slots: [t], gaps: [" "], tail: "")
        #expect(JointChoice.resolve(trigger, combos: [], scores: nil).fix?.replacement == "strength")
    }

    @Test func aCorrectlySpelledWordIsNeverPulledToATroubleWord() {
        // "till" and "stall" are words: the slip list never questions them.
        for text in ["i am here till ", "i am stall ", "the more "] {
            #expect(finder().finding(before: text, deferAmbiguous: true)
                == finder(profile: nil).finding(before: text, deferAmbiguous: true), "\(text)")
        }
    }

    @Test func casingFollowsTheTypedWord() {
        guard case .ambiguous(let t)? = finder().finding(before: "Stuioill ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.candidates.first == "Still")
    }

    @Test func theModelRanksATroubleWordAheadOfAnEquallyCheapCandidate() {
        var slot = AmbiguousTypo(misspelled: "mroe", candidates: ["mire", "more"], fallback: nil, deleteCount: 5, trailing: " ")
        slot.personal = SlipProfile(words: ["more": []])
        #expect(JointChoice.candidateCosts(slot)[1] == 0)
        #expect(JointChoice.rankedOptions(slot) == [0, 2, 1])
    }
}

struct FixKeptWatchTests {
    @Test func typingOnPastTheFixKeepsIt() {
        var w = FixRejectionWatch<Int>()
        w.fixApplied(field: 1, beforeFix: "the strenght ", word: "strenght", fix: "strength", trailing: " ")
        #expect(w.update(field: 1, before: "the strength ") == nil)
        #expect(w.takeKept() == nil)
        #expect(w.update(field: 1, before: "the strength of") == nil)
        let kept = w.takeKept()
        #expect(kept?.word == "strenght" && kept?.fix == "strength")
        #expect(w.takeKept() == nil)  // once
    }

    @Test func anUndoneFixIsNotKept() {
        var w = FixRejectionWatch<Int>()
        w.fixApplied(field: 1, beforeFix: "the strenght ", word: "strenght", fix: "strength", trailing: " ")
        w.undone(field: 1, word: "strenght")
        #expect(w.update(field: 1, before: "the strenght ") == nil)
        #expect(w.update(field: 1, before: "the strenght of") == "strenght")
        #expect(w.lastRejectedFix == "strength")
        #expect(w.takeKept() == nil)
    }

    @Test func deletingThePastSentenceIsNotKept() {
        var w = FixRejectionWatch<Int>()
        w.fixApplied(field: 1, beforeFix: "the strenght ", word: "strenght", fix: "strength", trailing: " ")
        #expect(w.update(field: 1, before: "the ") == nil)
        #expect(w.takeKept() == nil)
    }
}
