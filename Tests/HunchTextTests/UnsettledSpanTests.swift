import Foundation
import Testing
@testable import HunchText

/// "teh"/"qiuck" are confident fixes, "fo" is ambiguous; everything else is fine. Records each stem.
private final class FakeFinding: @unchecked Sendable {
    var stems: [String] = []

    func callAsFunction(_ stem: String) -> CorrectionFinding? {
        stems.append(stem)
        guard stem.last == " " else { return nil }
        let word = String(stem.dropLast().split(separator: " ", omittingEmptySubsequences: false).last ?? "")
        switch word {
        case "teh": return .fix(CorrectionProposal(misspelled: "teh", replacement: "the", deleteCount: 4, trailing: " "))
        case "qiuck": return .fix(CorrectionProposal(misspelled: "qiuck", replacement: "quick", deleteCount: 6, trailing: " "))
        case "fo": return .ambiguous(AmbiguousTypo(misspelled: "fo", candidates: ["to", "of"], fallback: "to",
                                                   deleteCount: 3, trailing: " "))
        default: return nil
        }
    }
}

struct UnsettledSpanTests {
    /// Feeds the reads in order; returns the first step and the span.
    private func feed(_ reads: [String], finding: FakeFinding = FakeFinding(),
                      span: inout UnsettledSpan<Int>) -> UnsettledSpan<Int>.Step? {
        var step: UnsettledSpan<Int>.Step?
        for r in reads where step == nil { step = span.read(field: 1, before: r, finding: finding.callAsFunction) }
        return step
    }

    @Test func fixAtTheCaretRightAfterTheWord() {
        var span = UnsettledSpan<Int>()
        let step = feed(["I saw t", "I saw teh", "I saw teh "], span: &span)
        #expect(step == .fix(SpanFix(before: "I saw teh ", word: "teh", replacement: "the", tail: " ")))
    }

