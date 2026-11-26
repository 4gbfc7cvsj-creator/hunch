import Foundation
import Testing
@testable import HunchText

private struct FakeSuggester: CorrectionSuggesting {
    var table: [String: String] = ["recieve": "receive", "teh": "the", "wierd": "weird", "adress": "Address"]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word] }
}

private struct NilSuggester: CorrectionSuggesting {
    func correction(for word: String, context: String, languages: [String]) -> String? { nil }
}

private let english = StubGuesser([:], default: ("en", 0.9))
private let dict = FakeSpell(["receive", "the", "weird", "address", "i", "hello", "world", "please", "this", "that"])

private func finder(known: Set<String> = [], suggester: any CorrectionSuggesting = FakeSuggester(),
                    guesser: any LanguageGuessing = english) -> CorrectionFinder {
    CorrectionFinder(spellChecker: dict, suggester: suggester, languages: ["en"], knownWords: known, guesser: guesser)
}

struct CorrectionFinderTests {
    @Test func wordPlusSpace() {
        let p = finder().proposal(before: "I recieve ")
        #expect(p == CorrectionProposal(misspelled: "recieve", replacement: "receive", deleteCount: 8, trailing: " "))
    }

    @Test func noBreakSpaceFromWebEditorsCountsAsFinished() {
        let p = finder().proposal(before: "I recieve\u{00A0}")
        #expect(p?.replacement == "receive")
        #expect(p?.deleteCount == 8)
        #expect(p?.trailing == "\u{00A0}")
    }

