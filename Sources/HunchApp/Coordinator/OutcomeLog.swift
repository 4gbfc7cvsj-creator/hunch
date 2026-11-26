import CryptoKit
import Foundation
import HunchCore
import HunchText

/// Live acceptance log, on with "Save typing samples" (Settings → Privacy → Diagnostics, off by
/// default): one JSON line per shown suggestion saying what happened to it, one per automatic fix
/// (kept, undone, changed; sent or not), and one per field visit with the characters typed there.
/// Lines carry the suggestion's words and the fixed words, never the field's text. Written to
/// ~/Library/Logs/Hunch/live-outcomes.jsonl on this Mac only; lines older than 90 days are
/// dropped. `hunch-eval live` turns it into numbers per build and settings.
@MainActor
final class OutcomeLog {
    nonisolated static var fileURL: URL { DrawDebugLog.logDirectory.appendingPathComponent("live-outcomes.jsonl") }
    nonisolated static let keepDays: Double = 90

    /// What a suggestion line carries besides the outcome.
    struct Info: Sendable, Equatable {
        var at: Date
        var app: String
        var site: String?
        var surface: SurfaceKind
        var firstLogProb: Float?
        var meanLogProb: Float?
        var latencyMs: Double?
        /// From the last key press to the suggestion showing.
        var sinceKeyMs: Double?
        var late: Bool
    }

    private let isEnabled: () -> Bool
    private let settings: () -> HunchSettings
    private var tracker = SuggestionOutcomeTracker<FieldID, Info>()
    private var visit: (field: FieldID, app: String, site: String?, surface: SurfaceKind, keys: Int)?
    private var lastKeyAt: ContinuousClock.Instant?
    private var ticker: Task<Void, Never>?
    private var lastTrim = Date.distantPast
    private let queue = DispatchQueue(label: "Hunch.OutcomeLog", qos: .utility)

