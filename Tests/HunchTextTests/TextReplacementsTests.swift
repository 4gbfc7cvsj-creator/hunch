import Foundation
import Testing
@testable import HunchText

/// macOS Text Replacements: shortcuts are never typos; applied only where chosen. Entries are made up.
private struct NoGuessSuggester: CorrectionSuggesting {
    private let table = ["adn": "and", "teh": "the"]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word] }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        CorrectionOptions(confident: table[word], guesses: [])
    }
}

private let spell = FakeSpell(["the", "and", "on", "my", "way", "i", "am"])
private let list = TextReplacements(["adn": "see you at the hall", "qxr": "Alex Morgan", "multi": "a\nb"])

private func finder(_ replacements: TextReplacements, applies: Bool) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: NoGuessSuggester(), languages: ["en"], knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)))
    f.textReplacements = replacements
    f.appliesReplacements = applies
    return f
}

struct TextReplacementsTests {
    @Test func parsesEnabledItemsOnly() {
        let items: [[String: Any]] = [
            ["on": 1, "replace": "adn", "with": "one"],
            ["on": 0, "replace": "off", "with": "two"],
            ["replace": "nokey", "with": "three"],
            ["on": 1, "replace": "bad"],
        ]
        let parsed = TextReplacements.parse(items: items)
        #expect(parsed.entries == ["adn": "one", "nokey": "three"])
    }

    @Test func shortcutIsNotATypoAndWithoutApplyingNothingHappens() {
        // Without the list the system would "fix" the unknown word.
        #expect(finder(.empty, applies: false).proposal(before: "I am adn ") != nil)
        let f = finder(list, applies: true)
        #expect(finder(list, applies: false).proposal(before: "I am adn ") == nil)
        #expect(finder(list, applies: false).finding(before: "I am adn ", deferAmbiguous: true) == nil)
        // The struck-through (non-automatic) path never applies a replacement either.
        #expect(f.proposal(before: "I am adn ") == nil)
    }

    @Test func protectionIgnoresCase() {
        #expect(finder(list, applies: false).finding(before: "I am Adn ", deferAmbiguous: true) == nil)
        // Case-sensitive like the system: the capitalised shortcut is not replaced.
        #expect(finder(list, applies: true).finding(before: "I am Adn ", deferAmbiguous: true) == nil)
    }

    @Test func appliedWhereChosenWithFixAutomatically() {
        let f = finder(list, applies: true)
        guard case .fix(let p)? = f.finding(before: "I am adn ", deferAmbiguous: true) else {
            Issue.record("expected a fix"); return
        }
        #expect(p.misspelled == "adn" && p.replacement == "see you at the hall")
        #expect(p.deleteCount == 4 && p.trailing == " ")
        guard case .fix(let q)? = f.finding(before: "ok qxr, ", deferAmbiguous: true) else {
            Issue.record("expected a fix"); return
        }
        #expect(q.replacement == "Alex Morgan" && q.trailing == ", ")
    }

    @Test func notAppliedWhenTheHostDoesIt() {
        #expect(finder(list, applies: false).finding(before: "I am adn ", deferAmbiguous: true) == nil)
        #expect(HostTextReplacements.appliesItself(bundleID: "com.apple.TextEdit"))
        #expect(!HostTextReplacements.appliesItself(bundleID: "com.google.Chrome"))
    }

    @Test func noDoubleApply() {
        // The host already replaced it: the text no longer holds the shortcut, so there is no fix.
        let f = finder(list, applies: true)
        #expect(f.finding(before: "I am Alex Morgan ", deferAmbiguous: true) == nil)
    }

    @Test func multiLineReplacementsAreProtectedButNotApplied() {
        let f = finder(list, applies: true)
        #expect(f.finding(before: "I am multi ", deferAmbiguous: true) == nil)
    }

    @Test func otherWordsAreStillFixed() {
        #expect(finder(list, applies: true).proposal(before: "I am teh ") != nil)
    }
}
