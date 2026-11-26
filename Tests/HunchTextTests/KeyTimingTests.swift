import Foundation
import Testing
@testable import HunchText

/// Autocorrect mechanism: key timing backs swaps and doubled letters.

/// A word typed key by key, `ms` apart (down to down); `gaps` overrides the gap before key i.
private func strokes(_ word: String, ms: Double = 100, gaps: [Int: Double] = [:], start: Double = 1,
                     repeats: Set<Int> = []) -> [KeyStroke] {
    var t = start
    return Array(word).enumerated().map { i, c in
        if i > 0 { t += (gaps[i] ?? ms) / 1000 }
        let code = KeyTimingLog.keyCode(for: Character(c.lowercased()))?.code ?? 999
        return KeyStroke(keyCode: code, char: c, down: t, up: t + 0.09, isRepeat: repeats.contains(i))
    }
}

private func log(_ text: String, ms: Double = 100, gaps: [Int: Double] = [:], repeats: Set<Int> = []) -> KeyTimingLog {
    var log = KeyTimingLog()
    for s in strokes(text, ms: ms, gaps: gaps, repeats: repeats) { log.append(s) }
    return log
}

struct KeyTimingLogTests {
    @Test func keyCodesMapToQwertyCharactersAndBackspaceTakesAPressBack() {
        var log = KeyTimingLog()
        log.keyDown(keyCode: 17, shift: true, commandLike: false, at: 1.0)   // T
        log.keyDown(keyCode: 14, shift: false, commandLike: false, at: 1.1)  // e
        log.keyDown(keyCode: 0, shift: false, commandLike: false, at: 1.2)   // a (slip)
        log.keyDown(keyCode: 51, shift: false, commandLike: false, at: 1.3)  // Backspace
        log.keyDown(keyCode: 4, shift: false, commandLike: false, at: 1.4)   // h
        log.keyUp(keyCode: 4, at: 1.45)
        #expect(log.strokes.map(\.char) == ["T", "e", "h"])
        #expect(log.strokes.last?.up == 1.45)
    }

    @Test func shortcutsArrowsAndLongPausesStartOver() {
        var log = KeyTimingLog()
        log.keyDown(keyCode: 0, shift: false, commandLike: false, at: 1)
        log.keyDown(keyCode: 9, shift: false, commandLike: true, at: 1.1)  // Cmd-V
        #expect(log.strokes.isEmpty)
        log.keyDown(keyCode: 0, shift: false, commandLike: false, at: 2)
        log.keyDown(keyCode: 123, shift: false, commandLike: false, at: 2.1)  // Left arrow
        #expect(log.strokes.isEmpty)
        log.keyDown(keyCode: 0, shift: false, commandLike: false, at: 3)
        log.keyDown(keyCode: 11, shift: false, commandLike: false, at: 3 + KeyTimingLog.idleReset + 1)
        #expect(log.strokes.map(\.char) == ["b"])
    }

    @Test func keepsOnlyTheLastFewDozenKeys() {
        let l = log(String(repeating: "ab ", count: 40))
        #expect(l.strokes.count == KeyTimingLog.capacity)
    }

    @Test func swappedKeysPressedTogetherAreRolled() throws {
        // "teh": e and h went down 20 ms apart.
        let t = try #require(log("the teh ", gaps: [6: 20]).evidence(for: "teh"))
        #expect(t.rolled == [false, true])
        #expect(t.doubleHit == [false, false])
    }

    @Test func overlapAloneIsNotEvidence() {
        // 60 ms apart with 90 ms key-downs: overlapping, as fast typists do on clean pairs.
        #expect(log("teh ", ms: 60).evidence(for: "teh") == nil)
    }

    @Test func aFastRepeatOrAutoRepeatIsADoubleHit() throws {
        let fast = try #require(log("stilll ", gaps: [5: 30]).evidence(for: "stilll"))
        #expect(fast.doubleHit == [false, false, false, false, true])
        let held = try #require(log("stilll ", repeats: [5]).evidence(for: "stilll"))
        #expect(held.doubleHit[4])
        // A meant double letter at typing speed is not.
        #expect(log("still ").evidence(for: "still") == nil)
    }

