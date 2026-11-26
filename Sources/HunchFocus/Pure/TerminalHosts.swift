import Foundation
import HunchCore
import HunchPolicy

/// How a terminal app exposes its text to Accessibility, and so how Hunch reads it.
public enum TerminalHostProfile: Sendable, Equatable {
    /// The focused element's value is the screen text (scrollback included): only an AI-agent
    /// prompt found in it by `TerminalPromptParser` counts as the field.
    case axScreen
    /// The input is a real Accessibility text field (Warp's editor): read like any other field,
    /// with the terminal surface.
    case axTextField
    /// The terminal draws its text without exposing it to Accessibility, so there is nothing to
    /// read and no suggestion can work there.
    case unsupported
}

/// Read strategy for every app in `Seeds.terminals`, which stays the one list of terminals.
public enum TerminalHosts {
    static let profiles: [String: TerminalHostProfile] = [
        "com.apple.Terminal": .axScreen,
        "com.googlecode.iterm2": .axScreen,
        "com.mitchellh.ghostty": .axScreen,
        "com.cmuxterm.app": .axScreen,
        "dev.warp.Warp-Stable": .axTextField,
        "net.kovidgoyal.kitty": .unsupported,
        "org.alacritty": .unsupported,
        "com.github.wez.wezterm": .unsupported,
    ]

    /// The terminal's profile, or nil when the app is not a known terminal.
    public static func profile(for bundleID: String) -> TerminalHostProfile? { profiles[bundleID] }

    /// Lines kept before and after the caret when a long screen is read in a window. Before is
    /// what an agent's input box and the agent signature above it need; after covers the box's
    /// closing border and a footer.
    static let windowLinesBefore = 60
    static let windowLinesAfter = 5
    /// Widest screen line planned for, in UTF-16 units.
    static let windowLineWidth = 300

    /// UTF-16 range to read around the caret when the screen (Terminal and iTerm2 include the
    /// scrollback) is longer than the window; nil to read the whole value.
    static func screenWindow(caretUTF16: Int, totalUTF16: Int) -> (location: Int, length: Int)? {
        // `fetchRange` reads four UTF-16 units per allowed character.
        let limits = ContextLimits(beforeChars: windowLinesBefore * windowLineWidth / 4,
                                   afterChars: windowLinesAfter * windowLineWidth / 4)
        let range = TextWindow.fetchRange(caretUTF16: caretUTF16, selectionUTF16: 0, totalUTF16: totalUTF16,
                                          limits: limits)
        return range.location == 0 && range.length >= totalUTF16 ? nil : range
    }

    /// Drops the cut first line of a window that starts mid-screen, so the parser never sees half
    /// a rule or border. Returns the text and the caret (`caretUTF16` is screen-absolute) in it.
    static func wholeLines(_ window: String, windowStart: Int, caretUTF16: Int) -> (text: String, caretUTF16: Int) {
        let local = caretUTF16 - windowStart
        guard windowStart > 0 else { return (window, local) }
        let ns = window as NSString
        let newline = ns.range(of: "\n")
        guard newline.location != NSNotFound, newline.location < local else { return (window, local) }
        let cut = newline.location + 1
        return (ns.substring(from: cut), local - cut)
    }
}
