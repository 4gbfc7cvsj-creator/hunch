import Testing
@testable import HunchText

// Autocorrect catch-up: which shown fixes become missed fixes, when they are dropped, the order the
// shortcut takes them in, and the checks that make it do nothing when the text changed.

private func typedPast(_ t: inout MissedFixTracker<Int>, field: Int = 1, before: String, word: String,
                       fix: String, trailing: Int = 1, next: String, deferSkips: Bool = true) -> [String] {
    t.shown(field: field, before: before, word: word, replacement: fix, trailingCount: trailing)
    return t.update(field: field, before: next, skipped: word.lowercased(), deferSkips: deferSkips)
}

@Test func fixTypedPastBecomesMissedFix() {
    var t = MissedFixTracker<Int>()
    t.update(field: 1, before: "I like teh ")
    let counted = typedPast(&t, before: "I like teh ", word: "teh", fix: "the", next: "I like teh c")
    #expect(counted.isEmpty)  // the skip waits: a catch-up may still take the fix
    #expect(t.entries.map(\.word) == ["teh"])
    #expect(t.entries.first?.span == "teh c")
    _ = t.update(field: 1, before: "I like teh cat")
    #expect(t.newest(field: 1, before: "I like teh cat")?.span == "teh cat")
}

@Test func shownButNotTypedPastIsNotMissed() {
    var t = MissedFixTracker<Int>()
    t.shown(field: 1, before: "a teh ", word: "teh", replacement: "the", trailingCount: 1)
    t.update(field: 1, before: "a teh ")          // same text: still showing
    t.update(field: 1, before: "a teh")           // backspaced into the trailing space
    #expect(t.isEmpty)
}

@Test func escapeDismissedAndTabAcceptedFixesAreNotMissed() {
    var t = MissedFixTracker<Int>()
    t.shown(field: 1, before: "a teh ", word: "teh", replacement: "the", trailingCount: 1)
    t.escaped()
    let r1 = t.update(field: 1, before: "a teh x", skipped: "teh", deferSkips: true)
    #expect(r1 == ["teh"])
    #expect(t.isEmpty)

    t.shown(field: 1, before: "b recieve ", word: "recieve", replacement: "receive", trailingCount: 1)
    t.accepted()
    t.update(field: 1, before: "b receive x")
    #expect(t.isEmpty)
}

@Test func withoutCatchUpTheSkipCountsRightAway() {
    var t = MissedFixTracker<Int>()
    let counted = typedPast(&t, before: "x teh ", word: "teh", fix: "the", next: "x teh y", deferSkips: false)
    #expect(counted == ["teh"])
    #expect(t.entries.first?.skipPending == false)
    let r2 = t.reset()
    #expect(r2.isEmpty)  // nothing counted twice
}

@Test func newestFirstAcrossRepeatedPresses() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "teh ", word: "teh", fix: "the", next: "teh c")
    _ = typedPast(&t, before: "teh cta ", word: "cta", fix: "cat", next: "teh cta s")
    let before = "teh cta sat"
    _ = t.update(field: 1, before: before)

    // First press: the newest missed word.
    let first = try! #require(t.newest(field: 1, before: before))
    #expect(first.word == "cta")
    let plan1 = try! #require(CatchUpPlan.make(first, before: before))
    #expect(plan1.tail == " sat")
    let after1 = plan1.fixedBefore(before)
    #expect(after1 == "teh cat sat")
    t.applied(id: first.id)
    _ = t.update(field: 1, before: after1)  // the field now reads with the fix in

    // Second press: the one before it, whose span now holds the fixed word.
    let second = try! #require(t.newest(field: 1, before: after1))
    #expect(second.word == "teh")
    #expect(second.span == "teh cat sat")
    let plan2 = try! #require(CatchUpPlan.make(second, before: after1))
    #expect(plan2.fixedBefore(after1) == "the cat sat")
    t.applied(id: second.id)
    #expect(t.isEmpty)
    #expect(t.newest(field: 1, before: "the cat sat") == nil)
}