    @Test func evidenceIsForTheLatestWholeWordTheKeysSpell() throws {
        // "teh" typed twice, rolled only the second time; "tehx" doesn't count as "teh".
        let l = log("teh tehx teh ", gaps: [11: 20])
        #expect(try #require(l.evidence(for: "teh")).rolled == [false, true])
        #expect(l.evidence(for: "the") == nil)          // not what the keys spell
        #expect(log("Teh ", gaps: [2: 20]).evidence(for: "Teh") != nil)
        // Over two words, spaces included.
        let pair = try #require(log("a s ", gaps: [1: 20]).evidence(for: "a s"))
        #expect(pair.rolled == [true, false])
    }
}

struct TimedSlipCostTests {
    @Test func aRolledSwapCostsLessAndNothingCostsMore() {
        let rolled = KeyTiming(rolled: [false, true], doubleHit: [false, false])
        #expect(SlipCost.cost(typed: "teh", candidate: "the", timing: rolled) == SlipCost.swapRolled)
        #expect(SlipCost.cost(typed: "teh", candidate: "the", timing: nil) == SlipCost.swap)
        // Timing about another pair changes nothing.
        let other = KeyTiming(rolled: [true, false], doubleHit: [false, false])
        #expect(SlipCost.cost(typed: "teh", candidate: "the", timing: other) == SlipCost.swap)
        for candidate in ["ten", "tea", "eh", "the", "tech"] {
            #expect(SlipCost.cost(typed: "teh", candidate: candidate, timing: rolled)
                    <= SlipCost.cost(typed: "teh", candidate: candidate))
        }
    }

    @Test func aBouncedDoubleCostsLess() {
        let t = KeyTiming(rolled: [false, false, false, false, false], doubleHit: [false, false, false, false, true])
        #expect(SlipCost.cost(typed: "stilll", candidate: "still", timing: t) == SlipCost.extraDoubleHit)
        #expect(SlipCost.cost(typed: "stilll", candidate: "still") == SlipCost.extraNearKey)
    }

    @Test func timingExplainsOnlyFixesMadeOfBackedSlips() {
        let t = KeyTiming(rolled: [false, true, false], doubleHit: [false, false, false])
        #expect(SlipCost.timingExplains(typed: "adnx", candidate: "andx", timing: t))
        #expect(!SlipCost.timingExplains(typed: "adnx", candidate: "and", timing: t))   // plus a dropped x
        #expect(!SlipCost.timingExplains(typed: "adnx", candidate: "addx", timing: t))
        #expect(!SlipCost.timingExplains(typed: "adnx", candidate: "andx", timing: nil))
        // Timing for another length is not this word's.
        #expect(!SlipCost.timingExplains(typed: "adn", candidate: "and", timing: t))
    }
}

struct TimedJointChoiceTests {
    private func slot(_ timing: KeyTiming?) -> AmbiguousTypo {
        var typo = AmbiguousTypo(misspelled: "adn", candidates: ["and", "add"], fallback: "and", deleteCount: 4,
                                 trailing: " ")
        typo.timing = timing
        return typo
    }

    @Test func aFixTheTimingExplainsNeedsLessMargin() {
        // "and" leads the word as typed by 1.5 nats: unsure without timing, a fix with it.
        let combos = [[0], [1], [2]]
        let scores: [Float] = [-10, -8.5, -12]
        #expect(JointChoice.decide([slot(nil)], combos: combos, scores: scores) == [.unsure("and")])
        let rolled = KeyTiming(rolled: [false, true], doubleHit: [false, false])
        #expect(JointChoice.decide([slot(rolled)], combos: combos, scores: scores) == [.fix("and")])
    }

    @Test func timingForAnotherSlipChangesNothing() {
        let combos = [[0], [1], [2]]
        let scores: [Float] = [-10, -8.5, -12]
        let other = KeyTiming(rolled: [true, false], doubleHit: [false, false])
        #expect(JointChoice.decide([slot(other)], combos: combos, scores: scores) == [.unsure("and")])
    }

