import Foundation
import Testing
@testable import HunchText

@Suite struct SuggestionOutcomeTrackerTests {
    typealias Tracker = SuggestionOutcomeTracker<Int, String>
    let t0 = Date(timeIntervalSince1970: 1_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func fullAcceptSettlesAsKept() {
        var t = Tracker(settleInterval: 10)
        _ = t.shown(field: 1, before: "I think we ", suggestion: "should go", info: "a", at: at(0))
        #expect(t.accepted(field: 1, text: "should", at: at(1)).isEmpty)
        #expect(t.accepted(field: 1, text: " go", at: at(2)).isEmpty)
        // A lagging read, then the full text, then typing on.
        #expect(t.textChanged(field: 1, before: "I think we should", at: at(2.1)).isEmpty)
        #expect(t.textChanged(field: 1, before: "I think we should go", at: at(2.2)).isEmpty)
        #expect(t.textChanged(field: 1, before: "I think we should go now", at: at(5)).isEmpty)
        let r = t.tick(at: at(12.5))
        #expect(r.count == 1)
        #expect(r[0].result == .acceptedFull)
        #expect(r[0].acceptedChars == 9 && r[0].accepts == 2 && r[0].typedAlongChars == 0)
        #expect(r[0].editedAfterAccept == false)
        #expect(r[0].visibleSeconds == 2)
        #expect(r[0].info == "a" && r[0].suggestion == "should go")
    }

    @Test func editIntoTakenTextIsRegret() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "Hi ", suggestion: "there friend", info: "a", at: at(0))
        _ = t.accepted(field: 1, text: "there friend", at: at(1))
        _ = t.textChanged(field: 1, before: "Hi there friend", at: at(1.1))
        let r = t.textChanged(field: 1, before: "Hi there fr", at: at(2))
        #expect(r.count == 1)
        #expect(r[0].result == .acceptedFull && r[0].editedAfterAccept == true)
    }

    @Test func aReadBeforeTheInsertLandsIsNotRegret() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "Hi ", suggestion: "there", info: "a", at: at(0))
        _ = t.accepted(field: 1, text: "there", at: at(1))
        #expect(t.textChanged(field: 1, before: "Hi ", at: at(1.05)).isEmpty)
        let r = t.focusEnded(at: at(3))
        #expect(r.count == 1 && r[0].editedAfterAccept == nil)
    }

    @Test func partialAcceptThenTypingElse() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "Let's meet ", suggestion: "tomorrow at noon", info: "a", at: at(0))
        _ = t.accepted(field: 1, text: "tomorrow", at: at(1))
        _ = t.textChanged(field: 1, before: "Let's meet tomorrow", at: at(1.1))
        #expect(t.textChanged(field: 1, before: "Let's meet tomorrow!", at: at(2)).isEmpty)
        let r = t.tick(at: at(20))
        #expect(r.count == 1)
        #expect(r[0].result == .acceptedPartial && r[0].acceptedChars == 8 && r[0].editedAfterAccept == false)
        #expect(r[0].visibleSeconds == 2)
    }

    @Test func typedOverAndDismissed() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "See you ", suggestion: "soon", info: "a", at: at(0))
        var r = t.textChanged(field: 1, before: "See you l", at: at(0.5))
        #expect(r.map(\.result) == [.typedOver])
        #expect(r[0].editedAfterAccept == nil)
        _ = t.shown(field: 1, before: "See you later ", suggestion: "today", info: "b", at: at(1))
        r = t.dismissed(field: 1, at: at(1.5))
        #expect(r.map(\.result) == [.dismissed] && r[0].info == "b")
    }

    @Test func typingAlongThenReplaced() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "How ", suggestion: "are you", info: "a", at: at(0))
        #expect(t.textChanged(field: 1, before: "How ar", at: at(0.3)).isEmpty)
        let r = t.shown(field: 1, before: "How ar", suggestion: "e you doing", info: "b", at: at(0.6))
        #expect(r.count == 1 && r[0].result == .typedAlong && r[0].typedAlongChars == 2)
    }

    @Test func typingAlongToTheEnd() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "ok ", suggestion: "sure", info: "a", at: at(0))
        let r = t.textChanged(field: 1, before: "ok sure", at: at(1))
        #expect(r.map(\.result) == [.typedAlong])
    }

    @Test func replacedWithoutTypingAndRepublishIgnored() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "a ", suggestion: "b c", info: "x", at: at(0))
        #expect(t.shown(field: 1, before: "a ", suggestion: "b c", info: "x", at: at(0.1)).isEmpty)
        let r = t.shown(field: 1, before: "a ", suggestion: "d", info: "y", at: at(0.2))
        #expect(r.map(\.result) == [.replaced])
    }

    @Test func focusLossEndsTheVisibleOne() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "x ", suggestion: "y", info: "a", at: at(0))
        #expect(t.focusEnded(at: at(4)).map(\.result) == [.left])
    }

    @Test func otherFieldsDoNotTouchIt() {
        var t = Tracker()
        _ = t.shown(field: 1, before: "x ", suggestion: "yz", info: "a", at: at(0))
        #expect(t.textChanged(field: 2, before: "q", at: at(1)).isEmpty)
        #expect(t.accepted(field: 2, text: "yz", at: at(1)).isEmpty)
        #expect(t.dismissed(field: 2, at: at(1)).isEmpty)
    }

    @Test func slidingWindowKeepsFollowing() {
        var t = Tracker()
        let head = String(repeating: "word ", count: 20)
        _ = t.shown(field: 1, before: head, suggestion: "next", info: "a", at: at(0))
        // The read window moved forward by 10 characters and the user typed "ne".
        let r = t.textChanged(field: 1, before: String(head.dropFirst(10)) + "ne", at: at(1))
        #expect(r.isEmpty)
        #expect(t.focusEnded(at: at(2)).first?.typedAlongChars == 2)
    }
}

