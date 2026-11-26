import Foundation

/// "Fix automatically" owner of the text not yet settled: the last few words before the caret that
/// autocorrect hasn't looked at. Pure: fed the before-caret text of every read, it says what to do
/// next, one step at a time.
///
/// Every finished word (followed by a space) is looked at once, in order, also when no read came
/// right after it (fast typing, or reads skipped while a fix went in): a confident fix is a `.fix`
/// (at the caret, or behind it when the user typed on). A flagged word with candidates waits, and so
/// do flagged words right after it (up to `maxSlots`, a stretch); once a word that needs nothing is
/// finished after them, the model chooses for the whole stretch at once (`.choose`). After
/// Hunch changes the text (`rewriteEnd`), the next read continues with the words still unchecked.
public struct UnsettledSpan<Field: Hashable & Sendable>: Sendable {
    public enum Step: Sendable, Equatable {
        /// A confident fix: replace `word` (and retype what follows it) now.
        case fix(SpanFix)
        /// The waiting words have a finished word after them: the model chooses.
        case choose(StretchTrigger)
    }

    /// Most finished words held unchecked; older ones are settled without a look.
    public static var maxWords: Int { 4 }
    /// Most flagged words in a row decided together.
    public static var maxSlots: Int { 3 }
    /// Longest text after the last waiting word before the wait is given up.
    public static var maxTail: Int { 40 }

    /// A flagged word waiting: `stem` is the before-caret text through the word's trailing text.
    private struct Slot: Sendable {
        var stem: String
        var typo: AmbiguousTypo
        var start: Int { stem.count - typo.deleteCount }
    }

    private var field: Field?
    /// Before-caret text of the last read.
    private var lastBefore = ""
    /// The end of `lastBefore` not looked at yet (starts at a word or at whitespace).
    private var unchecked = ""
    private var waiting: [Slot] = []

    public init() {}

    public var isWaiting: Bool { !waiting.isEmpty }
    public var waitingWords: [String] { waiting.map(\.typo.misspelled) }
    /// Something before the caret is not settled yet: waiting words, or a word not looked at.
    public var needsSettle: Bool { !waiting.isEmpty || unchecked.contains(where: { $0.isLetter }) }

    public mutating func reset() {
        field = nil
        lastBefore = ""
        unchecked = ""
        waiting = []
    }

    /// A read of the field. `checkWords` false (a suggestion was just taken, the caret is mid-line):
    /// the finished words are settled without a look; waiting words can still be chosen.
    /// `finding` gets the text up to and including a word's first space after it.
    public mutating func read(field: Field, before: String, checkWords: Bool = true,
                              finding: (String) -> CorrectionFinding?) -> Step? {
        if self.field != field { waiting = [] }
        follow(field: field, before: before)
        // Return (or Send) approves what is shown: words before a line break are settled as typed.
        if let lineBreak = unchecked.lastIndex(where: \.isNewline) {
            unchecked = String(unchecked[unchecked.index(after: lineBreak)...])
        }
        keepValidWaiting(before)
        if let trigger = contextSettledTrigger(before) { return .choose(trigger) }
        var stems = finishedStems(before)
        if stems.count > Self.maxWords {
            settle(through: stems[stems.count - Self.maxWords - 1], before: before)
            stems.removeFirst(stems.count - Self.maxWords)
        }
        for stem in stems {
            guard checkWords else { settle(through: stem, before: before); continue }
            switch finding(stem) {
            case .fix(let p)?:
                settle(through: stem, before: before)
                guard p.deleteCount <= stem.count else { continue }
                let tail = p.trailing + String(before.dropFirst(stem.count))
                return .fix(SpanFix(before: before, word: p.misspelled, replacement: p.replacement, tail: tail))
            case .ambiguous(let typo)?:
                guard typo.deleteCount <= stem.count else { settle(through: stem, before: before); continue }
                let slot = Slot(stem: stem, typo: typo)
                // A slip across words covers the words before: it replaces their waits. One that
                // starts inside a waiting group whose first word is itself a slip ("w ith", then
                // "ith utilities") would split it: the group is chosen first (this word as typed after
                // it), and this word is looked at again on the next read. A group that only took a fine
                // word along ("note th") gives way ("th at").
                if let last = waiting.last, last.stem.count - last.typo.trailing.count > slot.start, slot.start > last.start,
                   last.typo.leadIsSlip, let trigger = trigger(before) {
                    return .choose(trigger)
                }
                while let last = waiting.last, last.stem.count - last.typo.trailing.count > slot.start {
                    waiting.removeLast()
                }
                if waiting.count == Self.maxSlots, let trigger = trigger(before) {
                    return .choose(trigger)  // this word is looked at again on the next read
                }
                settle(through: stem, before: before)
                waiting.append(slot)
            case nil:
                settle(through: stem, before: before)
                if let trigger = trigger(before) { return .choose(trigger) }
            }
        }
        if let trigger = contextSettledTrigger(before) { return .choose(trigger) }
        guard checkWords, let last = unchecked.last, !last.isWhitespace, !last.isLetter, !last.isNumber,
              unchecked.contains(where: { $0.isLetter }) else { return nil }
        // A sentence ended right at the caret ("reiew." at the end of a message): a settling point.
        // The waiting words and this word are decided now, with nothing after them.
        if Self.sentenceEnds.contains(last) { return settleAtCaret(before, finding: finding) }
        // Other punctuation ("reiew,"): waiting words are chosen with this word as typed after them;
        // a confident fix goes in now; anything else waits for the space after it.
        if !waiting.isEmpty, let trigger = trigger(before) { return .choose(trigger) }
        let fix: CorrectionProposal?
        switch finding(before) {
        case .fix(let p)?: fix = p
        case .ambiguous(let t)?: fix = t.preferred.map {
            CorrectionProposal(misspelled: t.misspelled, replacement: $0, deleteCount: t.deleteCount, trailing: t.trailing)
        }
        case nil: fix = nil
        }
        if let p = fix, p.deleteCount <= unchecked.count {
            unchecked = ""
            return .fix(SpanFix(before: before, word: p.misspelled, replacement: p.replacement, tail: p.trailing))
        }
        return nil
    }

