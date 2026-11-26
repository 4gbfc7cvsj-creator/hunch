import Foundation
import Testing
@testable import HunchFocus

@Suite struct ShellPromptTests {
    private func parse(_ screen: String) -> ShellPromptText? {
        ShellPromptParser.parse(screen: screen, caretUTF16: (screen as NSString).length)
    }

    @Test func defaultZshPrompt() {
        let screen = "Last login: Fri Oct 16 on ttys001\nalex@Alexs-MacBook-Pro Hunch % git st"
        let p = parse(screen)
        #expect(p?.prompt == "alex@Alexs-MacBook-Pro Hunch %")
        #expect(p?.command == "git st")
        #expect(p?.above == ["Last login: Fri Oct 16 on ttys001"])
    }

    @Test func bashRootAndThemePrompts() {
        #expect(parse("user@host:~/src$ ls -")?.command == "ls -")
        #expect(parse("root@box:/# apt up")?.command == "apt up")
        #expect(parse("~/src/app main \u{276F} npm run")?.command == "npm run")
        #expect(parse("$ echo hi")?.command == "echo hi")
        // A trailing space is part of what was typed.
        #expect(parse("me@mac ~ % git ")?.command == "git ")
    }

    @Test func nothingWithoutTypedTextOrPrompt() {
        #expect(parse("me@mac ~ % ") == nil)               // empty prompt
        #expect(parse("Compiling 50% done") == nil)        // output, no marker followed by text
        #expect(parse("Downloading: 50% complete") == nil) // number before the marker
        #expect(parse("just some output text") == nil)
        #expect(parse("> help me refactor") == nil)        // an agent prompt is not a shell prompt
    }

    @Test func caretMustBeAtLineEnd() {
        let screen = "me@mac ~ % git status"
        // Caret after "git": "status" follows it.
        #expect(ShellPromptParser.parse(screen: screen, caretUTF16: 14) == nil)
        // Trailing spaces after the caret are fine.
        let padded = "me@mac ~ % git   "
        #expect(ShellPromptParser.parse(screen: padded, caretUTF16: 14)?.command == "git")
    }

    @Test func keepsRecentLinesAboveOnly() {
        let output = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let p = parse(output + "\n\nme@mac ~ % make")
        #expect(p?.above.count == ShellPromptParser.contextLines)
        #expect(p?.above.last == "line 30")   // blank line before the prompt dropped
    }

    @Test func traditionalChineseCommandText() {
        #expect(parse("me@mac ~ % echo 台北")?.command == "echo 台北")
    }
}

@Suite struct TerminalModeExclusivityTests {
    /// The two modes read different things: in shell mode Claude Code's box is not a shell prompt,
    /// and in agent mode a shell prompt is not an agent prompt.
    @Test func eachParserIgnoresTheOtherModesPrompt() {
        let claudeBox = """
        ╭──────────────────────────────────────╮
        │ > fix the failing test               │
        ╰──────────────────────────────────────╯
        """
        let caret = (claudeBox as NSString).range(of: "test").upperBound
        #expect(ShellPromptParser.parse(screen: claudeBox, caretUTF16: caret) == nil)
        let shell = "me@mac Hunch % git st"
        #expect(TerminalPromptParser.parse(screen: shell, caretUTF16: (shell as NSString).length) == nil)
    }
}
