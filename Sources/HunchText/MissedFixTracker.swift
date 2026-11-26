import Foundation

/// A spelling fix that was shown and then typed past, still waiting in the field (autocorrect
/// catch-up). `span` is the misspelled word plus everything typed after it, up to the caret.
public struct MissedFix: Sendable, Equatable {
    public var id: Int
    public var word: String
    public var replacement: String
    /// The word and the text after it, up to the caret. Always starts with `word`.
    public var span: String
    /// The skip ("typed past") is counted only when the entry leaves the list without a catch-up.
    public var skipPending: Bool

    /// The text between the word and the caret.
    public var tail: Substring { span.dropFirst(word.count) }

    public init(id: Int, word: String, replacement: String, span: String, skipPending: Bool) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.span = span
        self.skipPending = skipPending
    }
}

/// Remembers the last few fixes the user typed past in the field they are still in, so a shortcut
/// can apply them later, newest first (design §13, autocorrect catch-up).
///
/// Pure: fed the before-caret text of every read. A fix shown and dismissed with Escape, or taken
/// with Tab, never becomes a missed fix. An entry is dropped when focus leaves the field, the field
/// is emptied, the word itself (or the text after it) is edited so the text no longer ends with the
/// entry's span, or the list is full. Dropped entries hand back their word when their skip is still
/// pending, so the caller can count it then.
public struct MissedFixTracker<Field: Hashable & Sendable>: Sendable {
    public static var capacity: Int { 5 }
    /// Entries whose text after the word grows past this are dropped: no longer "just missed".
    public static var maxTail: Int { 300 }

    private struct Pending: Sendable {
        var field: Field
        var before: String
        var word: String
        var replacement: String
        var trailingCount: Int
    }

    private var pending: Pending?
    private var field: Field?
    /// The before-caret text of the last read, to tell typing at the end from other edits.
    private var lastBefore: String?
    /// Oldest first.
    public private(set) var entries: [MissedFix] = []
    private var nextID = 1

    public init() {}

    /// A fix for `word` is showing with this text before the caret (word + `trailingCount` characters).
    public mutating func shown(field: Field, before: String, word: String, replacement: String, trailingCount: Int) {
        pending = Pending(field: field, before: before, word: word, replacement: replacement,
                          trailingCount: trailingCount)
    }

    /// A fix that was never shown joins the list as already typed past (autocorrect for an
    /// ambiguous word: the model's pick when it wasn't sure enough to apply it). `before` is the
    /// last text read and ends with `span`, the word and what follows it up to the caret.
    public mutating func offer(field: Field, before: String, word: String, replacement: String, span: String) {
        guard span.hasPrefix(word), before.hasSuffix(span), word != replacement else { return }
        if self.field != field {
            _ = dropAll()
            self.field = field
        }
        lastBefore = before
        entries.removeAll { $0.span == span }
        entries.append(MissedFix(id: nextID, word: word, replacement: replacement, span: span, skipPending: false))
        nextID += 1
        while entries.count > Self.capacity { entries.removeFirst() }
    }

    /// Escape on the shown fix: it is not a missed fix.
    public mutating func escaped() { pending = nil }

    /// The shown fix was applied with Tab, or applied automatically.
    public mutating func accepted() { pending = nil }

