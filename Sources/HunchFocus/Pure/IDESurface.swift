import Foundation

/// What a text field inside a code editor is for. Decided from element metadata only.
public enum IDESurface: Sendable, Equatable {
    /// A source buffer (Monaco's editor textarea, Xcode's source editor).
    case codeBuffer
    /// Prose typed into the editor: the chat composer, the commit message box, find and replace,
    /// the command palette. Handled like any other text field.
    case proseInput
    /// The AI chat or composer box (Copilot chat, Cursor's composer). Prose like `proseInput`;
    /// Write for me writes prompts there.
    case aiChat
    /// The integrated terminal (xterm's hidden textarea): no text worth reading.
    case terminal
    /// Nothing recognized. Inside a code editor this is treated as a code buffer.
    case unknown
}

/// Tells code buffers, prose inputs and terminals apart inside a code editor, from the strings
/// the host puts on the focused element (`AXDescription` / `AXTitle`, `AXPlaceholderValue`,
/// `AXRoleDescription`). Every signal is a case-insensitive substring in one table, so the table
/// can be corrected from real accessibility dumps without touching the logic.
///
/// The Monaco signals come from VS Code's sources (`textAreaHandler.ts`, `chatWidget.ts`,
/// `scmViewPane.ts`, xterm.js) and are the same in Cursor and VS Code Insiders; the Xcode
/// signals are assumed, not measured. See docs/features/ide-support.md.
public enum IDESurfaceClassifier {
    /// A signal: a surface and the lowercased substrings that mark it.
    public struct Signal: Sendable, Equatable {
        public var surface: IDESurface
        public var substrings: [String]
    }

    /// Matched in order against the description (then the placeholder, then the role
    /// description): the first hit wins, so terminal and prose markers are listed before the
    /// generic editor marker.
    public static let signals: [Signal] = [
        // xterm.js: aria-label "Terminal input"; VS Code labels its terminals "Terminal 1, zsh".
        // Xcode's debug console (assumed).
        Signal(surface: .terminal, substrings: ["terminal", "console"]),
        // VS Code SCM input ("Source Control Input", placeholder "Message (⌘Enter to commit …)").
        Signal(surface: .proseInput, substrings: ["source control", "commit"]),
        // VS Code chat ("Chat Input", "Ask Copilot"), Cursor composer ("Plan, search, build
        // anything", "Ask anything"), Copilot/Cursor inline chat.
        Signal(surface: .aiChat, substrings: ["chat", "ask ", "plan, search", "composer", "message"]),
        // Find/replace widget and the command palette / quick open box.
        Signal(surface: .proseInput, substrings: ["find", "replace", "search", "command to run", "quick open",
                                                  "go to file", "filter"]),
        // Monaco's editor textarea: aria-label "Editor content" (with the accessibility hint
        // appended) or, with editor.accessibilitySupport off, "The editor is not accessible at
        // this time …"; aria-roledescription "editor". Xcode: "Source Editor" (assumed).
        Signal(surface: .codeBuffer, substrings: ["editor content", "editor is not accessible", "source editor"]),
    ]

    /// Role descriptions that mark a code buffer on their own (Monaco's `aria-roledescription`).
    static let codeRoleDescriptions: Set<String> = ["editor"]

    public static func classify(role: String?, description: String?, placeholder: String?,
                                roleDescription: String?) -> IDESurface {
        // Single-line fields are never source buffers: a hit decides, otherwise they are prose.
        let singleLine = role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox"
        for text in [description, placeholder] {
            guard let lowered = text?.lowercased(), !lowered.isEmpty else { continue }
            if let hit = signals.first(where: { $0.substrings.contains(where: lowered.contains) }) {
                return hit.surface
            }
        }
        if let rd = roleDescription?.lowercased() {
            if codeRoleDescriptions.contains(rd) { return .codeBuffer }
            if let hit = signals.first(where: { $0.substrings.contains(where: rd.contains) }) { return hit.surface }
        }
        return singleLine ? .proseInput : .unknown
    }
}

/// Line-end rule for code buffers. Editors auto-close brackets and quotes, so the caret usually
/// sits in front of `)`, `]`, `}` or a quote it never typed; a line whose remainder is only such
/// closers (plus `;` and whitespace) counts as ended, and the mid-line gate lets the suggestion through.
public enum CodeLineEnd {
    public static let closers: Set<Character> = [")", "]", "}", ">", "\"", "'", "`", ";"]

    /// True when nothing but closers and whitespace follows the caret on its line.
    public static func isEffectiveLineEnd(after: String) -> Bool {
        for c in after {
            if c.isNewline { return true }
            if c.isWhitespace || closers.contains(c) { continue }
            return false
        }
        return true
    }
}
