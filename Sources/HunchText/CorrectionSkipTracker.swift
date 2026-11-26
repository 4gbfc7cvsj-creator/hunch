import Foundation

/// Decides when a shown spelling fix counts as skipped: the user typed on past it, or pressed
/// Escape on it. Backspacing into the word, emptying the field, or moving elsewhere is not a skip.
public struct CorrectionSkipTracker<Field: Hashable & Sendable>: Sendable {
    private struct Pending: Sendable {
        var field: Field
        var before: String
        var word: String
        /// Text up to and including the word: identifies this occurrence of it.
        var stem: String
    }
    private var pending: Pending?
    /// The occurrence last counted, so "amigo," then "amigo, " (shown twice) counts once.
    private var counted: (field: Field, stem: String)?

    public init() {}

    /// A fix for `word` is showing, with this text before the caret. Showing the same one again
    /// (the ghost is re-shown after every keyDown) changes nothing.
    /// `trailingCount` is how many characters after the word were typed (space, punctuation).
    public mutating func shown(field: Field, before: String, word: String, trailingCount: Int = 1) {
        pending = Pending(field: field, before: before, word: word.lowercased(),
                          stem: String(before.dropLast(trailingCount)))
    }

    /// New before-caret text. Returns the word once, when the user typed on past the shown fix.
    public mutating func update(field: Field, before: String) -> String? {
        guard let p = pending else { return nil }
        guard p.field == field else { pending = nil; return nil }
        if before == p.before { return nil }
        pending = nil
        guard before.count > p.before.count, before.hasPrefix(p.before) else { return nil }
        return count(p)
    }

    /// Escape on the fix: the word counts as skipped.
    public mutating func escaped() -> String? {
        guard let p = pending else { return nil }
        pending = nil
        return count(p)
    }

    /// The fix was applied.
    public mutating func accepted() -> String? {
        defer { pending = nil }
        return pending?.word
    }

    /// Focus moved, the field changed, or secure input began: forget without counting.
    public mutating func reset() { pending = nil }

    private mutating func count(_ p: Pending) -> String? {
        if let c = counted, c.field == p.field, c.stem == p.stem { return nil }
        counted = (p.field, p.stem)
        return p.word
    }
}
