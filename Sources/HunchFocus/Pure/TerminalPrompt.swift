import Foundation

/// The user's unsent input in an AI-agent prompt box drawn inside a terminal, split at the caret.
public struct AgentPromptText: Sendable, Equatable {
    public var before: String
    public var after: String
    /// Nothing but whitespace follows the caret on its screen line.
    public var caretAtLineEnd: Bool
    public init(before: String, after: String, caretAtLineEnd: Bool) {
        self.before = before
        self.after = after
        self.caretAtLineEnd = caretAtLineEnd
    }
}

/// Finds an AI-agent prompt around the caret in a terminal's screen text and returns only what
/// the user typed in it. Anything else on the screen (a shell prompt, the agent's output, menus)
/// yields nil.
///
/// Product decision: Hunch completes only inside AI-agent prompts, never at a bare shell
/// prompt (competitors do the same). A shell prompt has no box around it, and a bare ">" or "›"
/// prompt counts only while the screen also shows an agent's signature (`agentSignatures`), so
/// a plain zsh or bash prompt (PS2 is "> ") never matches.
///
/// Every shape starts the input with a prompt mark and a space and indents continuation lines by
/// two spaces:
/// - Ruled box (Claude Code): a full-width rule ("─", "━" or "═") above and below; the space
///   after "❯" is U+00A0 in Terminal.
/// - Rounded box (Gemini CLI): "╭─╮" above, "│ " … " │" around each line, "╰─╯" below.
/// - Bare prompt (Codex CLI "›", Aider ">"): no box; followed only by blank lines and a short
///   footer, with an agent signature somewhere on the screen.
///
/// A screen split into side-by-side panes (tmux) is first cut down to the caret's pane. Long
/// lines wrap at a word, drop that space and indent like a typed line break, so wraps are told
/// apart by width: a line whose next word would still have fit ended with a typed line break.
public enum TerminalPromptParser {
    /// Marks that open the input inside a box.
    static let promptMarks: Set<Character> = ["❯", ">", "›", "$"]
    /// Marks that open a bare prompt. "❯" and "$" are common shell prompts, so they never do.
    static let barePromptMarks: Set<Character> = [">", "›"]
    static let ruleCharacters: Set<Character> = ["─", "━", "═"]
    /// Columns Claude Code keeps free on the right of a wrapped line (measured: a line reaching
    /// width − 1 wrapped).
    static let wrapMargin = 2
    /// Most box lines searched above and below the caret.
    static let maxBoxLines = 80
    /// Most non-blank lines (an agent's footer) allowed below a bare prompt's input.
    static let maxFooterLines = 3

    /// Text only an agent CLI prints near a bare prompt: its banner, footer or per-reply report.
    /// One matching line on the screen makes a bare prompt an agent's; such a line also ends the
    /// input above it.
    struct AgentSignature: Sendable {
        let agent: String
        /// A line starting with one of these.
        let linePrefixes: [String]
        /// A line containing one of these.
        let fragments: [String]

        func matches(_ line: String) -> Bool {
            linePrefixes.contains { line.hasPrefix($0) } || fragments.contains { line.contains($0) }
        }
    }

    static let agentSignatures: [AgentSignature] = [
        // Banner ">_ OpenAI Codex (v…)", footer "100% context left · ? for shortcuts" or "⏎ send".
        AgentSignature(agent: "Codex CLI", linePrefixes: [],
                       fragments: [">_ OpenAI Codex", "% context left", "? for shortcuts", "⏎ send"]),
        // Banner "Aider v…" and "Main model: …"; "Tokens: … sent, … received." after each reply.
        AgentSignature(agent: "Aider", linePrefixes: ["Aider v", "Main model: ", "Tokens: "], fragments: []),
    ]

    /// How the input lines sit on the screen.
    enum Frame: Equatable {
        /// From the screen's (pane's) left edge: a ruled box or a bare prompt.
        case open
        /// Inside a rounded box whose left "│" is at this UTF-16 offset of each line.
        case rounded(left: Int)
    }

    /// A line's input area: its UTF-16 offset in the line and its text, which stops before a
    /// rounded box's right border.
    struct InputArea: Equatable {
        let offset: Int
        let text: String
    }

