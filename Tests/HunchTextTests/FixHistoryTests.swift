import Testing
@testable import HunchText

// Autocorrect "undo a fix later": which fixes are kept, how they follow typing, when they are
// dropped, the order the revert shortcut takes them in, and the checks that make a revert do
// nothing when the text around the fix changed.

/// An automatic fix of `word` (followed by `tail`) at the end of `before`, then the read showing it.
@discardableResult
private func fixed(_ h: inout FixHistory<Int>, field: Int = 1, before: String, word: String, fix: String,
                   tail: String = " ", automatic: Bool = true) -> String {
    h.record(field: field, beforeFix: before, original: word, replacement: fix, tail: tail, automatic: automatic)
    let after = String(before.dropLast(word.count + tail.count)) + fix + tail
    h.update(field: field, before: after)
    return after
}

@Test func fixIsKeptAndFollowsTyping() {
    var h = FixHistory<Int>()
    h.update(field: 1, before: "I like teh ")
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    h.update(field: 1, before: "I like the cat")
    let newest = h.newest(field: 1, before: "I like the cat")
    #expect(newest?.original == "teh")
    #expect(newest?.span == "the cat")
    #expect(newest?.tail == " cat")
    #expect(newest?.automatic == true)
}

@Test func revertPlanPutsBackTheTypedWordBehindTheCaret() throws {
    var h = FixHistory<Int>()
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    h.update(field: 1, before: "I like the cat")
    let fix = try #require(h.newest(field: 1, before: "I like the cat"))
    let plan = try #require(FixHistory<Int>.revertPlan(fix, before: "I like the cat"))
    #expect(plan.word == "the")
    #expect(plan.replacement == "teh")
    #expect(plan.tail == " cat")
    #expect(plan.fixedBefore("I like the cat") == "I like teh cat")
}

@Test func repeatedPressesGoNewestFirst() throws {
    var h = FixHistory<Int>()
    var text = fixed(&h, before: "teh ", word: "teh", fix: "the")
    text = fixed(&h, before: text + "cta ", word: "cta", fix: "cat")
    text = fixed(&h, before: text + "dont ", word: "dont", fix: "don't")
    #expect(text == "the cat don't ")
    #expect(h.matching(field: 1, before: text).map(\.original) == ["dont", "cta", "teh"])

    // First press: the newest. Its revert rewrites the end of the older entries' text.
    let first = try #require(h.newest(field: 1, before: text))
    let plan = try #require(FixHistory<Int>.revertPlan(first, before: text))
    h.remove(id: first.id)
    h.rewriteEnd(from: plan.span, to: plan.replacement + plan.tail)
    text = plan.fixedBefore(text)
    h.update(field: 1, before: text)
    #expect(text == "the cat dont ")

    // Second press: the one before, still found although the text after it changed.
    let second = try #require(h.newest(field: 1, before: text))
    #expect(second.original == "cta")
    #expect(second.span == "cat dont ")
    let plan2 = try #require(FixHistory<Int>.revertPlan(second, before: text))
    #expect(plan2.fixedBefore(text) == "the cta dont ")
}

@Test func keptPerFieldAndClearedOnLeaving() {
    var h = FixHistory<Int>()
    fixed(&h, field: 1, before: "teh ", word: "teh", fix: "the")
    #expect(!h.isEmpty)
    // Another field: everything goes (focus moved to another field or app).
    h.update(field: 2, before: "hello")
    #expect(h.isEmpty)
    #expect(h.newest(field: 1, before: "the ") == nil)

    fixed(&h, field: 2, before: "hello wrold ", word: "wrold", fix: "world")
    h.reset()  // focus left the field
    #expect(h.isEmpty)
    #expect(h.trackedField == nil)
}

@Test func emptiedFieldForgetsFixes() {
    var h = FixHistory<Int>()
    fixed(&h, before: "teh ", word: "teh", fix: "the")
    h.update(field: 1, before: "")  // message sent
    #expect(h.isEmpty)
}

