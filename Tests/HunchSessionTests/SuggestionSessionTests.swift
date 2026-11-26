import HunchCore
import Testing
@testable import HunchSession

@Suite struct SessionLifecycleTests {
    @Test func contextRequestsAndFreshResultPresents() {
        var d = Driver()
        let first = d.type("Hello")
        #expect(first.requests.count == 1)
        let shown = d.answer(" world, how are you")
        #expect(shown.presented == [" world, how are you"])
        #expect(d.session.visibleGhost?.remaining == " world, how are you")
    }

    @Test func staleResultsAreDropped() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello!")
        // Old request id.
        #expect(d.send(.result(id: old.id, text: " there", requestContext: old.context)).isEmpty)
        // Latest id but the field content changed since.
        let latest = d.lastRequest!
        #expect(d.send(.result(id: latest.id, text: " there", requestContext: Fixture.context("Hello!?"))).isEmpty)
        // Suppressed outcome.
        #expect(d.send(.result(id: latest.id, text: nil, requestContext: latest.context)).isEmpty)
        #expect(d.send(.result(id: latest.id, text: "   ", requestContext: latest.context)).isEmpty)
        #expect(d.session.visibleGhost == nil)
    }

    @Test func resultForAnotherFieldIsDropped() {
        var d = Driver()
        d.type("Hello")
        let req = d.lastRequest!
        let wrongField = Fixture.context("Hello", field: Fixture.fieldB)
        #expect(d.send(.result(id: req.id, text: " x", requestContext: wrongField)).isEmpty)
    }

    @Test func markedTextSelectionAndMidLineHide() {
        for variant in 0..<3 {
            var d = Driver()
            d.show(" world", after: "Hello")
            let ctx: TextContext
            switch variant {
            case 0: ctx = Fixture.context("Hello", marked: true)
            case 1: ctx = Fixture.context("Hello", selection: 3)
            default: ctx = Fixture.context("Hello", after: "tail", lineEnd: false)
            }
            let out = d.send(.context(ctx, Fixture.geometry, midLineEnabled: false))
            #expect(out.hides)
            #expect(out.contains(.cancelRequest))
            #expect(out.requests.isEmpty)
            #expect(d.session.visibleGhost == nil)
        }
    }

    @Test func midLineAllowedByPolicyRequests() {
        var d = Driver()
        let out = d.send(.context(Fixture.context("Hello", after: "tail", lineEnd: false), Fixture.geometry,
                                  midLineEnabled: true))
        #expect(out.requests.count == 1)
    }

    @Test func escapePausesThenExpires() {
        var d = Driver()
        d.show(" world", after: "Hello")
        let out = d.send(.escape(pauseBriefly: true))
        #expect(out.hides && out.contains(.cancelRequest))
        #expect(d.type("Hello!").requests.isEmpty)
        d.now = Fixture.t0 + .seconds(4)
        #expect(d.type("Hello!!").requests.count == 1)
    }

    @Test func escapeWithoutPauseKeepsRequesting() {
        var d = Driver()
        d.show(" world", after: "Hello")
        d.send(.escape(pauseBriefly: false))
        #expect(d.type("Hello!").requests.count == 1)
    }

    @Test func resultDuringPauseIsDropped() {
        var d = Driver()
        d.type("Hello")
        d.send(.escape(pauseBriefly: true))
        #expect(d.answer(" world").isEmpty)
    }

    @Test func forceActivateClearsPauseAndRequests() {
        var d = Driver()
        d.show(" world", after: "Hello")
        d.send(.escape(pauseBriefly: true))
        d.type("Hello")
        let out = d.send(.forceActivate)
        #expect(out.requests.count == 1)
        #expect(d.session.pausedUntil == nil)
        #expect(d.answer(" again").presented == [" again"])
    }

    @Test func blockedAndFocusLostHideAndCancel() {
        var d = Driver()
        d.show(" world", after: "Hello")
        let out = d.send(.blocked)
        #expect(out.hides && out.contains(.cancelRequest))
        #expect(d.session.visibleGhost == nil)
        d.show(" world", after: "Hello")
        #expect(d.send(.focusLost).hides)
        d.show(" world", after: "Hello")
        #expect(d.send(.secureInputChanged(true)).hides)
    }

    @Test func requestIDsAreMonotonic() {
        var d = Driver()
        let a = d.type("a").requests[0].0
        let b = d.type("ab").requests[0].0
        #expect(a < b)
        #expect(d.session.latestRequestID == b)
    }
}

@Suite struct TypeThroughTests {
    @Test func typingTheGhostTrimsWithoutRequest() {
        var d = Driver()
        d.show(" world, how are you", after: "Hello")
        let out = d.type("Hello wo", geometry: Fixture.movedGeometry)
        #expect(out.requests.isEmpty)
        #expect(out.presented == ["rld, how are you"])
        #expect(d.session.visibleGhost?.geometry == Fixture.movedGeometry)
    }

