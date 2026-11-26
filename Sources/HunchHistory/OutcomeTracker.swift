import Foundation
import HunchCore

/// Turns raw observations (suggestion shown, Tab, text changes, Escape, focus loss, time) into
/// `LearningEvent`s. A pure value-type state machine: time is passed in, nothing is stored beyond
/// the words needed to decide, and nothing is persisted.
///
/// Assumption: `before` strings for one field come from the same source/window, so a later value
/// extends an earlier one when the user only typed. If the app truncates context differently
/// between calls, edits look like "unrelated change" and the pending accept is silently dropped.
public struct OutcomeTracker: Sendable {
    public let settleInterval: TimeInterval

    public init(settleInterval: TimeInterval = 10) {
        self.settleInterval = settleInterval
    }

    /// The suggestion currently on screen, reduced to what typed-over detection needs.
    private struct Anchor: Sendable {
        var field: FieldID
        /// Text before the word being suggested (excludes any partial word already typed).
        var start: String
        var fullBefore: String
        var suggested: String
        var scores: [WordScore]
        var boosted: Set<String>
        var diverged = false
    }

    private struct Pending: Sendable {
        var field: FieldID
        /// Text before the accepted words (partial word excluded).
        var prior: String
        /// Accepted words as inserted (a typed partial word is prepended).
        var text: String
        var expectedBefore: String
        var scores: [String: Float]
        /// Normalized words the decoder was biased toward when proposing them.
        var boosted: Set<String>
        var at: Date
        var edited = false
    }

    private var anchor: Anchor?
    private var pending: [Pending] = []
    private var knownField: FieldID?
    private var knownBefore = ""

    // MARK: Observations

    public mutating func suggestionShown(field: FieldID, before: String, suggestion: String,
                                         scores: [WordScore], boosted: Set<String> = [],
                                         at now: Date) -> [LearningEvent] {
        let events = sweep(now)
        knownField = field
        knownBefore = before
        if let old = anchor, old.field == field, old.diverged, Self.remainder(of: before, after: old.start) != nil {
            return events   // keep judging the word the user is typing against the original ghost
        }
        anchor = makeAnchor(field: field, before: before, suggestion: suggestion, scores: scores,
                            boosted: Set(boosted.map(Self.norm)))
        return events
    }

    /// A unit of the visible suggestion was inserted via Tab.
    public mutating func accepted(field: FieldID, text: String, at now: Date) -> [LearningEvent] {
        let events = sweep(now)
        let bv: String
        var scoreList: [WordScore] = []
        var boosted: Set<String> = []
        if let a = anchor, a.field == field {
            bv = a.fullBefore
            scoreList = a.scores
            boosted = a.boosted
        } else if knownField == field {
            bv = knownBefore
        } else {
            return events
        }
        anchor = nil
        guard !text.isEmpty else { return events }
        var lookup: [String: Float] = [:]
        for s in scoreList { lookup[Self.norm(s.text)] = s.logProb }

        var partial = ""
        if let first = text.first, WordText.isWordChar(first), let last = WordText.tokens(in: bv).last,
           !last.completed, !last.isCJK {
            partial = last.text
        }
        let newBefore = bv + text
        knownField = field
        knownBefore = newBefore

        if let idx = pending.lastIndex(where: { $0.field == field }),
           pending[idx].expectedBefore == bv, !pending[idx].edited, partial.isEmpty {
            pending[idx].text += text
            pending[idx].expectedBefore = newBefore
            pending[idx].scores.merge(lookup) { old, _ in old }
            pending[idx].boosted.formUnion(boosted)
            pending[idx].at = now
            return events
        }
        // A partial word sits at the end of `bv`; drop it from the prior text and prepend it.
        var scoresByWord = lookup
        if !partial.isEmpty, let firstTok = WordText.tokens(in: text).first, firstTok.start == 0,
           let lp = lookup[Self.norm(firstTok.text)] {
            scoresByWord[Self.norm(partial + firstTok.text)] = lp
        }
        pending.append(Pending(field: field, prior: String(bv.dropLast(partial.count)), text: partial + text,
                               expectedBefore: newBefore, scores: scoresByWord, boosted: boosted, at: now))
        return events
    }

    /// The text before the caret changed.
    public mutating func textChanged(field: FieldID, before: String, at now: Date) -> [LearningEvent] {
        var events = sweep(now)
        knownField = field
        knownBefore = before

        // Edits to accepted text.
        var kept: [Pending] = []
        for var p in pending {
            guard p.field == field else { kept.append(p); continue }
            if Self.remainder(of: before, after: p.expectedBefore) != nil {
                p.edited = false
                kept.append(p)
                continue
            }
            p.edited = true
            guard let tail = Self.remainder(of: before, after: p.prior) else { kept.append(p); continue }
            if let ev = correction(p, tail: tail) {
                events.append(ev)
            } else {
                kept.append(p)
            }
        }
        pending = kept

        // Typed over a visible suggestion.
        if var a = anchor, a.field == field {
            if let rest = Self.remainder(of: before, after: a.start) {
                let firstChar = rest.first(where: { !$0.isWhitespace })
                if let c = firstChar, !WordText.isWordChar(c) {
                    anchor = nil
                } else if let t = WordText.tokens(in: rest).first {
                    if t.completed {
                        if !t.isCJK, !t.opaque, t.text.lowercased() != a.suggested.lowercased() {
                            events.append(LearningEvent(field: field, kind: .typedOver(
                                context: WordText.contextWords(of: a.start),
                                suggested: a.suggested, typed: t.text),
                                names: Self.names(after: a.start, in: rest).intersection([t.text])))
                        }
                        anchor = nil
                    } else {
                        a.diverged = !a.suggested.lowercased().hasPrefix(t.text.lowercased())
                        anchor = a
                    }
                }
            } else {
                anchor = nil
            }
        }
        return events
    }

