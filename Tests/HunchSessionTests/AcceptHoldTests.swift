import HunchCore
import Testing
@testable import HunchSession

/// Fast Tab presses right after the last word was accepted are held and replayed onto the next
/// suggestion instead of falling through to the app.
@Suite struct AcceptHoldTests {
    private static let word = SessionEvent.accept(.word, WordUnitOptions())

    /// Shows " world", accepts it, and lets the insert land.
    private func exhausted() -> Driver {
        var d = Driver()
        d.show(" world", after: "Hello")
        let accept = d.send(Self.word)
        #expect(accept.inserts == [" world"])
        #expect(accept.contains(.holdAccept(field: Fixture.fieldA, app: Fixture.app, urlHost: nil)))
        d.send(.insertFinished(success: true))
        d.type("Hello world")
        return d
    }

    @Test func pressDuringHoldIsReplayedOntoNextSuggestion() {
        var d = exhausted()
        #expect(d.session.isHoldingAccept(now: d.now))
        #expect(d.send(Self.word).inserts.isEmpty)
        let shown = d.answer(" again and again")
        #expect(shown.inserts == [" again"])
        #expect(d.session.visibleGhost?.remaining == " and again")
        #expect(!d.session.isHoldingAccept(now: d.now))
    }

    @Test func atMostTwoPressesAreQueued() {
        var d = exhausted()
        for _ in 0..<4 { d.send(Self.word) }
        let shown = d.answer(" one two three four")
        // One insert at a time; the second waits for insertFinished.
        #expect(shown.inserts == [" one"])
        #expect(d.send(.insertFinished(success: true)).inserts == [" two"])
        #expect(d.session.visibleGhost?.remaining == " three four")
    }

    @Test func expiredHoldDropsQueuedPresses() {
        var d = exhausted()
        d.send(Self.word)
        d.now = d.now + .milliseconds(1500)
        let shown = d.answer(" later")
        #expect(shown.inserts.isEmpty)
        #expect(shown.presented == [" later"])
    }

    @Test func typingEndsTheHold() {
        var d = exhausted()
        d.send(Self.word)
        d.type("Hello world!")
        #expect(!d.session.isHoldingAccept(now: d.now))
        #expect(d.answer(" Bye").inserts.isEmpty)
    }

    @Test func emptyResultDropsQueuedPresses() {
        var d = exhausted()
        d.send(Self.word)
        #expect(d.answer("   ").inserts.isEmpty)
        #expect(!d.session.isHoldingAccept(now: d.now))
    }

    @Test func escapeEndsTheHold() {
        var d = exhausted()
        d.send(.escape(pauseBriefly: false))
        #expect(!d.session.isHoldingAccept(now: d.now))
    }
}

/// Mirror mode redraws the field's line, so it must know when accepted text hasn't landed yet.
@Suite struct AcceptedTextLandingTests {
    @Test func landingFromAcceptUntilTheFieldShowsIt() {
        var d = Driver()
        d.show(" big wide world", after: "Hello")
        #expect(!d.session.acceptedTextLanding)
        d.send(.accept(.word, WordUnitOptions()))
        #expect(d.session.acceptedTextLanding)
        d.send(.insertFinished(success: true))
        // Inserted but not yet reported by the field.
        #expect(d.session.acceptedTextLanding)
        d.type("Hello bi")
        #expect(d.session.acceptedTextLanding)
        let landed = d.type("Hello big")
        #expect(!d.session.acceptedTextLanding)
        #expect(landed.presented == [" wide world"])
    }

    @Test func failedInsertIsNotLanding() {
        var d = Driver()
        d.show(" big wide world", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.insertFinished(success: false))
        #expect(!d.session.acceptedTextLanding)
    }
}