@Test func keepsTheLastFive() {
    var t = MissedFixTracker<Int>()
    var text = ""
    for i in 0..<7 {
        let word = "wrd\(i)"
        let before = text + word + " "
        text = before + "x "
        let counted = typedPast(&t, before: before, word: word, fix: "word", next: before + "x")
        _ = t.update(field: 1, before: text)
        if i >= 5 { #expect(counted == ["wrd\(i - 5)"]) }  // the oldest leaves and its skip is counted
    }
    #expect(t.entries.count == MissedFixTracker<Int>.capacity)
    #expect(t.entries.first?.word == "wrd2")
}

@Test func droppedWhenLeavingOrEmptyingTheField() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "a teh ", word: "teh", fix: "the", next: "a teh b")
    let r3 = t.update(field: 2, before: "other")
    #expect(r3 == ["teh"])
    #expect(t.isEmpty)

    _ = typedPast(&t, field: 2, before: "a teh ", word: "teh", fix: "the", next: "a teh b")
    let r4 = t.update(field: 2, before: "   ")
    #expect(r4 == ["teh"])  // message sent: the box emptied
    #expect(t.isEmpty)

    _ = typedPast(&t, field: 2, before: "a teh ", word: "teh", fix: "the", next: "a teh b")
    let r5 = t.reset()
    #expect(r5 == ["teh"])  // focus left or secure input
    #expect(t.isEmpty)
}

@Test func backspacingIntoTheWordDropsIt() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "a teh ", word: "teh", fix: "the", next: "a teh bc")
    _ = t.update(field: 1, before: "a teh b")    // Backspace in the tail: kept
    #expect(t.entries.first?.span == "teh b")
    _ = t.update(field: 1, before: "a teh ")
    #expect(t.entries.first?.span == "teh ")
    let r6 = t.update(field: 1, before: "a teh")
    #expect(r6 == ["teh"])  // now editing the word itself
    #expect(t.isEmpty)
}

@Test func editElsewhereThatChangesTheSpanDropsIt() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "a teh ", word: "teh", fix: "the", next: "a teh b")
    // The user fixed the word by hand (caret moved back and forth): the text no longer ends with it.
    let r7 = t.update(field: 1, before: "a the b")
    #expect(r7 == ["teh"])
    #expect(t.isEmpty)
}

@Test func followsTypingWhenTheReadWindowSlides() {
    var t = MissedFixTracker<Int>()
    let start = String(repeating: "x", count: 20)
    _ = typedPast(&t, before: start + " teh ", word: "teh", fix: "the", next: start + " teh a")
    // The window keeps its length: one character drops at the front for each typed at the end.
    _ = t.update(field: 1, before: String(start.dropFirst(1)) + " teh ab")
    #expect(t.entries.first?.span == "teh ab")
}

@Test func textNoLongerMatchingDoesNothing() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "a teh ", word: "teh", fix: "the", next: "a teh b")
    let entry = try! #require(t.entries.first)
    // A read that doesn't end with the span: no entry offered, no plan.
    #expect(t.newest(field: 1, before: "a teh c") == nil)
    #expect(CatchUpPlan.make(entry, before: "a teh c") == nil)
    // The word now continues a longer one ("xteh"): not the word that was flagged.
    #expect(CatchUpPlan.make(entry, before: "a xteh b") == nil)
    let r8 = t.abandon(id: entry.id)
    #expect(r8 == "teh")
    #expect(t.isEmpty)
}

@Test func sameOccurrenceShownTwiceIsOneEntry() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "amigo,", word: "amigo", fix: "amiga", trailing: 1, next: "amigo, ")
    // Re-shown after the space; typed past again. The skip tracker counts the occurrence once (nil).
    t.shown(field: 1, before: "amigo, ", word: "amigo", replacement: "amiga", trailingCount: 2)
    _ = t.update(field: 1, before: "amigo, x", skipped: nil, deferSkips: true)
    #expect(t.entries.count == 1)
    #expect(t.entries.first?.span == "amigo, x")
}

