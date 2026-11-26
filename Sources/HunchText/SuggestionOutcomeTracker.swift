import Foundation

/// Live acceptance log (opt-in, shares "Save typing samples"): follows each shown suggestion in the
/// focused field and says what happened to it, so live numbers can be set against the replays.
/// Pure: time is passed in, and `Info` is whatever the app wants carried to the finished record
/// (app, surface, confidence, build). Nothing here decides whether recording is allowed.
///
/// A suggestion ends as one `Result`. Taken text is then watched for `settleInterval`: if the user
/// edits back into it, the record says so (`editedAfterAccept`). Reads may lag behind an insert, so
/// the watch only starts once a read has shown the taken text in the field.
public struct SuggestionOutcomeTracker<Field: Hashable & Sendable, Info: Sendable & Equatable>: Sendable {
    public enum Result: String, Codable, Sendable, Equatable {
        /// Every character was taken with the accept keys (some may have been typed along first).
        case acceptedFull
        /// Some was taken with the accept keys, then the user typed something else or left.
        case acceptedPartial
        /// The user typed the suggestion's own characters without accepting, then a new one replaced it.
        case typedAlong
        /// The user typed something that differs from the suggestion.
        case typedOver
        case dismissed
        /// Focus left the field (or Secure Input started) while it was showing.
        case left
        /// A new suggestion replaced it before the user typed anything into it.
        case replaced
    }

    public struct Record: Sendable, Equatable {
        public var info: Info
        public var suggestion: String
        public var result: Result
        /// Characters inserted with the accept keys.
        public var acceptedChars: Int
        /// Accept key presses (word or whole).
        public var accepts: Int
        /// Characters of the suggestion the user typed themselves while it showed.
        public var typedAlongChars: Int
        /// The taken text was edited within the settle interval. Nil when nothing was taken, or the
        /// taken text was never seen in the field (unknown).
        public var editedAfterAccept: Bool?
        /// From shown until it stopped showing.
        public var visibleSeconds: Double
    }

    private struct Episode: Sendable {
        var field: Field
        var info: Info
        /// Text before the caret when it was shown.
        var start: String
        var suggestion: String
        var shownAt: Date
        /// Characters of the suggestion now in the field (taken or typed along), in order.
        var consumed = 0
        var acceptedChars = 0
        var accepts = 0
        var typedAlongChars = 0
        var result: Result?
        var endedAt: Date?
        // After a take: watched until `settleAt`.
        var settleAt: Date?
        var seenInField = false
        var edited = false

        var takenEnd: String { start + String(suggestion.prefix(consumed)) }
    }

    public let settleInterval: TimeInterval
    private var visible: Episode?
    private var settling: [Episode] = []

    public init(settleInterval: TimeInterval = 10) {
        self.settleInterval = settleInterval
    }

    // MARK: Observations

    /// A suggestion became visible in `field` for the text `before`.
    public mutating func shown(field: Field, before: String, suggestion: String, info: Info,
                               at now: Date) -> [Record] {
        var out = sweep(now)
        if let v = visible {
            // The same text again (a republish, or a late copy): keep following the first one.
            if v.field == field, v.result == nil, v.start + v.suggestion == before + suggestion { return out }
            out += end(v.typedAlongChars > 0 ? .typedAlong : .replaced, at: now)
        }
        guard !suggestion.isEmpty else { return out }
        visible = Episode(field: field, info: info, start: before, suggestion: suggestion, shownAt: now)
        return out
    }

    /// An accept key inserted `text` (the next part of the visible suggestion).
    public mutating func accepted(field: Field, text: String, at now: Date) -> [Record] {
        var out = sweep(now)
        guard var v = visible, v.field == field, !text.isEmpty else { return out }
        let rest = String(v.suggestion.dropFirst(v.consumed))
        let taken = rest.hasPrefix(text) ? text.count : min(text.count, rest.count)
        v.consumed += taken
        v.acceptedChars += taken
        v.accepts += 1
        visible = v
        if v.consumed >= v.suggestion.count { out += end(.acceptedFull, at: now) }
        return out
    }

