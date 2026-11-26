import Foundation
import Testing
@testable import HunchText

/// A word at the start of a sentence that the spell checker or the model corrects comes out
/// capitalized in the same step ("ye" → "Yes"), on every path, only with Auto-capitalization on.
/// What was typed stays untouched in the fix, so undo gives back "ye".
private struct Suggester: CorrectionSuggesting {
    var table: [String: CorrectionOptions] = [
        "ye": CorrectionOptions(confident: "yes", guesses: ["yes", "yet"]),
        "teh": CorrectionOptions(confident: "the", guesses: ["the", "ten"]),
        "wrold": CorrectionOptions(confident: "world", guesses: ["world"]),
        "dont": CorrectionOptions(confident: nil, guesses: []),
    ]
    func correction(for word: String, context: String, languages: [String]) -> String? {
        table[word]?.confident ?? table[word]?.guesses.first
    }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
}

private let spell = FakeSpell(["yes", "yet", "the", "ten", "world", "dont", "is", "good", "please", "so", "i"])
private let common: Set<String> = ["yes", "yet", "the", "ten", "world", "is", "good", "please", "so"]

private func finder(caps: Bool = true) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: Suggester(), languages: ["en"], knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)), isCommonWord: { common.contains($0) })
    f.fixesCapitals = caps
    f.fixesPunctuation = true
    return f
}

struct SentenceStartFixTests {
    // Path 1: the instant fix (Tab path and "Fix automatically" with a confident word).
    @Test func instantFix() {
        #expect(finder().proposal(before: "teh ")?.replacement == "The")
        #expect(finder().proposal(before: "Nice. teh ")?.replacement == "The")
        #expect(finder().proposal(before: "Nice.\nteh ")?.replacement == "The")
        #expect(finder().proposal(before: "Nice. dont ")?.replacement == "Don't")
        // Mid-sentence, with the switch off, or after an abbreviation: as before.
        #expect(finder().proposal(before: "say teh ")?.replacement == "the")
        #expect(finder(caps: false).proposal(before: "teh ")?.replacement == "the")
        #expect(finder().proposal(before: "Ask Dr. teh ")?.replacement == "the")
        // The typed word is kept as typed (undo).
        #expect(finder().proposal(before: "teh ")?.misspelled == "teh")
    }

    @Test func deferredConfidentFix() {
        guard case .fix(let p)? = finder().finding(before: "Hi. wrold ", deferAmbiguous: true) else {
            Issue.record("expected fix"); return
        }
        #expect(p.replacement == "World")
        #expect(p.misspelled == "wrold")
        guard case .fix(let mid)? = finder().finding(before: "Hi my wrold ", deferAmbiguous: true) else {
            Issue.record("expected fix"); return
        }
        #expect(mid.replacement == "world")
    }

    // Path 2: the model chooses among candidates; the settled or deferred fix goes through `resolve`.
    @Test func modelChoice() throws {
        guard case .ambiguous(let typo)? = finder().finding(before: "ye ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.capitalizesFirst)
        #expect(typo.misspelled == "ye")
        let trigger = StretchTrigger(before: "ye please ", head: "", slots: [typo], gaps: [" please "], tail: "")
        let combos = JointChoice.combos([typo])
        // The model clearly prefers candidate "yes" over the word as typed and the others.
        let scores = combos.map { combo -> Float in combo[0] > 0 && typo.candidates[combo[0] - 1] == "yes" ? 0 : -30 }
        let r = JointChoice.resolve(trigger, combos: combos, scores: scores)
        #expect(r.fix?.replacement == "Yes")
        #expect(r.fix?.word == "ye")  // the typed text, so undo gives back "ye" and not "Ye"
    }

    @Test func withoutModelAndOffers() {
        guard case .ambiguous(let typo)? = finder().finding(before: "Ok. ye ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        let trigger = StretchTrigger(before: "Ok. ye please ", head: "Ok. ", slots: [typo], gaps: [" please "], tail: "")
        let none = JointChoice.resolve(trigger, combos: [], scores: nil)
        if let p = typo.preferred {
            #expect(none.fix?.replacement.hasPrefix(p.prefix(1).uppercased()) == true)
        } else {
            #expect(none.offer?.pick.first?.isUppercase == true)
        }
        // A close call (the model is unsure) is offered with the capital too.
        var slot = typo
        slot.preferred = nil
        let t2 = StretchTrigger(before: "Ok. ye please ", head: "Ok. ", slots: [slot], gaps: [" please "], tail: "")
        let combos = JointChoice.combos([slot])
        let flat = combos.map { _ in Float(-1) }
        let r = JointChoice.resolve(t2, combos: combos, scores: flat)
        #expect(r.fix == nil || r.fix?.replacement.first?.isUppercase == true)
    }

    @Test func notFlaggedWhenOffOrMidSentence() {
        if case .ambiguous(let a)? = finder(caps: false).finding(before: "ye ", deferAmbiguous: true) {
            #expect(!a.capitalizesFirst)
        }
        if case .ambiguous(let b)? = finder().finding(before: "so ye ", deferAmbiguous: true) {
            #expect(!b.capitalizesFirst)
        }
    }

    // Path 3: a word picked from the underline menu.
    @Test func menuAlternatives() {
        let alts = finder().alternatives(for: "teh", head: "Wait. ", current: "The")
        #expect(alts.contains("Ten"))
        #expect(!alts.contains("ten"))
        #expect(finder(caps: false).alternatives(for: "teh", head: "Wait. ", current: "the").contains("ten"))
        #expect(finder().alternatives(for: "teh", head: "so ", current: "the").contains("ten"))
    }
}