    @Test func rollingRanksTheSwapAboveAnEquallyLikelyOtherFix() {
        // "add" and "and" score the same; the rolled d-n pair makes the swap cheaper.
        let rolled = KeyTiming(rolled: [false, true], doubleHit: [false, false])
        let t = slot(rolled)
        let costs = JointChoice.candidateCosts(t)
        #expect(costs[0] < costs[1])
    }
}

private let spell = FakeSpell(["from", "form", "on", "no", "the", "and", "of", "go", "to"])
private let everyday: Set<String> = ["from", "form", "on", "no", "the", "and", "of", "go", "to"]

private func finder(_ keys: KeyTimingLog?, timedSwaps: Bool = true) -> CorrectionFinder {
    var f = CorrectionFinder(spellChecker: spell, suggester: NoSuggester(), languages: ["en"], knownWords: [],
                             guesser: StubGuesser([:], default: ("en", 0.9)), isCommonWord: { everyday.contains($0) },
                             isEverydayWord: { everyday.contains($0) })
    f.keyTiming = keys
    f.flagsTimedSwaps = timedSwaps
    return f
}

private struct NoSuggester: CorrectionSuggesting {
    func correction(for word: String, context: String, languages: [String]) -> String? { nil }
    func options(for word: String, context: String, languages: [String]) -> CorrectionOptions {
        CorrectionOptions(confident: nil, guesses: [])
    }
}

struct TimedFinderTests {
    @Test func anEverydayWordTypedWithRolledKeysAsksTheModel() throws {
        // "form" with o and r pressed together: "from" is the swap.
        let keys = log("I got it form ", gaps: [11: 15])
        guard case .ambiguous(let typo)? = finder(keys).finding(before: "I got it form ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.candidates == ["from"])
        #expect(typo.margin == CorrectionFinder.strictMargin)
        #expect(typo.fallback == nil)
        #expect(typo.timing?.rolled == [false, true, false])
    }

    @Test func withoutRolledKeysOrWithTheSwitchOffAnEverydayWordStays() {
        #expect(finder(log("I got it form ")).finding(before: "I got it form ", deferAmbiguous: true) == nil)
        #expect(finder(nil).finding(before: "I got it form ", deferAmbiguous: true) == nil)
        #expect(finder(log("I got it form ", gaps: [11: 15]), timedSwaps: false)
            .finding(before: "I got it form ", deferAmbiguous: true) == nil)
        // Only a deferred finding ("Fix automatically") asks the model.
        #expect(finder(log("I got it form ", gaps: [11: 15])).finding(before: "I got it form ", deferAmbiguous: false) == nil)
    }

    @Test func aWaitingWordCarriesItsTiming() throws {
        let keys = log("go fo ", gaps: [4: 20])
        guard case .ambiguous(let typo)? = finder(keys).finding(before: "go fo ", deferAmbiguous: true) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(typo.timing?.rolled == [true])
        #expect(typo.candidates.contains("of"))
    }
}

struct KeyTimingModelTests {
    @Test func marksSwapsAndBouncedDoubles() {
        let (swaps, bounces) = KeyTimingModel.slipMarks(clean: Array("the still"), typed: Array("teh stilll"))
        #expect(swaps == [1])
        #expect(bounces.count == 1)
        #expect(bounces.allSatisfy { [8, 9].contains($0) })
    }

    @Test func swapsMostlyComeWithKeysPressedTogether() {
        let model = KeyTimingModel()
        var rolledSwaps = 0, rolledClean = 0, cleanPairs = 0
        for seed in 0..<200 {
            let s = model.strokes(clean: "the quick fox", typed: "teh quick fox", cps: 11, seed: UInt64(seed))
            if s[2].down - s[1].down < KeyTimingLog.rolloverGap { rolledSwaps += 1 }
            for i in 4..<12 where s[i + 1].down - s[i].down < KeyTimingLog.rolloverGap { rolledClean += 1 }
            cleanPairs += 8
        }
        #expect((110...170).contains(rolledSwaps))           // ≈ 70 %
        #expect(Double(rolledClean) / Double(cleanPairs) < 0.25)  // ≈ 15 %
        #expect(model.strokes(clean: "ab", typed: "ba", cps: 11, seed: 3) == model.strokes(clean: "ab", typed: "ba", cps: 11, seed: 3))
    }
}

