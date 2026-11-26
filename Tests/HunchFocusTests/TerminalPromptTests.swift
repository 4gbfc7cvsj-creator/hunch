import Foundation
import Testing
@testable import HunchFocus

// Screens modelled on Terminal.app's AXValue with Claude Code running: a 30-column rule, "❯" plus
// U+00A0, continuation lines indented by two spaces, trailing blanks trimmed.

private let rule = String(repeating: "─", count: 30)

/// Screen text and the caret offset where "|" stands (the "|" is removed).
private func screen(_ lines: [String]) -> (String, Int) {
    let joined = lines.joined(separator: "\n")
    let caret = (joined as NSString).range(of: "|").location
    return (joined.replacingOccurrences(of: "|", with: ""), caret)
}

@Test func agentPromptSingleLine() {
    let (text, caret) = screen(["⏺ Done.", "", rule, "❯\u{00A0}fix the failing|", rule, "  ? for shortcuts"])
    let p = TerminalPromptParser.parse(screen: text, caretUTF16: caret)
    #expect(p == AgentPromptText(before: "fix the failing", after: "", caretAtLineEnd: true))
}

@Test func agentPromptTypedLineBreak() {
    let (text, caret) = screen([rule, "❯\u{00A0}this is line one ", "  this is line two|", rule])
    let p = TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 2)
    #expect(p?.before == "this is line one\nthis is line two")
}

@Test func agentPromptSoftWrapJoinsWithSpace() {
    // "alpha bravo charlie delta echo" is 30 columns with the prefix: "echo" did not fit.
    let (text, caret) = screen([rule, "❯\u{00A0}alpha bravo charlie delta", "  echo fox|", rule])
    let p = TerminalPromptParser.parse(screen: text, caretUTF16: caret)
    #expect(p?.before == "alpha bravo charlie delta echo fox")
}

@Test func agentPromptTrailingSpacePastLineEnd() {
    // Terminal trims the typed space and reports the caret one past the line, which is the
    // start of the closing rule.
    let lines = [rule, "❯\u{00A0}hello there", rule]
    let text = lines.joined(separator: "\n")
    let caret = (lines[0] as NSString).length + 1 + (lines[1] as NSString).length + 1
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 1)?.before == "hello there ")
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "hello there ")
}

@Test func agentPromptMidLineAndLaterLines() {
    let (text, caret) = screen([rule, "❯\u{00A0}one |two", "  three", rule])
    let p = TerminalPromptParser.parse(screen: text, caretUTF16: caret)
    #expect(p == AgentPromptText(before: "one ", after: "two\nthree", caretAtLineEnd: false))
}

@Test func agentPromptIgnoresRedrawLeftoverSpaces() {
    let (text, caret) = screen([rule, "❯\u{00A0}draft|   ", rule])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "draft", after: "", caretAtLineEnd: true))
}

@Test func agentPromptEmptyBoxPlaceholderIsNotInput() {
    let (text, caret) = screen([rule, "❯\u{00A0}|Try \"refactor this\"", rule])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "", after: "", caretAtLineEnd: false))
}

@Test func agentPromptHandlesWideCharacters() {
    let (text, caret) = screen([rule, "❯\u{00A0}幫我修好這個 😀 測|", rule])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "幫我修好這個 😀 測")
}