    init(isEnabled: @escaping () -> Bool, settings: @escaping () -> HunchSettings) {
        self.isEnabled = isEnabled
        self.settings = settings
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.tick()
            }
        }
    }

    // MARK: Observations (all from the suggestion coordinator, only where suggestions are on)

    func noteContext(_ context: TextContext) {
        guard isEnabled() else { return drop() }
        if visit?.field != context.field {
            flushVisit()
            write(tracker.focusEnded(at: Date()))
            visit = (context.field, context.app.bundleID, context.urlHost, context.metadata.surface, 0)
        }
        write(tracker.textChanged(field: context.field, before: context.before, at: Date()))
    }

    func keyDown(isCharacter: Bool) {
        lastKeyAt = .now
        guard isCharacter, visit != nil, isEnabled() else { return }
        visit?.keys += 1
    }

    func noteShown(context: TextContext, text: String, result: CompletionResult, late: Bool) {
        guard isEnabled(), visit?.field == context.field else { return }
        let scores = result.wordScores.map(\.logProb)
        let since = lastKeyAt.map { Self.ms(.now - $0) }
        let info = Info(at: Date(), app: context.app.bundleID, site: context.urlHost, surface: context.metadata.surface,
                        firstLogProb: scores.first, meanLogProb: scores.isEmpty ? nil : scores.reduce(0, +) / Float(scores.count),
                        latencyMs: Self.ms(result.timings.firstVisible ?? result.timings.total),
                        sinceKeyMs: since, late: late)
        write(tracker.shown(field: context.field, before: context.before, suggestion: text, info: info, at: Date()))
    }

    func noteAccepted(_ text: String) {
        guard isEnabled(), let field = visit?.field else { return }
        write(tracker.accepted(field: field, text: text, at: Date()))
    }

    func noteDismissed() {
        guard isEnabled(), let field = visit?.field else { return }
        write(tracker.dismissed(field: field, at: Date()))
    }

    /// Focus left, the field was blocked, or Secure Input started.
    func focusEnded() {
        guard isEnabled() else { return drop() }
        flushVisit()
        write(tracker.focusEnded(at: Date()))
        visit = nil
    }

    /// A finished message's automatic fixes (from the typing-sample tracker).
    func noteFixes(_ report: TypingSampleTracker<FieldID>.FixReport, app: String?, surface: SurfaceKind) {
        guard isEnabled() else { return }
        let stamp = Self.stamp(settings())
        let now = Date()
        let lines = report.fixes.map { fix in
            let secret = SecretSanitizer.containsSecret(fix.from) || SecretSanitizer.containsSecret(fix.to)
            return Line(kind: "fix", at: Self.iso(now), build: stamp.build, config: stamp.config, model: stamp.model,
                        app: app, surface: surface, from: secret ? nil : fix.from, to: secret ? nil : fix.to,
                        fixOutcome: fix.outcome.rawValue, sent: report.sent)
        }
        append(lines)
    }

    private func tick() {
        guard isEnabled() else { return drop() }
        write(tracker.tick(at: Date()))
        if Date().timeIntervalSince(lastTrim) > 86_400 {
            lastTrim = Date()
            let url = Self.fileURL
            queue.async { Self.trim(url, olderThan: Date().addingTimeInterval(-Self.keepDays * 86_400)) }
        }
    }

    /// Logging was switched off: forget what is open without writing it.
    private func drop() {
        tracker = SuggestionOutcomeTracker()
        visit = nil
    }

    private func flushVisit() {
        guard let v = visit, v.keys > 0 else { return }
        let stamp = Self.stamp(settings())
        append([Line(kind: "typing", at: Self.iso(Date()), build: stamp.build, config: stamp.config, model: stamp.model,
                     app: v.app, site: v.site, surface: v.surface, keys: v.keys)])
        visit?.keys = 0
    }

    private func write(_ records: [SuggestionOutcomeTracker<FieldID, Info>.Record]) {
        guard !records.isEmpty else { return }
        let stamp = Self.stamp(settings())
        append(records.map { r in
            let text = SecretSanitizer.containsSecret(r.suggestion, surface: r.info.surface) ? nil : r.suggestion
            return Line(kind: "suggestion", at: Self.iso(r.info.at), build: stamp.build, config: stamp.config,
                        model: stamp.model, app: r.info.app, site: r.info.site, surface: r.info.surface,
                        result: r.result.rawValue, suggestion: text, chars: r.suggestion.count,
                        acceptedChars: r.acceptedChars, accepts: r.accepts, typedAlongChars: r.typedAlongChars,
                        editedAfterAccept: r.editedAfterAccept, visibleMs: (r.visibleSeconds * 1000).rounded(),
                        firstLogProb: r.info.firstLogProb, meanLogProb: r.info.meanLogProb,
                        latencyMs: r.info.latencyMs?.rounded(), sinceKeyMs: r.info.sinceKeyMs?.rounded(),
                        late: r.info.late ? true : nil)
        })
    }

    private func append(_ lines: [Line]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var buffer = Data()
        for line in lines {
            guard let json = try? encoder.encode(line) else { continue }
            buffer.append(json)
            buffer.append(0x0A)
        }
        guard !buffer.isEmpty else { return }
        let data = buffer
        let url = Self.fileURL
        queue.async { Self.appendData(data, to: url) }
    }

    // MARK: File

    nonisolated private static func appendData(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Drops lines stamped before `cutoff` (lines that can't be read are kept).
    nonisolated static func trim(_ url: URL, olderThan cutoff: Date) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let parser = ISO8601DateFormatter()
        let kept = lines.filter { line in
            guard let range = line.range(of: "\"at\":\""), let end = line[range.upperBound...].firstIndex(of: "\""),
                  let at = parser.date(from: String(line[range.upperBound..<end])) else { return true }
            return at >= cutoff
        }
        guard kept.count < lines.count else { return }
        let out = kept.map { $0 + "\n" }.joined()
        try? Data(out.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Build and settings stamp

    private struct Stamp { var build: String; var config: String; var model: String? }
    private static var cachedStamp: (settings: HunchSettings, stamp: Stamp)?

    /// The build is the app version plus when the running executable was built (every install has
    /// the same version number). The config id is a short hash of the settings that change what is
    /// suggested, so lines from the same setup group together.
    private static func stamp(_ s: HunchSettings) -> Stamp {
        if let c = cachedStamp, c.settings == s { return c.stamp }
        let key = ConfigKey(engine: s.engine.rawValue, model: s.activeModel?.relativePath, length: s.length.rawValue,
                            decode: s.decode, framerOverrides: s.framerOverrides, learning: s.learning.enabled,
                            learningStrength: s.learning.strength, styleExamples: s.learning.styleExamplesEnabled,
                            screenContext: s.screenContextEnabled, pauseMs: s.suggestionPauseMs,
                            minWords: s.minWordsBeforeSuggesting, customInstructions: !s.customInstructions.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: (try? encoder.encode(key)) ?? Data())
        let config = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let model = s.activeModel.map { ($0.relativePath as NSString).lastPathComponent }
        let stamp = Stamp(build: build, config: config, model: model)
        cachedStamp = (s, stamp)
        return stamp
    }

    private struct ConfigKey: Encodable {
        var engine: String
        var model: String?
        var length: String
        var decode: DecodeConfig
        var framerOverrides: [String: String]
        var learning: Bool
        var learningStrength: Float
        var styleExamples: Bool
        var screenContext: Bool
        var pauseMs: Int
        var minWords: Int
        var customInstructions: Bool
    }

    private static let build: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let path = Bundle.main.executablePath,
              let built = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return version }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "\(version)+\(f.string(from: built))"
    }()

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: Line

    /// One JSON line. Absent fields are left out.
    private struct Line: Encodable {
        var kind: String
        var at: String
        var build: String
        var config: String
        var model: String?
        var app: String?
        var site: String?
        var surface: SurfaceKind
        // suggestion
        var result: String?
        var suggestion: String?
        var chars: Int?
        var acceptedChars: Int?
        var accepts: Int?
        var typedAlongChars: Int?
        var editedAfterAccept: Bool?
        var visibleMs: Double?
        var firstLogProb: Float?
        var meanLogProb: Float?
        var latencyMs: Double?
        var sinceKeyMs: Double?
        var late: Bool?
        // fix
        var from: String?
        var to: String?
        var fixOutcome: String?
        var sent: Bool?
        // typing
        var keys: Int?
    }
}
