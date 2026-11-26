import Foundation
import HunchCore

/// The user's shell history, newest last, without duplicates (a repeated command keeps only its
/// newest place) and without any command that holds a secret (`SecretSanitizer`). Pure: parsing
/// and lookup only; `ShellHistoryFile` reads the file.
public struct ShellHistory: Sendable, Equatable {
    public private(set) var commands: [String]

    public init(commands: [String]) {
        var seen = Set<String>()
        var kept: [String] = []
        for command in commands.reversed() {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("\n"), !SecretSanitizer.containsSecret(trimmed),
                  seen.insert(trimmed).inserted else { continue }
            kept.append(trimmed)
        }
        self.commands = kept.reversed()
    }

    /// The rest of the newest command that starts with `typed` and is longer than it, or nil.
    /// `typed` must hold a non-space character; it is matched exactly (case and spacing).
    public func completion(for typed: String) -> String? {
        guard typed.contains(where: { !$0.isWhitespace }) else { return nil }
        for command in commands.reversed() where command.count > typed.count && command.hasPrefix(typed) {
            return String(command.dropFirst(typed.count))
        }
        return nil
    }

    /// The newest `count` commands, oldest first.
    public func recent(_ count: Int) -> [String] { Array(commands.suffix(count)) }

    // MARK: Parsing

    /// zsh history (`: 1697040000:0;git status` with EXTENDED_HISTORY, or plain lines), with
    /// zsh's byte metafication undone and backslash-continued lines joined.
    public static func parseZsh(_ data: Data) -> [String] {
        let text = String(decoding: unmetafy(data), as: UTF8.self)
        var out: [String] = []
        var pending: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if pending == nil, line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                line = String(line[line.index(after: semicolon)...])
            }
            if line.hasSuffix("\\") {
                pending = (pending.map { $0 + "\n" } ?? "") + String(line.dropLast())
                continue
            }
            let command = pending.map { $0 + "\n" + line } ?? line
            pending = nil
            if !command.isEmpty { out.append(command) }
        }
        return out
    }

    /// bash history: one command per line; `#1697040000` timestamp lines are skipped.
    public static func parseBash(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            if line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber) { return nil }
            return String(line)
        }
    }

    /// zsh writes bytes 0x83...0xA2 as 0x83 followed by the byte XOR 0x20.
    static func unmetafy(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var out = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta { out.append(byte ^ 0x20); meta = false } else if byte == 0x83 { meta = true } else { out.append(byte) }
        }
        return out
    }
}

/// Reads `~/.zsh_history` (or `$HISTFILE`-less bash's `~/.bash_history` when there is no zsh
/// history), re-reading only when the file changes. Thread-safe.
public final class ShellHistoryFile: @unchecked Sendable {
    private let lock = NSLock()
    private let paths: [(URL, zsh: Bool)]
    private var loaded: (modified: Date, history: ShellHistory)?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        paths = [(home.appendingPathComponent(".zsh_history"), true), (home.appendingPathComponent(".bash_history"), false)]
    }

    /// The current history; empty when no history file can be read.
    public func current() -> ShellHistory {
        guard let (url, zsh) = paths.first(where: { FileManager.default.isReadableFile(atPath: $0.0.path) }),
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return ShellHistory(commands: []) }
        return lock.withLock {
            if let loaded, loaded.modified == modified { return loaded.history }
            let data = (try? Data(contentsOf: url)) ?? Data()
            let history = ShellHistory(commands: zsh ? ShellHistory.parseZsh(data) : ShellHistory.parseBash(data))
            loaded = (modified, history)
            return history
        }
    }
}
