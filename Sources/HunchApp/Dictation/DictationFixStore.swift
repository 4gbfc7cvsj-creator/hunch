import Foundation
import HunchCore

/// The fixes dictation learned from the user correcting dictated text (the learned words sheet in Personalization lists
/// them). Saved as JSON in Application Support; small, so it is read and written whole.
@MainActor
final class DictationFixStore {
    private let url: URL
    private(set) var fixes: [DictationFix] = []
    /// Called after every change (Settings refreshes its list).
    var onChange: (() -> Void)?

    static let capacity = 500

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? Self.decoder.decode([DictationFix].self, from: data) {
            fixes = saved
        }
    }

    /// Records a fix (again): counts up an existing one. Any rule that wrote `heard` now writes
    /// `written` instead, and the reverse rule (the user undoing an earlier fix) is dropped.
    func record(heard: String, written: String, appKey: String?, now: Date = Date()) {
        let key = DictationFix.key(heard)
        fixes.removeAll { DictationFix.key($0.heard) == DictationFix.key(written) && $0.written == heard }
        for i in fixes.indices where fixes[i].written == heard { fixes[i].written = written }
        if let i = fixes.firstIndex(where: { $0.id == key }) {
            fixes[i].written = written
            fixes[i].count += 1
            fixes[i].lastFixed = now
            fixes[i].enabled = true
            if let appKey { fixes[i].apps = [appKey] + fixes[i].apps.filter { $0 != appKey }.prefix(4) }
        } else {
            fixes.append(DictationFix(heard: heard, written: written, lastFixed: now, apps: appKey.map { [$0] } ?? []))
        }
        if fixes.count > Self.capacity {
            // Drop the least used, oldest first.
            fixes.sort { ($0.count, $0.lastFixed) > ($1.count, $1.lastFixed) }
            fixes.removeLast(fixes.count - Self.capacity)
        }
        save()
    }

    func remove(id: String) {
        fixes.removeAll { $0.id == id }
        save()
    }

    /// Takes back one recording of a fix (the pill's Undo): a fix made once is removed.
    func undo(heard: String) {
        guard let i = fixes.firstIndex(where: { $0.id == DictationFix.key(heard) }) else { return }
        if fixes[i].count > 1 { fixes[i].count -= 1 } else { fixes.remove(at: i) }
        save()
    }

    func update(_ fix: DictationFix) {
        guard let i = fixes.firstIndex(where: { $0.id == fix.id }) else { return }
        fixes[i] = fix
        save()
    }

    func removeAll() {
        fixes = []
        save()
    }

    /// Ranking for the spellings whisper and the cleanup get: fixed more often, more recently,
    /// and in this app first.
    func score(word: String, appKey: String?, now: Date = Date()) -> Float {
        let key = DictationFix.key(word)
        var best: Float = 0
        for fix in fixes where fix.enabled && DictationFix.key(fix.written).contains(key) {
            let days = Float(now.timeIntervalSince(fix.lastFixed) / 86_400)
            var s: Float = 4 + Float(min(fix.count, 5)) + max(0, 3 - days / 10)
            if let appKey, fix.apps.contains(appKey) { s += 1 }
            best = max(best, s)
        }
        return best
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(fixes).write(to: url, options: .atomic)
        } catch {
            NSLog("Hunch: couldn't save dictation fixes: \(error)")
        }
        onChange?()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