    /// - Parameters:
    ///   - screen: the terminal's screen text (lines separated by "\n"; Terminal trims trailing
    ///     blanks, iTerm2 keeps spaces that were written).
    ///   - caretUTF16: the caret as a UTF-16 offset into `screen`. Terminal reports a caret past a
    ///     line's trimmed end as one past that line, never further, so it may point into the
    ///     next line (or one past the end of the screen); `caretLine` resolves which.
    ///   - caretLine: the caret's line index when the host reports it (AXInsertionPointLineNumber).
    ///     Used only when the caret offset falls on that line: iTerm2 counts soft-wrapped rows,
    ///     and a windowed read shifts every line.
    public static func parse(screen: String, caretUTF16: Int, caretLine: Int? = nil) -> AgentPromptText? {
        let length = (screen as NSString).length
        guard caretUTF16 >= 0, caretUTF16 <= length + 1 else { return nil }
        // iTerm2 stands a NUL for the right half of a wide character: dropped, caret moved along.
        var screen = screen
        var caretUTF16 = caretUTF16
        if screen.contains("\u{0}") {
            caretUTF16 -= (screen as NSString).substring(to: min(caretUTF16, length)).utf16.filter { $0 == 0 }.count
            screen = screen.replacingOccurrences(of: "\u{0}", with: "")
        }
        let lines = screen.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }

        // The caret's line and column (UTF-16 within the line).
        var row: Int
        if let caretLine, caretLine >= 0, caretLine < lines.count, caretUTF16 >= starts[caretLine],
           caretUTF16 - starts[caretLine] <= (lines[caretLine] as NSString).length + 1 {
            row = caretLine
        } else {
            row = starts.lastIndex(where: { $0 <= caretUTF16 }) ?? 0
            // Column 0 is never inside the box: the caret is past the end of the line above.
            if row > 0, caretUTF16 == starts[row] { row -= 1 }
        }
        let column = caretUTF16 - starts[row]
        guard column <= (lines[row] as NSString).length + 1 else { return nil }

