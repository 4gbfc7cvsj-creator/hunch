import Foundation

/// Developer aid for writing terminal fixtures: with `HUNCH_DEBUG_TERMINAL_DUMP=<path>` in the
/// launch environment, every changed terminal screen Hunch reads is appended to that file as
/// one JSON line (bundle ID, caret, line number, window, and the screen text exactly as the host
/// reported it). Off unless the variable names an absolute path (or one under "~/"); never writes
/// anywhere else. The screen holds whatever the terminal shows, so the file is created readable
/// by its owner only. Confined to the AX thread, like `ContextReader`.
final class TerminalScreenDump {
    static let variable = "HUNCH_DEBUG_TERMINAL_DUMP"

    private struct Record: Encodable {
        let date: String
        let bundleID: String
        let caretUTF16: Int
        let caretLine: Int?
        let windowStart: Int
        let totalUTF16: Int?
        let screen: String
    }

    private let url: URL
    private var last: (bundleID: String, caret: Int, screen: String)?

    /// The dump the environment asks for, or nil (the default).
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalScreenDump? {
        guard let url = path(from: environment[variable]) else { return nil }
        return TerminalScreenDump(url: url)
    }

    /// The file a variable value names: absolute, or under the home folder with "~/".
    static func path(from value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        if value.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(value.dropFirst(2)))
        }
        return nil
    }

    init(url: URL) { self.url = url }

    func record(bundleID: String, screen: String, caretUTF16: Int, caretLine: Int?, windowStart: Int, totalUTF16: Int?) {
        // The tracker polls; skip a screen identical to the last one.
        if let last, last.bundleID == bundleID, last.caret == caretUTF16, last.screen == screen { return }
        last = (bundleID, caretUTF16, screen)
        let record = Record(date: ISO8601DateFormatter().string(from: Date()), bundleID: bundleID,
                            caretUTF16: caretUTF16, caretLine: caretLine, windowStart: windowStart,
                            totalUTF16: totalUTF16, screen: screen)
        guard var data = try? JSONEncoder().encode(record) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
