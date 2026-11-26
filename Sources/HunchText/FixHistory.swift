import Foundation

/// A fix Hunch made in the field the user is still in, kept so it can be put back later
/// (autocorrect "undo a fix later": the revert shortcut, or the underline's Revert button).
public struct RecordedFix: Sendable, Equatable {
    public var id: Int
    /// What the user typed (the word, or the stretch a punctuation fix rewrote).
    public var original: String
    /// What Hunch put there instead.
    public var replacement: String
    /// The replacement and everything after it up to the caret. Always starts with `replacement`.
    public var span: String
    /// The end of the text right before the fix (up to `FixHistory.anchorLength` characters), as it
    /// was when the fix went in: a revert needs it unchanged.
    public var anchor: String
    /// Made by "Apply Corrections Automatically" (not taken with Tab or the catch-up shortcut,
    /// which are the user's own picks). Only these teach "learn from rejected fixes".
    public var automatic: Bool
    /// How sure fix-as-you-type was of the fix (nil: not recorded, a rewrite pass's change).
    public var confidence: FixConfidence?

    /// The text between the replacement and the caret.
    public var tail: Substring { span.dropFirst(replacement.count) }

    public init(id: Int, original: String, replacement: String, span: String, anchor: String, automatic: Bool,
                confidence: FixConfidence? = nil) {
        self.confidence = confidence
        self.id = id
        self.original = original
        self.replacement = replacement
        self.span = span
        self.anchor = anchor
        self.automatic = automatic
    }
}

/// The last few fixes made in the field the user is in, newest last, so they can be put back
/// after more typing (design §13, autocorrect "undo a fix later").
///
/// Pure: fed the text around the caret of every read. A fix is found again by its expected text:
/// the text before the caret must end with the fix's replacement and what was typed after it, and
/// the text before the replacement must still end with the recorded anchor. Typing at the end grows
/// every entry, Backspace at the end shrinks it (into the replacement drops the entry), moving the
/// caret back over unchanged text parks the list until the caret is back (`home`), and any other
/// change keeps only the entries the text still ends with. Everything is forgotten when focus
/// leaves the field or the field is emptied (a message sent). Nothing is saved.
public struct FixHistory<Field: Hashable & Sendable>: Sendable {
    public static var capacity: Int { 8 }
    /// Entries whose text after the fix grows past this are dropped (the read window is 4000).
    public static var maxTail: Int { 1500 }
    static var anchorLength: Int { 32 }

    private var field: Field?
    /// The text before the caret where the entries are valid: the last read at the end of the typing.
    public private(set) var home: String?
    /// Reads left to ignore while a just-recorded fix isn't seen in the field yet: a lagging read
    /// from before it, or one from halfway through (deleted, not yet typed). 0: none pending.
    private var pendingReads = 0
    static var maxPendingReads: Int { 8 }
    /// Oldest first.
    public private(set) var entries: [RecordedFix] = []
    private var nextID = 1

    public init() {}

    public var trackedField: Field? { field }
    public var isEmpty: Bool { entries.isEmpty }