    @Test func divergingHidesAndRequests() {
        var d = Driver()
        d.show(" world, how are you", after: "Hello")
        let out = d.type("Hello x")
        #expect(out.hides)
        #expect(out.requests.count == 1)
        #expect(out.requests[0].2 == false)
    }

    @Test func exhaustingTheGhostRequestsFresh() {
        var d = Driver()
        d.show(" now", after: "Hello")
        let out = d.type("Hello now")
        #expect(out.hides)
        #expect(out.requests.count == 1)
        #expect(out.requests[0].2 == false)
    }

    @Test func slidingWindowTypeThrough() {
        var d = Driver()
        let doc = String(repeating: "lorem ipsum ", count: 334).prefix(4000)
        d.show(" dolor sit amet, consectetur", after: String(doc))
        // The window dropped 5 leading chars while the user typed " dol".
        let slid = String(doc.dropFirst(5)) + " dol"
        let out = d.type(slid)
        #expect(out.requests.isEmpty)
        #expect(out.presented == ["or sit amet, consectetur"])
        // And again, sliding further.
        let slid2 = String(doc.dropFirst(9)) + " dolor"
        #expect(d.type(slid2).presented == [" sit amet, consectetur"])
    }

    @Test func slidingWindowWordAccept() {
        var d = Driver()
        let doc = String(String(repeating: "lorem ipsum ", count: 334).prefix(4000))
        d.show(" dolor sit amet, consectetur", after: doc)
        let accept = d.send(.accept(.word, WordUnitOptions()))
        #expect(accept.inserts == [" dolor"])
        d.send(.insertFinished(success: true))
        let out = d.type(String(doc.dropFirst(6)) + " dolor")
        #expect(out.requests.isEmpty)
        #expect(!out.hides)
        #expect(d.session.visibleGhost?.remaining == " sit amet, consectetur")
    }
}

@Suite struct FreshnessTests {
    @Test func republishWhileVisibleInSameField() {
        var d = Driver()
        d.show(" world again", after: "Hello")
        #expect(d.session.shouldRepublish)
        let tick = d.send(.republishTick)
        #expect(tick.count == 1)
        if case .republish(let ghost) = tick.first { #expect(ghost.field == Fixture.fieldA) } else { Issue.record("no republish") }
        // Still republishing after the user only read it for a while.
        d.now = Fixture.t0 + .seconds(5)
        #expect(d.send(.republishTick).count == 1)
    }

    @Test func noRepublishAfterHide() {
        var d = Driver()
        d.show(" world again", after: "Hello")
        d.send(.mouseDown)
        #expect(!d.session.shouldRepublish)
        #expect(d.send(.republishTick).isEmpty)
    }

    @Test func noRepublishWithoutGhostOrAfterIneligibleContext() {
        var d = Driver()
        #expect(d.send(.republishTick).isEmpty)
        d.show(" world again", after: "Hello")
        d.send(.context(Fixture.context("Hello", marked: true), Fixture.geometry, midLineEnabled: false))
        #expect(d.send(.republishTick).isEmpty)
    }
}

@Suite struct InsertSerializationTests {
    @Test func midInsertContextIsInProgress() {
        var d = Driver()
        d.show(" wonderful world today", after: "Hello")
        #expect(d.send(.accept(.word, WordUnitOptions())).inserts == [" wonderful"])
        // AX caught the field with half the word inserted.
        let partial = d.type("Hello wond", geometry: Fixture.movedGeometry)
        #expect(partial.isEmpty)
        #expect(d.session.visibleGhost?.remaining == " world today")
        #expect(d.session.visibleGhost?.geometry == Fixture.movedGeometry)
        d.send(.insertFinished(success: true))
        let done = d.type("Hello wonderful")
        #expect(done.requests.isEmpty && !done.hides)
        #expect(done.presented == [" world today"])
    }

    @Test func rapidTabsQueueInOrder() {
        var d = Driver()
        d.show(" one two three four", after: "Hello")
        #expect(d.send(.accept(.word, WordUnitOptions())).inserts == [" one"])
        #expect(d.send(.accept(.word, WordUnitOptions())).inserts.isEmpty)
        #expect(d.send(.accept(.word, WordUnitOptions())).inserts.isEmpty)
        #expect(d.session.visibleGhost?.remaining == " four")
        #expect(d.send(.insertFinished(success: true)).inserts == [" two"])
        // A context mid-way through the queue is still in progress.
        #expect(d.type("Hello one tw").isEmpty)
        #expect(d.send(.insertFinished(success: true)).inserts == [" three"])
        #expect(d.send(.insertFinished(success: true)).isEmpty)
        #expect(!d.session.hasPendingInsert)
        let landed = d.type("Hello one two three")
        #expect(landed.presented == [" four"])
    }

