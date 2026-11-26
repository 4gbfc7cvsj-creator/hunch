import Foundation

/// The diagnostic logs Debug logging saves, for Privacy & Data → Diagnostics → Saved logs: read
/// them entry by entry, delete single entries or whole logs. Each log is one JSON object per line.
public enum SavedLogKind: String, CaseIterable, Sendable, Identifiable {
    case evalCaptures, typingSamples, outcomes, dictations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .evalCaptures: "Eval captures"
        case .typingSamples: "Typing samples"
        case .outcomes: "Suggestion outcomes"
        case .dictations: "Dictations"
        }
    }

    /// Singular and plural noun for counts ("1 capture", "41 captures").
    public func count(_ n: Int) -> String {
        let (one, many) = switch self {
        case .evalCaptures: ("capture", "captures")
        case .typingSamples: ("sample", "samples")
        case .outcomes: ("outcome", "outcomes")
        case .dictations: ("dictation", "dictations")
        }
        return "\(n) \(n == 1 ? one : many)"
    }

    public var fileURL: URL {
        switch self {
        case .evalCaptures: DrawDebugLog.logDirectory.appendingPathComponent("eval-captures.jsonl")
        case .typingSamples: DrawDebugLog.logDirectory.appendingPathComponent("typing-samples.jsonl")
        case .outcomes: DrawDebugLog.logDirectory.appendingPathComponent("live-outcomes.jsonl")
        case .dictations:
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Hunch/dictation-test.log")
        }
    }
}

/// One saved entry: when, which app, a one-line preview and every field for the detail view.
public struct SavedLogEntry: Identifiable, Sendable, Equatable {
    public struct Field: Sendable, Equatable, Hashable {
        public let name: String
        public let value: String
    }

    /// Position in the file when it was read (unique within one read).
    public let id: Int
    /// The line as saved; deleting matches on it, so lines appended since the read are kept.
    public let line: String
    public let date: Date?
    public let app: String?
    public let preview: String
    public let fields: [Field]
}

/// A plain-text debug log (perf.log, prompt.log, alignment.log…): listed with its size only.
public struct DebugLogFile: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public var name: String { url.lastPathComponent }
}

public enum SavedLogs {
    // MARK: Reading

    /// Entries of `kind`, newest first. Lines that aren't JSON objects are skipped.
    public static func entries(_ kind: SavedLogKind, at url: URL? = nil) -> [SavedLogEntry] {
        guard let text = try? String(contentsOf: url ?? kind.fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.enumerated().compactMap { entry(kind, line: String($0.element), index: $0.offset) }.reversed()
    }

    /// How many entries `kind` holds (lines), or nil when there is no file.
    public static func count(_ kind: SavedLogKind, at url: URL? = nil) -> Int? {
        guard let data = try? Data(contentsOf: url ?? kind.fileURL) else { return nil }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }

    /// The plain-text logs in `directory` (every `.log` file), largest first.
    public static func debugLogFiles(in directory: URL = DrawDebugLog.logDirectory) -> [DebugLogFile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        return files.filter { $0.pathExtension == "log" }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return DebugLogFile(url: url, bytes: Int64(size))
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    /// Whether any saved log or debug log is on disk.
    public static func anySaved(debugDirectory: URL = DrawDebugLog.logDirectory) -> Bool {
        SavedLogKind.allCases.contains { (count($0) ?? 0) > 0 } || !debugLogFiles(in: debugDirectory).isEmpty
    }

    /// Parses one saved line; nil when it isn't a JSON object.
    public static func entry(_ kind: SavedLogKind, line: String, index: Int) -> SavedLogEntry? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let s = object[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        let date = (string("capturedAt") ?? string("at")).flatMap(parseDate)
        return SavedLogEntry(id: index, line: line, date: date, app: string("app"),
                             preview: oneLine(preview(kind, object, string)), fields: fields(kind, object))
    }

    private static func preview(_ kind: SavedLogKind, _ o: [String: Any], _ string: (String) -> String?) -> String {
        switch kind {
        case .evalCaptures:
            return string("text") ?? ""
        case .typingSamples:
            return string("final") ?? string("typed") ?? ""
        case .dictations:
            return string("cleaned") ?? string("raw") ?? string("outcome") ?? ""
        case .outcomes:
            switch string("kind") {
            case "suggestion":
                let result = string("result").map { " \u{2013} \($0)" } ?? ""
                return "Suggestion \u{201C}\(string("suggestion") ?? "")\u{201D}" + result
            case "fix":
                let outcome = string("fixOutcome").map { " \u{2013} \($0)" } ?? ""
                return "Fix \u{201C}\(string("from") ?? "")\u{201D} \u{2192} \u{201C}\(string("to") ?? "")\u{201D}" + outcome
            case "typing":
                let keys = (o["keys"] as? Int).map { "\($0) keys" } ?? ""
                return "Typing" + (keys.isEmpty ? "" : " \u{2013} \(keys)")
            case let other?:
                return other
            case nil:
                return ""
            }
        }
    }

    /// Every field, the telling ones first, for the detail view.
    private static func fields(_ kind: SavedLogKind, _ o: [String: Any]) -> [SavedLogEntry.Field] {
        let first: [String] = switch kind {
        case .evalCaptures: ["text", "prefix", "app", "domain", "windowTitle", "surface", "tags", "screen"]
        case .typingSamples: ["typed", "final", "fixes", "backspaced", "app", "surface", "verified"]
        case .outcomes: ["kind", "suggestion", "result", "from", "to", "fixOutcome", "app", "site", "surface"]
        case .dictations: ["raw", "cleaned", "outcome", "inserted", "language", "audioSeconds", "whisperMs", "cleanupMs"]
        }
        let skip: Set = ["capturedAt", "at", "id"]
        let order = first.filter { o[$0] != nil } + o.keys.filter { !first.contains($0) && !skip.contains($0) }.sorted()
        return order.map { key in
            SavedLogEntry.Field(name: label(key), value: describe(key, o[key] ?? NSNull()))
        }
    }

    private static func describe(_ key: String, _ value: Any) -> String {
        switch value {
        case is NSNull: return "\u{2013}"
        case let s as String: return s
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "yes" : "no") : n.stringValue
        case let a as [String]: return a.isEmpty ? "none" : a.joined(separator: ", ")
        case let a as [Any]:
            // Per-key timing in typing samples is long and holds no extra text.
            if key == "keys" { return "\(a.count) key presses" }
            if a.isEmpty { return "none" }
            let json = compactJSON(a)
            return json.count <= 2000 ? json : "\(a.count) items"
        default: return compactJSON(value)
        }
    }

    private static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// "windowTitle" → "Window title".
    static func label(_ key: String) -> String {
        var out = ""
        for c in key {
            if c.isUppercase, !out.isEmpty { out.append(" "); out.append(Character(c.lowercased())) } else { out.append(c) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 200 ? String(flat.prefix(200)) + "\u{2026}" : flat
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: Deleting

    /// Removes the entries whose saved line is in `lines`; the rest (including lines written since
    /// they were read) stay. An emptied log is deleted. Owner-only permissions are kept.
    public static func remove(lines: Set<String>, from kind: SavedLogKind, at url: URL? = nil) throws {
        let url = url ?? kind.fileURL
        guard !lines.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).filter { !lines.contains(String($0)) }
        if kept.isEmpty {
            try FileManager.default.removeItem(at: url)
            return
        }
        try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Deletes the whole log of `kind`.
    public static func removeAll(_ kind: SavedLogKind, at url: URL? = nil) throws {
        try removeFile(url ?? kind.fileURL)
    }

    /// Deletes a file if it is there.
    public static func removeFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
