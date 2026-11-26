import HunchCore
import Testing
@testable import HunchSession

/// A superseded request's result is shown when the text typed since its request is the start of it.
@Suite struct LateResultTests {
    @Test func lateResultShowsTheRestAndTypesThrough() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello w")
        let out = d.send(.result(id: old.id, text: " world, how are you", requestContext: old.context))
        #expect(out.presented == ["orld, how are you"])
        // Typing on follows the late ghost like any other.
        let next = d.type("Hello wo")
        #expect(next.presented == ["rld, how are you"])
        #expect(next.requests.isEmpty)
    }

    @Test func lateResultThatDisagreesIsDropped() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello t")
        #expect(d.send(.result(id: old.id, text: " world", requestContext: old.context)).isEmpty)
        // Nothing typed past the end of it, or only whitespace left: nothing to show either.
        d.type("Hello world")
        #expect(d.send(.result(id: old.id, text: " world", requestContext: old.context)).isEmpty)
        #expect(d.send(.result(id: old.id, text: " world  ", requestContext: old.context)).isEmpty)
        #expect(d.session.visibleGhost == nil)
    }

    @Test func latestResultReplacesALateGhost() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello w")
        d.send(.result(id: old.id, text: " world", requestContext: old.context))
        #expect(d.answer("onderful day").presented == ["onderful day"])
    }

    @Test func latestResultForOlderTextIsDroppedAfterTypingThroughALateGhost() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello w")
        d.send(.result(id: old.id, text: " world, friend", requestContext: old.context))
        d.type("Hello wo")
        #expect(d.answer("onderful day").isEmpty)
        #expect(d.session.visibleGhost?.remaining == "rld, friend")
    }

    @Test func olderLateResultNeverReplacesAVisibleGhost() {
        var d = Driver()
        d.type("Hello")
        let first = d.lastRequest!
        d.type("Hello w")
        let second = d.lastRequest!
        d.type("Hello wo")
        d.send(.result(id: second.id, text: "orld today", requestContext: second.context))
        #expect(d.session.visibleGhost?.remaining == "rld today")
        #expect(d.send(.result(id: first.id, text: " world, friend", requestContext: first.context)).isEmpty)
        #expect(d.session.visibleGhost?.remaining == "rld today")
    }

    @Test func cancelledRequestsStayVoid() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello w")
        d.send(.escape(pauseBriefly: false))
        #expect(d.send(.result(id: old.id, text: " world", requestContext: old.context)).isEmpty)
        // A request issued after the cancel is not affected.
        d.type("Hello wo")
        #expect(d.answer("rld").presented == ["rld"])
    }

    @Test func lateResultNeedsTheSameFieldAndTextAfterTheCaret() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello w", field: Fixture.fieldB)
        #expect(d.send(.result(id: old.id, text: " world", requestContext: old.context)).isEmpty)

        var e = Driver()
        e.send(.context(Fixture.context("Hello", after: "!", lineEnd: false), Fixture.geometry, midLineEnabled: true))
        let request = e.lastRequest!
        e.send(.context(Fixture.context("Hello w", after: "?", lineEnd: false), Fixture.geometry, midLineEnabled: true))
        #expect(e.send(.result(id: request.id, text: " world", requestContext: request.context)).isEmpty)
    }

    @Test func lateGhostOffersNoAlternatives() {
        var d = Driver()
        d.type("Hello")
        let old = d.lastRequest!
        d.type("Hello w")
        d.send(.result(id: old.id, text: " world", requestContext: old.context))
        #expect(d.send(.cycleAlternative(forward: true)).isEmpty)
    }

    @Test func traditionalChineseLateResult() {
        var d = Driver()
        d.type("我們明天")
        let old = d.lastRequest!
        d.type("我們明天一")
        let out = d.send(.result(id: old.id, text: "一起去吃飯吧", requestContext: old.context))
        #expect(out.presented == ["起去吃飯吧"])
    }
}