    /// New before-caret text. `skipped` is the word the skip tracker counted as typed past on this
    /// read (`CorrectionSkipTracker.update`), if any. With `deferSkips` (catch-up is on), that skip
    /// stays pending on the new entry and is counted only if the entry leaves without a catch-up;
    /// otherwise it is counted right away. Returns the words whose skip must be counted now.
    @discardableResult
    public mutating func update(field: Field, before: String, skipped: String? = nil,
                                deferSkips: Bool = false) -> [String] {
        var counted: [String] = []
        var skipTaken = false
        func done() -> [String] {
            if let skipped, !skipTaken { counted.append(skipped) }
            return counted
        }
        if self.field != field {
            counted += dropAll()
            self.field = field
            lastBefore = nil
        }
        if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            counted += dropAll()
            pending = nil
            lastBefore = before
            return done()
        }
        if let last = lastBefore, last != before { counted += follow(from: last, to: before) }
        lastBefore = before
        if let p = pending, p.field == field, before != p.before {
            pending = nil
            let wordStart = p.before.count - p.trailingCount - p.word.count
            if before.count > p.before.count, before.hasPrefix(p.before), wordStart >= 0 {
                let span = String(before.dropFirst(wordStart))
                let pendingSkip = deferSkips && skipped != nil
                if let same = entries.firstIndex(where: { $0.span == span }) {
                    // The same occurrence shown twice ("amigo," then "amigo, "): one entry.
                    if pendingSkip, !entries[same].skipPending { entries[same].skipPending = true; skipTaken = true }
                } else if span.hasPrefix(p.word) {
                    entries.append(MissedFix(id: nextID, word: p.word, replacement: p.replacement,
                                             span: span, skipPending: pendingSkip))
                    nextID += 1
                    skipTaken = pendingSkip
                }
            }
        } else if let p = pending, p.field != field {
            pending = nil
        }
        while entries.count > Self.capacity {
            let old = entries.removeFirst()
            if old.skipPending { counted.append(old.word) }
        }
        return done()
    }

    /// Focus left the field or secure input began: forget everything. Returns pending skips.
    public mutating func reset() -> [String] {
        pending = nil
        field = nil
        lastBefore = nil
        return dropAll()
    }

    /// The newest entry that still matches the text before the caret, or nil.
    public func newest(field: Field, before: String) -> MissedFix? {
        guard self.field == field else { return nil }
        return entries.last { before.hasSuffix($0.span) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The field the entries belong to (the last one read).
    public var trackedField: Field? { field }

    /// The entry's fix was applied in place: it leaves the list, older entries' spans (which
    /// contain the fixed word) take the replacement, and the expected text before the caret follows.
    public mutating func applied(id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let done = entries.remove(at: index)
        rewriteEnd(from: done.span, to: done.replacement + done.tail)
    }

    /// Hunch itself changed the end of the text before the caret from `old` to `new` (a fix
    /// applied at or behind the caret): entries whose spans reach over it, and the text expected
    /// before the caret, follow instead of being dropped as edited.
    public mutating func rewriteEnd(from old: String, to new: String) {
        guard old != new else { return }
        for i in entries.indices where entries[i].span.hasSuffix(old) && entries[i].span.count > old.count {
            entries[i].span = String(entries[i].span.dropLast(old.count)) + new
        }
        if let last = lastBefore, last.hasSuffix(old) {
            lastBefore = String(last.dropLast(old.count)) + new
        }
    }

    /// The entry can't be applied (the field doesn't hold what was expected): drop it. Returns its
    /// word when its skip is still pending.
    public mutating func abandon(id: Int) -> String? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let gone = entries.remove(at: index)
        return gone.skipPending ? gone.word : nil
    }

    // MARK: Following edits

    /// Typing at the end grows every span, Backspace at the end shrinks it; any other change keeps
    /// only entries the text still ends with.
    private mutating func follow(from last: String, to before: String) -> [String] {
        guard !entries.isEmpty else { return [] }
        var counted: [String] = []
        if let added = Self.appended(from: last, to: before) {
            for i in entries.indices { entries[i].span += added }
        } else if before.count < last.count, last.hasPrefix(before) {
            let removed = last.count - before.count
            entries = entries.filter { entry in
                // Backspacing into the word (or right up to it) edits that word: it no longer matches.
                let keep = entry.span.count - removed > entry.word.count
                if !keep, entry.skipPending { counted.append(entry.word) }
                return keep
            }
            for i in entries.indices { entries[i].span = String(entries[i].span.dropLast(removed)) }
        }
        entries = entries.filter { entry in
            let keep = before.hasSuffix(entry.span) && entry.tail.count <= Self.maxTail
            if !keep, entry.skipPending { counted.append(entry.word) }
            return keep
        }
        return counted
    }

    /// The text typed at the end, also when the read window slid forward (a long field whose
    /// before-caret text is cut at the front).
    public static func appended(from last: String, to before: String) -> String? {
        if before.count > last.count, before.hasPrefix(last) { return String(before.dropFirst(last.count)) }
        for shift in 1...16 where last.count > shift {
            let kept = last.dropFirst(shift)
            if before.count > kept.count, before.hasPrefix(kept) { return String(before.dropFirst(kept.count)) }
        }
        return nil
    }

    private mutating func dropAll() -> [String] {
        let words = entries.filter(\.skipPending).map(\.word)
        entries = []
        return words
    }
}

/// What a catch-up fix replaces, checked against the text before the caret right now. Offsets are
/// given in UTF-16 units (Accessibility ranges) and in characters (arrow-key presses).
public struct CatchUpPlan: Sendable, Equatable {
    public var word: String
    public var replacement: String
    /// Text between the word and the caret.
    public var tail: String

    public var wordUTF16: Int { word.utf16.count }
    public var tailUTF16: Int { tail.utf16.count }
    public var spanUTF16: Int { wordUTF16 + tailUTF16 }
    public var span: String { word + tail }
    /// Characters (grapheme clusters) the caret moves past with arrow keys.
    public var tailCharacters: Int { tail.count }
    public var wordCharacters: Int { word.count }
    /// The text before the caret once the fix is in.
    public func fixedBefore(_ before: String) -> String { String(before.dropLast(span.count)) + replacement + tail }

    /// Most characters between the word and the caret the arrow-key path walks.
    public static let maxKeyboardTail = 80

