import Foundation

/// Pure math for selecting the text around a collapsed caret through `AXSelectedTextRange`, so a
/// paste replaces it in one step instead of one Backspace per character.
public enum CaretSelection {
    /// Why the host's text couldn't be selected; the caller then deletes with key presses.
    public enum Failure: String, Sendable, Error {
        case focusMoved = "focus moved or a gate blocked"
        case noRange = "no AXSelectedTextRange"
        case notCollapsed = "selection not collapsed"
        case outOfBounds = "range out of bounds"
        case setFailed = "setting the range failed"
        case notApplied = "host didn't apply the range"
        case unreadable = "selected text unreadable"
        case mismatch = "selected text differs"
        case timedOut = "AX thread didn't answer in time"
    }

    /// The range from `backward` UTF-16 units before the caret to `forward` after it, or nil when it
    /// would start before the field's start.
    public static func range(caret: Int, backward: Int, forward: Int) -> (location: Int, length: Int)? {
        guard caret >= 0, backward >= 0, forward >= 0, caret - backward >= 0 else { return nil }
        return (caret - backward, backward + forward)
    }

    /// Whether the text the host reports for the new selection is the text meant to be replaced.
    /// Hosts differ in line ends and non-breaking spaces, so those compare equal.
    public static func matches(_ read: String, expected: String) -> Bool {
        normalized(read) == normalized(expected)
    }

    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
