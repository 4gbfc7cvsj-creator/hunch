import Foundation
import Testing
@testable import HunchText

/// Stage 4 of fast-typing autocorrect: the model scores whole combinations over the unsettled
/// stretch, with a keyboard-slip prior; confident system fixes become a default it can overrule.

// MARK: Keyboard-slip cost

struct SlipCostTests {
    private func cost(_ typed: String, _ meant: String) -> Float { SlipCost.cost(typed: typed, candidate: meant) }

    @Test func neighbouringKeysCostLessThanOthers() {
        #expect(cost("ten", "the") > 0)
        #expect(cost("tge", "the") < cost("tpe", "the"))   // g is by h, p is not
        #expect(cost("riught", "right") < cost("rizght", "right"))  // u is by i
        #expect(cost("sammple", "sample") < cost("saxmple", "sample"))  // doubled key
    }

    @Test func spacesAndApostrophesAreCheap() {
        #expect(cost("dont", "don't") < cost("dont", "dent"))
        #expect(cost("a s", "as") < cost("ass", "as") + 0.01)
        #expect(cost("ye spklease", "yes please") < 1.5)
        #expect(cost("canfix", "can fix") <= SlipCost.space)
    }

    @Test func caseDoesNotCount() {
        #expect(cost("Teh", "the") == cost("teh", "the"))
        #expect(cost("the", "the") == 0)
    }
}

// MARK: Combinations and decisions

struct JointChoiceTests {
    private func typo(_ word: String, _ candidates: [String], preferred: String? = nil,
                      margin: Float = TypoChoice.defaultMargin) -> AmbiguousTypo {
        AmbiguousTypo(misspelled: word, candidates: candidates, fallback: preferred ?? candidates.first,
                      deleteCount: word.count + 1, trailing: " ", margin: margin, preferred: preferred)
    }

    @Test func oneWordScoresAllItsCandidates() {
        let slot = typo("fo", ["to", "of", "do", "go", "for"])
        #expect(JointChoice.combos([slot]).count == 6)
    }

    @Test func combinationsArePrunedToTheLimit() {
        let a = typo("fo", ["to", "of", "do", "go", "for", "so"])
        let b = typo("si", ["is", "so", "sit", "ski"])
        let combos = JointChoice.combos([a, b])
        #expect(combos.count <= JointChoice.maxJointCombos)
        #expect(combos.count == 9)
        #expect(combos.contains([0, 0]))  // both as typed
        let three = JointChoice.combos([a, b, typo("teh", ["the", "ten"])])
        #expect(three.count <= JointChoice.maxJointCombos)
        #expect(Set(three.map { $0[2] }).count >= 2)
    }

    @Test func thePreferredFixIsAlwaysScored() {
        let slot = typo("deply", ["reply", "deploy", "deeply"], preferred: "reply")
        let pair = typo("zz", ["a", "b", "c", "d", "e"])
        for combos in [JointChoice.combos([slot]), JointChoice.combos([pair, slot])] {
            #expect(combos.contains { $0.last == 1 })
        }
    }

    @Test func continuationJoinsPicksAndGaps() {
        let trigger = StretchTrigger(before: "x fo si sure ", head: "x ", slots: [typo("fo", ["for"]), typo("si", ["is"])],
                                     gaps: [" ", " sure"], tail: " ")
        #expect(JointChoice.continuation([1, 1], trigger) == "for is sure")
        #expect(JointChoice.continuation([0, 1], trigger) == "fo is sure")
    }

    @Test func adjacentTyposAreDecidedTogether() {
        // "fo si": alone, each word's best pick depends on the other; the joint best wins.
        let slots = [typo("fo", ["of", "for"]), typo("si", ["is", "so"])]
        let combos = JointChoice.combos(slots)
        let scores = combos.map { c -> Float in c == [2, 1] ? -4 : (c == [1, 2] ? -9 : -15) }
        #expect(JointChoice.decide(slots, combos: combos, scores: scores) == [.fix("for"), .fix("is")])
    }

    @Test func confidentFixStandsUnlessClearlyBeaten() {
        let slot = typo("thnk", ["thank", "think"], preferred: "thank")
        let combos = JointChoice.combos([slot])  // [typed, thank, think]
        func decide(_ s: [Float]) -> TypoChoice {
            let byIndex = combos.map { s[$0[0]] }
            return JointChoice.decide([slot], combos: combos, scores: byIndex)[0]
        }
        #expect(decide([-20, -8, -3]) == .fix("think"))  // think clearly better
        #expect(decide([-20, -8, -7]) == .fix("thank"))  // close: the system's fix stands
        #expect(decide([-20, -3, -9]) == .fix("thank"))
        #expect(decide([-4, -8, -9]) == .keep)          // typed clearly better (strict margin)
        #expect(decide([-6, -8, -9]) == .fix("thank"))
    }

