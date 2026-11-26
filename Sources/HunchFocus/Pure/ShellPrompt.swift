import Foundation

/// What the user is typing at a shell prompt, and the screen lines above it.
public struct ShellPromptText: Equatable, Sendable {
    /// The prompt itself ("alex@mac Hunch %").
    public var prompt: String
    /// The command typed after the prompt so far (no trailing spaces trimmed: "git " stays).
    public var command: String
    /// Up to `ShellPromptParser.contextLines` screen lines above the prompt line, oldest first,
    /// trailing blank lines dropped.
    public var above: [String]
}

/// Finds a shell prompt (zsh `%`, bash `$`, root `#`, and the `❯` that common prompt themes end
/// with) on the caret's line. Only the end of the line counts: the caret must sit after the last
/// typed character, at least one character must be typed, and the command must fit on that line
/// (a wrapped command has no prompt on the caret's line and is skipped).
public enum ShellPromptParser {
    /// Prompt endings: the character, then a space.
    static let markers: [Character] = ["%", "$", "#", "\u{276F}"]
    /// Prompts longer than this are treated as output, not a prompt.
    static let maxPromptLength = 120
    public static let contextLines = 20

    public static func parse(screen: String, caretUTF16: Int) -> ShellPromptText? {
        let ns = screen as NSString
        let caret = min(max(0, caretUTF16), ns.length)
        let previousBreak = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let lineStart = previousBreak.location == NSNotFound ? 0 : previousBreak.location + 1
        let nextBreak = ns.range(of: "\n", options: [], range: NSRange(location: caret, length: ns.length - caret))
        let lineEnd = nextBreak.location == NSNotFound ? ns.length : nextBreak.location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let after = ns.substring(with: NSRange(location: caret, length: lineEnd - caret))
        // Mid-line editing is out of scope: nothing but spaces may follow the caret.
        guard after.allSatisfy({ $0 == " " || $0 == "\u{00A0}" }) else { return nil }
        guard let (prompt, command) = split(line: before) else { return nil }
        let lines = ns.substring(to: lineStart).components(separatedBy: "\n")
        var above = Array(lines.dropLast())   // the last piece is the empty tail
        while let last = above.last, last.trimmingCharacters(in: .whitespaces).isEmpty { above.removeLast() }
        return ShellPromptText(prompt: prompt, command: command, above: Array(above.suffix(contextLines)))
    }

    /// Splits a prompt line into the prompt (through its marker) and the typed command, or nil
    /// when the line has no prompt or nothing is typed yet.
    static func split(line: String) -> (prompt: String, command: String)? {
        let chars = Array(line)
        for i in chars.indices where markers.contains(chars[i]) {
            guard i + 1 < chars.count, chars[i + 1] == " " else { continue }
            let prompt = String(chars[...i])
            guard prompt.count <= maxPromptLength, looksLikePrompt(prompt) else { continue }
            var start = i + 1
            while start < chars.count, chars[start] == " " { start += 1 }
            let command = String(chars[start...])
            guard command.contains(where: { !$0.isWhitespace }) else { return nil }
            return (prompt, command)
        }
        return nil
    }

    /// The marker alone (`$ `, `❯ `) or text that ends in it without looking like a sentence:
    /// a `%`/`$`/`#` prompt is a short run of user, host and folder words.
    static func looksLikePrompt(_ prompt: String) -> Bool {
        guard let marker = prompt.last else { return false }
        let body = prompt.dropLast().trimmingCharacters(in: .whitespaces)
        if marker == "\u{276F}" { return true }
        if body.isEmpty { return true }
        // "50% done", "costs 5$": a number right before the marker is output, not a prompt.
        if let last = body.last, last.isNumber, prompt.dropLast().last != " " { return false }
        let words = body.split(separator: " ")
        return words.count <= 4
    }
}
