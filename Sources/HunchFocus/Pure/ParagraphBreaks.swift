import Foundation

/// Chromium and Electron hosts (Claude, Slack, Discord, web pages) answer a text-marker read with the
/// paragraphs run together: "Task:" ⏎ "Do this" reads as "Task:Do this", list items included
/// ("Tasks:1. First"). The element's AXValue keeps the breaks ("Task:\nDo this"). Without them every
/// later step sees one line: a fix or a rewrite reaches back over the break, and retyping it (Backspace
/// at a paragraph's start joins it to the one above) puts the new line back onto the previous one.
/// This puts the breaks back from the value; the caret's own line decides a break right at the caret.
/// (Verified with a direct AX probe of a contenteditable in Claude desktop's Chromium, 2026-11-20.)
public enum ParagraphBreaks {
    /// Where the caret sits on its line, from the host's line range around the caret marker.
    public struct CaretLine: Sendable, Equatable {
        /// Nothing on the caret's line before it.
        public var atLineStart: Bool
        /// The caret's line is empty (a paragraph just opened with Return). Chromium's AXValue leaves
        /// an empty last paragraph out, so its break is only known from here.
        public var emptyLine: Bool
        public init(atLineStart: Bool, emptyLine: Bool) {
            self.atLineStart = atLineStart
            self.emptyLine = emptyLine
        }
    }

    /// `before`, `selected` and `after` (the marker read) with the line breaks `value` has and they
    /// lack. Nil when nothing changes, or when the value doesn't line up with the read (another
    /// field's text, a stale value): the read is then kept as it was.
    /// - Parameter caretLine: nil when the host gave no line range; a break at the caret then goes after it.
    public static func restore(before: String, selected: String, after: String, value: String,
                               caretLine: CaretLine?) -> (before: String, selected: String, after: String)? {
        let read = Array(before + selected + after)
        let full = Array(value)
        let caret = before.count, selectionEnd = before.count + selected.count
        // Positions in the read (as Characters) where a break goes, in order.
        var breaks: [(at: Int, char: Character)] = []
        var i = 0, j = 0
        while i < full.count {
            if j < read.count, full[i] == read[j] {
                i += 1; j += 1
            } else if full[i].isNewline {
                breaks.append((j, full[i])); i += 1
            } else if j < read.count, read[j].isNewline {
                j += 1  // a break the read has and the value doesn't: kept
            } else {
                i += 1  // text only the value has (list numbers in some hosts)
            }
        }
        while j < read.count, read[j].isNewline { j += 1 }
        guard j == read.count else { return nil }

        var b = "", s = "", a = ""
        var k = 0
        func add(_ c: Character, at position: Int, isBreak: Bool) {
            // A break right at the caret belongs before it only when the caret starts its line.
            if position < caret || (position == caret && isBreak && (caretLine?.atLineStart ?? false)) {
                b.append(c)
            } else if position < selectionEnd {
                s.append(c)
            } else {
                a.append(c)
            }
        }
        for (p, c) in read.enumerated() {
            while k < breaks.count, breaks[k].at == p { add(breaks[k].char, at: p, isBreak: true); k += 1 }
            add(c, at: p, isBreak: false)
        }
        while k < breaks.count { add(breaks[k].char, at: read.count, isBreak: true); k += 1 }
        // An empty paragraph the value left out: the caret is on a new line.
        if caretLine?.emptyLine == true, !b.isEmpty, b.last?.isNewline == false {
            b.append("\n")
        }
        guard b != before || s != selected || a != after else { return nil }
        return (b, s, a)
    }
}