@Test func editingTheFixedWordDropsIt() {
    var h = FixHistory<Int>()
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    h.update(field: 1, before: "I like the")    // trailing space deleted: the word is intact
    #expect(h.newest(field: 1, before: "I like the")?.original == "teh")
    h.update(field: 1, before: "I like th")     // backspaced into it
    #expect(h.isEmpty)
}

@Test func refusedWhenTextBeforeTheFixChanged() throws {
    var h = FixHistory<Int>()
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    h.update(field: 1, before: "I like the cat")
    let fix = try #require(h.newest(field: 1, before: "I like the cat"))
    // Same fix and tail, but what's before it is different now.
    #expect(FixHistory<Int>.revertPlan(fix, before: "We love the cat") == nil)
    // The fix itself changed.
    #expect(FixHistory<Int>.revertPlan(fix, before: "I like thy cat") == nil)
    // A read where the text was rewritten drops the entry.
    h.update(field: 1, before: "We love the cat")
    #expect(h.isEmpty)
}

@Test func caretMovedBackOverUnchangedTextParksTheList() throws {
    var h = FixHistory<Int>()
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    h.update(field: 1, before: "I like the cat")
    // A click into "the": the text is the same, the caret is 5 characters back.
    let changed = h.update(field: 1, before: "I like th", after: "e cat")
    #expect(!changed)
    #expect(h.caretBack(before: "I like th", after: "e cat") == 5)
    #expect(h.home == "I like the cat")
    let fix = try #require(h.newest(field: 1, before: h.home ?? ""))
    #expect(fix.original == "teh")
    // Back at the end: nothing changed.
    h.update(field: 1, before: "I like the cat")
    #expect(h.caretBack(before: "I like the cat", after: "") == 0)
    #expect(!h.isEmpty)
    // Typed in the middle instead: not the same text any more, so nothing is kept.
    h.update(field: 1, before: "I like th", after: "e cat")
    h.update(field: 1, before: "I like thX", after: "e cat")
    #expect(h.isEmpty)
}

@Test func rewriteOverAnOwnFixPutsBackWhatWasTyped() throws {
    var h = FixHistory<Int>()
    h.update(field: 1, before: "the quialty ")
    let recorded = h.record(field: 1, beforeFix: "the quialty ", original: "quialty", replacement: "quietly",
                            tail: " ", automatic: true)
    let old = try #require(recorded)
    h.update(field: 1, before: "the quietly of it")
    // A rewrite pass replaces the fix: undo gives back what was typed, and the old entry leaves.
    h.record(field: 1, beforeFix: "the quietly of it", original: "quietly ", replacement: "quality ", tail: "of it",
             automatic: true, typed: "quialty ")
    let fix = try #require(h.newest(field: 1, before: "the quality of it"))
    #expect(fix.original == "quialty")
    #expect(fix.replacement == "quality")
    #expect(h.entry(id: old) == nil)
    let plan = try #require(FixHistory<Int>.revertPlan(fix, before: "the quality of it"))
    #expect(plan.replacement == "quialty")
}

@Test func tabFixWithTrailingTextUnderlinesOnlyTheWord() throws {
    var h = FixHistory<Int>()
    // Tab replaced "teh " (word and its space) with "the ".
    h.record(field: 1, beforeFix: "I like teh ", original: "teh ", replacement: "the ", tail: "", automatic: false)
    let fix = try #require(h.newest(field: 1, before: "I like the "))
    #expect(fix.original == "teh")
    #expect(fix.replacement == "the")
    #expect(fix.tail == " ")
    #expect(!fix.automatic)
}