    /// Punctuation that ends a sentence: typed right after a word, it is a settling point.
    public static var sentenceEnds: Set<Character> { [".", "!", "?"] }

    /// A settling point at the caret (the user pressed Return, or the text ends here): nothing more
    /// will follow the words before the caret. Like `read`, one step at a time, but the waiting words
    /// and the word at the caret (finished or not) are decided now, with nothing after them. Call it
    /// again after each step (`rewriteEnd` for a fix) until it answers nil: then everything before the
    /// caret is settled.
    public mutating func settle(field: Field, before: String, finding: (String) -> CorrectionFinding?) -> Step? {
        if let step = read(field: field, before: before, finding: finding) { return step }
        return settleAtCaret(before, finding: finding)
    }

    /// The word at the caret is looked at now (with a space after it when it has nothing after it),
    /// and the waiting words are chosen with it and nothing after.
    private mutating func settleAtCaret(_ before: String, finding: (String) -> CorrectionFinding?) -> Step? {
        if let last = unchecked.last, !last.isWhitespace, unchecked.contains(where: { $0.isLetter || $0.isNumber }) {
            let open = last.isLetter || last.isNumber  // nothing typed after the word yet
            switch Self.finding(at: before, open: open, finding: finding) {
            case .ambiguous(let typo)? where typo.deleteCount <= before.count:
                let slot = Slot(stem: before, typo: typo)
                if let last = waiting.last, last.stem.count - last.typo.trailing.count > slot.start, slot.start > last.start,
                   last.typo.leadIsSlip {
                    // Splits a group whose first word is a slip: the group goes first (see `read`).
                    return trigger(before, end: before.count).map { .choose($0) }
                }
                while let last = waiting.last, last.stem.count - last.typo.trailing.count > slot.start {
                    waiting.removeLast()
                }
                if waiting.count == Self.maxSlots {
                    return trigger(before, end: before.count).map { .choose($0) }  // this word on the next call
                }
                waiting.append(slot)
                unchecked = ""
            case .fix(let p)? where p.deleteCount <= unchecked.count:
                // The waiting words first, with this word as typed after them; the fix on the next call.
                if !waiting.isEmpty { return trigger(before, end: before.count).map { .choose($0) } }
                unchecked = ""
                return .fix(SpanFix(before: before, word: p.misspelled, replacement: p.replacement, tail: p.trailing))
            default:
                unchecked = ""
            }
        }
        return trigger(before, end: before.count).map { .choose($0) }
    }