    /// Text typed after `earlier`, given a later before-caret snapshot of the same field. The app
    /// reads a bounded window that slides forward in long documents, so the snapshot's start can
    /// move: align on the last stretch of `earlier` instead of requiring a whole-string prefix.
    /// Nil when that stretch isn't present (the user edited or moved elsewhere).
    static func remainder(of later: String, after earlier: String) -> String? {
        if later.hasPrefix(earlier) { return String(later.dropFirst(earlier.count)) }
        let anchorLength = 48
        guard earlier.count > anchorLength else { return nil }
        let tail = String(earlier.suffix(anchorLength))
        guard let hit = later.range(of: tail, options: .backwards) else { return nil }
        return String(later[hit.upperBound...])
    }

    public mutating func dismissed(field: FieldID, at now: Date) -> [LearningEvent] {
        var events = sweep(now)
        if let a = anchor, a.field == field {
            events.append(LearningEvent(field: field, kind: .dismissed(
                context: WordText.contextWords(of: a.start), suggested: a.suggested)))
            anchor = nil
        }
        return events
    }

    /// Focus left `field`: unedited accepted text counts as confirmed; everything else is dropped.
    public mutating func focusLeft(field: FieldID, at now: Date) -> [LearningEvent] {
        var events = sweep(now)
        for p in pending where p.field == field && !p.edited { events.append(confirm(p)) }
        pending.removeAll { $0.field == field }
        if anchor?.field == field { anchor = nil }
        if knownField == field { knownField = nil; knownBefore = "" }
        return events
    }

    /// Forget everything: pending accepts (never confirmed), the on-screen anchor, and any retained
    /// before-caret text. Call when learning is turned off or Secure Input begins.
    public mutating func reset() {
        anchor = nil
        pending = []
        knownField = nil
        knownBefore = ""
    }

    public mutating func tick(at now: Date) -> [LearningEvent] { sweep(now) }

    // MARK: Internals

    private mutating func sweep(_ now: Date) -> [LearningEvent] {
        var events: [LearningEvent] = []
        var kept: [Pending] = []
        for p in pending {
            if now.timeIntervalSince(p.at) >= settleInterval {
                if !p.edited { events.append(confirm(p)) }
            } else {
                kept.append(p)
            }
        }
        pending = kept
        return events
    }

    private func confirm(_ p: Pending) -> LearningEvent {
        // An opaque token (URL, email) becomes an empty-text break so its neighbors don't pair up.
        var words: [WordScore] = []
        for t in WordText.tokens(in: p.text) {
            if t.opaque {
                if let last = words.last, !last.text.isEmpty { words.append(WordScore(text: "", logProb: 0)) }
            } else {
                words.append(WordScore(text: t.text, logProb: p.scores[Self.norm(t.text)] ?? Self.unknownLogProb))
            }
        }
        return LearningEvent(field: p.field, kind: .confirmed(
            words: words, context: WordText.contextWords(of: p.prior), boosted: p.boosted),
            names: Self.names(after: p.prior, in: p.text))
    }

    /// First completed word in `tail` that differs from the accepted word at the same position.
    private func correction(_ p: Pending, tail: String) -> LearningEvent? {
        let acc = WordText.tokens(in: p.text)
        let typed = WordText.tokens(in: tail)
        for (i, t) in typed.enumerated() {
            guard t.completed, i < acc.count else { return nil }
            if t.text.lowercased() == acc[i].text.lowercased() { continue }
            if t.isCJK || t.opaque || acc[i].isCJK || acc[i].opaque { return nil }
            let ctx = WordText.contextWords(of: ([p.prior] + acc.prefix(i).map(\.text)).joined(separator: " "))
            return LearningEvent(field: p.field, kind: .correctedAfterAccept(
                context: ctx, accepted: acc[i].text, corrected: t.text),
                names: Self.names(after: p.prior, in: tail).intersection([t.text]))
        }
        return nil
    }

    private func makeAnchor(field: FieldID, before: String, suggestion: String, scores: [WordScore],
                            boosted: Set<String>) -> Anchor? {
        let sugToks = WordText.tokens(in: suggestion)
        guard let first = sugToks.first, !first.isCJK else { return nil }
        var start = before
        var word = first.text
        if let b = before.last, WordText.isWordChar(b), let s = suggestion.first, WordText.isWordChar(s),
           let last = WordText.tokens(in: before).last, !last.completed, !last.isCJK {
            start = String(before.dropLast(last.text.count))
            word = last.text + first.text
        }
        return Anchor(field: field, start: start, fullBefore: before, suggested: word, scores: scores, boosted: boosted)
    }

    /// Names (`WordText.namesMidSentence`) in `text`, which follows `prior`. Only the end of
    /// `prior` matters: it decides whether the first words of `text` start a sentence.
    static func names(after prior: String, in text: String) -> Set<String> {
        let head = String(prior.suffix(80))
        return WordText.namesMidSentence(in: head + text, from: head.count)
    }

    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Assumed log-probability for an accepted word that has no score (moderately surprising).
    static let unknownLogProb: Float = -2
}