    /// A fix replaced `original + tail` at the end of `beforeFix` with `replacement + tail` (older
    /// entries follow both what was typed since the last read and the change: no `rewriteEnd` for it). The
    /// common trailing text that isn't part of a word (a space, punctuation) moves into the tail, so
    /// the underline covers only what changed. Returns the entry's id, nil when nothing is recorded.
    /// `typed`: what putting the fix back gives, when it isn't `original` (a rewrite pass that
    /// replaces Hunch's own earlier fix: what the writer typed there).
    /// `confidence`: how sure fix-as-you-type was of it (`FixConfidence`), for a later rewrite pass.
    @discardableResult
    public mutating func record(field: Field, beforeFix: String, original: String, replacement: String,
                                tail: String, automatic: Bool, typed: String? = nil,
                                confidence: FixConfidence? = nil) -> Int? {
        var original = original, replacement = replacement, tail = tail, typed = typed
        while let a = original.last, let b = replacement.last, a == b, !Self.isWordCharacter(a),
              original.count > 1, replacement.count > 1 {
            original.removeLast()
            replacement.removeLast()
            if typed?.last == a, (typed?.count ?? 0) > 1 { typed?.removeLast() }
            tail = String(a) + tail
        }
        guard !original.isEmpty, !replacement.isEmpty, original != replacement,
              beforeFix.hasSuffix(original + tail) else { return nil }
        if self.field != field {
            entries = []
            self.field = field
            home = nil
        }
        // Typed since the last read, then the change itself: older entries follow both.
        if let home, home != beforeFix { follow(from: home, to: beforeFix) }
        let head = beforeFix.dropLast(original.count + tail.count)
        let after = String(head) + replacement + tail
        home = beforeFix
        rewriteEnd(from: original + tail, to: replacement + tail)
        entries = entries.filter { after.hasSuffix($0.span) && Self.anchorHolds($0, before: after) }
        let entry = RecordedFix(id: nextID, original: typed.flatMap { $0.isEmpty || $0 == replacement ? nil : $0 } ?? original,
                                replacement: replacement,
                                span: replacement + tail, anchor: String(head.suffix(Self.anchorLength)),
                                automatic: automatic, confidence: confidence)
        nextID += 1
        entries.removeAll { $0.span == entry.span && $0.original == entry.original }
        entries.append(entry)
        while entries.count > Self.capacity { entries.removeFirst() }
        home = after
        pendingReads = Self.maxPendingReads
        return entry.id
    }