    /// The finding for the word at the caret. `open`: nothing typed after it yet, so it is looked at as
    /// if a space followed, and the answer is made to end at the caret.
    static func finding(at before: String, open: Bool, finding: (String) -> CorrectionFinding?) -> CorrectionFinding? {
        guard open else { return finding(before) }
        switch finding(before + " ") {
        case .fix(var p)? where p.trailing.hasSuffix(" "):
            p.trailing.removeLast()
            p.deleteCount -= 1
            return .fix(p)
        case .ambiguous(var t)? where t.trailing.hasSuffix(" "):
            t.trailing.removeLast()
            t.deleteCount -= 1
            return .ambiguous(t)
        default:
            return nil
        }
    }

    /// Hunch changed the end of the text before the caret from `old` to `new` (a fix went in, or
    /// was undone). Text it rewrote before the unchecked part stays settled.
    /// `old` may end with text typed after the last read (the same at the end of `new`).
    public mutating func rewriteEnd(from fullOld: String, to fullNew: String) {
        // Drop what this span hasn't seen yet from both ends.
        var unseen = 0
        while unseen < fullOld.count, !lastBefore.hasSuffix(fullOld.dropLast(unseen)) { unseen += 1 }
        guard unseen < fullOld.count, fullNew.hasSuffix(fullOld.suffix(unseen)) else {
            waiting = []
            return
        }
        let old = String(fullOld.dropLast(unseen)), new = String(fullNew.dropLast(unseen))
        guard old != new else { return }
        let editStart = lastBefore.count - old.count
        waiting.removeAll { $0.stem.count > editStart }
        lastBefore = String(lastBefore.dropLast(old.count)) + new
        if old.count <= unchecked.count {
            unchecked = String(unchecked.dropLast(old.count)) + new
        } else if !(old.hasSuffix(unchecked) && new.hasSuffix(unchecked)) {
            unchecked = ""
        }
    }

    // MARK: The waiting words

    /// Drops waiting words whose text changed, and all of them when a line break or too much text
    /// came after them.
    private mutating func keepValidWaiting(_ before: String) {
        waiting.removeAll { !before.hasPrefix($0.stem) }
        guard let last = waiting.last else { return }
        let added = before.dropFirst(last.stem.count)
        if added.contains(where: \.isNewline) || added.count > Self.maxTail { waiting = [] }
    }

    /// The trigger when the word after the waiting ones was already looked at (it was fixed, or
    /// settled without a look).
    private mutating func contextSettledTrigger(_ before: String) -> StretchTrigger? {
        guard let last = waiting.last, let end = Self.contextWordEnd(before, after: last.stem.count, finishedOnly: true),
              end < before.count - unchecked.count else { return nil }
        return trigger(before)
    }

    /// Where the first word after `offset` ends (nil: none yet). A word counts once a space follows
    /// it, or punctuation ends it right at the caret (unless `finishedOnly`).
    static func contextWordEnd(_ before: String, after offset: Int, finishedOnly: Bool = false) -> Int? {
        let added = Array(before.dropFirst(offset))
        var i = 0
        while i < added.count, isSpace(added[i]) { i += 1 }
        let wordStart = i
        while i < added.count, !added[i].isWhitespace { i += 1 }
        guard i > wordStart else { return nil }
        if i < added.count { return offset + i }
        guard !finishedOnly, let last = added.last, ".,;:!?".contains(last),
              added[wordStart..<i].contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return offset + i
    }

    /// The waiting words and the word after them, as a trigger; the wait is over then.
    /// `end`: where the context ends (default: the end of the first word after them).
    private mutating func trigger(_ before: String, end fixedEnd: Int? = nil) -> StretchTrigger? {
        guard let last = waiting.last,
              let end = fixedEnd ?? Self.contextWordEnd(before, after: last.stem.count), end >= last.stem.count
        else { return nil }
        let slots = waiting
        waiting = []
        let chars = Array(before)
        guard slots.allSatisfy({ before.hasPrefix($0.stem) }) else { return nil }
        func text(_ a: Int, _ b: Int) -> String { String(chars[a..<b]) }
        var gaps: [String] = []
        for (i, slot) in slots.enumerated() {
            let wordEnd = slot.start + slot.typo.misspelled.count
            guard text(slot.start, wordEnd) == slot.typo.misspelled else { return nil }
            gaps.append(text(wordEnd, i + 1 < slots.count ? slots[i + 1].start : end))
        }
        var typos = slots.map(\.typo)
        // Nothing at all after the last word (Return): the model sees no context after it, so the
        // system's confident fix there is not taken by default ("haa" at the end of a chat is not
        // "has"); it goes in only when the model picks it by the margin. A sentence end ("snaks.")
        // keeps the default.
        if fixedEnd != nil, gaps[gaps.count - 1].allSatisfy(\.isWhitespace) {
            typos[typos.count - 1].preferred = nil
        }
        return StretchTrigger(before: before, head: text(0, slots[0].start), slots: typos,
                              gaps: gaps, tail: text(end, chars.count))
    }