    /// A read of the focused field's text before the caret.
    public mutating func textChanged(field: Field, before: String, at now: Date) -> [Record] {
        var out = sweep(now)
        out += watchTaken(field: field, before: before, at: now)
        guard var v = visible, v.field == field else { return out }
        // The taken text is in this read (the watch after the take can start from here).
        if v.acceptedChars > 0, Self.remainder(of: before, after: v.takenEnd) != nil {
            v.seenInField = true
            visible = v
        }
        guard let typed = Self.remainder(of: before, after: v.start) else {
            out += end(v.accepts > 0 ? .acceptedPartial : .typedOver, at: now)
            return out
        }
        if v.suggestion.hasPrefix(typed) {
            // Still on the suggestion: a lagging read (shorter) or the user typing along.
            if typed.count > v.consumed {
                v.typedAlongChars += typed.count - v.consumed
                v.consumed = typed.count
                visible = v
                if v.consumed >= v.suggestion.count {
                    out += end(v.accepts > 0 ? .acceptedFull : .typedAlong, at: now)
                }
            }
            return out
        }
        out += end(v.accepts > 0 ? .acceptedPartial : .typedOver, at: now)
        return out
    }

    public mutating func dismissed(field: Field, at now: Date) -> [Record] {
        var out = sweep(now)
        guard let v = visible, v.field == field else { return out }
        out += end(v.accepts > 0 ? .acceptedPartial : .dismissed, at: now)
        return out
    }

    /// Focus left the field, or Secure Input started: everything open is finished now.
    public mutating func focusEnded(at now: Date) -> [Record] {
        var out = sweep(now)
        if let v = visible { out += end(v.accepts > 0 ? .acceptedPartial : .left, at: now) }
        out += settling.map { finish($0) }
        settling = []
        return out
    }

    public mutating func tick(at now: Date) -> [Record] { sweep(now) }

    // MARK: Internals

    /// Ends the visible suggestion. Taken text goes on to the settle watch; the rest is final.
    private mutating func end(_ result: Result, at now: Date) -> [Record] {
        guard var v = visible else { return [] }
        visible = nil
        v.result = result
        v.endedAt = now
        guard v.acceptedChars > 0 else { return [finish(v)] }
        v.settleAt = now.addingTimeInterval(settleInterval)
        settling.append(v)
        return []
    }

    private mutating func watchTaken(field: Field, before: String, at now: Date) -> [Record] {
        var out: [Record] = []
        var kept: [Episode] = []
        for var e in settling {
            guard e.field == field else { kept.append(e); continue }
            let end = e.takenEnd
            if Self.remainder(of: before, after: end) != nil {
                e.seenInField = true
                kept.append(e)
            } else if e.seenInField {
                e.edited = true
                out.append(finish(e))
            } else {
                kept.append(e)   // the insert hasn't shown up in a read yet
            }
        }
        settling = kept
        return out
    }

    private mutating func sweep(_ now: Date) -> [Record] {
        var out: [Record] = []
        var kept: [Episode] = []
        for e in settling {
            if let at = e.settleAt, now >= at { out.append(finish(e)) } else { kept.append(e) }
        }
        settling = kept
        return out
    }

    private func finish(_ e: Episode) -> Record {
        let edited: Bool? = e.acceptedChars == 0 ? nil : (e.edited ? true : (e.seenInField ? false : nil))
        return Record(info: e.info, suggestion: e.suggestion, result: e.result ?? .left,
                      acceptedChars: e.acceptedChars, accepts: e.accepts, typedAlongChars: e.typedAlongChars,
                      editedAfterAccept: edited,
                      visibleSeconds: max(0, (e.endedAt ?? e.shownAt).timeIntervalSince(e.shownAt)))
    }

    /// Text typed after `earlier`, given a later read of the same field. Reads are a bounded window
    /// that can slide forward in long documents, so align on the last stretch of `earlier` when the
    /// whole of it is no longer a prefix. Nil when the user edited before that point.
    static func remainder(of later: String, after earlier: String) -> String? {
        if later.hasPrefix(earlier) { return String(later.dropFirst(earlier.count)) }
        let anchorLength = 48
        guard earlier.count > anchorLength, later.count >= anchorLength else { return nil }
        let tail = String(earlier.suffix(anchorLength))
        guard let hit = later.range(of: tail, options: .backwards) else { return nil }
        return String(later[hit.upperBound...])
    }
}