        if let pane = TerminalPanes.pane(lines: lines, row: row, column: column) {
            return parse(lines: pane.lines, row: pane.row, column: pane.column)
        }
        return parse(lines: lines, row: row, column: column)
    }

    /// The prompt around the caret at `row`/`column` (UTF-16 within the line) of `lines`.
    static func parse(lines: [String], row: Int, column: Int) -> AgentPromptText? {
        let frame: Frame = roundedLeft(lines[row]).map { .rounded(left: $0) } ?? .open
        guard let caretArea = inputArea(lines[row], frame: frame) else { return nil }
        let caretColumn = column - caretArea.offset
        // The caret is past the prompt mark (or continuation indent) and its space, and inside
        // a rounded box's border.
        guard caretColumn >= prefixUTF16(caretArea.text) else { return nil }
        if case .rounded = frame, caretColumn > (caretArea.text as NSString).length { return nil }

        // Prompt line: at or above the caret, with only continuation lines in between.
        var promptRow: Int?
        var crossedBlank = false
        var r = row
        while r >= 0, row - r <= maxBoxLines {
            guard let area = inputArea(lines[r], frame: frame) else { return nil }
            if isPromptLine(area.text) { promptRow = r; break }
            guard isContinuation(area.text) else { return nil }
            if trimmedEnd(area.text).isEmpty { crossedBlank = true }
            r -= 1
        }
        guard let top = promptRow else { return nil }

        // The frame's closing border (or a bare prompt's end) and the width lines wrap at.
        let bottom: Int
        let width: Int
        switch frame {
        case .rounded(let left):
            guard top > 0, let w = roundedBorderWidth(lines[top - 1], left: left, corners: ("╭", "╮")),
                  let b = closingRow(lines, after: row, frame: frame, isBorder: {
                      roundedBorderWidth($0, left: left, corners: ("╰", "╯")) != nil
                  }) else { return nil }
            width = w
            bottom = b
        case .open:
            if top > 0, let w = ruleWidth(lines[top - 1]),
               let b = closingRow(lines, after: row, frame: frame, isBorder: { ruleWidth($0) != nil }) {
                width = w
                bottom = b
            } else if let mark = lines[top].first, barePromptMarks.contains(mark), !crossedBlank,
                      !(top...row).contains(where: { isAgentSignature(lines[$0]) }),
                      let b = bareInputEnd(lines, after: row), lines.contains(where: isAgentSignature) {
                // No rule tells the width: the widest line on the screen is the best guess.
                width = lines.map { trimmedEnd($0).count }.max() ?? 0
                bottom = b
            } else {
                return nil
            }
        }
        let texts = (top..<bottom).map { inputArea(lines[$0], frame: frame)?.text ?? "" }
        func text(_ i: Int) -> String { texts[i - top] }

        // Each input line without its two-column prefix; the caret line split at the caret.
        func content(_ i: Int) -> String { String(text(i).dropFirst(2)) }
        let caretContentColumn = caretColumn - prefixUTF16(text(row))
        let caretContent = content(row) as NSString
        var caretBefore: String
        var caretAfter: String
        if caretContentColumn > caretContent.length {
            // Past the trimmed end: the user typed a space there.
            caretBefore = (caretContent as String) + " "
            caretAfter = ""
        } else {
            caretBefore = caretContent.substring(to: caretContentColumn)
            caretAfter = caretContent.substring(from: caretContentColumn)
        }

        var before = ""
        for i in top..<row {
            before += trimmedEnd(content(i)) + separator(after: text(i), next: i + 1 == row ? caretBefore : content(i + 1), width: width)
        }
        before += caretBefore

        let caretAtLineEnd = caretAfter.allSatisfy(\.isWhitespace)
        var after = caretAtLineEnd ? "" : trimmedEnd(caretAfter)
        for i in (row + 1)..<bottom {
            after += separator(after: text(i - 1), next: content(i), width: width) + trimmedEnd(content(i))
        }
        if before.isEmpty { after = "" }   // an empty box shows a dimmed placeholder, not input
        return AgentPromptText(before: before, after: after, caretAtLineEnd: caretAtLineEnd)
    }

    static func isPromptLine(_ line: String) -> Bool {
        let chars = Array(line.prefix(2))
        guard chars.count == 2 || (chars.count == 1 && promptMarks.contains(chars[0])) else { return false }
        return promptMarks.contains(chars[0]) && (chars.count == 1 || chars[1] == " " || chars[1] == "\u{00A0}")
    }

    static func isContinuation(_ line: String) -> Bool {
        line.isEmpty || line.hasPrefix("  ")
    }

    static func isAgentSignature(_ line: String) -> Bool {
        agentSignatures.contains { $0.matches(line) }
    }

    /// Row of the closing border below `row`, with only continuation lines in between, or nil.
    static func closingRow(_ lines: [String], after row: Int, frame: Frame, isBorder: (String) -> Bool) -> Int? {
        var bottom = row + 1
        while bottom < lines.count, bottom - row <= maxBoxLines, !isBorder(lines[bottom]) {
            guard let area = inputArea(lines[bottom], frame: frame), isContinuation(area.text) else { return nil }
            bottom += 1
        }
        return bottom < lines.count && isBorder(lines[bottom]) ? bottom : nil
    }

    /// End (exclusive) of a bare prompt's input below `row`: it stops at a blank line, a line that
    /// is not indented, or an agent's footer. Nil when more than a short footer follows (a menu
    /// or the agent's output: the prompt is not at the bottom of the screen).
    static func bareInputEnd(_ lines: [String], after row: Int) -> Int? {
        var end = row + 1
        while end < lines.count, end - row <= maxBoxLines, !trimmedEnd(lines[end]).isEmpty,
              lines[end].hasPrefix("  "), !isAgentSignature(lines[end]) {
            end += 1
        }
        let following = lines[end...].filter { !trimmedEnd($0).isEmpty }.count
        return following <= maxFooterLines ? end : nil
    }

    /// Columns of a full rule line, or nil when the line is not one.
    static func ruleWidth(_ line: String) -> Int? {
        let trimmed = trimmedEnd(line)
        guard trimmed.count >= 10, trimmed.allSatisfy({ ruleCharacters.contains($0) }) else { return nil }
        return trimmed.count
    }

    /// UTF-16 offset of a rounded box's left "│" when `line` is a box line ("│ " … "│" after
    /// leading spaces), else nil.
    static func roundedLeft(_ line: String) -> Int? {
        let ns = line as NSString
        var i = 0
        while i < ns.length, ns.character(at: i) == 0x20 { i += 1 }
        guard i < ns.length, ns.character(at: i) == verticalBar,
              inputArea(line, frame: .rounded(left: i)) != nil else { return nil }
        return i
    }

    /// Width of a rounded box's input area (between "│ " and " │") when `line` is its top or
    /// bottom border starting at `left` ("╭─…─╮" / "╰─…─╯"), else nil.
    static func roundedBorderWidth(_ line: String, left: Int, corners: (Character, Character)) -> Int? {
        let ns = line as NSString
        guard ns.length > left else { return nil }
        let border = trimmedEnd(ns.substring(from: left))
        guard border.count >= 6, border.first == corners.0, border.last == corners.1,
              border.dropFirst().dropLast().allSatisfy({ $0 == "─" }) else { return nil }
        return border.count - 4
    }

    static let verticalBar: unichar = 0x2502   // "│"

    static func inputArea(_ line: String, frame: Frame) -> InputArea? {
        switch frame {
        case .open:
            return InputArea(offset: 0, text: line)
        case .rounded(let left):
            let ns = line as NSString
            let right = (trimmedEnd(line) as NSString).length - 1
            guard left >= 0, left + 1 < right, ns.character(at: left) == verticalBar,
                  ns.character(at: right) == verticalBar, ns.character(at: left + 1) == 0x20 else { return nil }
            return InputArea(offset: left + 2, text: ns.substring(with: NSRange(location: left + 2, length: right - left - 2)))
        }
    }

    static func prefixUTF16(_ line: String) -> Int {
        (String(line.prefix(2)) as NSString).length
    }

    static func trimmedEnd(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }

    /// " " when `line` was wrapped (the next word would not have fit), else "\n".
    static func separator(after line: String, next: String, width: Int) -> String {
        let used = trimmedEnd(line).count
        let word = next.prefix(while: { !$0.isWhitespace }).count
        return used + 1 + word > width - wrapMargin ? " " : "\n"
    }
}

