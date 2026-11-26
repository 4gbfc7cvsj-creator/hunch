import Foundation
import HunchCore
import HunchText

/// Opt-in typing samples (Settings → Privacy → Diagnostics, off by default): each message typed
/// in a prose field that had a misspelling, a Backspace or an autocorrect fix is saved as typed
/// (Hunch's fixes undone) and as it ended up, one JSON object per line in
/// ~/Library/Logs/Hunch/typing-samples.jsonl. Real fast typing for the autocorrect eval. Plain
/// text on this Mac only; nothing is sent anywhere.
@MainActor
final class TypingSampleLog {
    static var fileURL: URL { DrawDebugLog.logDirectory.appendingPathComponent("typing-samples.jsonl") }
    static let minimumCharacters = 20

    private struct Meta {
        var field: FieldID
        var app: String?
        var bundleID: String
        var surface: SurfaceKind
    }

    /// The keyboard monitor's kept key presses (set by the app delegate): turn keeping on or off,
    /// and take what was kept. Saved with a sample as per-key timing (`RecordedKey`), no extra text.
    static var recordKeys: (Bool) -> Void = { _ in }
    static var drainKeys: () -> [KeyStroke] = { [] }
    /// The live acceptance log (set by the suggestion coordinator): hears every finished message's
    /// automatic fixes, whether or not the message is saved as a sample.
    static var fixReport: (TypingSampleTracker<FieldID>.FixReport, _ app: String?, SurfaceKind) -> Void = { _, _, _ in }

    private let isEnabled: () -> Bool
    private let spellChecker: any SpellChecking
    private var tracker = TypingSampleTracker<FieldID>()
    private var meta: Meta?

    init(isEnabled: @escaping () -> Bool, spellChecker: any SpellChecking = SystemSpellChecker.cached()) {
        self.isEnabled = isEnabled
        self.spellChecker = spellChecker
    }

    /// Every read of the focused field, Hunch's own edits included.
    func noteContext(_ context: TextContext) {
        guard isEnabled(), !Self.skipped(context.metadata.surface) else {
            tracker = TypingSampleTracker()
            meta = nil
            Self.recordKeys(false)
            return
        }
        Self.recordKeys(true)
        let previous = meta
        if meta?.field != context.field {
            meta = Meta(field: context.field, app: context.app.localizedName, bundleID: context.app.bundleID,
                        surface: context.metadata.surface)
        }
        let sample = tracker.update(field: context.field, before: context.before)
        reportFixes(previous ?? meta)
        if let sample { save(sample, previous ?? meta) }
    }

    private func reportFixes(_ meta: Meta?) {
        guard let report = tracker.takeFixReport() else { return }
        Self.fixReport(report, meta?.bundleID, meta?.surface ?? .unknown)
    }

    /// Hunch replaced `from` with `to` right before the caret; `after` is the text before the
    /// caret afterwards.
    func ownEdit(field: FieldID, after: String, from: String, to: String) {
        guard isEnabled() else { return }
        tracker.ownEdit(field: field, after: after, from: from, to: to)
    }

    func focusEnded() {
        let sample = tracker.focusEnded()
        if isEnabled() { reportFixes(meta) }
        if let sample, isEnabled() { save(sample, meta) }
        meta = nil
        _ = Self.drainKeys()
    }

    /// Code and command lines are not prose: autocorrect stays out of them.
    private static func skipped(_ surface: SurfaceKind) -> Bool {
        [.code, .terminal, .shell].contains(surface)
    }

    private func save(_ sample: TypingSampleTracker<FieldID>.Sample, _ meta: Meta?) {
        // Keys since the last sample; the eval keeps the ones that typed `typed` (the end of them).
        let keys = Self.drainKeys()
        guard sample.typed.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumCharacters,
              !SecretSanitizer.containsSecret(sample.typed), !SecretSanitizer.containsSecret(sample.final),
              !sample.fixes.isEmpty || sample.backspaced > 0 || hasMisspelling(sample.typed)
        else { return }
        let record = Record(capturedAt: ISO8601DateFormatter().string(from: Date()), app: meta?.app,
                            surface: meta?.surface ?? .unknown, typed: sample.typed, final: sample.final,
                            fixes: sample.fixes, backspaced: sample.backspaced, verified: sample.verified,
                            keys: keys.isEmpty ? nil : RecordedKey.record(keys))
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        let url = Self.fileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// A lowercase word the spell checker flags, or letters run into digits or punctuation ("s3with").
    private func hasMisspelling(_ text: String) -> Bool {
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}"))
            guard token.contains(where: \.isLetter), !token.contains(where: \.isUppercase),
                  !token.contains("/"), !token.contains("@") else { continue }
            if token.contains(where: { $0.isNumber || $0 == ";" || $0 == "," }) { return true }
            let word = token.filter { $0.isLetter || $0 == "'" }
            if word.count >= 2, spellChecker.isMisspelled(word, languages: Locale.preferredLanguages) { return true }
        }
        return false
    }

    private struct Record: Encodable {
        var capturedAt: String
        var app: String?
        var surface: SurfaceKind
        var typed: String
        var final: String
        var fixes: [TypingSampleTracker<FieldID>.Sample.Fix]
        var backspaced: Int
        var verified: Bool
        var keys: [RecordedKey]?
    }
}