    /// The plan for `fix`, or nil when the text before the caret doesn't end with exactly the word
    /// and what was typed after it (the text changed: do nothing).
    public static func make(_ fix: MissedFix, before: String) -> CatchUpPlan? {
        guard !fix.word.isEmpty, fix.span.hasPrefix(fix.word), before.hasSuffix(fix.span) else { return nil }
        // The character before the word must not continue it ("xteh" is not "teh").
        let head = before.dropLast(fix.span.count)
        if let previous = head.last, previous.isLetter || previous.isNumber { return nil }
        return CatchUpPlan(word: fix.word, replacement: fix.replacement, tail: String(fix.tail))
    }

    /// Whether the arrow-key path may walk this tail: short enough, and no line break (Up/Down-free
    /// walking still crosses lines, but a line break in a chat box is where a message was sent).
    public var keyboardAllowed: Bool {
        tail.count <= Self.maxKeyboardTail && !tail.contains(where: \.isNewline)
    }

    // MARK: Checking reads during the arrow-key path

    /// The caret walked back over the tail and the word is selected: the text before the selection
    /// is what was before the word, the selection is the word, the tail follows it.
    public func wordSelected(before: String, selected: String, after: String, originalBefore: String) -> Bool {
        let head = originalBefore.dropLast(span.count)
        return Self.endsSame(before, head) && Self.norm(selected) == Self.norm(word)
            && Self.norm(after).hasPrefix(Self.norm(tail))
    }

    /// The replacement was typed over the selected word: it ends the text before the caret and the
    /// tail follows.
    public func replacementTyped(before: String, after: String, originalBefore: String) -> Bool {
        let head = originalBefore.dropLast(span.count)
        return Self.endsSame(before, head + replacement) && Self.norm(after).hasPrefix(Self.norm(tail))
    }

    /// The caret is back after the tail, with the fix in.
    public func caretRestored(before: String, originalBefore: String) -> Bool {
        Self.endsSame(before, Substring(fixedBefore(originalBefore)))
    }

    /// The caret is where it started and nothing changed (after undoing the moves).
    public static func unchanged(before: String, originalBefore: String) -> Bool {
        endsSame(before, Substring(originalBefore))
    }

    /// Same text at the end, over what both reads cover (their windows may start differently).
    static func endsSame(_ read: String, _ expected: Substring) -> Bool {
        let a = norm(read), b = norm(String(expected))
        let n = min(a.count, b.count, 400)
        if a.count < b.count && a.count < 400 { return false }  // the read is shorter than the text expected
        return a.suffix(n) == b.suffix(n)
    }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    public init(word: String, replacement: String, tail: String) {
        self.word = word
        self.replacement = replacement
        self.tail = tail
    }
}

/// "Fix automatically": Backspace straight after an automatic fix restores the original word.
/// Pure state; the keyboard monitor consumes that Backspace, the coordinator asks `backspace`.
public struct AutoFixUndo<Field: Hashable & Sendable>: Sendable {
    public struct Plan: Sendable, Equatable {
        /// Characters to delete before the caret: the fix and its trailing text.
        public var deleteCount: Int
        /// What to type instead: the original word and its trailing text.
        public var text: String
        /// The word that was restored (counts as a skip).
        public var word: String
    }

    private struct Armed: Sendable {
        var field: Field
        var beforeFix: String
        var afterFix: String
        var original: String
        var fix: String
        var trailing: String
    }

    private var armed: Armed?

    public init() {}

    public var isArmed: Bool { armed != nil }

    /// An automatic fix replaced `original + trailing` (ending `beforeFix`) with `fix + trailing`.
    public mutating func applied(field: Field, beforeFix: String, original: String, fix: String, trailing: String) {
        let stem = beforeFix.dropLast(original.count + trailing.count)
        armed = Armed(field: field, beforeFix: beforeFix, afterFix: stem + fix + trailing,
                      original: original, fix: fix, trailing: trailing)
    }

    /// A read of the field. Still the text from just before or just after the fix keeps the undo;
    /// anything else (typing on, another field) ends it.
    public mutating func update(field: Field, before: String) {
        guard let a = armed else { return }
        if a.field != field || (before != a.afterFix && before != a.beforeFix) { armed = nil }
    }

    /// Any key other than that first Backspace makes Backspace behave normally again.
    public mutating func otherKey() { armed = nil }

    /// Backspace straight after the fix: the replacement to make, when the field shows the fix.
    /// Ends the undo either way.
    public mutating func backspace(field: Field, before: String) -> Plan? {
        defer { armed = nil }
        guard let a = armed, a.field == field, before == a.afterFix else { return nil }
        return Plan(deleteCount: a.fix.count + a.trailing.count, text: a.original + a.trailing, word: a.original)
    }

    public mutating func reset() { armed = nil }
}