    @Test func fullAcceptHidesAndWaitsForInsert() {
        var d = Driver()
        d.show(" world", after: "Hello")
        let out = d.send(.accept(.full, WordUnitOptions()))
        #expect(out.hides)
        #expect(out.inserts == [" world"])
        #expect(d.type("Hello wor").isEmpty)
        d.send(.insertFinished(success: true))
        let landed = d.type("Hello world")
        #expect(landed.requests.count == 1)
    }

    @Test func failedInsertDropsGhostAndQueue() {
        var d = Driver()
        d.show(" one two three", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.accept(.word, WordUnitOptions()))
        let out = d.send(.insertFinished(success: false))
        #expect(out.hides)
        #expect(out.inserts.isEmpty)
        #expect(!d.session.hasPendingInsert)
        #expect(d.session.visibleGhost == nil)
    }

    @Test func acceptWithoutGhostDoesNothing() {
        var d = Driver()
        d.type("Hello")
        #expect(d.send(.accept(.word, WordUnitOptions())).isEmpty)
    }
}

@Suite struct FieldCheckTests {
    @Test func otherFieldHidesImmediately() {
        var d = Driver()
        d.show(" world", after: "Hello")
        let out = d.type("Other", field: Fixture.fieldB)
        #expect(out.first == .hide)
        #expect(out.requests.count == 1)
        #expect(out.requests[0].1.field == Fixture.fieldB)
        #expect(d.session.visibleGhost == nil)
    }

    @Test func otherFieldDropsQueuedInserts() {
        var d = Driver()
        d.show(" one two three", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.accept(.word, WordUnitOptions()))
        d.type("Other", field: Fixture.fieldB)
        #expect(d.send(.insertFinished(success: true)).isEmpty)
    }
}

@Suite struct RefillTests {
    @Test func refillWhenFewerThanTwoWordsRemain() {
        var d = Driver()
        d.show(" big world", after: "Hello")
        let out = d.type("Hello big")
        #expect(out.presented == [" world"])
        #expect(out.requests.count == 1)
        #expect(out.requests[0].2 == true)
    }

    @Test func noRefillWithEnoughWords() {
        var d = Driver()
        d.show(" big wide world", after: "Hello")
        #expect(d.type("Hello big").requests.isEmpty)
        // No progress (same text, e.g. a geometry update) never refills.
        var e = Driver()
        e.show(" world", after: "Hello")
        #expect(e.type("Hello").requests.isEmpty)
    }

    @Test func refillResultReplacesGhostWhenValid() {
        var d = Driver()
        d.show(" big world", after: "Hello")
        d.type("Hello big")
        let out = d.answer(" world of ours")
        #expect(out.presented == [" world of ours"])
    }

    @Test func staleRefillResultIsDropped() {
        var d = Driver()
        d.show(" big world", after: "Hello")
        d.type("Hello big")
        let refill = d.lastRequest!
        d.type("Hello big w") // another refill supersedes
        #expect(d.send(.result(id: refill.id, text: " world of ours", requestContext: refill.context)).isEmpty)
        #expect(d.session.visibleGhost?.remaining == "orld")
    }

    @Test func refillAfterWordAcceptLands() {
        var d = Driver()
        d.show(" big world", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.insertFinished(success: true))
        let out = d.type("Hello big")
        #expect(out.requests.count == 1 && out.requests[0].2)
    }

    @Test func refillNotRepeatedForSameContent() {
        var d = Driver()
        d.show(" big world", after: "Hello")
        #expect(d.type("Hello big").requests.count == 1)
        #expect(d.type("Hello big").requests.isEmpty)
    }
}

@Suite struct InsertLostTests {
    @Test func lostInsertRestoresGhost() {
        var d = Driver()
        d.show(" one two three", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.insertFinished(success: true))
        let out = d.send(.insertLost(" one"))
        #expect(out.presented == [" one two three"])
        #expect(d.session.visibleGhost?.remaining == " one two three")
    }

    @Test func lostInsertAfterLastWordBringsGhostBack() {
        var d = Driver()
        d.show(" one", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.insertFinished(success: true))
        #expect(d.session.visibleGhost == nil)
        d.send(.insertLost(" one"))
        #expect(d.session.visibleGhost?.remaining == " one")
    }

    @Test func lostInsertAfterFieldMovedOnRestoresNothing() {
        var d = Driver()
        d.show(" one two", after: "Hello")
        d.send(.accept(.word, WordUnitOptions()))
        d.send(.insertFinished(success: true))
        d.type("Hello one")
        #expect(d.send(.insertLost(" one")).isEmpty)
    }
}