    @Test func wordAtCaretIsStillBeingTyped() {
        // No fix until the word is finished; then it is offered with the space re-typed.
        #expect(finder().proposal(before: "I said teh") == nil)
        #expect(finder().proposal(before: "I said teh ")
            == CorrectionProposal(misspelled: "teh", replacement: "the", deleteCount: 4, trailing: " "))
    }

    @Test func midSentence() {
        #expect(finder().proposal(before: "please say teh ")?.replacement == "the")
    }

    @Test func punctuation() {
        let p = finder().proposal(before: "Well, I recieve, ")
        #expect(p?.trailing == ", ")
        #expect(p?.deleteCount == 9)
        #expect(p?.replacement == "receive")
        #expect(finder().proposal(before: "I recieve.")?.trailing == ".")
    }

    @Test func caseFollowsUser() {
        // Suggester answers "Address" for a lowercase word: lowercase is kept.
        #expect(finder().proposal(before: "the adress ")?.replacement == "address")
    }

    @Test func learnedWordPreferredWithItsCase() {
        let p = finder(known: ["Kubernetes"], suggester: NilSuggester()).proposal(before: "deploy to kuberentes ")
        #expect(p?.replacement == "Kubernetes")
        #expect(p?.deleteCount == 11)
    }

    @Test func learnedBeatsSystem() {
        let s = FakeSuggester(table: ["recieve": "receive"])
        #expect(finder(known: ["recievee"], suggester: s).proposal(before: "I recieve ")?.replacement == "recievee")
    }

    @Test func learnedWordFromThisAppBeatsCloserOneFromAnother() {
        // "kubactl" (this app) is 2 away from "kubectx", "kubectl" (another app) 1 away: this app's
        // word wins; with no preference the closer one does.
        var f = finder(known: ["kubactl", "kubectl"], suggester: NilSuggester())
        #expect(f.proposal(before: "run kubectx ")?.replacement == "kubectl")
        f.learnedHere = ["kubactl"]
        #expect(f.proposal(before: "run kubectx ")?.replacement == "kubactl")
    }

    @Test func learnedWordFromAnotherAppIsTheFallback() {
        var f = finder(known: ["Kubernetes", "Zorblax"], suggester: NilSuggester())
        f.learnedHere = ["zorblax"]
        #expect(f.proposal(before: "deploy to kuberentes ")?.replacement == "Kubernetes")
        f.learnedHere = []
        #expect(f.proposal(before: "deploy to kuberentes ")?.replacement == "Kubernetes")
    }

    @Test func learnedWordFromAnotherAppStillCountsAsSpelledRight() {
        var f = CorrectionFinder(spellChecker: FakeSpell(["kubernetes"]), suggester: FakeSuggester(),
                                 languages: ["en"], knownWords: ["Kubernetes"], guesser: english)
        f.learnedHere = []
        #expect(f.proposal(before: "deploy to kubernetes ") == nil)
    }

    @Test func fixConfidenceUsesCommonAndLearnedWords() {
        let f = CorrectionFinder(spellChecker: FakeSpell(["kubernetes"]), suggester: FakeSuggester(),
                                 languages: ["en"], knownWords: ["Kubernetes"], guesser: english,
                                 isCommonWord: { ["the", "file"].contains($0) })
        #expect(f.confidence(typed: "teh", fixed: "the") == .sure)
        #expect(f.confidence(typed: "kuberentes", fixed: "Kubernetes") == .sure)
        #expect(f.confidence(typed: "gguf", fixed: "gruff") == .unsure)
        // No common-word list: nothing to tell by, sure.
        let plain = CorrectionFinder(spellChecker: FakeSpell([]), suggester: FakeSuggester(), languages: ["en"],
                                     knownWords: [], guesser: english)
        #expect(plain.confidence(typed: "gguf", fixed: "gruff") == .sure)
    }

    @Test func guardsReturnNil() {
        let f = finder()
        #expect(f.proposal(before: "I met Recieve ") == nil)      // capitalized
        #expect(f.proposal(before: "the NASAA ") == nil)          // acronym
        #expect(f.proposal(before: "call getRecieve ") == nil)    // camelCase
        #expect(f.proposal(before: "see foo_recieve ") == nil)    // code
        #expect(f.proposal(before: "open a/recieve ") == nil)
        #expect(f.proposal(before: "我喜欢苹果 ") == nil)          // CJK
        #expect(f.proposal(before: "that was lol ") == nil)       // slang
        #expect(f.proposal(before: "hello world ") == nil)        // correct
        #expect(f.proposal(before: "recieve") == nil)             // still being typed
        #expect(f.proposal(before: "recieve  ") == nil)           // two spaces: word no longer just typed
        #expect(f.proposal(before: "") == nil)
        #expect(f.proposal(before: "I recieve (") == nil)
    }

    @Test func knownWordIsNotATypo() {
        #expect(finder(known: ["recieve"]).proposal(before: "I recieve ") == nil)
    }

    @Test func singleWordLanguageGuessIsIgnored() {
        // Typos are often guessed as another language ("tihs" → Indonesian); only the spell
        // checker decides, like the system underline.
        let spanish = StubGuesser([:], default: ("es", 0.95))
        #expect(finder(guesser: spanish).proposal(before: "I recieve ")?.replacement == "receive")
        let spell = LanguageSpell(["en": ["i", "amino"], "es": ["amigo"]])
        func make(_ languages: [String]) -> CorrectionFinder {
            CorrectionFinder(spellChecker: spell, suggester: FakeSuggester(table: ["amigo": "amino"]),
                             languages: languages, knownWords: [], guesser: StubGuesser([:], default: ("es", 0.9)))
        }
        #expect(make(["en"]).proposal(before: "hi amigo ")?.replacement == "amino")
        #expect(make(["en", "es"]).proposal(before: "hi amigo ") == nil)
    }

    @Test func foreignSentenceIsLeftAlone() {
        let spanish = StubGuesser([:], default: ("es", 0.95))
        #expect(finder(guesser: spanish).proposal(before: "Hola, me gustaria hablar sobre el proyecto recieve ") == nil)
    }

    @Test func noSuggestionOrBadSuggestion() {
        #expect(finder(suggester: NilSuggester()).proposal(before: "I recieve ") == nil)
        let bad = FakeSuggester(table: ["recieve": "recieve"])
        #expect(finder(suggester: bad).proposal(before: "I recieve ") == nil)
        let misspelledFix = FakeSuggester(table: ["recieve": "recieeve"])
        #expect(finder(suggester: misspelledFix).proposal(before: "I recieve ") == nil)
        let spaced = FakeSuggester(table: ["recieve": "re ceive"])
        #expect(finder(suggester: spaced).proposal(before: "I recieve ") == nil)
        let empty = FakeSuggester(table: ["recieve": ""])
        #expect(finder(suggester: empty).proposal(before: "I recieve ") == nil)
    }

    @Test func unknownCheckerAnswerIsNil() {
        struct Timeout: UncertainSpellChecking {
            func isMisspelled(_ word: String, languages: [String]) -> Bool { lookupMisspelled(word, languages: languages) ?? false }
            func isKnownPrefix(_ partial: String, languages: [String]) -> Bool { true }
            func lookupMisspelled(_ word: String, languages: [String]) -> Bool? { nil }
            func lookupKnownPrefix(_ partial: String, languages: [String]) -> Bool? { nil }
        }
        let f = CorrectionFinder(spellChecker: CachedSpellChecker(Timeout()), suggester: FakeSuggester(),
                                 languages: ["en"], knownWords: [], guesser: english)
        #expect(f.proposal(before: "I recieve ") == nil)
    }

    @Test func editDistance() {
        #expect(EditDistance.osa("teh", "the") == 1)
        #expect(EditDistance.osa("kitten", "sitting") == 3)
        #expect(EditDistance.isTransposition("teh", "the"))
        #expect(!EditDistance.isTransposition("teh", "tea"))
        #expect(EditDistance.isPlausibleGuess("receive", for: "recieve"))
        #expect(!EditDistance.isPlausibleGuess("believe", for: "recieve"))
        #expect(CorrectionFinder.matchCase("the", to: "Teh") == "The")
        #expect(CorrectionFinder.matchCase("The", to: "teh") == "the")
    }

    @Test func lruSuggesterCachesTimeoutsNot() {
        #if canImport(AppKit)
        let s = SystemCorrectionSuggester()
        s.mainWaitTimeout = .milliseconds(1)
        // Called off-main with a busy-free main thread this may or may not answer; it must not crash.
        _ = s.correction(for: "recieve", context: "I recieve", languages: ["en"])
        #endif
    }

    @Test func realCheckerSmoke() {
        #if canImport(AppKit)
        let s = SystemCorrectionSuggester()
        s.mainWaitTimeout = .seconds(2)
        let words = ["recieve", "teh", "wierd", "definately", "seperate", "becuase"]
        let got = words.map { ($0, s.correction(for: $0, context: "I think " + $0, languages: ["en"])) }
        print("SMOKE", got)
        #endif
    }
}

