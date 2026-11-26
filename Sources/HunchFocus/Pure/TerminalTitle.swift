import Foundation

/// What a terminal window's title says is running in front, for `ShellCommandMode.automatic`.
public enum TerminalTitleKind: Equatable, Sendable {
    /// A shell waiting for a command (zsh, bash, fish): shell-command suggestions.
    case shell
    /// An AI agent CLI (Claude Code, Gemini CLI, Codex, Aider): agent-prompt suggestions.
    case agent
    /// Another interactive program (an editor, a pager, ssh, a REPL): no suggestions.
    case otherProgram
    /// Nothing recognizable (a folder name, the terminal's own name, no title): the screen decides.
    case unknown
}

/// Classifies terminal window titles. Terminal.app and iTerm put the foreground process in the
/// title ("alex — -zsh — 80×24", "vim ◂ -zsh", "Default (zsh)"); Ghostty and cmux show whatever
/// the shell or program sets, often only a folder. Claude Code sets its own title, led by "✳"
/// or a braille spinner while it works. An agent anywhere in the title wins, then another
/// program, then a shell: a shell name is often shown next to the program it runs.
public enum TerminalTitleClassifier {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "login"]
    static let agents: Set<String> = ["claude", "gemini", "codex", "aider", "opencode", "cursor-agent"]
    static let otherPrograms: Set<String> = [
        "vim", "nvim", "vi", "nano", "emacs", "hx", "helix", "micro", "less", "more", "man", "htop", "top", "btop",
        "ssh", "mosh", "telnet", "python", "python3", "ipython", "node", "irb", "ruby", "psql", "mysql", "sqlite3",
        "redis-cli", "mongosh", "lua", "ghci", "erl", "iex", "R", "julia", "swift", "lldb", "gdb",
    ]

    public static func classify(_ title: String?) -> TerminalTitleKind {
        guard let title, !title.isEmpty else { return .unknown }
        if let first = title.unicodeScalars.first(where: { !$0.properties.isWhitespace }),
           first.value == 0x2733 || (0x2800...0x28FF).contains(first.value) {
            return .agent
        }
        if title.range(of: "claude code", options: .caseInsensitive) != nil { return .agent }
        let words = self.words(title)
        if words.contains(where: agents.contains) { return .agent }
        if words.contains(where: otherPrograms.contains) { return .otherProgram }
        if words.contains(where: shells.contains) { return .shell }
        return .unknown
    }

    /// Program-name candidates: the title split on spaces and separators, a login shell's "-"
    /// dropped ("-zsh"), a path cut to its last part ("/bin/zsh"), lowercased except "R".
    static func words(_ title: String) -> [String] {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–◂▸|()[]{}:,;\"'"))
        return title.components(separatedBy: separators).compactMap { raw in
            var word = raw
            while word.hasPrefix("-") { word.removeFirst() }
            if let slash = word.lastIndex(of: "/") { word = String(word[word.index(after: slash)...]) }
            guard !word.isEmpty else { return nil }
            return word == "R" ? word : word.lowercased()
        }
    }
}