@Test func shellPromptIsNotAnAgentPrompt() {
    let (text, caret) = screen(["Last login: Mon Oct 12 on console", "me@mac ~ % git sta|"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func promptWithoutRuleAboveIsRejected() {
    let (text, caret) = screen(["some output", "❯\u{00A0}text|", rule])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func promptWithoutClosingRuleIsRejected() {
    let (text, caret) = screen([rule, "❯\u{00A0}text|", "plain output"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func caretInsideMenuBelowBoxIsRejected() {
    // An option list ("❯ 1. Yes") without rules around it, as in permission questions.
    let (text, caret) = screen(["Do you want to proceed?", "❯ 1. Yes|", "  2. No", "", "Esc to cancel"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

// MARK: Other agents, panes and hosts
//
// Synthetic screens: no real AXValue dumps were available. They imitate the documented layouts of
// Gemini CLI 0.x (rounded input box, "> " prompt, one column of padding), Codex CLI 0.4x
// (Rust TUI: "›" composer above a "context left" footer), Aider 0.8x (banner, "─" rule, ">"
// prompt at the bottom) and tmux 3.x vertical splits ("│" border, status line), as Terminal
// (trailing blanks trimmed), iTerm2 (written spaces kept, NUL after a wide character, soft-wrapped
// rows joined) and Ghostty (assumed like Terminal, no line number) would report them.

/// A Gemini CLI box line `width` columns wide: "│ " + text + padding + " │" ("|" marks the caret
/// and takes no column).
private func gemini(_ text: String, width: Int = 40) -> String {
    let used = text.replacingOccurrences(of: "|", with: "").count
    return "│ " + text + String(repeating: " ", count: max(0, width - 4 - used)) + " │"
}

private func geminiTop(_ width: Int = 40) -> String { "╭" + String(repeating: "─", count: width - 2) + "╮" }
private func geminiBottom(_ width: Int = 40) -> String { "╰" + String(repeating: "─", count: width - 2) + "╯" }
private let geminiFooter = "~/src/hunch (main*)   no sandbox   gemini-2.5-pro (99% context left)"

@Test func geminiSingleLine() {
    let (text, caret) = screen(["Using: 1 GEMINI.md file", geminiTop(), gemini("> explain the parser|"), geminiBottom(),
                                geminiFooter])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "explain the parser", after: "", caretAtLineEnd: true))
}

@Test func geminiTypedLineBreakAndMidLineCaret() {
    let (text, caret) = screen([geminiTop(), gemini("> first line"), gemini("  second |line"), gemini("  third"),
                                geminiBottom()])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "first line\nsecond ", after: "line\nthird", caretAtLineEnd: false))
}

@Test func geminiSoftWrapJoinsWithSpace() {
    // The input area is 36 columns: "> alpha bravo charlie delta echo" (32) left no room for "foxtrot".
    let (text, caret) = screen([geminiTop(), gemini("> alpha bravo charlie delta echo"), gemini("  foxtrot golf|"),
                                geminiBottom()])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before
        == "alpha bravo charlie delta echo foxtrot golf")
}

@Test func geminiTypedTrailingSpaceStaysInsideTheBox() {
    // The right border keeps the line from being trimmed, so the typed space is on screen.
    let (text, caret) = screen([geminiTop(), gemini("> hello |"), geminiBottom()])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "hello ", after: "", caretAtLineEnd: true))
}

@Test func geminiEmptyBoxPlaceholderIsNotInput() {
    let (text, caret) = screen([geminiTop(), gemini("> |  Type your message or @path/to/file"), geminiBottom()])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "", after: "", caretAtLineEnd: false))
}

@Test func geminiCaretBelowTheBoxIsRejected() {
    let (text, caret) = screen([geminiTop(), gemini("> draft"), geminiBottom(), "~/src/hunch (main*)|"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func roundedQuestionBoxIsRejected() {
    // A permission question in a rounded box: the option line is not right under the top border.
    let (text, caret) = screen([geminiTop(), gemini("Allow execution of: 'swift build'?"), gemini("❯ 1. Yes|"),
                                gemini("  2. No"), geminiBottom()])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func roundedPickerWithItemsIsRejected() {
    // A fuzzy finder's query line in a rounded box, followed by its list (one item marked ">").
    let (text, caret) = screen([geminiTop(), gemini("> que|"), gemini("  3/120"), gemini("> query.swift"),
                                gemini("  queue.swift"), geminiBottom()])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

private let codexBanner = [
    "╭──────────────────────────────────────────────╮",
    "│ >_ OpenAI Codex (v0.46.0)                    │",
    "│                                              │",
    "│ model:     gpt-5-codex   /model to change    │",
    "│ directory: ~/src/hunch                   │",
    "╰──────────────────────────────────────────────╯",
    "",
    "  To get started, describe a task or try one of these commands:",
    "",
]
private let codexFooter = "  100% context left · ? for shortcuts"

@Test func codexComposer() {
    let (text, caret) = screen(codexBanner + ["› write a test for the pars|", "", codexFooter])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "write a test for the pars", after: "", caretAtLineEnd: true))
}

@Test func codexContinuationAndFooterRightBelow() {
    // No blank line before the footer: the footer still ends the input.
    let (text, caret) = screen(codexBanner + ["› first line", "  second |line", codexFooter])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "first line\nsecond ", after: "line", caretAtLineEnd: false))
}

@Test func codexFooterIdentifiesTheAgentWithoutBanner() {
    // The banner has scrolled away; the footer alone marks the prompt as Codex's.
    let (text, caret) = screen(["• Updated Sources/HunchFocus/Pure/TerminalPrompt.swift", "",
                                "› and the tests|", "", codexFooter])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "and the tests")
}

@Test func codexTrailingSpacePastLineEnd() {
    // Terminal: the typed space is trimmed and the caret reported at the start of the next line.
    let lines = codexBanner + ["› hello there", "", codexFooter]
    let text = lines.joined(separator: "\n")
    let row = lines.count - 3
    let caret = lines[...row].map { ($0 as NSString).length + 1 }.reduce(0, +)
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: row)?.before == "hello there ")
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "hello there ")
}

