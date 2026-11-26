import CoreGraphics
import Testing
@testable import HunchScreen

private func anchor(_ start: CGFloat, _ baseline: CGFloat = 7) -> TypedTextAnchor {
    TypedTextAnchor(startOffset: start, baselineOffset: baseline, pointSize: 14)
}

@Suite struct TypedAnchorBookTests {
    @Test func firstLookIsAdoptedAndSmallMovesRefine() {
        var book = TypedAnchorBook<String>()
        do { let r = book.noteFound(anchor(0.5), for: "chrome"); #expect(r) }
        #expect(book.anchor(for: "chrome") == anchor(0.5))
        do { let r = book.noteFound(anchor(0.5), for: "chrome"); #expect(!r) }
        do { let r = book.noteFound(anchor(1.5), for: "chrome"); #expect(r) }
        #expect(book.anchor(for: "chrome") == anchor(1.5))
        #expect(book.anchor(for: "other") == nil)
    }

    /// Live in Chrome: one look matched 773 pt to the right; the ghost must not jump there.
    @Test func aJumpNeedsTwoLooksInARow() {
        var book = TypedAnchorBook<String>()
        book.noteFound(anchor(0.5), for: "k")
        do { let r = book.noteFound(anchor(773.5), for: "k"); #expect(!r) }
        #expect(book.anchor(for: "k") == anchor(0.5))
        // Back at the known spot: the stray candidate is dropped.
        book.noteFound(anchor(0.5), for: "k")
        do { let r = book.noteFound(anchor(773.5), for: "k"); #expect(!r) }
        do { let r = book.noteFound(anchor(774), for: "k"); #expect(r) }
        #expect(book.anchor(for: "k") == anchor(774))
    }

    @Test func forgottenOnlyAfterRepeatedMisses() {
        var book = TypedAnchorBook<String>()
        book.noteFound(anchor(0.5), for: "k")
        do { let r = book.noteMissed(for: "k"); #expect(!r) }
        do { let r = book.noteMissed(for: "k"); #expect(!r) }
        book.noteFound(anchor(0.5), for: "k")   // a hit resets the count
        do { let r = book.noteMissed(for: "k"); #expect(!r) }
        do { let r = book.noteMissed(for: "k"); #expect(!r) }
        do { let r = book.noteMissed(for: "k"); #expect(r) }
        #expect(book.anchor(for: "k") == nil)
        do { let r = book.noteMissed(for: "k"); #expect(!r) }
    }

    @Test func placeableAtAnyLength() {
        #expect(TypedTextAnchor.isPlaceable(before: "n"))
        #expect(TypedTextAnchor.isPlaceable(before: "台"))
        #expect(!TypedTextAnchor.isPlaceable(before: ""))
        #expect(!TypedTextAnchor.isPlaceable(before: "a\nb"))
        #expect(!TypedTextAnchor.isEligible(before: "no"))
    }
}