@Suite struct TypingSampleFixReportTests {
    @Test func keptUndoneAndSent() {
        var t = TypingSampleTracker<Int>()
        _ = t.update(field: 1, before: "")
        _ = t.update(field: 1, before: "teh ")
        t.ownEdit(field: 1, after: "the ", from: "teh ", to: "the ")
        _ = t.update(field: 1, before: "the ui ")
        t.ownEdit(field: 1, after: "the up ", from: "ui ", to: "up ")
        // Hunch's undo puts "ui " back.
        t.ownEdit(field: 1, after: "the ui ", from: "up ", to: "ui ")
        _ = t.update(field: 1, before: "the ui adn ")
        t.ownEdit(field: 1, after: "the ui and ", from: "adn ", to: "and ")
        // The user backspaces the last fix and retypes the word as typed.
        _ = t.update(field: 1, before: "the ui adn ok")
        #expect(t.takeFixReport() == nil)
        _ = t.update(field: 1, before: "")   // sent
        let r = t.takeFixReport()
        #expect(r?.sent == true)
        #expect(r?.fixes.map(\.outcome) == [.kept, .undone, .undone])
        #expect(r?.fixes.map(\.to) == ["the ", "up ", "and "])
        #expect(t.takeFixReport() == nil)
    }

    @Test func changedAndFocusLoss() {
        var t = TypingSampleTracker<Int>()
        _ = t.update(field: 1, before: "")
        _ = t.update(field: 1, before: "teh ")
        t.ownEdit(field: 1, after: "the ", from: "teh ", to: "the ")
        _ = t.update(field: 1, before: "then ")
        _ = t.focusEnded()
        let r = t.takeFixReport()
        #expect(r?.sent == false && r?.fixes.map(\.outcome) == [.changed])
    }

    @Test func noFixesNoReport() {
        var t = TypingSampleTracker<Int>()
        _ = t.update(field: 1, before: "")
        _ = t.update(field: 1, before: "hello")
        _ = t.focusEnded()
        #expect(t.takeFixReport() == nil)
    }
}