@Test func codexPopupBelowComposerIsRejected() {
    // A slash-command popup under the composer: the prompt is no longer at the bottom.
    let (text, caret) = screen(codexBanner + ["› /mo|", "", "  /model     choose what model to use",
                                              "  /mention   mention a file", "  /mcp       list MCP tools",
                                              "  /new       start a new chat", codexFooter])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func codexCaretOnFooterIsRejected() {
    let (text, caret) = screen(codexBanner + ["› draft", codexFooter.replacingOccurrences(of: "shortcuts", with: "short|cuts")])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

private let aiderRule = String(repeating: "─", count: 80)
private let aiderBanner = [
    "Aider v0.86.1",
    "Main model: anthropic/claude-sonnet-4-20250514 with diff edit format, infinite output",
    "Weak model: anthropic/claude-3-5-haiku-20241022",
    "Git repo: .git with 212 files",
    "Repo-map: using 4096 tokens, auto refresh",
]

@Test func aiderPromptWithFileList() {
    let (text, caret) = screen(aiderBanner + [aiderRule, "src/parser.py", "> add a docstring to parse_li|"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "add a docstring to parse_li", after: "", caretAtLineEnd: true))
}

@Test func aiderRuleRightAbovePromptIsNotAClosedBox() {
    let (text, caret) = screen(aiderBanner + [aiderRule, "> fix it|"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "fix it")
}

@Test func aiderAfterAReplyWithoutBanner() {
    // The banner has scrolled away; the token report after each reply marks the agent.
    let (text, caret) = screen(["> what does parse do?", "", "It splits the screen into lines and finds the box.", "",
                                "Tokens: 2.1k sent, 180 received. Cost: $0.01 message, $0.02 session.",
                                aiderRule, "> and the pane spl|"])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "and the pane spl")
}

@Test func aiderTrailingSpacePastLastLine() {
    // The prompt is the screen's last line: Terminal's "one past the line" is one past the text.
    let text = (aiderBanner + [aiderRule, "> hello"]).joined(separator: "\n")
    let caret = (text as NSString).length + 1
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "hello ")
}

@Test func plainShellPromptsNeverMatch() {
    // Product decision: no suggestions at a shell prompt, including zsh/bash's "> " continuation.
    let zsh = screen(["Last login: Mon Oct 12 on console", "me@mac ~ % echo \"hello", "> wor|"])
    #expect(TerminalPromptParser.parse(screen: zsh.0, caretUTF16: zsh.1) == nil)
    let bash = screen(["$ ls", "README.md  Sources  Tests", "$ git sta|"])
    #expect(TerminalPromptParser.parse(screen: bash.0, caretUTF16: bash.1) == nil)
    let custom = screen(["> ls", "README.md  Sources  Tests", "> git sta|"])
    #expect(TerminalPromptParser.parse(screen: custom.0, caretUTF16: custom.1) == nil)
    let starship = screen(["~/src/hunch on  main", "❯ git sta|"])
    #expect(TerminalPromptParser.parse(screen: starship.0, caretUTF16: starship.1) == nil)
}

@Test func barePromptAcrossBlankLineIsRejected() {
    // A bare prompt has no border to bound it: a blank line above the caret ends the input.
    let (text, caret) = screen(codexBanner + ["› earlier message", "", "  |", "", codexFooter])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

/// Two tmux panes side by side: `left` padded to `width` columns, the "│" border, then `right`,
/// trailing blanks trimmed as Terminal does, and tmux's status line ("|" takes no column).
private func tmux(_ left: [String], _ right: [String], width: Int = 40) -> [String] {
    let rows = max(left.count, right.count)
    var lines: [String] = []
    for i in 0..<rows {
        let l = i < left.count ? left[i] : ""
        let r = i < right.count ? right[i] : ""
        // CJK and emoji take two cells; everything else in these fixtures one.
        let used = l.replacingOccurrences(of: "|", with: "").reduce(0) { $0 + ($1.unicodeScalars.first!.value >= 0x2E80 ? 2 : 1) }
        lines.append(TerminalPromptParser.trimmedEnd(l + String(repeating: " ", count: max(0, width - used)) + "│" + r))
    }
    return lines + ["[0] 0:claude*                                  \"mac\" 12:00 15-Oct-26"]
}

private let paneRule = String(repeating: "─", count: 40)

@Test func tmuxCaretInLeftPane() {
    let (text, caret) = screen(tmux(["⏺ Done.", "", paneRule, "❯\u{00A0}refactor the reader|", paneRule, "  ? for shortcuts"],
                                    ["$ swift build", "Building for debugging...", "Build complete!", "$"]))
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "refactor the reader", after: "", caretAtLineEnd: true))
}

