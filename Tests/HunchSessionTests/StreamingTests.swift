import HunchCore
import Testing
@testable import HunchSession

/// Ghosts shown while the suggestion is still written (`.partial`), then settled by `.result`.
@Suite struct StreamingTests {
    private func partial(_ d: inout Driver, _ text: String) -> [SessionCommand] {
        let last = d.lastRequest!
        return d.send(.partial(id: last.id, text: text, requestContext: last.context))
    }

    @Test func firstWordsStreamThenTheRestArrivesWhole() {
        var d = Driver()
        d.type("Hello")
        #expect(partial(&d, " world,").presented == [" world,"])
        #expect(partial(&d, " world, how").isEmpty)   // no word-by-word growth
        #expect(d.session.visibleGhost?.remaining == " world,")
        #expect(d.answer(" world, how are you").presented == [" world, how are you"])
        // The stream is over: a late partial changes nothing.
        #expect(partial(&d, " world, how are").isEmpty)
        #expect(d.session.visibleGhost?.remaining == " world, how are you")
    }

    @Test func suppressedFinalHidesTheStream() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " world")
        let out = d.send(.result(id: d.lastRequest!.id, text: nil, requestContext: d.lastRequest!.context))
        #expect(out.hides)
        #expect(d.session.visibleGhost == nil)
    }

    @Test func shorterFinalShortens() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " world, how are")
        #expect(d.answer(" world").presented == [" world"])
    }

    @Test func typingThroughAStreamKeepsTheFinalRest() {
        var d = Driver()
        d.type("Hello")
        let request = d.lastRequest!
        partial(&d, " world, how")
        let typed = d.type("Hello wo")
        #expect(typed.presented == ["rld, how"])
        #expect(typed.requests.isEmpty)   // no refill while it is still written
        let out = d.send(.result(id: request.id, text: " world, how are you", requestContext: request.context))
        #expect(out.presented == ["rld, how are you"])
    }

    @Test func finalThatNoLongerMatchesHides() {
        var d = Driver()
        d.type("Hello")
        let request = d.lastRequest!
        partial(&d, " world, how")
        d.type("Hello wo")
        let out = d.send(.result(id: request.id, text: " what a day", requestContext: request.context))
        #expect(out.hides)
    }

    @Test func tabAcceptsWhatIsShown() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " world, how")
        let out = d.send(.accept(.word, WordUnitOptions()))
        #expect(out.inserts == [" world"])
        #expect(out.presented == [", how"])
    }

    @Test func partialNeverReplacesAnotherGhost() {
        var d = Driver()
        d.show(" world, how are you", after: "Hello")
        d.type("Hello world") // types through: still the first ghost
        // A refill request may be issued; its partial must not replace the visible ghost.
        if let last = d.lastRequest, last.refill {
            #expect(d.send(.partial(id: last.id, text: " today", requestContext: last.context)).isEmpty)
        }
        #expect(d.session.visibleGhost?.remaining == ", how are you")
    }

    @Test func partialsForOtherTextOrOlderRequestsAreDropped() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello!")
        #expect(d.send(.partial(id: old.id, text: " world", requestContext: old.context)).isEmpty)
        let latest = d.lastRequest!
        #expect(d.send(.partial(id: latest.id, text: " x", requestContext: Fixture.context("Hello!?"))).isEmpty)
        d.send(.escape(pauseBriefly: false))
        #expect(d.send(.partial(id: latest.id, text: " x", requestContext: latest.context)).isEmpty)
    }

    @Test func noAlternativesWhileWriting() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " world")
        #expect(d.send(.cycleAlternative(forward: true)).isEmpty)
    }

    @Test func traditionalChineseStream() {
        var d = Driver()
        d.type("我們明天")
        #expect(partial(&d, "一起").presented == ["一起"])
        #expect(d.type("我們明天一").presented == ["起"])
        let request = d.lastRequest!
        let out = d.send(.result(id: request.id, text: "一起去吃飯吧", requestContext: request.context))
        #expect(out.presented == ["起去吃飯吧"])
    }
}

/// Tab through a streamed ghost while it is still written: the finished result must not pull the
/// ghost away or end the accept hold (the next Tab would reach the app and move focus).
@Suite struct StreamingAcceptTests {
    private static let word = SessionEvent.accept(.word, WordUnitOptions())

    private func partial(_ d: inout Driver, _ text: String) {
        let last = d.lastRequest!
        d.send(.partial(id: last.id, text: text, requestContext: last.context))
    }

    @Test func allStreamedWordsTakenThenFinalShowsTheRest() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " world")
        let took = d.send(Self.word)
        #expect(took.inserts == [" world"])
        #expect(d.session.isHoldingAccept(now: d.now))
        // A second Tab while the rest is still written: queued for it.
        #expect(d.send(Self.word).inserts.isEmpty)
        let out = d.answer(" world, how are you")
        #expect(out.presented.first == ", how are you")
        // The queued press took the next word; its insert follows the first one.
        let next = d.send(.insertFinished(success: true)).inserts
        #expect(next.count == 1)
        #expect(d.session.visibleGhost?.remaining == String(", how are you".dropFirst(next.first?.count ?? 0)))
    }

    @Test func finalWithNothingMoreKeepsTheHold() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " world")
        d.send(Self.word)
        d.send(Self.word)
        d.answer(" world")
        #expect(d.session.isHoldingAccept(now: d.now))
        // The insert lands; the next suggestion takes the waiting press.
        d.send(.insertFinished(success: true))
        d.type("Hello world")
        #expect(d.answer(" again and again").inserts == [" again"])
    }

    @Test func differentFinalKeepsTheStreamedRestAfterTab() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " big wide world")
        d.send(Self.word)
        d.send(.insertFinished(success: true))
        d.type("Hello big")
        let out = d.answer(" small world")
        #expect(!out.hides)
        #expect(d.session.visibleGhost?.remaining == " wide world")
        #expect(d.send(Self.word).inserts == [" wide"])
    }

    @Test func suppressedFinalAfterTabKeepsTheStreamedRest() {
        var d = Driver()
        d.type("Hello")
        partial(&d, " big wide world")
        d.send(Self.word)
        let last = d.lastRequest!
        let out = d.send(.result(id: last.id, text: nil, requestContext: last.context))
        #expect(!out.hides)
        #expect(d.session.visibleGhost?.remaining == " wide world")
    }
}