@Test func automaticFixAtTheEndKeepsOlderEntries() {
    var t = MissedFixTracker<Int>()
    _ = typedPast(&t, before: "teh ", word: "teh", fix: "the", next: "teh c")
    _ = t.update(field: 1, before: "teh cta ")
    // Hunch fixed "cta " → "cat " itself.
    t.rewriteEnd(from: "cta ", to: "cat ")
    _ = t.update(field: 1, before: "teh cat ")
    #expect(t.entries.first?.span == "teh cat ")
}

@Test func planOffsetsCountEmojiAndChineseInUTF16AndCharacters() {
    let plan = CatchUpPlan(word: "teh", replacement: "the", tail: " 👍🏽 好的 ")
    #expect(plan.tailCharacters == 6)          // space, emoji, space, 好, 的, space
    #expect(plan.tailUTF16 == 9)               // the emoji with its skin tone is 4 units
    #expect(plan.spanUTF16 == 12)
    #expect(plan.keyboardAllowed)
    #expect(!CatchUpPlan(word: "teh", replacement: "the", tail: " line\nnext").keyboardAllowed)
    #expect(!CatchUpPlan(word: "teh", replacement: "the", tail: String(repeating: "a", count: 81)).keyboardAllowed)
}

@Test func arrowKeyChecks() {
    let original = "Say teh cat"
    let plan = CatchUpPlan(word: "teh", replacement: "the", tail: " cat")
    #expect(plan.wordSelected(before: "Say ", selected: "teh", after: " cat", originalBefore: original))
    #expect(!plan.wordSelected(before: "Say ", selected: "te", after: "h cat", originalBefore: original))
    #expect(!plan.wordSelected(before: "Say ", selected: "teh", after: " dog", originalBefore: original))
    #expect(plan.replacementTyped(before: "Say the", after: "\u{00A0}cat", originalBefore: original))
    #expect(plan.caretRestored(before: "Say the cat", originalBefore: original))
    #expect(!plan.caretRestored(before: "Say the ca", originalBefore: original))
    #expect(CatchUpPlan.unchanged(before: original, originalBefore: original))
}

// MARK: Fix automatically: Backspace undo

@Test func backspaceStraightAfterAnAutomaticFixRestoresTheWord() {
    var u = AutoFixUndo<Int>()
    u.applied(field: 1, beforeFix: "I saw teh ", original: "teh", fix: "the", trailing: " ")
    u.update(field: 1, before: "I saw teh ")      // a read from before the fix landed keeps it
    u.update(field: 1, before: "I saw the ")
    #expect(u.isArmed)
    let plan = u.backspace(field: 1, before: "I saw the ")
    #expect(plan == AutoFixUndo<Int>.Plan(deleteCount: 4, text: "teh ", word: "teh"))
    #expect(!u.isArmed)
    let r9 = u.backspace(field: 1, before: "I saw the ")
    #expect(r9 == nil)  // only once
}

@Test func anyOtherKeyEndsTheUndoWindow() {
    var u = AutoFixUndo<Int>()
    u.applied(field: 1, beforeFix: "a teh.", original: "teh", fix: "the", trailing: ".")
    u.otherKey()
    let r10 = u.backspace(field: 1, before: "a the.")
    #expect(r10 == nil)

    u.applied(field: 1, beforeFix: "a teh.", original: "teh", fix: "the", trailing: ".")
    u.update(field: 1, before: "a the. x")         // typed on
    #expect(!u.isArmed)

    u.applied(field: 1, beforeFix: "a teh.", original: "teh", fix: "the", trailing: ".")
    u.update(field: 2, before: "a the.")           // another field
    #expect(!u.isArmed)
}

@Test func undoNeedsTheFieldToShowTheFix() {
    var u = AutoFixUndo<Int>()
    u.applied(field: 1, beforeFix: "a teh ", original: "teh", fix: "the", trailing: " ")
    let r11 = u.backspace(field: 1, before: "a teh ")
    #expect(r11 == nil)  // the fix never showed: plain Backspace
}
