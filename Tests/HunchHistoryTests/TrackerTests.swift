import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let field = FieldID(pid: 100, elementHash: 7, generation: 1)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private func show(_ t: inout OutcomeTracker, _ before: String, _ sug: String, _ scores: [WordScore] = [],
                  _ s: TimeInterval = 0) {
    _ = t.suggestionShown(field: field, before: before, suggestion: sug, scores: scores, at: at(s))
}

@Test func confirmedAfterSettle() {
    var t = OutcomeTracker()
    show(&t, "We should deploy to", " Kubernetes", [WordScore(text: " Kubernetes", logProb: -6)])
    #expect(t.accepted(field: field, text: " Kubernetes", at: at(1)).isEmpty)
    #expect(t.textChanged(field: field, before: "We should deploy to Kubernetes", at: at(2)).isEmpty)
    #expect(t.tick(at: at(5)).isEmpty)
    let ev = t.tick(at: at(12))
    #expect(ev.count == 1)
    #expect(ev.first?.kind == .confirmed(words: [WordScore(text: "Kubernetes", logProb: -6)],
                                         context: ["deploy", "to"]))
    #expect(t.tick(at: at(30)).isEmpty)
}

@Test func focusLeftConfirms() {
    var t = OutcomeTracker()
    show(&t, "Ship it", " tomorrow", [WordScore(text: " tomorrow", logProb: -3)])
    _ = t.accepted(field: field, text: " tomorrow", at: at(1))
    let ev = t.focusLeft(field: field, at: at(3))
    #expect(ev.count == 1)
    if case let .confirmed(words, ctx, _)? = ev.first?.kind {
        #expect(words.map(\.text) == ["tomorrow"])
        #expect(ctx == ["Ship", "it"])
    } else { Issue.record("expected confirmed") }
}

@Test func editedBeforeSettleBecomesCorrection() {
    var t = OutcomeTracker()
    let base = "The results clearly"
    show(&t, base, " demonstrated", [WordScore(text: " demonstrated", logProb: -2)])
    _ = t.accepted(field: field, text: " demonstrated", at: at(1))
    #expect(t.textChanged(field: field, before: base + " demonstrat", at: at(2)).isEmpty)
    #expect(t.textChanged(field: field, before: base + " demonstration", at: at(3)).isEmpty)
    let ev = t.textChanged(field: field, before: base + " demonstration ", at: at(4))
    #expect(ev.count == 1)
    #expect(ev.first?.kind == .correctedAfterAccept(context: ["results", "clearly"],
                                                     accepted: "demonstrated", corrected: "demonstration"))
    // Nothing is confirmed later.
    #expect(t.tick(at: at(60)).isEmpty)
}

@Test func editedThenRestoredStillConfirms() {
    var t = OutcomeTracker()
    show(&t, "It was", " fantastic", [WordScore(text: " fantastic", logProb: -3)])
    _ = t.accepted(field: field, text: " fantastic", at: at(1))
    _ = t.textChanged(field: field, before: "It was fantas", at: at(2))
    _ = t.textChanged(field: field, before: "It was fantastic", at: at(3))
    #expect(t.tick(at: at(20)).count == 1)
}

@Test func editedAndNeverCompletedLearnsNothing() {
    var t = OutcomeTracker()
    show(&t, "It was", " fantastic")
    _ = t.accepted(field: field, text: " fantastic", at: at(1))
    _ = t.textChanged(field: field, before: "It was fant", at: at(2))
    #expect(t.tick(at: at(30)).isEmpty)
}

@Test func typedOverDetected() {
    var t = OutcomeTracker()
    show(&t, "I really like the", " idea")
    #expect(t.textChanged(field: field, before: "I really like the c", at: at(1)).isEmpty)
    show(&t, "I really like the c", "ool")   // new ghost for the partial word is ignored once diverged
    let ev = t.textChanged(field: field, before: "I really like the colour ", at: at(2))
    #expect(ev.count == 1)
    #expect(ev.first?.kind == .typedOver(context: ["like", "the"], suggested: "idea", typed: "colour"))
}

@Test func typingTheSuggestedWordIsNotTypedOver() {
    var t = OutcomeTracker()
    show(&t, "I really like the", " idea")
    _ = t.textChanged(field: field, before: "I really like the id", at: at(1))
    #expect(t.textChanged(field: field, before: "I really like the idea ", at: at(2)).isEmpty)
}

@Test func dismissedEmitsFirstWord() {
    var t = OutcomeTracker()
    show(&t, "Thanks for your", " help with this")
    let ev = t.dismissed(field: field, at: at(1))
    #expect(ev.first?.kind == .dismissed(context: ["for", "your"], suggested: "help"))
    #expect(t.dismissed(field: field, at: at(2)).isEmpty)
}

@Test func otherFieldDoesNotInterfere() {
    var t = OutcomeTracker()
    let other = FieldID(pid: 5, elementHash: 1, generation: 1)
    show(&t, "Thanks for your", " help")
    #expect(t.dismissed(field: other, at: at(1)).isEmpty)
    #expect(t.textChanged(field: other, before: "zzz zzz ", at: at(2)).isEmpty)
}

@Test func consecutiveAcceptsMergeIntoPhrase() {
    var t = OutcomeTracker()
    show(&t, "We use", " machine", [WordScore(text: " machine", logProb: -5)])
    _ = t.accepted(field: field, text: " machine", at: at(1))
    show(&t, "We use machine", " learning", [WordScore(text: " learning", logProb: -3)])
    _ = t.accepted(field: field, text: " learning", at: at(2))
    let ev = t.focusLeft(field: field, at: at(3))
    #expect(ev.count == 1)
    if case let .confirmed(words, _, _)? = ev.first?.kind {
        #expect(words.map(\.text) == ["machine", "learning"])
    } else { Issue.record("expected confirmed") }
}

@Test func tokenizerBasics() {
    let toks = WordText.tokens(in: "Don't visit http://a.com now, ok")
    #expect(toks.map(\.text).contains("Don't"))
    #expect(toks.first { $0.text == "a" }?.opaque == true)
    #expect(toks.first { $0.text == "now" }?.opaque == false)
    let zh = WordText.tokens(in: "今天天气很好 ok")
    #expect(zh.map(\.text) == ["今天", "天气", "很好", "ok"])
}

@Suite struct SlidingWindowTests {
    @Test func remainderAlignsWhenTheWindowStartMoves() {
        let earlier = String(repeating: "lorem ipsum dolor ", count: 6) + "the quick brown"
        // The app's window dropped 10 leading characters and the user typed " fox".
        let later = String(earlier.dropFirst(10)) + " fox"
        #expect(OutcomeTracker.remainder(of: later, after: earlier) == " fox")
        #expect(OutcomeTracker.remainder(of: "abc def", after: "abc") == " def")
        #expect(OutcomeTracker.remainder(of: "something else entirely", after: earlier) == nil)
    }
}
