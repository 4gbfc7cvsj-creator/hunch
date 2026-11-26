import Foundation

/// Pure rules for model-written shell commands: which words must name real commands, and which
/// commands are too risky for the model to propose (`rm -rf`, `sudo`, force pushes, piping a
/// download into a shell). Commands from the user's own history are not checked here.
public enum ShellCommandCheck {
    /// zsh and bash builtins and reserved words that can start a command.
    static let builtins: Set<String> = [
        "cd", "echo", "export", "source", ".", "alias", "unalias", "set", "unset", "pushd", "popd", "dirs",
        "history", "fc", "exit", "logout", "which", "where", "whence", "type", "eval", "exec", "read", "printf",
        "print", "test", "[", "[[", "time", "jobs", "fg", "bg", "kill", "wait", "disown", "ulimit", "umask",
        "setopt", "unsetopt", "autoload", "bindkey", "builtin", "command", "declare", "local", "typeset",
        "readonly", "functions", "hash", "rehash", "true", "false", "trap", "shift", "return", "break",
        "continue", "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "function", "select", "repeat", "noglob", "nocorrect", "emulate", "zle", "zmodload", "getopts", "let",
        "enable", "disable", "suspend", "limit", "unlimit", "r", "!", "{", "}", "(", ")",
    ]

    /// Risky shapes, matched case-sensitively on the whole command.
    static let riskyPatterns: [NSRegularExpression] = [
        #"(^|[\s;&|(])sudo\s"#, #"(^|[\s;&|(])doas\s"#,
        #"(^|[\s;&|(])rm\s+(-[A-Za-z]*[rRf][A-Za-z]*\s+|--recursive\s+|--force\s+)"#,
        #"git\s+push\b.*(\s--force\b|\s-f\b|\s--force-with-lease\b|\s\+\S)"#,
        #"git\s+reset\s+--hard\b"#, #"git\s+clean\s+-[A-Za-z]*f"#, #"git\s+checkout\s+--\s+\."#,
        #"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|fi|da)?sh\b"#,
        #"(^|[\s;&|(])(dd|mkfs(\.\w+)?|fdisk|diskutil\s+(erase|partition|zero|secureErase)\w*)\b"#,
        #"(^|[\s;&|(])(shutdown|reboot|halt|killall)\b"#, #"kill\s+-9\s+-1\b"#,
        #"(chmod|chown)\s+-R\s"#, #">\s*/dev/(disk|sd|rdisk)"#, #":\(\)\s*\{"#,
        #"(^|[\s;&|(])(launchctl\s+(unload|remove|bootout)|csrutil|nvram|spctl)\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func isRisky(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return riskyPatterns.contains { $0.firstMatch(in: command, range: range) != nil }
    }

    /// The command word of every simple command in the line (after `|`, `||`, `&&`, `;`, `&`, and
    /// inside `( … )` and `$( … )`), skipping leading `VAR=value` assignments. Quoted text does not
    /// split words. Words that are not plain names (`./run.sh`, `~/bin/x`) are returned as written,
    /// without their quotes.
    public static func commandWords(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var atCommandStart = true
        var quote: Character?
        let chars = Array(line)
        func endWord() {
            defer { current = "" }
            guard !current.isEmpty, atCommandStart else { return }
            if let eq = current.firstIndex(of: "="), let first = current.first, first.isLetter || first == "_",
               current[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { return }   // FOO=bar cmd
            words.append(current.filter { $0 != "\"" && $0 != "'" })
            atCommandStart = false
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == q { quote = nil } else if c == "\\", q == "\"", i + 1 < chars.count { i += 1; current.append(chars[i]) }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                current.append(c)
            case "\\":
                current.append(c)
                if i + 1 < chars.count { i += 1; current.append(chars[i]) }
            case " ", "\t", "\n":
                endWord()
            case "&" where (i > 0 && "<>".contains(chars[i - 1])) || (i + 1 < chars.count && chars[i + 1] == ">"):
                current.append(c)   // a redirection: 2>&1, &>file
            case "|", "&", ";":
                endWord()
                atCommandStart = true
            case "(":
                if current == "$" { current = "" } else { endWord() }
                atCommandStart = true
            case ")":
                endWord()
            default:
                current.append(c)
            }
            i += 1
        }
        endWord()
        return words
    }

    /// True when every command word names a builtin, an alias, a function, or an executable.
    public static func commandsKnown(_ line: String, isKnown: (String) -> Bool) -> Bool {
        let words = commandWords(line)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { builtins.contains($0) || isKnown($0) }
    }
}