    @Test func eachWordIsLookedAtOnce() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["I saw", "I saw a ", "I saw a ", "I saw a b"], finding: finding, span: &span)
        #expect(finding.stems == ["I saw ", "I saw a "])
    }

    @Test func aWordNoReadCaughtIsFixedBehindTheCaret() {
        var span = UnsettledSpan<Int>()
        let step = feed(["I saw t", "I saw teh do"], span: &span)
        #expect(step == .fix(SpanFix(before: "I saw teh do", word: "teh", replacement: "the", tail: " do")))
    }

    @Test func aSecondFixComesOnTheNextReadAfterTheFirstWentIn() {
        // Typed "teh qiuck " while no read came: the first fix, then (after the edit) the second.
        var span = UnsettledSpan<Int>()
        let first = feed(["the", "the teh qiuck b"], span: &span)
        guard case .fix(let fix)? = first, let edit = fix.edit(now: "the teh qiuck b") else {
            Issue.record("expected a fix"); return
        }
        #expect(edit.after == "the the qiuck b")
        span.rewriteEnd(from: edit.original, to: edit.fixed)
        let second = span.read(field: 1, before: "the the qiuck br", finding: FakeFinding().callAsFunction)
        #expect(second == .fix(SpanFix(before: "the the qiuck br", word: "qiuck", replacement: "quick", tail: " br")))
    }

    @Test func theFixedWordIsNotLookedAtAgain() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["I saw teh "], finding: finding, span: &span)
        span.rewriteEnd(from: "teh ", to: "the ")
        _ = span.read(field: 1, before: "I saw the c", finding: finding.callAsFunction)
        #expect(finding.stems == ["I saw teh "])
    }

    @Test func ambiguousWordWaitsForTheNextWord() {
        var span = UnsettledSpan<Int>()
        #expect(feed(["are you fo "], span: &span) == nil)
        #expect(span.waitingWords == ["fo"])
        #expect(span.read(field: 1, before: "are you fo su", finding: FakeFinding().callAsFunction) == nil)
        guard case .choose(let trigger)? = span.read(field: 1, before: "are you fo sure ",
                                                     finding: FakeFinding().callAsFunction) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.head == "are you ")
        #expect(trigger.gaps == [" sure"])
        #expect(trigger.tail == " ")
    }

    @Test func ambiguousWordNoReadCaughtIsChosenAtOnceWhenTheNextWordIsDone() {
        var span = UnsettledSpan<Int>()
        guard case .choose(let trigger)? = feed(["are you f", "are you fo sure t"], span: &span) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.typo.misspelled == "fo")
        #expect(trigger.gaps == [" sure"])
        #expect(trigger.tail == " t")
    }

    @Test func theWordAfterAChosenWordIsStillLookedAt() {
        var span = UnsettledSpan<Int>()
        guard case .choose? = feed(["are you f", "are you fo sure teh x"], span: &span) else {
            Issue.record("expected a choice"); return
        }
        span.rewriteEnd(from: "fo sure teh x", to: "to sure teh x")
        let step = span.read(field: 1, before: "are you to sure teh x", finding: FakeFinding().callAsFunction)
        #expect(step == .fix(SpanFix(before: "are you to sure teh x", word: "teh", replacement: "the", tail: " x")))
    }

    @Test func existingTextIsNotCheckedOnlyTheLastWord() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["teh old text here "], finding: finding, span: &span)
        #expect(finding.stems == ["teh old text here "])
    }

    @Test func editingElsewhereStartsAgainAtTheLastWord() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["one two thr"], finding: finding, span: &span)
        _ = span.read(field: 1, before: "teh two three ", finding: finding.callAsFunction)  // pasted over
        #expect(finding.stems == ["teh two three "])
    }

    @Test func backspaceInsideTheWordKeepsFollowing() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["I saw tej", "I saw te", "I saw teh "], finding: finding, span: &span)
        #expect(finding.stems == ["I saw teh "])
    }

    @Test func atMostFourWordsAreLookedAt() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["x", "x a b c d e f "], finding: finding, span: &span)
        #expect(finding.stems == ["x a b c ", "x a b c d ", "x a b c d e ", "x a b c d e f "])
    }

    @Test func wordsEndedByALineBreakAreSettled() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["hi", "hi teh\nok "], finding: finding, span: &span)
        // Return approves what was shown: "hi " and "teh" before the line break stay as typed.
        #expect(finding.stems == ["hi teh\nok "])
    }

    @Test func wordsFinishedBeforeAReturnStayAsTyped() {
        // "teh " finished, then Return before any read: not looked at, never fixed behind the line break.
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = feed(["see", "see teh \n"], finding: finding, span: &span)
        #expect(finding.stems.isEmpty)
        #expect(!span.needsSettle)
    }

    @Test func notCheckingWordsSettlesThem() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "a", finding: finding.callAsFunction)
        #expect(span.read(field: 1, before: "a teh b ", checkWords: false, finding: finding.callAsFunction) == nil)
        _ = span.read(field: 1, before: "a teh b c", finding: finding.callAsFunction)
        #expect(finding.stems.isEmpty)
    }

    @Test func anotherFieldStartsOver() {
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "x", finding: finding.callAsFunction)
        _ = span.read(field: 2, before: "teh x", finding: finding.callAsFunction)
        #expect(finding.stems.isEmpty)
    }

    @Test func wordEndedByPunctuationAtTheCaretIsFixedAtOnce() {
        var span = UnsettledSpan<Int>()
        let finding: (String) -> CorrectionFinding? = { before in
            before.hasSuffix("teh.") ? .fix(CorrectionProposal(misspelled: "teh", replacement: "the",
                                                               deleteCount: 4, trailing: ".")) : nil
        }
        _ = span.read(field: 1, before: "see teh", finding: finding)
        #expect(span.read(field: 1, before: "see teh.", finding: finding)
            == .fix(SpanFix(before: "see teh.", word: "teh", replacement: "the", tail: ".")))
        span.rewriteEnd(from: "teh.", to: "the.")
        #expect(span.read(field: 1, before: "see the. ", finding: finding) == nil)
    }

    @Test func rewriteIncludingTextNotReadYetKeepsTheUncheckedWords() {
        // The fix landed after more was typed than the span saw: "cn " must still be looked at.
        let finding = FakeFinding()
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "x", finding: finding.callAsFunction)
        _ = span.read(field: 1, before: "x teh cn", finding: finding.callAsFunction)  // fix for teh
        span.rewriteEnd(from: "teh cn al", to: "the cn al")
        _ = span.read(field: 1, before: "x the cn all ", finding: finding.callAsFunction)
        #expect(finding.stems.last == "x the cn all ")
        #expect(finding.stems.contains("x the cn "))
    }

    @Test func spanFixFollowsTypingOn() {
        let fix = SpanFix(before: "a teh ", word: "teh", replacement: "the", tail: " ")
        #expect(fix.edit(now: "a teh ")?.after == "a the ")
        #expect(fix.edit(now: "a teh qu") == SpanFix.Edit(original: "teh qu", fixed: "the qu", tail: " qu",
                                                          after: "a the qu"))
        #expect(fix.edit(now: "a te") == nil)
        #expect(fix.edit(now: "a teh \nx") == nil)
    }

    // MARK: Settling points (stage 5)

    /// Like `FakeFinding`, plus "fo." (ambiguous, ended by a period).
    private static func finding(_ stem: String) -> CorrectionFinding? {
        if stem.hasSuffix(" fo.") {
            return .ambiguous(AmbiguousTypo(misspelled: "fo", candidates: ["to", "of"], fallback: "to",
                                            deleteCount: 3, trailing: "."))
        }
        return FakeFinding()(stem)
    }

    @Test func aSentenceEndDecidesTheWaitingWordsWithNothingAfterThem() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "thanks fo ", finding: Self.finding)
        #expect(span.waitingWords == ["fo"])
        guard case .choose(let trigger)? = span.read(field: 1, before: "thanks fo all.", finding: Self.finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.head == "thanks ")
        #expect(trigger.gaps == [" all."])
        #expect(trigger.tail == "")
        #expect(!span.needsSettle)
    }

    @Test func aFlaggedWordEndingASentenceIsDecidedAtTheStop() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "thanks fo", finding: Self.finding)
        guard case .choose(let trigger)? = span.read(field: 1, before: "thanks fo.", finding: Self.finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.slots.map(\.misspelled) == ["fo"])
        #expect(trigger.gaps == ["."])
        #expect(trigger.tail == "")
        // Not looked at again after the space.
        #expect(span.read(field: 1, before: "thanks fo. ", finding: Self.finding) == nil)
        #expect(!span.isWaiting)
    }

    @Test func aCommaDoesNotSettle() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "thanks fo", finding: Self.finding)
        #expect(span.read(field: 1, before: "thanks fo,", finding: Self.finding) == nil)
    }

    @Test func returnDecidesTheWordAtTheCaretWithNothingAfterIt() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "thanks fo", finding: Self.finding)
        #expect(span.needsSettle)
        guard case .choose(let trigger)? = span.settle(field: 1, before: "thanks fo", finding: Self.finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.head == "thanks ")
        #expect(trigger.slots.first?.deleteCount == 2)
        #expect(trigger.slots.first?.trailing == "")
        #expect(trigger.gaps == [""])
        #expect(span.settle(field: 1, before: "thanks fo", finding: Self.finding) == nil)
    }

    @Test func returnFixesAConfidentWordAtTheCaret() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "see teh", finding: Self.finding)
        let step = span.settle(field: 1, before: "see teh", finding: Self.finding)
        #expect(step == .fix(SpanFix(before: "see teh", word: "teh", replacement: "the", tail: "")))
        span.rewriteEnd(from: "teh", to: "the")
        #expect(span.settle(field: 1, before: "see the", finding: Self.finding) == nil)
    }

    @Test func returnDecidesWaitingWordsFirstThenFixesTheCaretWord() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "go fo ", finding: Self.finding)
        _ = span.read(field: 1, before: "go fo teh", finding: Self.finding)
        guard case .choose(let trigger)? = span.settle(field: 1, before: "go fo teh", finding: Self.finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.gaps == [" teh"])
        // The model kept "fo": the caret word is fixed on the next call.
        #expect(span.settle(field: 1, before: "go fo teh", finding: Self.finding)
            == .fix(SpanFix(before: "go fo teh", word: "teh", replacement: "the", tail: "")))
    }

    @Test func returnWithTrailingSpaceDecidesTheWaitingWord() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "thanks fo ", finding: Self.finding)
        guard case .choose(let trigger)? = span.settle(field: 1, before: "thanks fo ", finding: Self.finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.gaps == [" "])
        #expect(!span.needsSettle)
    }

    @Test func nothingToSettleAfterAFinishedFineWord() {
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "all good ", finding: Self.finding)
        #expect(!span.needsSettle)
        #expect(span.settle(field: 1, before: "all good ", finding: Self.finding) == nil)
    }

    @Test func theLastWordAtASettlingPointHasNoDefaultFix() {
        let finding: (String) -> CorrectionFinding? = { stem in
            if stem.hasSuffix("haa.") {
                return .ambiguous(AmbiguousTypo(misspelled: "haa", candidates: ["has", "haha"], fallback: "has",
                                                deleteCount: 4, trailing: ".", preferred: "has"))
            }
            return stem.hasSuffix("haa ") ? .ambiguous(AmbiguousTypo(misspelled: "haa", candidates: ["has", "haha"], fallback: "has",
                                                                    deleteCount: 4, trailing: " ", preferred: "has")) : nil
        }
        var span = UnsettledSpan<Int>()
        _ = span.read(field: 1, before: "i speak haa", finding: finding)
        guard case .choose(let trigger)? = span.settle(field: 1, before: "i speak haa", finding: finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(trigger.slots.first?.preferred == nil)
        // With a word after it, the default stays.
        var later = UnsettledSpan<Int>()
        _ = later.read(field: 1, before: "i speak haa ", finding: finding)
        guard case .choose(let t2)? = later.read(field: 1, before: "i speak haa now ", finding: finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(t2.slots.first?.preferred == "has")
        // A sentence end keeps it too ("snaks." → snacks).
        var stop = UnsettledSpan<Int>()
        _ = stop.read(field: 1, before: "i speak haa", finding: finding)
        guard case .choose(let t3)? = stop.read(field: 1, before: "i speak haa.", finding: finding) else {
            Issue.record("expected a choice"); return
        }
        #expect(t3.slots.first?.preferred == "has")
    }

    /// An edit in place that `appended` mistakes for typing (an accent joining the last letter) once
    /// made the unchecked part longer than the field, and the next finished word trapped in `settle`.
    @Test func anEditInPlaceIsNotTakenForTyping() {
        var span = UnsettledSpan<Int>()
        let finding = FakeFinding()
        for r in ["hfo", "hfoteh", "hfoteh\u{301}", "hfoteh\u{301}a", "hfoteh\u{301}", "hfoteh\u{301} "] {
            _ = span.read(field: 1, before: r, finding: finding.callAsFunction)
        }
        var same = UnsettledSpan<Int>()
        for r in ["so aaaa", "so aaab", "so aaab "] { _ = same.read(field: 1, before: r, finding: finding.callAsFunction) }
        #expect(finding.stems.allSatisfy { stem in ["hfoteh\u{301} ", "so aaab "].contains(where: { $0.hasPrefix(stem) }) })
    }

    /// Random typing, Backspace, combining marks, emoji parts, line breaks and a sliding window: no read
    /// traps, and every stem looked at is a prefix of the text it was read from.
    @Test func randomEditsNeverTrap() {
        let pieces = ["a", "e", "t", "h", "teh", "fo", "qiuck", " ", " ", " ", "\n", "\r", "\u{301}", "👍", "🏽",
                      "\u{200D}", "你", ".", ","]
        for seed in 0..<3000 {
            var rng = SeededGenerator(seed: UInt64(seed))
            var span = UnsettledSpan<Int>()
            var text = ""
            for _ in 0..<40 {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<6: text += pieces.randomElement(using: &rng)!
                case 6..<9: if !text.isEmpty { text.removeLast() }
                default: text = String(text.suffix(Int.random(in: 0..<8, using: &rng)))
                }
                let before = text
                _ = span.read(field: 1, before: before, finding: { stem in
                    if !before.hasPrefix(stem) { Issue.record("seed \(seed): stem \(stem.debugDescription) not in \(before.debugDescription)") }
                    return FakeFinding()(stem)
                })
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
