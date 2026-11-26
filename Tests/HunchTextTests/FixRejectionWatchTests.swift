import Testing
@testable import HunchText

// Learning from rejected automatic fixes: only a clean rejection counts (undo or delete the fix and
// keep the word); backspacing on into the sentence to rephrase, or typing another word, does not.

private let stem = "Send me the "

/// An automatic fix of "csv " to "css " at the end of `stem`.
private func fixed(_ before: String = stem, word: String = "csv", fix: String = "css",
                   field: Int = 1) -> FixRejectionWatch<Int> {
    var w = FixRejectionWatch<Int>()
    w.fixApplied(field: field, beforeFix: before + word + " ", word: word, fix: fix, trailing: " ")
    return w
}

/// The fix, then Backspace restored the word.
private func undone(_ before: String = stem) -> FixRejectionWatch<Int> {
    var w = fixed(before)
    w.undone(field: 1, word: "csv")
    return w
}

@Test func undoThenTypeOnIsClean() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csv ") == nil)       // the restore itself
    #expect(w.update(field: 1, before: stem + "csv f") == "csv")    // next word begun
    #expect(!w.isWatching)
}

@Test func undoThenPunctuationAndTypeOnIsClean() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csv, ") == nil)
    #expect(w.update(field: 1, before: stem + "csv, please") == "csv")
}

@Test func fastTypingWithMissedReadsStillCounts() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csv file please") == "csv")
}

@Test func undoThenBackspacingIntoTheSentenceIsNotARejection() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csv") == nil)
    #expect(w.update(field: 1, before: stem + "c") == nil)
    #expect(w.update(field: 1, before: "Send me the") == nil)       // past the word: rephrasing
    #expect(!w.isWatching)
    #expect(w.update(field: 1, before: "Send me the csv file") == nil)
}

@Test func undoThenOtherWordIsNotARejection() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "cs") == nil)
    #expect(w.update(field: 1, before: stem + "cat ") == nil)
    #expect(!w.isWatching)
}

@Test func undoThenRetypeSameWordIsClean() {
    var w = undone()
    #expect(w.update(field: 1, before: stem) == nil)                // the word deleted…
    #expect(w.update(field: 1, before: stem + "csv") == nil)        // …and typed again
    #expect(w.update(field: 1, before: stem + "csv ") == nil)
    #expect(w.update(field: 1, before: stem + "csv now") == "csv")
}

@Test func undoThenLeaveWithWordKeptIsClean() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csv ") == nil)
    #expect(w.leave() == "csv")
}

@Test func undoThenSendIsClean() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csv ") == nil)
    #expect(w.update(field: 1, before: "") == "csv")                // chat box emptied: sent
}

@Test func undoThenLeaveMidDeleteIsNotARejection() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "cs") == nil)
    #expect(w.leave() == nil)
}

@Test func otherFieldEndsTheWatchLikeLeaving() {
    var w = undone()
    #expect(w.update(field: 2, before: "hello") == "csv")
    var v = undone()
    #expect(v.update(field: 1, before: stem + "c") == nil)
    #expect(v.update(field: 2, before: "hello") == nil)
}

@Test func deletingTheFixByHandAndRetypingIsClean() {
    var w = fixed()
    #expect(w.update(field: 1, before: stem + "css ") == nil)       // the fix
    #expect(w.update(field: 1, before: stem + "cs") == nil)         // deleting it
    #expect(w.update(field: 1, before: stem) == nil)
    #expect(w.update(field: 1, before: stem + "csv") == nil)
    // Counted as soon as the word is finished, before it could be fixed again.
    #expect(w.update(field: 1, before: stem + "csv ") == "csv")
}

@Test func typingOnPastTheFixKeepsTheFix() {
    var w = fixed()
    #expect(w.update(field: 1, before: stem + "css ") == nil)
    #expect(w.update(field: 1, before: stem + "css file") == nil)
    #expect(!w.isWatching)
}

@Test func deletingTheFixAndTypingAnotherWordIsNotARejection() {
    var w = fixed()
    #expect(w.update(field: 1, before: stem) == nil)
    #expect(w.update(field: 1, before: stem + "data ") == nil)
    #expect(!w.isWatching)
}

@Test func extendingTheRestoredWordIsNotARejection() {
    var w = undone()
    #expect(w.update(field: 1, before: stem + "csvs ") == nil)
    #expect(!w.isWatching)
}

@Test func retypedWordCaseDoesNotMatter() {
    var w = undone()
    #expect(w.update(field: 1, before: stem) == nil)
    #expect(w.update(field: 1, before: stem + "CSV file") == "csv")
}

@Test func longTextAnchorsOnTheEndOfTheTextBeforeTheWord() {
    let long = String(repeating: "Some earlier words in a long note. ", count: 20) + "Then the "
    var w = undone(long)
    // The read window starts later as the text grows.
    #expect(w.update(field: 1, before: String((long + "csv ").dropFirst(50))) == nil)
    #expect(w.update(field: 1, before: String((long + "csv f").dropFirst(60))) == "csv")
    var v = undone(long)
    #expect(v.update(field: 1, before: String(long.dropLast(2))) == nil)  // backspaced past the word
    #expect(!v.isWatching)
}

@Test func splitFixWaitsUntilTypedOn() {
    var w = fixed(word: "webhook", fix: "web hook")
    #expect(w.update(field: 1, before: stem + "web hook ") == nil)
    #expect(w.isWatching)
    #expect(w.update(field: 1, before: stem + "web hook url") == nil)
    #expect(!w.isWatching)
}

@Test func firstWordOfTheField() {
    var w = FixRejectionWatch<Int>()
    w.fixApplied(field: 1, beforeFix: "csv ", word: "csv", fix: "css", trailing: " ")
    w.undone(field: 1, word: "csv")
    #expect(w.update(field: 1, before: "csv ") == nil)
    #expect(w.update(field: 1, before: "csv is") == "csv")
}

@Test func undoOfAnotherWordIsIgnored() {
    var w = fixed()
    w.undone(field: 1, word: "teh")
    #expect(w.update(field: 1, before: stem + "css ") == nil)
    #expect(w.leave() == nil)
}
