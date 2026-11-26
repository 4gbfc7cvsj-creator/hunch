import Foundation

/// "Fix automatically": tells a deliberate rejection of an automatic fix from an accidental one.
///
/// Watches the field after the latest automatic fix, and after Backspace restored the word:
/// - **Undo, then type on**: after the restore, the next word is typed after the kept word.
/// - **Delete and retype**: the fix (or the restored word) is deleted and exactly the typed word is
///   typed again, followed by a space or punctuation.
/// - **Undo, then leave**: the restored word is still there, with a space or punctuation after it,
///   when focus leaves or the field is emptied (message sent).
///
/// Not a rejection: backspacing past the start of the word (rephrasing the sentence), or typing a
/// different word in its place. Typing on past the fix itself ends the watch: the fix was kept
/// (`takeKept`, which teaches the personal slip list).
///
/// Pure state; `AutocorrectFollowUp` feeds it the fix, the undo, and every read.
public struct FixRejectionWatch<Field: Hashable & Sendable>: Sendable {
    private struct Watch: Sendable {
        var field: Field
        /// The end of the text before the word (normalized), found again in later reads: reads are
        /// windows, so their start may move as the text grows.
        var anchor: String
        /// The anchor is the whole text before the word: later reads must start with it.
        var anchorIsStem: Bool
        var word: String
        var fix: String
        var undone = false
        /// Undone, and the last read showed the word intact with a boundary after it.
        var kept = false
    }

    private var watch: Watch?
    /// The last fix the user typed on past without undoing it, until taken.
    private var keptFix: (word: String, fix: String)?
    /// The fix of the last clean rejection returned.
    public private(set) var lastRejectedFix: String?
    static var anchorLength: Int { 32 }

    public init() {}

    public var isWatching: Bool { watch != nil }
    public var watchedField: Field? { watch?.field }

    /// An automatic fix replaced `word + trailing` at the end of `beforeFix` with `fix + trailing`.
    public mutating func fixApplied(field: Field, beforeFix: String, word: String, fix: String, trailing: String) {
        let stem = Self.norm(String(beforeFix.dropLast(word.count + trailing.count)))
        let anchorIsStem = stem.count <= Self.anchorLength
        watch = Watch(field: field, anchor: anchorIsStem ? stem : String(stem.suffix(Self.anchorLength)),
                      anchorIsStem: anchorIsStem, word: Self.norm(word), fix: Self.norm(fix))
    }

    /// Backspace straight after the fix restored `word`.
    public mutating func undone(field: Field, word: String) {
        guard var w = watch, w.field == field, w.word == Self.norm(word) else { return }
        w.undone = true
        w.kept = true
        watch = w
    }

    /// A read of the field. Returns the word when this read completes a clean rejection.
    public mutating func update(field: Field, before: String) -> String? {
        guard var w = watch else { return nil }
        guard w.field == field else { return leave() }
        let b = Self.norm(before)
        if w.undone, w.kept, b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finish()  // kept, then the message was sent
        }
        let rest: Substring
        if w.anchorIsStem {
            guard b.hasPrefix(w.anchor) else { return drop() }
            rest = b.dropFirst(w.anchor.count)
        } else {
            guard let r = b.range(of: w.anchor, options: .backwards) else { return drop() }
            rest = b[r.upperBound...]
        }
        // The fix is still in place: wait while it is the last word; typed on past it, it was kept.
        if !w.undone, Self.startsWord(rest, w.fix) {
            guard Self.wordFollows(rest.dropFirst(w.fix.count)) else { return nil }
            keptFix = (w.word, w.fix)
            return drop()
        }
        if Self.startsWord(rest, w.word) {
            let after = rest.dropFirst(w.word.count)
            if after.isEmpty {
                w.kept = false  // retyped, or the trailing space deleted: not finished yet
                watch = w
                return nil
            }
            // Typed on after the word, or (fix still not undone) the word retyped and finished.
            if Self.wordFollows(after) || !w.undone { return finish() }
            w.kept = true
            watch = w
            return nil
        }
        // Deleting into the word, maybe to type it again.
        if rest.count < w.word.count, w.word.lowercased().hasPrefix(rest.lowercased()) {
            w.kept = false
            watch = w
            return nil
        }
        if !w.undone, rest.count < w.fix.count, w.fix.hasPrefix(rest) { return nil }  // deleting the fix
        return drop()  // something else typed in its place
    }

    /// Focus left the field: an undone word still kept counts. Ends the watch.
    public mutating func leave() -> String? {
        guard let w = watch else { return nil }
        watch = nil
        guard w.undone && w.kept else { return nil }
        lastRejectedFix = w.fix
        return w.word
    }

    public mutating func reset() { watch = nil; keptFix = nil }

    /// The automatic fix the user kept (typed on past it, never undone): the word as typed and
    /// the fix. Returned once.
    public mutating func takeKept() -> (word: String, fix: String)? {
        defer { keptFix = nil }
        return keptFix
    }

    private mutating func finish() -> String? {
        defer { watch = nil }
        lastRejectedFix = watch?.fix
        return watch?.word
    }

    private mutating func drop() -> String? {
        watch = nil
        return nil
    }

    /// `rest` starts with `word` (ignoring case) as a whole word: nothing or a boundary after it.
    static func startsWord(_ rest: Substring, _ word: String) -> Bool {
        guard rest.count >= word.count, rest.prefix(word.count).lowercased() == word.lowercased() else { return false }
        return rest.dropFirst(word.count).first.map { !isWordCharacter($0) } ?? true
    }

    /// `after` (text right after a word) starts with a boundary and a new word was begun.
    static func wordFollows(_ after: Substring) -> Bool {
        guard let first = after.first, !isWordCharacter(first) else { return false }
        return after.contains(where: isWordCharacter)
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }

    static func norm(_ s: String) -> String { CatchUpPlan.norm(s) }
}