@Test func staleReadFromBeforeTheFixIsIgnored() {
    var h = FixHistory<Int>()
    h.update(field: 1, before: "I like teh ")
    h.record(field: 1, beforeFix: "I like teh ", original: "teh", replacement: "the", tail: " ", automatic: false)
    h.update(field: 1, before: "I like teh ")  // lagging read: the fix wasn't in the field yet
    h.update(field: 1, before: "I like ")      // halfway: deleted, not typed yet
    h.update(field: 1, before: "I like the ")
    #expect(h.newest(field: 1, before: "I like the ")?.original == "teh")
}

@Test func fixThatNeverShowsUpIsDropped() {
    var h = FixHistory<Int>()
    h.update(field: 1, before: "I like teh ")
    h.record(field: 1, beforeFix: "I like teh ", original: "teh", replacement: "the", tail: " ", automatic: false)
    for _ in 0..<FixHistory<Int>.maxPendingReads { h.update(field: 1, before: "I like teh ") }
    #expect(h.isEmpty)
}

@Test func backspaceUndoOfTheFixRemovesIt() {
    var h = FixHistory<Int>()
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    // Backspace straight after: Hunch rewrote "the " back to "teh ".
    h.rewriteEnd(from: "the ", to: "teh ")
    #expect(h.isEmpty)
}

@Test func laterOwnFixFollowsInOlderEntries() {
    var h = FixHistory<Int>()
    var text = fixed(&h, before: "teh ", word: "teh", fix: "the")
    h.update(field: 1, before: text + "cta")
    // An ambiguous word fixed behind the caret later: the older entry's tail follows.
    h.rewriteEnd(from: "cta", to: "cat")
    text = "the cat"
    h.update(field: 1, before: text)
    #expect(h.newest(field: 1, before: text)?.span == "the cat")
}

@Test func allFixKindsAreKept() {
    // Capitals, punctuation and apostrophes, confused words, text replacements.
    // (text, what the fix replaced, the fix, what the entry keeps as typed)
    let cases: [(String, String, String, String)] = [
        ("hello i ", "i", "I", "i"),
        ("I am here .", "here .", "here.", "here "),  // the full stop moves into the tail
        ("its dont ", "dont", "don't", "dont"),
        ("I could of ", "of", "have", "of"),
        ("see you omw ", "omw", "On my way!", "omw"),
    ]
    for (before, word, fix, typed) in cases {
        var h = FixHistory<Int>()
        let tail = before.hasSuffix(" ") ? " " : ""
        let after = fixed(&h, before: before, word: word, fix: fix, tail: tail)
        let entry = h.newest(field: 1, before: after)
        #expect(entry?.original == typed, "\(before)")
        if let entry {
            #expect(FixHistory<Int>.revertPlan(entry, before: after)?.fixedBefore(after) == before, "\(before)")
        }
    }
}

@Test func capacityKeepsTheNewest() {
    var h = FixHistory<Int>()
    var text = ""
    for i in 0..<(FixHistory<Int>.capacity + 3) {
        text = fixed(&h, before: text + "wrod\(i) ", word: "wrod\(i)", fix: "word\(i)")
    }
    #expect(h.entries.count == FixHistory<Int>.capacity)
    #expect(h.newest(field: 1, before: text)?.original == "wrod\(FixHistory<Int>.capacity + 2)")
}

@Test func revertCountsAsRejectionOnlyForOneWordTypedOn() throws {
    var h = FixHistory<Int>()
    fixed(&h, before: "I like teh ", word: "teh", fix: "the")
    let atCaret = try #require(h.newest(field: 1, before: "I like the "))
    #expect(!FixHistory<Int>.typedOnAfter(atCaret))  // watched like a Backspace undo instead
    h.update(field: 1, before: "I like the cat")
    let typedOn = try #require(h.newest(field: 1, before: "I like the cat"))
    #expect(FixHistory<Int>.typedOnAfter(typedOn))
    #expect(FixHistory<Int>.isSingleWord("teh"))
    #expect(FixHistory<Int>.isSingleWord("dont"))
    #expect(!FixHistory<Int>.isSingleWord("here ."))
    #expect(!FixHistory<Int>.isSingleWord("fo teh"))
}