@Test func tmuxCaretInRightPane() {
    let (text, caret) = screen(tmux(["$ swift build", "Building for debugging...", "Build complete!", "$"],
                                    ["⏺ Done.", "", paneRule, "❯\u{00A0}one |two", "  three", paneRule]))
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "one ", after: "two\nthree", caretAtLineEnd: false))
}

@Test func tmuxRightPaneTrailingSpacePastLineEnd() {
    // The right pane's line is trimmed: Terminal reports the caret at the start of the next line.
    let lines = tmux(["$ ls", "README.md", "$", ""], [paneRule, "❯\u{00A0}hello there", paneRule, ""])
    let text = lines.joined(separator: "\n")
    let caret = (lines[0] as NSString).length + 1 + (lines[1] as NSString).length + 1
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 1)?.before == "hello there ")
}

@Test func tmuxShellPaneBesideAnAgentIsRejected() {
    let (text, caret) = screen(tmux([paneRule, "❯\u{00A0}draft", paneRule, "  ? for shortcuts"],
                                    ["$ ls", "README.md", "$ git sta|", ""]))
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret) == nil)
}

@Test func tmuxBorderFoundPastWideCharacters() {
    // Wide characters take two cells, so the border sits at different UTF-16 offsets per line.
    let (text, caret) = screen(tmux(["幫我修好這個測試", "😀 done", "$ ls", "$"],
                                    [paneRule, "❯\u{00A0}fix the build|", paneRule, ""]))
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "fix the build")
}

@Test func geminiBoxFillingATmuxPane() {
    // The box's right edge sits right beside the pane border; the edge is not a pane border.
    let (text, caret) = screen(tmux([geminiTop(), gemini("> long input line one"), gemini("  line two"),
                                      gemini("  line three|"), geminiBottom()],
                                     ["$ ls", "README.md", "$", "", ""]))
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before
        == "long input line one\nline two\nline three")
}

@Test func boxRightEdgeAloneIsNotAPaneBorder() {
    // A rounded box's right border with nothing to its right never splits the screen.
    let lines = [geminiTop(), gemini("> one"), gemini("  two"), gemini("  three"), gemini("  four|"), geminiBottom()]
    let (text, caret) = screen(lines)
    let rows = text.components(separatedBy: "\n")
    #expect(TerminalPanes.pane(lines: rows, row: 4, column: caret - rows[..<4].map { ($0 as NSString).length + 1 }.reduce(0, +)) == nil)
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "one\ntwo\nthree\nfour")
}

