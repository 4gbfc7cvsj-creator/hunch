import Foundation

/// Opt-in typing samples for the autocorrect eval: follows one field's text and Hunch's own
/// edits to it, so that when the message ends it can give back what was typed (Hunch's fixes
/// undone) next to what the field ended up with. Pure; the app decides whether and where to save.
public struct TypingSampleTracker<Field: Hashable & Sendable>: Sendable {
    public struct Sample: Sendable, Equatable, Codable {
        public struct Fix: Sendable, Equatable, Codable {
            public var from: String
            public var to: String
        }
        /// What was typed, Hunch's fixes undone (the user's own edits kept).
        public var typed: String
        /// What the field held at the end.
        public var final: String
        public var fixes: [Fix]
        /// Characters the user deleted with Backspace (their own corrections).
        public var backspaced: Int
        /// False when a fix could no longer be found where it was made (the text before it was
        /// edited), so `typed` may still contain it.
        public var verified: Bool
    }

    private struct OwnEdit: Sendable {
        var offset: Int
        var from: String
        var to: String
    }

    private struct Message: Sendable {
        var field: Field
        var start: String
        var last: String
        var edits: [OwnEdit] = []
        var backspaced = 0
    }

    /// What became of each automatic fix in a finished message (live acceptance log).
    public struct FixReport: Sendable, Equatable {
        public enum Outcome: String, Sendable, Equatable, Codable {
            /// The fix was still there at the end.
            case kept
            /// The typed word was back at the end (Hunch's undo, or the user's Backspace).
            case undone
            /// Something else stood there at the end (edited, or not found any more).
            case changed
        }
        public struct Fix: Sendable, Equatable {
            public var from: String
            public var to: String
            public var outcome: Outcome
        }
        public var fixes: [Fix]
        /// The message ended because the box was emptied or replaced (sent), not because focus left.
        public var sent: Bool
    }

    private var message: Message?
    private var report: FixReport?

    public init() {}

    /// The fix report of the message that the last `update` or `focusEnded` finished, once.
    public mutating func takeFixReport() -> FixReport? {
        defer { report = nil }
        return report
    }

    /// A read of the focused field. Returns the finished sample of the previous message when this
    /// read starts a new one (another field, or the box was emptied or replaced: sent).
    public mutating func update(field: Field, before: String) -> Sample? {
        guard var m = message, m.field == field else {
            report = fixReport(sent: false)
            let done = finish()
            message = Message(field: field, start: before, last: before)
            return done
        }
        let sent = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!before.hasPrefix(m.start) && before.count < m.last.count / 2)
        if sent {
            report = fixReport(sent: true)
            let done = finish()
            message = Message(field: field, start: before, last: before)
            return done
        }
        if before.count < m.last.count, m.last.hasPrefix(before) {
            m.backspaced += m.last.count - before.count
        }
        m.last = before
        message = m
        return nil
    }

    /// Hunch replaced `from` with `to` at the end of the text before the caret; `after` is that
    /// text afterwards (it ends with `to`).
    public mutating func ownEdit(field: Field, after: String, from: String, to: String) {
        guard var m = message, m.field == field, after.hasSuffix(to) else { return }
        m.edits.append(OwnEdit(offset: after.count - to.count, from: from, to: to))
        m.last = after
        message = m
    }

    /// Focus left the field: the message is over.
    public mutating func focusEnded() -> Sample? {
        report = fixReport(sent: false)
        let done = finish()
        message = nil
        return done
    }

    /// Each fix's fate, read off the final text. A later edit that swaps a fix straight back (same
    /// place, `to` back to `from`) is Hunch's own undo: that fix is undone and the undo itself is
    /// not a fix. Edits are checked newest first, each with the later ones taken back out, so an
    /// edit's offset still points at its own text.
    private func fixReport(sent: Bool) -> FixReport? {
        guard let m = message, !m.edits.isEmpty else { return nil }
        var undoneBy: [Int: Int] = [:]   // fix index -> the edit that put it back
        var isUndo = Set<Int>()
        for (j, e) in m.edits.enumerated() {
            if let i = m.edits.indices.last(where: { i in
                i < j && !isUndo.contains(i) && undoneBy[i] == nil && m.edits[i].offset == e.offset
                    && m.edits[i].to == e.from && m.edits[i].from == e.to
            }) {
                undoneBy[i] = j
                isUndo.insert(j)
            }
        }
        var text = Array(m.last)
        var outcomes: [Int: FixReport.Outcome] = [:]
        for (i, e) in m.edits.enumerated().reversed() {
            let to = Array(e.to), from = Array(e.from)
            let fits = e.offset >= 0 && e.offset + to.count <= text.count
                && Array(text[e.offset..<(e.offset + to.count)]) == to
            if !isUndo.contains(i) {
                if undoneBy[i] != nil {
                    outcomes[i] = .undone
                } else if fits {
                    outcomes[i] = .kept
                } else if e.offset >= 0, e.offset + from.count <= text.count,
                          Array(text[e.offset..<(e.offset + from.count)]) == from {
                    outcomes[i] = .undone
                } else {
                    outcomes[i] = .changed
                }
            }
            if fits { text.replaceSubrange(e.offset..<(e.offset + to.count), with: from) }
        }
        let fixes = m.edits.indices.compactMap { i in
            outcomes[i].map { FixReport.Fix(from: m.edits[i].from, to: m.edits[i].to, outcome: $0) }
        }
        return fixes.isEmpty ? nil : FixReport(fixes: fixes, sent: sent)
    }

    private func finish() -> Sample? {
        guard let m = message, m.last.hasPrefix(m.start) || !m.edits.isEmpty else { return nil }
        var text = Array(m.last)
        var verified = true
        for e in m.edits.reversed() {
            let to = Array(e.to)
            guard e.offset >= 0, e.offset + to.count <= text.count,
                  Array(text[e.offset..<(e.offset + to.count)]) == to else { verified = false; continue }
            text.replaceSubrange(e.offset..<(e.offset + to.count), with: Array(e.from))
        }
        let typedAll = String(text)
        let shared = m.last.hasPrefix(m.start) && typedAll.hasPrefix(m.start) ? m.start.count : 0
        return Sample(typed: String(typedAll.dropFirst(shared)), final: String(m.last.dropFirst(shared)),
                      fixes: m.edits.map { Sample.Fix(from: $0.from, to: $0.to) },
                      backspaced: m.backspaced, verified: verified)
    }
}