struct RecordedKeyTests {
    @Test func savedKeysReplayToTheTypedText() throws {
        var raw = strokes("x", start: 0.5)                  // an earlier key, not part of the sample
        raw += strokes("tex", start: 1)
        raw.append(KeyStroke(keyCode: 51, char: RecordedKey.backspace, down: 1.25))
        raw.append(KeyStroke(keyCode: 4, char: "h", down: 1.4, up: 1.45))
        raw += strokes("ot", gaps: [1: 20], start: 1.5)  // "teh" then "ot": o and t pressed together
        let keys = RecordedKey.record(raw)
        #expect(keys.first?.d == 0)
        let replayed = try #require(RecordedKey.strokes(for: "tehot", from: keys))
        #expect(replayed.map(\.char) == ["t", "e", "h", "o", "t"])
        #expect(KeyTiming(strokes: replayed).rolled == [false, false, false, true])
        #expect(RecordedKey.strokes(for: "theot", from: keys) == nil)
        // Round trip through JSON.
        let data = try JSONEncoder().encode(keys)
        #expect(try JSONDecoder().decode([RecordedKey].self, from: data) == keys)
    }
}

/// Slash commands, mentions and tags a host turned into a chip: the field reads "btw" though "/btw"
/// was typed, and retyping the word would delete the chip.
struct TokenTriggerTests {
    @Test func aWordTypedRightAfterSlashAtOrHashIsFlagged() {
        #expect(log("/btw ").typedAfterTokenTrigger("btw"))
        #expect(log("hi @alex ").typedAfterTokenTrigger("alex"))
        #expect(log("in #genral ").typedAfterTokenTrigger("genral"))
    }

    @Test func plainWordsAndWordsTypedLaterAreNot() {
        #expect(!log("btw ").typedAfterTokenTrigger("btw"))
        #expect(!log("and/or teh ").typedAfterTokenTrigger("teh"))  // a slash inside a word
        #expect(!log("/btw how ").typedAfterTokenTrigger("how"))  // lapsed after the token's word
        #expect(!log("/ wrold ").typedAfterTokenTrigger("wrold"))  // typed, not picked
        #expect(!KeyTimingLog().typedAfterTokenTrigger("btw"))
    }

    /// "/b", then the picker's entry chosen with the arrows and Return or a click: the host puts
    /// "btw" in, so the keys never spell it.
    @Test func aWordThePickerPutInIsFlaggedThroughArrowsAndClicks() {
        var keys = log("/b")
        keys.keyDown(keyCode: 125, shift: false, commandLike: false, at: 2)  // Down arrow
        keys.keyDown(keyCode: 36, shift: false, commandLike: false, at: 2.1)  // Return picks
        #expect(keys.typedAfterTokenTrigger("btw"))
        keys.keyDown(keyCode: 49, shift: false, commandLike: false, at: 2.2)  // space after the chip
        #expect(keys.typedAfterTokenTrigger("btw"))

        var clicked = log("@")
        clicked.reset(keepingTokenTrigger: true)  // the pick is a click
        #expect(clicked.typedAfterTokenTrigger("alex"))
        clicked.reset()  // focus moved: gone
        #expect(!clicked.typedAfterTokenTrigger("alex"))
    }

    @Test func theFinderLeavesAChipWordAlone() {
        // A sentence start gets its capital ("the" → "The"), unless "/the" was typed.
        var f = finder(log("the "))
        f.fixesCapitals = true
        #expect(f.proposal(before: "the ")?.replacement == "The")
        f.keyTiming = log("/the ")
        #expect(f.finding(before: "the ", deferAmbiguous: true) == nil)
    }
}
