import Foundation
import os

/// What the user's login shell knows: its PATH, aliases and functions, read by running the shell
/// once (`zsh -lic`, 3 s limit) and refreshed every 10 minutes; plus `zsh -n` syntax checks, which
/// parse a command without running it. The command is passed as an argument, never spliced into
/// a script. Thread-safe; call from a background task (both spawn a process).
public final class ShellEnvironment: @unchecked Sendable {
    struct Snapshot {
        var path: [String]
        var aliases: Set<String>
        var functions: Set<String>
        var at: Date
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var executableCache: [String: Bool] = [:]
    let shell: String

    public init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        self.shell = shell
    }

    /// A model-written command passes when every command word is known, zsh can parse the line,
    /// and it is not risky (`ShellCommandCheck.isRisky`).
    public func isValidSuggestion(_ command: String) -> Bool {
        let line = command.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.contains("\n"), !ShellCommandCheck.isRisky(line) else { return false }
        guard ShellCommandCheck.commandsKnown(line, isKnown: isKnownCommand) else { return false }
        return Self.parses(line)
    }

    /// An alias, a function, or an executable file (a path, or a name on the login shell's PATH).
    public func isKnownCommand(_ word: String) -> Bool {
        let env = current()
        if env.aliases.contains(word) || env.functions.contains(word) { return true }
        let expanded = word.hasPrefix("~/") ? NSHomeDirectory() + word.dropFirst() : word
        if expanded.contains("/") { return FileManager.default.isExecutableFile(atPath: expanded) }
        return lock.withLock {
            if let known = executableCache[word] { return known }
            let found = env.path.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + word) }
            executableCache[word] = found
            return found
        }
    }

    /// `zsh -n -c <command>`: exit status 0 when the line parses. Nothing is executed (NO_EXEC).
    static func parses(_ line: String) -> Bool {
        guard let result = run("/bin/zsh", ["-n", "-c", line], timeout: 1) else { return false }
        return result.status == 0
    }

    private func current() -> Snapshot {
        if let snapshot = lock.withLock({ snapshot }), Date().timeIntervalSince(snapshot.at) < 600 { return snapshot }
        let fresh = Self.load(shell: shell)
        lock.withLock {
            snapshot = fresh
            executableCache.removeAll()
        }
        return fresh
    }

    static let marker = "__HUNCH_SECTION__"

    /// Runs the login shell interactively once to read PATH, alias names and function names. When
    /// that fails, falls back to this process's PATH plus the usual Homebrew and system folders.
    static func load(shell: String) -> Snapshot {
        let fallbackPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let isZsh = shell.hasSuffix("zsh")
        let script = isZsh
            ? "print -r -- \(marker); print -r -- $PATH; print -r -- \(marker); print -rl -- ${(k)aliases}; print -r -- \(marker); print -rl -- ${(k)functions}"
            : "echo \(marker); echo \"$PATH\"; echo \(marker); compgen -a; echo \(marker); compgen -A function"
        guard let result = run(shell, ["-lic", script], timeout: 3), result.status == 0 else {
            return Snapshot(path: fallbackPath, aliases: [], functions: [], at: Date())
        }
        let sections = result.output.components(separatedBy: marker + "\n").dropFirst()
        func lines(_ i: Int) -> [String] {
            guard sections.count > i else { return [] }
            return sections[sections.startIndex + i].split(separator: "\n").map(String.init)
        }
        let path = (lines(0).first ?? "").split(separator: ":").map(String.init)
        return Snapshot(path: path.isEmpty ? fallbackPath : path + fallbackPath, aliases: Set(lines(1)),
                        functions: Set(lines(2)), at: Date())
    }

    /// Runs a program with no stdin, killing it after `timeout` seconds. Nil when it can't start
    /// or times out.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs so a full pipe can't block the child.
        let output = OSAllocatedUnfairLock(initialState: Data())
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            _ = readDone.wait(timeout: .now() + 0.5)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return (process.terminationStatus, String(decoding: output.withLock { $0 }, as: UTF8.self))
    }
}
