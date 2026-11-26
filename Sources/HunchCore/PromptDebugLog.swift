import Foundation

/// Per-request prompt sizes, on while debug logging is on in Settings (the app sets `isEnabled`).
/// Appends to `~/Library/Logs/Hunch/prompt.log`. Records token counts and timings only, never
/// text.
public enum PromptDebugLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false

    public static var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// One line per request: total prompt tokens, tokens decoded and reused, prompt-processing
    /// and framing time, then each block's tokens in prompt order (blocks the budget dropped are
    /// absent).
    public static func line(promptTokens: Int, budget: Int, decoded: Int, reused: Int, syncMilliseconds: Double,
                            framingMilliseconds: Double, prewarm: Bool, blocks: [(label: String, tokens: Int)]) -> String {
        let parts = blocks.map { "\($0.label)=\($0.tokens)" }.joined(separator: " | ")
        return String(format: "%@tokens=%d/%d decoded=%d reused=%d syncMs=%.1f framingMs=%.1f blocks: ",
                      prewarm ? "prewarm " : "", promptTokens, budget, decoded, reused, syncMilliseconds,
                      framingMilliseconds) + parts
    }

    /// Appends one line to `file` in the Hunch log folder while debug logging is on. Also used
    /// for `perf.log` (request fates, decode cost, GPU busy %, memory: counts only).
    public static func note(_ text: String, file: String = "prompt.log") {
        guard isEnabled else { return }
        let url = DrawDebugLog.logDirectory.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: DrawDebugLog.logDirectory, withIntermediateDirectories: true)
        let entry = Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(entry)
                try? handle.close()
            } else {
                try? entry.write(to: url)
            }
        }
    }
}