    @Test func slipCostBreaksNearTies() {
        // "riught": right (an extra neighbouring key) vs. rough (two keys off) score the same.
        let slot = typo("riught", ["rough", "right"])
        let combos = JointChoice.combos([slot])
        let scores = combos.map { $0[0] == 0 ? Float(-30) : -5 }
        guard case .unsure(let pick) = JointChoice.decide([slot], combos: combos, scores: scores)[0] else {
            Issue.record("expected a close call"); return
        }
        #expect(pick == "right")
    }

    @Test func resolveMakesOneEditOverTheFixedWords() {
        let trigger = StretchTrigger(before: "a fo si sure x", head: "a ", slots: [typo("fo", ["for"]), typo("si", ["is"])],
                                     gaps: [" ", " sure"], tail: " x")
        let combos = JointChoice.combos(trigger.slots)
        let scores = combos.map { $0 == [1, 1] ? Float(-3) : -12 }
        let r = JointChoice.resolve(trigger, combos: combos, scores: scores)
        #expect(r.fix == SpanFix(before: "a fo si sure x", word: "fo si", replacement: "for is", tail: " sure x"))
        #expect(r.fix?.edit(now: "a fo si sure x")?.after == "a for is sure x")
    }

    @Test func resolveFixesOnlyTheSecondWord() {
        let trigger = StretchTrigger(before: "a fo si sure ", head: "a ", slots: [typo("fo", ["for"]), typo("si", ["is"])],
                                     gaps: [" ", " sure"], tail: " ")
        let combos = JointChoice.combos(trigger.slots)
        let scores = combos.map { $0 == [0, 1] ? Float(-3) : -12 }
        let r = JointChoice.resolve(trigger, combos: combos, scores: scores)
        #expect(r.fix == SpanFix(before: "a fo si sure ", word: "si", replacement: "is", tail: " sure "))
    }

    @Test func resolveFixesOnlyTheFirstWord() {
        let trigger = StretchTrigger(before: "a fo si sure x", head: "a ", slots: [typo("fo", ["for"]), typo("si", ["is"])],
                                     gaps: [" ", " sure"], tail: " x")
        let combos = JointChoice.combos(trigger.slots)
        let scores = combos.map { $0 == [1, 0] ? Float(-3) : -12 }
        let r = JointChoice.resolve(trigger, combos: combos, scores: scores)
        #expect(r.fix == SpanFix(before: "a fo si sure x", word: "fo", replacement: "for", tail: " si sure x"))
        #expect(r.fix?.edit(now: "a fo si sure xy")?.after == "a for si sure xy")
    }

    @Test func withoutTheModelTheConfidentFixStillGoesIn() {
        let trigger = StretchTrigger(before: "I thnk so ", head: "I ", slots: [typo("thnk", ["thank", "think"], preferred: "thank")],
                                     gaps: [" so"], tail: " ")
        let r = JointChoice.resolve(trigger, combos: JointChoice.combos(trigger.slots), scores: nil)
        #expect(r.fix?.replacement == "thank")
        let guess = StretchTrigger(before: "I fo so ", head: "I ", slots: [typo("fo", ["for"])], gaps: [" so"], tail: " ")
        let g = JointChoice.resolve(guess, combos: JointChoice.combos(guess.slots), scores: nil)
        #expect(g.fix == nil)
        #expect(g.offer?.pick == "for")
        #expect(g.offer?.span == "fo so ")
    }
}

// MARK: The stretch in UnsettledSpan

/// "fo", "si" and "ye" are flagged words; "spklease" is flagged with "ye" before it as a pair;
/// "teh" is a confident fix.
private func stretchFinding(_ stem: String) -> CorrectionFinding? {
    guard stem.last == " " else { return nil }
    let words = stem.dropLast().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    let word = words.last ?? ""
    func ambiguous(_ w: String, _ c: [String]) -> CorrectionFinding {
        .ambiguous(AmbiguousTypo(misspelled: w, candidates: c, fallback: c.first, deleteCount: w.count + 1, trailing: " "))
    }
    switch word {
    case "fo": return ambiguous("fo", ["for", "of"])
    case "si": return ambiguous("si", ["is", "so"])
    case "ye": return ambiguous("ye", ["yes", "yet"])
    case "spklease" where words.dropLast().last == "ye": return ambiguous("ye spklease", ["yes please"])
    case "teh": return .fix(CorrectionProposal(misspelled: "teh", replacement: "the", deleteCount: 4, trailing: " "))
    default: return nil
    }
}