@Test func paneBorderMustRunThroughMostLines() {
    // "│" at column 10 on the caret's line but on only 3 of the 7 lines around it: not a split.
    let lines = ["left text │ right", "no border here", "nor here", "left text │ right", "plain", "plain",
                 "❯\u{00A0}abc     │ right"]
    #expect(TerminalPanes.pane(lines: lines, row: 6, column: 5) == nil)
    // On every line: a split, and the caret's pane is cut out.
    let split = ["left text │ right", "more left │ more", "and more  │ text", "❯\u{00A0}abc     │ right"]
    #expect(TerminalPanes.pane(lines: split, row: 3, column: 5)
        == TerminalPanes.Pane(lines: ["left text ", "more left ", "and more  ", "❯\u{00A0}abc     "], row: 3, column: 5))
}

@Test func iTermScrollbackLineNumberCountsWrappedRows() {
    // iTerm2 joins a soft-wrapped row to the next (no "\n") but counts both in
    // AXInsertionPointLineNumber, so the reported line is past the caret's text line.
    let long = String(repeating: "warning: unused variable ", count: 6)   // two rows on an 80-column screen
    let lines = ["$ swift build", long, "$ claude", "", rule, "❯ fix the warnings|", rule]
    let (text, caret) = screen(lines)
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 6)?.before == "fix the warnings")
    // A line number from the top of a longer scrollback than the text read (a windowed read).
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 1)?.before == "fix the warnings")
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 4_000)?.before == "fix the warnings")
}

@Test func iTermKeepsWrittenTrailingSpace() {
    // iTerm2 trims only cells never written: the typed space stays and the caret is after it.
    let (text, caret) = screen([rule, "❯ hello there |", rule])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: 1)
        == AgentPromptText(before: "hello there ", after: "", caretAtLineEnd: true))
}

@Test func iTermNulAfterWideCharacters() {
    let (text, caret) = screen([rule, "❯ 幫\u{0}我\u{0}修\u{0}|好\u{0}", rule])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)
        == AgentPromptText(before: "幫我修", after: "好", caretAtLineEnd: false))
}

@Test func ghosttyTrailingSpacePastLineEndWithoutLineNumber() {
    // Assumed like Terminal (trimmed lines) and without AXInsertionPointLineNumber.
    let lines = [rule, "❯ hello there", rule]
    let text = lines.joined(separator: "\n")
    let caret = (lines[0] as NSString).length + 1 + (lines[1] as NSString).length + 1
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret, caretLine: nil)?.before == "hello there ")
}

@Test func otherRuleStylesCloseABox() {
    let heavy = String(repeating: "━", count: 30)
    let double = String(repeating: "═", count: 30)
    let (text, caret) = screen([heavy, "> ask about this|", double])
    #expect(TerminalPromptParser.parse(screen: text, caretUTF16: caret)?.before == "ask about this")
}

@Test func windowedScrollbackKeepsTheBox() {
    // A long Terminal scrollback is read in a window around the caret; the cut first line goes.
    var lines = (0..<2_000).map { "build log line \($0) " + String(repeating: "x", count: 40) }
    lines += ["⏺ Done.", "", rule, "❯\u{00A0}summarize the log|", rule, "  ? for shortcuts"]
    let (text, caret) = screen(lines)
    let total = (text as NSString).length
    let range = try! #require(TerminalHosts.screenWindow(caretUTF16: caret, totalUTF16: total))
    #expect(range.location > 0)
    let windowed = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    let (window, local) = TerminalHosts.wholeLines(windowed, windowStart: range.location, caretUTF16: caret)
    #expect(window.hasPrefix("build log line "))
    #expect(window.components(separatedBy: "\n").count > TerminalHosts.windowLinesBefore)
    #expect(TerminalPromptParser.parse(screen: window, caretUTF16: local)
        == AgentPromptText(before: "summarize the log", after: "", caretAtLineEnd: true))
}