struct CorrectionFinderSplitAndCapsTests {
    private let words = FakeSpell(["moments", "ago", "the", "receive", "i", "said", "see", "you", "soon"])
    private func make(_ suggest: [String: String] = [:]) -> CorrectionFinder {
        CorrectionFinder(spellChecker: words, suggester: MapSuggester(map: suggest), languages: ["en"],
                         knownWords: [], guesser: english)
    }

    @Test func runTogetherWordsSplitWhenTheSystemOffersNothing() {
        #expect(make().proposal(before: "a few momentsago ")?.replacement == "moments ago")
    }

    @Test func systemSplitSuggestionIsAccepted() {
        #expect(make(["seeyou": "see you"]).proposal(before: "ok seeyou ")?.replacement == "see you")
    }

    @Test func sentenceStartCapitalIsChecked() {
        #expect(make(["teh": "the"]).proposal(before: "Done. Teh ")?.replacement == "The")
        #expect(make(["teh": "the"]).proposal(before: "Teh ")?.replacement == "The")
        // Mid-sentence capital: a name, left alone.
        #expect(make(["teh": "the"]).proposal(before: "I said Teh ") == nil)
    }

    @Test func oneEditGuessMayChangeTheFirstLetter() {
        #expect(EditDistance.isPlausibleGuess("receive", for: "deceive") == true)
        #expect(EditDistance.isPlausibleGuess("receive", for: "xexeive") == false)
        #expect(EditDistance.isPlausibleGuess("moments ago", for: "momentsago") == true)
        #expect(EditDistance.isPlausibleGuess("mom ents ago", for: "momentsago") == false)
    }
}

private struct MapSuggester: CorrectionSuggesting {
    let map: [String: String]
    func correction(for word: String, context: String, languages: [String]) -> String? { map[word] }
}

@Test func typoShapeSeparatesSlipsFromUnknownTerms() {
    #expect(TypoShape.isSlip("dont", fixedTo: "don't"))
    #expect(TypoShape.isSlip("teh", fixedTo: "the"))
    #expect(TypoShape.isSlip("definately", fixedTo: "definitely"))
    #expect(!TypoShape.isSlip("nightowl", fixedTo: "night owl"))   // a split: a new term, not a slip
    #expect(!TypoShape.isSlip("zorblax", fixedTo: "zebra"))
    #expect(!TypoShape.isSlip("bread", fixedTo: "brand"))
    #expect(!TypoShape.isSlip("kubernetes", fixedTo: "kubernetes"))
}

@Test func likelyTypoOfLearnedWord() {
    let everyday: (String) -> Bool = { ["the", "still", "open", "sunday"].contains($0) }
    #expect(TypoShape.isLikelyTypo("stil", fixedTo: "still", isEveryday: everyday))
    #expect(TypoShape.isLikelyTypo("teh", fixedTo: "the", isEveryday: everyday))
    #expect(TypoShape.isLikelyTypo("doesn", fixedTo: "doesn't", isEveryday: everyday))   // cut-off contraction
    #expect(TypoShape.isLikelyTypo("doesn", fixedTo: "doesn’t", isEveryday: everyday))
    // A missing apostrophe is the writer's style.
    #expect(!TypoShape.isLikelyTypo("dont", fixedTo: "don't", isEveryday: { _ in true }))
    #expect(!TypoShape.isLikelyTypo("ive", fixedTo: "I've", isEveryday: { _ in true }))
    // Rarer fixes, capitals only, splits and far fixes leave the word learnable.
    #expect(!TypoShape.isLikelyTypo("cyberware", fixedTo: "cyberwar", isEveryday: everyday))
    #expect(!TypoShape.isLikelyTypo("clawd", fixedTo: "claws", isEveryday: everyday))
    #expect(!TypoShape.isLikelyTypo("sunday", fixedTo: "Sunday", isEveryday: everyday))
    #expect(!TypoShape.isLikelyTypo("openai", fixedTo: "open", isEveryday: everyday))
    #expect(!TypoShape.isLikelyTypo("savekit", fixedTo: "save kit", isEveryday: everyday))
}

@Test func cutContractionShape() {
    #expect(TypoShape.isCutContraction("didn", fixedTo: "didn't"))
    #expect(TypoShape.isCutContraction("you", fixedTo: "you're"))
    #expect(!TypoShape.isCutContraction("dont", fixedTo: "don't"))
    #expect(!TypoShape.isCutContraction("doesn", fixedTo: "doesn'"))
    #expect(!TypoShape.isCutContraction("teh", fixedTo: "the"))
}
