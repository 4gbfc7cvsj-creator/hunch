import HunchCore
import Testing
@testable import HunchSession

private struct AltDriver {
    var d = Driver()
    var altRequest: (RequestID, TextContext)?

    mutating func send(_ event: SessionEvent) -> [SessionCommand] {
        let out = d.send(event)
        for case let .requestAlternatives(id, ctx) in out { altRequest = (id, ctx) }
        return out
    }

    mutating func answerAlternatives(_ list: [String]) -> [SessionCommand] {
        let (id, ctx) = altRequest!
        return send(.alternatives(id: id, list: list, requestContext: ctx))
    }

    var shown: String? { d.session.visibleGhost?.remaining }

    static func shown(_ text: String = " world today", after before: String = "Hello") -> AltDriver {
        var a = AltDriver()
        a.d.show(text, after: before)
        return a
    }
}

@Suite struct AlternativeTests {
    @Test func firstCycleRequestsOncePerGhost() {
        var a = AltDriver.shown()
        let first = a.send(.cycleAlternative(forward: true))
        #expect(first.count == 1)
        guard case .requestAlternatives = first[0] else { Issue.record("expected request"); return }
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)
        #expect(a.shown == " world today")
    }

    @Test func arrivalAppliesPendingForwardAndRingWraps() {
        var a = AltDriver.shown()
        _ = a.send(.cycleAlternative(forward: true))
        let out = a.answerAlternatives([" there", "  WORLD today ", "", " there ", " friend"])
        #expect(out.presented == [" there"])
        #expect(a.send(.cycleAlternative(forward: true)).presented == [" friend"])
        #expect(a.send(.cycleAlternative(forward: true)).presented == [" world today"])
        #expect(a.send(.cycleAlternative(forward: false)).presented == [" friend"])
        #expect(a.send(.cycleAlternative(forward: false)).presented == [" there"])
        #expect(a.send(.cycleAlternative(forward: true)).requestsAlt == 0)
    }

    @Test func newestRequestIDCoversTheAlternativesRequest() {
        var a = AltDriver.shown()
        let shownID = a.d.session.latestRequestID
        #expect(a.d.session.newestRequestID == shownID)
        _ = a.send(.cycleAlternative(forward: true))
        let (altID, _) = a.altRequest!
        // A writer borrowing the executor after Option+Down must not take an id below this one.
        #expect(altID.raw > shownID.raw)
        #expect(a.d.session.newestRequestID.raw >= altID.raw)
    }

    @Test func pendingBackwardSelectsLast() {
        var a = AltDriver.shown()
        _ = a.send(.cycleAlternative(forward: false))
        #expect(a.answerAlternatives([" a b", " c d"]).presented == [" c d"])
    }

    @Test func emptyAlternativesKeepGhost() {
        var a = AltDriver.shown()
        _ = a.send(.cycleAlternative(forward: true))
        #expect(a.answerAlternatives([]).isEmpty)
        #expect(a.shown == " world today")
        var b = AltDriver.shown()
        _ = b.send(.cycleAlternative(forward: true))
        #expect(b.answerAlternatives([" world today", "   "]).isEmpty)
    }

    @Test func staleAlternativesAreDropped() {
        var a = AltDriver.shown()
        _ = a.send(.cycleAlternative(forward: true))
        let (id, ctx) = a.altRequest!
        #expect(a.send(.alternatives(id: RequestID(id.raw + 99), list: [" x y"], requestContext: ctx)).isEmpty)
        #expect(a.send(.alternatives(id: id, list: [" x y"], requestContext: Fixture.context("Hello!"))).isEmpty)
        #expect(a.send(.alternatives(id: id, list: [" x y"], requestContext: Fixture.context("Hello", field: Fixture.fieldB))).isEmpty)
        #expect(a.shown == " world today")
    }

    @Test func typingThroughChosenAlternative() {
        var a = AltDriver.shown()
        _ = a.send(.cycleAlternative(forward: true))
        _ = a.answerAlternatives([" there friend"])
        let out = a.d.type("Hello the")
        #expect(out.presented == ["re friend"])
        #expect(a.shown == "re friend")
        // Alternatives no longer offered after typing through.
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)
    }

    @Test func divergenceFocusEscapeAndAcceptAllClearRing() {
        func ready() -> AltDriver {
            var a = AltDriver.shown()
            _ = a.send(.cycleAlternative(forward: true))
            _ = a.answerAlternatives([" there friend"])
            return a
        }
        var a = ready()
        _ = a.d.type("Hello zzz")
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)

        a = ready()
        _ = a.send(.focusLost)
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)

        a = ready()
        _ = a.send(.escape(pauseBriefly: false))
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)

        a = ready()
        let out = a.send(.accept(.full, WordUnitOptions()))
        #expect(out.inserts == [" there friend"])
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)
    }

    @Test func cyclingDisabledAfterPartialAccept() {
        var a = AltDriver.shown()
        let out = a.send(.accept(.word, WordUnitOptions()))
        #expect(out.inserts.count == 1)
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)
        #expect(a.altRequest == nil)
    }

    @Test func noGhostNoCycle() {
        var a = AltDriver()
        _ = a.d.type("Hello")
        #expect(a.send(.cycleAlternative(forward: true)).isEmpty)
    }

    @Test func wordAcceptOnChosenAlternativeInsertsItsFirstWord() {
        var a = AltDriver.shown()
        _ = a.send(.cycleAlternative(forward: true))
        _ = a.answerAlternatives([" there friend"])
        #expect(a.send(.accept(.word, WordUnitOptions())).inserts == [" there"])
        #expect(a.shown == " friend")
    }
}

private extension Array where Element == SessionCommand {
    var requestsAlt: Int { filter { if case .requestAlternatives = $0 { true } else { false } }.count }
}