struct StretchTests {
    private func feed(_ reads: [String], span: inout UnsettledSpan<Int>) -> UnsettledSpan<Int>.Step? {
        var step: UnsettledSpan<Int>.Step?
        for r in reads where step == nil { step = span.read(field: 1, before: r, finding: stretchFinding) }
        return step
    }

    @Test func triggersAfterTheNextWordAndSpace() {
        var span = UnsettledSpan<Int>()
        #expect(feed(["I need fo ", "I need fo t", "I need fo the"], span: &span) == nil)
        guard case .choose(let t)? = feed(["I need fo the "], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.head == "I need ")
        #expect(t.gaps == [" the"])
        #expect(t.tail == " ")
        #expect(!span.isWaiting)
    }

    @Test func backspaceInTheNextWordKeepsWaiting() {
        var span = UnsettledSpan<Int>()
        #expect(feed(["a fo ", "a fo th", "a fo t", "a fo te"], span: &span) == nil)
        guard case .choose(let t)? = feed(["a fo tea "], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.gaps == [" tea"])
    }

    @Test func editingTheWordOrItsSpaceCancels() {
        var span = UnsettledSpan<Int>()
        _ = feed(["a fo ", "a fo"], span: &span)
        #expect(!span.isWaiting)
    }

    @Test func otherFieldOrLineBreakCancels() {
        var span = UnsettledSpan<Int>()
        _ = feed(["a fo "], span: &span)
        #expect(span.read(field: 2, before: "a fo the ", finding: stretchFinding) == nil)
        #expect(!span.isWaiting)
        var other = UnsettledSpan<Int>()
        _ = feed(["a fo ", "a fo the\n"], span: &other)
        #expect(!other.isWaiting)
    }

    @Test func extraSpacesBeforeTheNextWordAreFine() {
        var span = UnsettledSpan<Int>()
        #expect(feed(["a fo ", "a fo  "], span: &span) == nil)
        #expect(span.isWaiting)
        guard case .choose(let t)? = feed(["a fo  the "], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.gaps == ["  the"])
        #expect(t.head == "a ")
    }

    @Test func adjacentFlaggedWordsWaitTogether() {
        var span = UnsettledSpan<Int>()
        #expect(feed(["x fo ", "x fo si "], span: &span) == nil)
        #expect(span.waitingWords == ["fo", "si"])
        guard case .choose(let t)? = feed(["x fo si sure "], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.slots.map(\.misspelled) == ["fo", "si"])
        #expect(t.head == "x ")
        #expect(t.gaps == [" ", " sure"])
    }

    @Test func fastTypingSeesTheWholeStretchInOneRead() {
        var span = UnsettledSpan<Int>()
        _ = feed(["x"], span: &span)
        guard case .choose(let t)? = feed(["x fo si sure tw"], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.slots.count == 2)
        #expect(t.tail == " tw")
    }

    @Test func atMostThreeWordsWait() {
        var span = UnsettledSpan<Int>()
        _ = feed(["x"], span: &span)
        guard case .choose(let t)? = feed(["x fo si fo si "], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.slots.count == 3)
        #expect(t.gaps.last == " si")
        // The fourth word is looked at again: it waits on its own.
        #expect(span.read(field: 1, before: "x fo si fo si ", finding: stretchFinding) == nil)
        #expect(span.waitingWords == ["si"])
    }

    @Test func aSlipAcrossTwoWordsReplacesTheFirstWordsWait() {
        var span = UnsettledSpan<Int>()
        #expect(feed(["ok ye ", "ok ye spklease "], span: &span) == nil)
        #expect(span.waitingWords == ["ye spklease"])
        guard case .choose(let t)? = feed(["ok ye spklease go "], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.head == "ok ")
        #expect(t.gaps == [" go"])
    }

    @Test func aConfidentFixAfterTheWaitingWordGoesInFirst() {
        var span = UnsettledSpan<Int>()
        _ = feed(["a fo "], span: &span)
        let step = feed(["a fo teh "], span: &span)
        #expect(step == .fix(SpanFix(before: "a fo teh ", word: "teh", replacement: "the", tail: " ")))
        span.rewriteEnd(from: "teh ", to: "the ")
        guard case .choose(let t)? = span.read(field: 1, before: "a fo the ", finding: stretchFinding) else {
            Issue.record("expected a choice"); return
        }
        #expect(t.gaps == [" the"])
    }

    @Test func punctuationAtTheCaretEndsTheWait() {
        var span = UnsettledSpan<Int>()
        _ = feed(["thanks fo "], span: &span)
        guard case .choose(let t)? = feed(["thanks fo you."], span: &span) else { Issue.record("expected a choice"); return }
        #expect(t.gaps == [" you."])
        #expect(t.tail == "")
    }