/// Cuts a screen split into side-by-side panes (tmux) down to the pane holding the caret, so the
/// prompt parser sees one pane as a whole screen.
///
/// A pane border is a column of "│" (or a junction where a horizontal border meets it) through
/// the caret's line that runs through at least 80 % of the lines around it and has text on
/// both sides. Columns are terminal cells, so wide characters count twice.
enum TerminalPanes {
    static let borderCharacters: Set<Character> = ["│", "├", "┤", "┼"]
    /// A column that runs into a corner is a box's edge, not a pane border.
    static let cornerCharacters: Set<Character> = ["╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"]
    /// Share of the lines in a split region that must show the border.
    static let minBorderShare = 0.8
    static let minPaneLines = 4
    /// Lines in a row without the border that end the split region.
    static let maxMissRun = 2
    /// Cells a border may sit off its column on one line (a wide character whose width is guessed
    /// differently from the terminal's) and still count.
    static let cellSlack = 1

    struct Pane: Equatable {
        let lines: [String]
        let row: Int
        /// The caret's UTF-16 column within `lines[row]`.
        let column: Int
    }

    struct Cell {
        let start: Int
        let width: Int
        let utf16: Int
        let character: Character
    }

    /// The caret's pane, or nil when the screen is not split around the caret.
    static func pane(lines: [String], row: Int, column: Int) -> Pane? {
        var cache: [Int: [Cell]] = [:]
        func cellsOf(_ r: Int) -> [Cell] {
            if let known = cache[r] { return known }
            let made = cells(lines[r])
            cache[r] = made
            return made
        }
        let caretCells = cellsOf(row)
        let caretCell = cellIndex(caretCells, utf16: column)
        let candidates = caretCells.filter { $0.start > 0 && $0.start != caretCell && borderCharacters.contains($0.character) }
        guard !candidates.isEmpty else { return nil }

        // The nearest border on each side of the caret, with the rows it runs through.
        var left: (cell: Int, rows: ClosedRange<Int>)?
        var right: (cell: Int, rows: ClosedRange<Int>)?
        for candidate in candidates {
            let c = candidate.start
            let isNearestLeft = c < caretCell && c > (left?.cell ?? -1)
            let isNearestRight = c > caretCell && c < (right?.cell ?? Int.max)
            guard isNearestLeft || isNearestRight, let rows = borderRegion(lines.count, row: row, cell: c, cellsOf: cellsOf)
            else { continue }
            if isNearestLeft { left = (c, rows) } else { right = (c, rows) }
        }
        guard left != nil || right != nil else { return nil }
        let leftBorder = left?.cell
        let rightBorder = right?.cell
        let first = max(left?.rows.lowerBound ?? 0, right?.rows.lowerBound ?? 0)
        let last = min(left?.rows.upperBound ?? Int.max, right?.rows.upperBound ?? Int.max)
        let region = first...last

        var paneLines: [String] = []
        var paneColumn = 0
        for r in region {
            let cs = cellsOf(r)
            let from = leftBorder.map { borderCell(cs, near: $0) + 1 } ?? 0
            let to = rightBorder.map { borderCell(cs, near: $0) } ?? Int.max
            let kept = cs.filter { $0.start >= from && $0.start < to }
            paneLines.append(String(kept.map(\.character)))
            if r == row {
                // Back to UTF-16 within the pane line; a caret past its end keeps the distance.
                var cell = from
                var utf16 = 0
                for c in kept where c.start < caretCell {
                    cell = c.start + c.width
                    utf16 += String(c.character).utf16.count
                }
                paneColumn = utf16 + max(0, caretCell - cell)
            }
        }
        return Pane(lines: paneLines, row: row - region.lowerBound, column: paneColumn)
    }