    /// A read of the field: `before` and `after` the caret. Returns whether the entries changed.
    @discardableResult
    public mutating func update(field: Field, before: String, after: String = "") -> Bool {
        if self.field != field {
            let had = !entries.isEmpty
            reset()
            self.field = field
            home = before
            return had
        }
        if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let had = !entries.isEmpty
            entries = []
            home = before
            pendingReads = 0
            return had
        }
        if pendingReads > 0, let home {
            if before == home || MissedFixTracker<Field>.appended(from: home, to: before) != nil {
                pendingReads = 0  // the fix is in
            } else {
                pendingReads -= 1  // not in yet (or never): the last pending read is taken as it is
                if pendingReads > 0 { return false }
            }
        }
        guard let home, home != before else {
            self.home = before
            return false
        }
        // The caret moved back over unchanged text (an arrow key, a click into the text): park.
        if home.hasPrefix(before), after.hasPrefix(home.dropFirst(before.count)) { return false }
        let old = entries
        follow(from: home, to: before)
        self.home = before
        return entries != old
    }

    /// Typing at the end grows every entry, Backspace at the end shrinks it; any other change keeps
    /// only the entries the text still ends with.
    private mutating func follow(from home: String, to before: String) {
        if let added = MissedFixTracker<Field>.appended(from: home, to: before) {
            for i in entries.indices { entries[i].span += added }
        } else if before.count < home.count, home.hasPrefix(before) {
            let removed = home.count - before.count
            // Backspacing into the replacement edits it: it can't be put back.
            entries = entries.filter { $0.span.count - removed >= $0.replacement.count }
            for i in entries.indices { entries[i].span = String(entries[i].span.dropLast(removed)) }
        }
        entries = entries.filter { entry in
            before.hasSuffix(entry.span) && entry.tail.count <= Self.maxTail && Self.anchorHolds(entry, before: before)
        }
    }

    /// Entries that still match the text before the caret, newest first.
    public func matching(field: Field, before: String) -> [RecordedFix] {
        guard self.field == field else { return [] }
        return entries.reversed().filter { before.hasSuffix($0.span) && Self.anchorHolds($0, before: before) }
    }

    /// The newest entry that still matches, for the revert shortcut.
    public func newest(field: Field, before: String) -> RecordedFix? { matching(field: field, before: before).first }

    public func entry(id: Int) -> RecordedFix? { entries.first { $0.id == id } }

    /// The entry was put back (or can't be): it leaves the list. The text change itself comes
    /// through `rewriteEnd`.
    public mutating func remove(id: Int) { entries.removeAll { $0.id == id } }

    /// Hunch changed the end of the text before the caret from `old` to `new` (another fix, a
    /// revert, an undo): entries whose tail holds the change follow it; an entry whose replacement
    /// the change reaches into leaves (it was undone or rewritten).
    public mutating func rewriteEnd(from old: String, to new: String) {
        guard old != new else { return }
        entries = entries.compactMap { entry in
            guard entry.span.hasSuffix(old) else { return entry }
            guard entry.tail.count >= old.count else { return nil }
            var e = entry
            e.span = String(entry.span.dropLast(old.count)) + new
            return e
        }
        if let h = home, h.hasSuffix(old) {
            let now = String(h.dropLast(old.count)) + new
            home = now
            // Newer fixes after the change keep their place; the text before them (their anchor)
            // may hold the changed word: it is Hunch's own edit, so their anchors follow.
            for i in entries.indices where now.hasSuffix(entries[i].span) {
                entries[i].anchor = String(now.dropLast(entries[i].span.count).suffix(Self.anchorLength))
            }
        }
    }

    /// The fix was changed in place to `word` (another pick than the word as typed): the entry
    /// stays, as a fix of the same typed text to `word`, and is now the user's own pick. The text
    /// change itself is followed here (older entries' tails and `home`).
    public mutating func replace(id: Int, with word: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !word.isEmpty else { return }
        let entry = entries.remove(at: index)
        let old = entry.span, new = word + entry.tail
        rewriteEnd(from: old, to: new)
        guard word != entry.original else { return }
        var changed = entry
        changed.replacement = word
        changed.span = new
        changed.automatic = false
        entries.insert(changed, at: min(index, entries.count))
    }

    /// Focus left the field: forget everything.
    public mutating func reset() {
        entries = []
        field = nil
        home = nil
        pendingReads = 0
    }

    /// How far the caret is back from `home` over unchanged text (UTF-16 units), 0 when at home,
    /// nil when the read isn't `home` with the caret moved back.
    public func caretBack(before: String, after: String) -> Int? {
        guard let home else { return nil }
        return Self.caretBack(home: home, before: before, after: after)
    }

    /// `caretBack` against a given `home` (a fix kept aside while its menu is open).
    public static func caretBack(home: String, before: String, after: String) -> Int? {
        if home == before { return 0 }
        guard home.hasPrefix(before) else { return nil }
        let moved = home.dropFirst(before.count)
        return after.hasPrefix(moved) ? moved.utf16.count : nil
    }

    /// The plan that puts `fix` back, or nil when the text before the caret doesn't end with exactly
    /// the fix and what was typed after it, or the text before the fix changed (do nothing).
    /// `to`: another word to put in the fix's place instead of the word as typed (the menu under
    /// a fixed word).
    public static func revertPlan(_ fix: RecordedFix, before: String, to word: String? = nil) -> CatchUpPlan? {
        let target = word ?? fix.original
        guard !fix.replacement.isEmpty, !target.isEmpty, fix.span.hasPrefix(fix.replacement), before.hasSuffix(fix.span),
              anchorHolds(fix, before: before) else { return nil }
        return CatchUpPlan(word: fix.replacement, replacement: target, tail: String(fix.tail))
    }

    /// The text right before the fix still ends with the anchor (over what the read window covers).
    static func anchorHolds(_ fix: RecordedFix, before: String) -> Bool {
        let head = before.dropLast(fix.span.count)
        let n = min(head.count, fix.anchor.count)
        // A read window cut right at the fix can't show the anchor; it must show some of it.
        if head.count < fix.anchor.count && n == 0 && !fix.anchor.isEmpty { return false }
        return head.suffix(n) == fix.anchor.suffix(n)
    }

    /// One word as typed (no space or punctuation inside): what "learn from rejected fixes" and the
    /// field's restored words take.
    public static func isSingleWord(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy(isWordCharacter) && text.contains(where: \.isLetter)
    }

    /// A new word was typed after the fix already (boundary, then a word): reverting it now is the
    /// "undo, then type on" clean rejection.
    public static func typedOnAfter(_ fix: RecordedFix) -> Bool {
        FixRejectionWatch<Field>.wordFollows(fix.tail)
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
}
