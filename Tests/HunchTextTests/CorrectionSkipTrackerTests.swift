import Testing
@testable import HunchText

@Test func skipWhenTypedOnPastFix() {
    var t = CorrectionSkipTracker<Int>()
    t.shown(field: 1, before: "I like Teh", word: "Teh")
    #expect(t.update(field: 1, before: "I like Teh ") == "teh")
    #expect(t.update(field: 1, before: "I like Teh x") == nil)
}

@Test func sameTextKeepsPendingAndShownIsIdempotent() {
    var t = CorrectionSkipTracker<Int>()
    t.shown(field: 1, before: "a Teh", word: "Teh")
    #expect(t.update(field: 1, before: "a Teh") == nil)
    t.shown(field: 1, before: "a Teh", word: "Teh")
    #expect(t.update(field: 1, before: "a Teh!") == "teh")
}

@Test func backspaceEmptyOrOtherFieldIsNotSkip() {
    var t = CorrectionSkipTracker<Int>()
    t.shown(field: 1, before: "a Teh", word: "Teh")
    #expect(t.update(field: 1, before: "a Te") == nil)
    #expect(t.update(field: 1, before: "a Teh ") == nil)   // cleared already
    t.shown(field: 1, before: "a Teh", word: "Teh")
    #expect(t.update(field: 1, before: "") == nil)
    #expect(t.update(field: 1, before: "a Teh ") == nil)
    t.shown(field: 1, before: "a Teh", word: "Teh")
    #expect(t.update(field: 2, before: "a Teh ") == nil)
    #expect(t.update(field: 1, before: "a Teh ") == nil)
}

@Test func escapeAcceptAndReset() {
    var t = CorrectionSkipTracker<Int>()
    t.shown(field: 1, before: "x Teh", word: "Teh")
    #expect(t.escaped() == "teh")
    #expect(t.escaped() == nil)
    t.shown(field: 1, before: "x Teh", word: "Teh")
    #expect(t.accepted() == "teh")
    #expect(t.accepted() == nil)
    #expect(t.update(field: 1, before: "x Teh ") == nil)
    t.shown(field: 1, before: "x Teh", word: "Teh")
    t.reset()
    #expect(t.update(field: 1, before: "x Teh ") == nil)
}

@Test func sameOccurrenceCountsOnce() {
    var t = CorrectionSkipTracker<Int>()
    t.shown(field: 1, before: "hi amigo,", word: "amigo", trailingCount: 1)
    #expect(t.update(field: 1, before: "hi amigo, ") == "amigo")
    t.shown(field: 1, before: "hi amigo, ", word: "amigo", trailingCount: 2)
    #expect(t.update(field: 1, before: "hi amigo, h") == nil)
    // A later occurrence counts again.
    t.shown(field: 1, before: "hi amigo, bye amigo ", word: "amigo", trailingCount: 1)
    #expect(t.update(field: 1, before: "hi amigo, bye amigo o") == "amigo")
}