@Test func changingAFixToAnotherWordKeepsItChangeable() throws {
    var h = FixHistory<Int>()
    var text = fixed(&h, before: "teh ", word: "teh", fix: "thy")
    text = fixed(&h, before: text + "cta ", word: "cta", fix: "cat")
    #expect(text == "thy cat ")
    let wrong = try #require(h.matching(field: 1, before: text).last)
    #expect(wrong.original == "teh")
    // Picked "the" in the menu: replace "thy" behind the caret.
    let plan = try #require(FixHistory<Int>.revertPlan(wrong, before: text, to: "the"))
    #expect(plan.word == "thy")
    #expect(plan.replacement == "the")
    #expect(plan.fixedBefore(text) == "the cat ")
    h.replace(id: wrong.id, with: "the")
    text = plan.fixedBefore(text)
    h.update(field: 1, before: text)
    // Still there, now as the user's own pick, still revertable to what was typed.
    let changed = try #require(h.entry(id: wrong.id))
    #expect(changed.replacement == "the")
    #expect(changed.span == "the cat ")
    #expect(!changed.automatic)
    #expect(FixHistory<Int>.revertPlan(changed, before: text)?.fixedBefore(text) == "teh cat ")
    // The newer fix is untouched and still first for the shortcut.
    #expect(h.newest(field: 1, before: text)?.original == "cta")
}

@Test func changingANewerFixFollowsInOlderTails() throws {
    var h = FixHistory<Int>()
    var text = fixed(&h, before: "teh ", word: "teh", fix: "the")
    text = fixed(&h, before: text + "fo ", word: "fo", fix: "to")
    let newest = try #require(h.newest(field: 1, before: text))
    let plan = try #require(FixHistory<Int>.revertPlan(newest, before: text, to: "of"))
    h.replace(id: newest.id, with: "of")
    text = plan.fixedBefore(text)
    h.update(field: 1, before: text)
    #expect(text == "the of ")
    #expect(h.matching(field: 1, before: text).map(\.span) == ["of ", "the of "])
}

@Test func caretBackAgainstAKeptHome() {
    #expect(FixHistory<Int>.caretBack(home: "I like the cat", before: "I like th", after: "e cat") == 5)
    #expect(FixHistory<Int>.caretBack(home: "I like the cat", before: "I like the cat", after: "") == 0)
    #expect(FixHistory<Int>.caretBack(home: "I like the cat", before: "I like th", after: "ere") == nil)
}

@Test func revertingAnOlderFixKeepsTheNewerOne() throws {
    var h = FixHistory<Int>()
    var text = fixed(&h, before: "teh ", word: "teh", fix: "the")
    text = fixed(&h, before: text + "cta ", word: "cta", fix: "cat")
    let older = try #require(h.matching(field: 1, before: text).last)
    let plan = try #require(FixHistory<Int>.revertPlan(older, before: text))
    h.remove(id: older.id)
    h.rewriteEnd(from: plan.span, to: plan.replacement + plan.tail)
    text = plan.fixedBefore(text)
    h.update(field: 1, before: text)
    #expect(text == "teh cat ")
    #expect(h.newest(field: 1, before: text)?.original == "cta")
}

@Test func fixConfidenceIsKeptWithTheFix() {
    var h = FixHistory<Int>()
    h.update(field: 1, before: "load the gguf ")
    h.record(field: 1, beforeFix: "load the gguf ", original: "gguf", replacement: "gruff", tail: " ", automatic: true,
             confidence: .unsure)
    h.update(field: 1, before: "load the gruff ")
    h.update(field: 1, before: "load the gruff file")
    #expect(h.newest(field: 1, before: "load the gruff file")?.confidence == .unsure)
    h.record(field: 1, beforeFix: "load the gruff fiel ", original: "fiel", replacement: "file", tail: " ", automatic: true)
    #expect(h.newest(field: 1, before: "load the gruff file ")?.confidence == nil)
}