    @Test func notCheckingWordsStillChoosesTheWaitingWord() {
        var span = UnsettledSpan<Int>()
        _ = feed(["a fo "], span: &span)
        guard case .choose? = span.read(field: 1, before: "a fo the ", checkWords: false, finding: stretchFinding) else {
            Issue.record("expected a choice"); return
        }
    }
}

// MARK: Finding rivals, two-slip and two-word candidates

private struct RivalSuggester: CorrectionSuggesting {
    let table: [String: CorrectionOptions] = [
        "thnk": CorrectionOptions(confident: "thank", guesses: ["thank", "think"]),
        "htw": CorrectionOptions(confident: "how", guesses: ["how"]),
        "qiuck": CorrectionOptions(confident: "quick", guesses: ["quick"]),
        "spklease": CorrectionOptions(confident: nil, guesses: []),
        "pklease": CorrectionOptions(confident: nil, guesses: []),
    ]
    func correction(for word: String, context: String, languages: [String]) -> String? { table[word]?.confident }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        table[word] ?? CorrectionOptions(confident: nil, guesses: [])
    }
}

private let rivalWords = ["thank", "think", "how", "the", "quick", "as", "a", "s", "yes", "please", "ye", "just",
                          "one", "i", "so", "we", "go", "sit", "he"]
private let rivalEveryday: Set<String> = ["thank", "think", "how", "the", "quick", "as", "a", "yes", "please",
                                          "just", "one", "i", "so", "we", "go", "sit", "he"]

private func rivalFinder() -> CorrectionFinder {
    CorrectionFinder(spellChecker: FakeSpell(rivalWords), suggester: RivalSuggester(), languages: ["en"], knownWords: [],
                     guesser: StubGuesser([:], default: ("en", 0.9)), isCommonWord: { rivalEveryday.contains($0) },
                     isEverydayWord: { rivalEveryday.contains($0) })
}

struct RivalFindingTests {
    @Test func aConfidentFixWithAnEquallyLikelyRivalWaitsWithItAsTheDefault() {
        guard case .ambiguous(let t)? = rivalFinder().finding(before: "I thnk ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.preferred == "thank")
        #expect(t.candidates.first == "thank")
        #expect(t.candidates.contains("think"))
    }

    @Test func aConfidentFixWithoutRivalsGoesInAtOnce() {
        #expect(rivalFinder().finding(before: "a qiuck ", deferAmbiguous: true)
            == .fix(CorrectionProposal(misspelled: "qiuck", replacement: "quick", deleteCount: 6, trailing: " ")))
    }

    @Test func twoSlipEverydayWordsAreRivals() {
        #expect(rivalFinder().twoSlipCandidates(for: "htw").contains("the"))
        guard case .ambiguous(let t)? = rivalFinder().finding(before: "fix htw ", deferAmbiguous: true) else {
            Issue.record("expected the model to choose"); return
        }
        #expect(t.preferred == "how")
        #expect(t.candidates.contains("the"))
    }

    @Test func aSpaceTypedInsideAWord() {
        guard case .ambiguous(let t)? = rivalFinder().finding(before: "just a s ", deferAmbiguous: true) else {
            Issue.record("expected a two-word slip"); return
        }
        #expect(t.misspelled == "a s")
        #expect(t.candidates == ["as"])
        #expect(t.deleteCount == 4)
    }

    @Test func aSpaceTypedOneKeyEarly() {
        guard case .ambiguous(let t)? = rivalFinder().finding(before: "ye spklease ", deferAmbiguous: true) else {
            Issue.record("expected a two-word slip"); return
        }
        #expect(t.misspelled == "ye spklease")
        #expect(t.candidates.contains("yes please"))
    }

    @Test func aSpaceIsMovedOnlyWhenTheSecondWordIsNoWord() {
        // "si the" is "is the" (the first word's own slip), not "sit he".
        if case .ambiguous(let t)? = rivalFinder().finding(before: "so si the ", deferAmbiguous: true) {
            #expect(!t.candidates.contains("sit he"))
        }
        if case .ambiguous(let t)? = rivalFinder().finding(before: "so si the go ", deferAmbiguous: true) {
            #expect(!t.candidates.contains { $0.hasPrefix("sit he") })
        }
    }

    @Test func ordinaryWordPairsAreLeftAlone() {
        #expect(rivalFinder().finding(before: "just one ", deferAmbiguous: true) == nil)
        #expect(rivalFinder().finding(before: "so we go ", deferAmbiguous: true) == nil)
    }
}