    /// Rows around `row` that show a border at `cell`, or nil when it is not a pane border.
    static func borderRegion(_ count: Int, row: Int, cell c: Int, cellsOf: (Int) -> [Cell]) -> ClosedRange<Int>? {
        enum Mark { case border, corner, miss }
        func mark(_ r: Int) -> Mark {
            let cs = cellsOf(r)
            if let exact = cs.first(where: { $0.start == c }) {
                if borderCharacters.contains(exact.character) { return .border }
                if cornerCharacters.contains(exact.character) { return .corner }
            }
            return cs.contains { abs($0.start - c) <= cellSlack && borderCharacters.contains($0.character) } ? .border : .miss
        }
        var top = row
        var bottom = row
        for step in [-1, 1] {
            var misses = 0
            var r = row + step
            while r >= 0, r < count {
                switch mark(r) {
                case .corner: return nil
                case .border:
                    if step < 0 { top = r } else { bottom = r }
                    misses = 0
                case .miss:
                    misses += 1
                }
                if misses > maxMissRun { break }
                r += step
            }
        }
        let rows = top...bottom
        let hits = rows.filter { mark($0) == .border }.count
        guard rows.count >= minPaneLines, Double(hits) >= minBorderShare * Double(rows.count) else { return nil }
        // Text on both sides somewhere, or there is nothing to split (a box's right edge).
        let left = rows.contains { r in cellsOf(r).contains { $0.start < c - cellSlack && !$0.character.isWhitespace } }
        let right = rows.contains { r in cellsOf(r).contains { $0.start > c + cellSlack && !$0.character.isWhitespace } }
        return left && right ? rows : nil
    }

    /// The border's cell on one line: at `cell`, or the nearest border character within the slack.
    static func borderCell(_ cs: [Cell], near cell: Int) -> Int {
        if cs.contains(where: { $0.start == cell && borderCharacters.contains($0.character) }) { return cell }
        let near = cs.filter { abs($0.start - cell) <= cellSlack && borderCharacters.contains($0.character) }
        return near.min { abs($0.start - cell) < abs($1.start - cell) }?.start ?? cell
    }

    /// Each character of `line` with its first cell, width in cells and UTF-16 offset.
    static func cells(_ line: String) -> [Cell] {
        var result: [Cell] = []
        var cell = 0
        var utf16 = 0
        for character in line {
            let width = cellWidth(character)
            result.append(Cell(start: cell, width: width, utf16: utf16, character: character))
            cell += width
            utf16 += String(character).utf16.count
        }
        return result
    }

    /// The cell a UTF-16 column falls on; past the line's end, one cell per unit.
    static func cellIndex(_ cs: [Cell], utf16 column: Int) -> Int {
        var end = 0
        var endUTF16 = 0
        for c in cs {
            if c.utf16 >= column { return c.start }
            end = c.start + c.width
            endUTF16 = c.utf16 + String(c.character).utf16.count
        }
        return end + max(0, column - endUTF16)
    }

    /// Terminal cells a character takes: two for East Asian wide and emoji, none for a lone
    /// combining mark.
    static func cellWidth(_ character: Character) -> Int {
        guard let first = character.unicodeScalars.first else { return 0 }
        let v = first.value
        switch first.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return 0
        default: break
        }
        if first.properties.isEmojiPresentation || character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
            return 2
        }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
