import Testing
@testable import HunchText

@Suite struct TypingSampleTrackerTests {
    @Test func undoesOwnFixesAndKeepsTheRest() {
        var t = TypingSampleTracker<Int>()
        #expect(t.update(field: 1, before: "Hi ") == nil)
        _ = t.update(field: 1, before: "Hi teh ")
        t.ownEdit(field: 1, after: "Hi the ", from: "teh ", to: "the ")
        _ = t.update(field: 1, before: "Hi the fo the ca")
        // A delayed fix with text typed on after it.
        t.ownEdit(field: 1, after: "Hi the for the cat ", from: "fo the cat ", to: "for the cat ")
        _ = t.update(field: 1, before: "Hi the for the cat sat")
        let s = t.focusEnded()
        #expect(s == .init(typed: "teh fo the cat sat", final: "the for the cat sat",
                           fixes: [.init(from: "teh ", to: "the "), .init(from: "fo the cat ", to: "for the cat ")],
                           backspaced: 0, verified: true))
    }

    @Test func backspaceUndoOfAFixRestoresTheTypedWord() {
        var t = TypingSampleTracker<Int>()
        _ = t.update(field: 1, before: "")
        _ = t.update(field: 1, before: "ui ")
        t.ownEdit(field: 1, after: "up ", from: "ui ", to: "up ")
        t.ownEdit(field: 1, after: "ui ", from: "up ", to: "ui ")
        _ = t.update(field: 1, before: "ui is new")
        #expect(t.focusEnded()?.typed == "ui is new")
    }

    @Test func userBackspacesAreCountedAndMessagesSplitOnSend() {
        var t = TypingSampleTracker<Int>()
        _ = t.update(field: 1, before: "")
        _ = t.update(field: 1, before: "hello wrold")
        _ = t.update(field: 1, before: "hello wr")
        _ = t.update(field: 1, before: "hello world")
        let sent = t.update(field: 1, before: "")
        #expect(sent?.typed == "hello world" && sent?.backspaced == 3)
        _ = t.update(field: 1, before: "next one")
        #expect(t.update(field: 2, before: "")?.typed == "next one")
    }

    @Test func editedTextBeforeAFixIsMarkedUnverified() {
        var t = TypingSampleTracker<Int>()
        _ = t.update(field: 1, before: "")
        t.ownEdit(field: 1, after: "the ", from: "teh ", to: "the ")
        _ = t.update(field: 1, before: "xthe end")  // something changed before the fix
        let s = t.focusEnded()
        #expect(s?.verified == false && s?.final == "xthe end")
    }
}
