import Foundation

/// Opt-in eval capture (Settings → Privacy → Diagnostics, off by default). For each message typed
/// in an AI chat box or an email, saves the screen text the model saw near the start of the message
/// and what was typed, as one replay case per line in ~/Library/Logs/Hunch/eval-captures.jsonl.
/// `hunch-eval capture-cases` turns that file into a local replay set. Plain text on this Mac
/// only; nothing is sent anywhere.
@MainActor
public final class EvalCaptureRecorder {
    public static let surfaces: Set<SurfaceKind> = [.agentPrompt, .email]
    /// AI chat apps and sites, and webmail, that the app itself classes as `.unknown`: their
    /// messages are captured under the surface they would have in the replay set.
    static let aiChatApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
                                           "ai.elementlabs.lmstudio"]
    static let aiChatHosts: Set<String> = ["claude.ai", "chatgpt.com", "gemini.google.com"]
    static let mailHosts: Set<String> = ["mail.google.com", "outlook.live.com", "outlook.office.com"]

    /// The surface a message is captured under, or nil when it isn't an AI chat or email field.
    static func captureSurface(_ context: TextContext) -> SurfaceKind? {
        let surface = context.metadata.surface
        if surfaces.contains(surface) { return surface }
        guard surface == .unknown else { return nil }
        if aiChatApps.contains(context.app.bundleID) { return .agentPrompt }
        if let host = context.urlHost {
            if aiChatHosts.contains(host) { return .agentPrompt }
            if mailHosts.contains(host) { return .email }
        }
        return nil
    }
    public static let minimumTypedCharacters = 30

    private struct Message {
        var field: FieldID
        var surface: SurfaceKind
        var app: String?
        var domain: String?
        var windowTitle: String?
        var startBefore: String
        var lastBefore: String
        var screen: String?
    }

    private let isEnabled: () -> Bool
    private let fileURL: URL
    private var message: Message?

    /// Where captures are saved: ~/Library/Logs/Hunch/eval-captures.jsonl.
    public static var defaultFileURL: URL { DrawDebugLog.logDirectory.appendingPathComponent("eval-captures.jsonl") }

    /// How many captures the file holds (nil when there is no file).
    public static func savedCount(at url: URL = defaultFileURL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// Deletes every saved capture.
    public static func deleteSaved(at url: URL = defaultFileURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public init(isEnabled: @escaping () -> Bool, fileURL: URL = EvalCaptureRecorder.defaultFileURL) {
        self.isEnabled = isEnabled
        self.fileURL = fileURL
    }

    /// A gated context for the focused field (focus or a text change).
    public func noteContext(_ context: TextContext) {
        guard isEnabled() else { message = nil; return }
        if var current = message, current.field == context.field {
            let before = context.before
            // The box emptied or was replaced (message sent, draft cleared): the message is done.
            let sent = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (!before.hasPrefix(current.startBefore) && before.count < current.lastBefore.count / 2)
            if sent {
                finish()
                start(context)
            } else {
                current.lastBefore = before
                message = current
            }
            return
        }
        finish()
        start(context)
    }

    /// The screen text a request sent to the model; the first one in a message is kept.
    public func noteRequest(_ context: TextContext, screen: String?) {
        guard var current = message, current.field == context.field, current.screen == nil,
              let screen, !screen.isEmpty else { return }
        current.screen = screen
        message = current
    }

    public func focusEnded() {
        finish()
    }

    private func start(_ context: TextContext) {
        guard let surface = Self.captureSurface(context) else { message = nil; return }
        message = Message(field: context.field, surface: surface, app: context.app.localizedName,
                          domain: context.urlHost, windowTitle: context.windowTitle,
                          startBefore: context.before, lastBefore: context.before, screen: nil)
    }

    private func finish() {
        defer { message = nil }
        guard isEnabled(), let m = message, let screen = m.screen, m.lastBefore.hasPrefix(m.startBefore) else { return }
        let typed = String(m.lastBefore.dropFirst(m.startBefore.count))
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumTypedCharacters else { return }
        // A message with anything secret-looking (an API key, a password line) isn't saved at all:
        // learned history skips such sentences too, and the screen text was filtered already.
        guard ![typed, m.startBefore, m.windowTitle ?? ""].contains(where: { SecretSanitizer.containsSecret($0) })
        else { return }
        // Seconds alone repeat when two messages finish in the same second (sent, then focus lost).
        let id = "cap-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6).lowercased())"
        let record = Record(id: id, surface: m.surface, tags: ["capture"],
                            app: m.app, domain: m.domain, windowTitle: m.windowTitle, screen: screen,
                            prefix: m.startBefore.isEmpty ? nil : m.startBefore, text: typed,
                            capturedAt: ISO8601DateFormatter().string(from: Date()))
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Same keys as a replay case (`hunch-eval`'s `ReplayCase`), plus when it was captured.
    private struct Record: Encodable {
        var id: String
        var surface: SurfaceKind
        var tags: [String]
        var app: String?
        var domain: String?
        var windowTitle: String?
        var screen: String
        var prefix: String?
        var text: String
        var capturedAt: String
    }
}
