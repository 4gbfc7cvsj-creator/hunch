import Foundation

/// Opt-in drawing trace, on only while `~/Library/Application Support/Hunch/debug-geometry`
/// exists (the same switch as the caret trace). Appends to `~/Library/Logs/Hunch/draw.log`.
/// Records sizes and positions only, never text.
public enum DrawDebugLog {
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hunch")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hunch/debug-geometry").path)
    }

    public static func note(_ text: String) {
        guard isEnabled else { return }
        let url = logDirectory.appendingPathComponent("draw.log")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let line = Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    public static func fmt(_ r: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", r.minX, r.minY, r.width, r.height)
    }
}
