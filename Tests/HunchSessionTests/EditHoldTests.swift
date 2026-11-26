import HunchCore
import Testing
@testable import HunchSession

/// Autocorrect fixing a word behind the caret hides the ghost for a moment. A Tab pressed on that
/// ghost (or held while the fix types) must go onto the next suggestion, never to the app.
@Suite struct EditHoldTests {
    private static let word = SessionEvent.accept(.word, WordUnitOptions())

    @Test func editKeepsTabOwnedAndReplaysOntoNextSuggestion() {
        var d = Driver()
        d.show(" brown fox", after: "teh quick")
        let took = d.send(.editBehindCaret)
        #expect(took.hides)
        #expect(took.contains(.holdAccept(field: Fixture.fieldA, app: Fixture.app, urlHost: nil)))
        #expect(d.session.isHoldingForEdit(now: d.now))
        // Tab pressed while the fix runs: queued, nothing inserted yet.
        #expect(d.send(Self.word).inserts.isEmpty)
        // The edit is done; its first read anchors the hold and asks for a suggestion.
        d.now = d.now + .milliseconds(400)
        d.type("the quick")
        #expect(!d.session.isHoldingForEdit(now: d.now))
        let shown = d.answer(" brown fox")
        #expect(shown.inserts == [" brown"])
    }

    @Test func noVisibleGhostIsAPlainDismiss() {
        var d = Driver()
        d.type("teh quick")
        let took = d.send(.editBehindCaret)
        #expect(!took.contains(.holdAccept(field: Fixture.fieldA, app: Fixture.app, urlHost: nil)))
        #expect(!d.session.isHoldingForEdit(now: d.now))
    }

    @Test func typingDuringTheEditDropsQueuedPresses() {
        var d = Driver()
        d.show(" brown fox", after: "teh quick")
        d.send(.editBehindCaret)
        d.send(Self.word)
        d.send(.characterTyped)
        #expect(!d.session.isHoldingForEdit(now: d.now))
        d.type("the quick j")
        #expect(d.answer(" jumps").inserts.isEmpty)
    }

    @Test func cancelledRequestResultDoesNotEndTheEditHold() {
        var d = Driver()
        d.show(" brown fox", after: "teh quick")
        d.send(.editBehindCaret)
        d.send(Self.word)
        // A late answer to the request cancelled when the edit began.
        d.answer(" brown fox")
        #expect(d.session.isHoldingForEdit(now: d.now))
    }

    @Test func pressWaitsAcrossChainedFixes() {
        var d = Driver()
        d.show(" brown fox", after: "teh quik")
        d.send(.editBehindCaret)
        d.send(Self.word)
        // First fix read back; before its suggestion, the next fix takes the field.
        d.type("the quik")
        #expect(d.session.isHoldingAccept(now: d.now))
        let next = d.send(.editBehindCaret)
        #expect(next.contains(.holdAccept(field: Fixture.fieldA, app: Fixture.app, urlHost: nil)))
        d.type("the quick")
        #expect(d.answer(" brown fox").inserts == [" brown"])
    }

    @Test func withoutPressesTheNextFixNeedNotWait() {
        var d = Driver()
        d.show(" brown fox", after: "teh quik")
        d.send(.editBehindCaret)
        d.type("the quik")
        #expect(!d.session.isHoldingAccept(now: d.now))
    }

    @Test func editHoldExpires() {
        var d = Driver()
        d.show(" brown fox", after: "teh quick")
        d.send(.editBehindCaret)
        d.send(Self.word)
        d.now = d.now + SuggestionSession.editHold + .milliseconds(10)
        #expect(!d.session.isHoldingForEdit(now: d.now))
        d.type("the quick")
        #expect(d.answer(" brown fox").inserts.isEmpty)
    }
}

@Suite struct EditHoldRepeatTests {
    @Test func reportingTheEditTwiceKeepsTheHold() {
        var d = Driver()
        d.show(" brown fox", after: "teh quick")
        d.send(.editBehindCaret)
        d.send(.editBehindCaret)
        #expect(d.session.isHoldingForEdit(now: d.now))
        d.send(.accept(.word, WordUnitOptions()))
        d.type("the quick")
        #expect(d.answer(" brown fox").inserts == [" brown"])
    }
}