    // MARK: Following the field

    private mutating func follow(field: Field, before: String) {
        defer {
            self.field = field
            lastBefore = before
        }
        guard self.field == field else {
            unchecked = Self.lastWordRegion(before)
            return
        }
        if before == lastBefore { return }
        if let more = MissedFixTracker<Field>.appended(from: lastBefore, to: before) {
            unchecked += more
        } else if before.count < lastBefore.count, lastBefore.hasPrefix(before),
                  lastBefore.count - before.count <= unchecked.count {
            unchecked = String(unchecked.dropLast(lastBefore.count - before.count))  // Backspace
        } else {
            unchecked = Self.lastWordRegion(before)  // edited elsewhere: start again at the last word
        }
        // `appended` can mistake an edit in place for typing (an accent joining the last letter, an
        // input method replacing its composition, "aaaa" → "aaab"); the unchecked part must stay the
        // end of `before`, or it outgrows it.
        if !before.hasSuffix(unchecked) { unchecked = Self.lastWordRegion(before) }
    }

    /// Marks everything up to the end of `stem` (a prefix of `before`) as looked at.
    private mutating func settle(through stem: String, before: String) {
        let rest = max(0, before.count - stem.count)
        if rest < unchecked.count { unchecked = String(unchecked.suffix(rest)) }
    }

    /// The stems of the finished words in the unchecked part: `before` up to and including the first
    /// space after each word. Words ended by a line break are settled without a look.
    private mutating func finishedStems(_ before: String) -> [String] {
        let head = before.dropLast(unchecked.count)
        var stems: [String] = []
        var consumed = 0
        var lastSettled = 0
        let chars = Array(unchecked)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            let wordStart = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            guard i > wordStart, i < chars.count else { break }  // no word, or still being typed
            if chars[i].isNewline {
                i += 1
                lastSettled = i
                continue
            }
            i += 1
            consumed = i
            stems.append(head + String(chars[0..<consumed]))
        }
        // A word ended by a line break (and nothing finished after it) is settled now.
        if lastSettled > consumed { unchecked = String(chars[lastSettled...]) }
        return stems
    }

    /// The last word before the caret and anything after it ("hello teh " → "teh ").
    static func lastWordRegion(_ before: String) -> String {
        var t = Substring(before)
        while let l = t.last, isSpace(l) { t = t.dropLast() }
        if let l = t.last, l.isNewline { return "" }
        while let l = t.last, !l.isWhitespace { t = t.dropLast() }
        return String(before.dropFirst(t.count))
    }

    static func isSpace(_ c: Character) -> Bool { c == " " || c == "\u{00A0}" || c == "\t" }
}

/// A fix for a word at or behind the caret: replaces the word and what follows it at the caret
/// (deletes back to the word, types the fix and the rest again), the way that works in every host.
public struct SpanFix: Sendable, Equatable {
    /// Before-caret text when the fix was decided: ends with `word + tail`.
    public var before: String
    public var word: String
    public var replacement: String
    /// What followed the word then (its trailing text, maybe more words).
    public var tail: String

    public init(before: String, word: String, replacement: String, tail: String) {
        self.before = before
        self.word = word
        self.replacement = replacement
        self.tail = tail
    }

    /// The edit at the caret for the text before it now (the user may have typed on since).
    public struct Edit: Sendable, Equatable {
        /// Deleted before the caret: the word and everything after it.
        public var original: String
        /// Typed instead: the fix and the same text after it.
        public var fixed: String
        public var tail: String
        /// The text before the caret once the edit is in.
        public var after: String
    }

    /// nil when the text changed other than by typing on, or the tail is too long or crosses a line.
    public func edit(now: String) -> Edit? {
        let typedOn: String
        if now == before {
            typedOn = ""
        } else if let more = MissedFixTracker<Int>.appended(from: before, to: now) {
            typedOn = more
        } else {
            return nil
        }
        let tail = self.tail + typedOn
        let original = word + tail
        guard now.hasSuffix(original), tail.count <= CatchUpPlan.maxKeyboardTail,
              !tail.contains(where: \.isNewline) else { return nil }
        let fixed = replacement + tail
        return Edit(original: original, fixed: fixed, tail: tail, after: String(now.dropLast(original.count)) + fixed)
    }
}
