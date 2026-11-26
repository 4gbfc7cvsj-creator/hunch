// The `live` subcommand: real-use numbers from the app's live acceptance log
// (~/Library/Logs/Hunch/live-outcomes.jsonl, written while "Save typing samples and suggestion
// outcomes" is on). Groups by build and settings id (or app / surface), so a change can be judged
// on what the user really did, next to its replay numbers.
import Foundation

struct LiveLine: Decodable {
    var kind: String
    var at: String
    var build: String
    var config: String
    var model: String?
    var app: String?
    var site: String?
    var surface: String
    var result: String?
    var suggestion: String?
    var chars: Int?
    var acceptedChars: Int?
    var accepts: Int?
    var typedAlongChars: Int?
    var editedAfterAccept: Bool?
    var visibleMs: Double?
    var firstLogProb: Float?
    var latencyMs: Double?
    var sinceKeyMs: Double?
    var fixOutcome: String?
    var sent: Bool?
    var keys: Int?
}

/// Per-group totals for the report.
struct LiveStats {
    var shown = 0
    var results: [String: Int] = [:]
    var acceptedChars = 0
    var acceptedSuggestions = 0
    var keys = 0
    var regretKnown = 0
    var regret = 0
    /// Shown for under `glanceMs` and then typed past or replaced: likely never seen.
    var unseen = 0
    var latency: [Double] = []
    var visible: [Double] = []
    var fixes = 0
    var fixOutcomes: [String: Int] = [:]
    var fixesKeptSent = 0
    /// Acceptance by first-word confidence band: band label -> (shown, accepted).
    var bands: [String: (shown: Int, accepted: Int)] = [:]

    static let glanceMs = 300.0
    static let bandEdges: [Float] = [-0.5, -1.0, -1.5, -2.5]

    static func band(_ lp: Float?) -> String {
        guard let lp else { return "unknown" }
        for edge in bandEdges where lp >= edge { return "≥ \(edge)" }
        return "< \(bandEdges.last!)"
    }

    mutating func add(_ l: LiveLine) {
        switch l.kind {
        case "suggestion":
            shown += 1
            let result = l.result ?? "?"
            results[result, default: 0] += 1
            let took = result == "acceptedFull" || result == "acceptedPartial"
            if took {
                acceptedSuggestions += 1
                acceptedChars += l.acceptedChars ?? 0
            }
            if let edited = l.editedAfterAccept {
                regretKnown += 1
                if edited { regret += 1 }
            }
            if let v = l.visibleMs {
                visible.append(v)
                if v < Self.glanceMs, ["typedOver", "typedAlong", "replaced"].contains(result) { unseen += 1 }
            }
            if let ms = l.latencyMs { latency.append(ms) }
            let b = Self.band(l.firstLogProb)
            var cell = bands[b] ?? (0, 0)
            cell.shown += 1
            if took { cell.accepted += 1 }
            bands[b] = cell
        case "typing":
            keys += l.keys ?? 0
        case "fix":
            fixes += 1
            let outcome = l.fixOutcome ?? "?"
            fixOutcomes[outcome, default: 0] += 1
            if outcome == "kept", l.sent == true { fixesKeptSent += 1 }
        default:
            break
        }
    }
}

func runLiveCommand(_ args: [String]) -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--in", "--by", "--since", "--out"])
    let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Hunch/live-outcomes.jsonl").path
    let path = parsed.value("--in") ?? defaultPath
    let by = parsed.value("--by") ?? "build"
    guard parsed.positionals.isEmpty, ["build", "config", "app", "surface", "model"].contains(by) else {
        printErr("usage: hunch-eval live [--in live-outcomes.jsonl] [--by build|config|model|app|surface] "
                 + "[--since 2026-11-18] [--out report.md]")
        return ExitCode.usage
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        printErr("live: cannot read \(path) (turn on Settings → Privacy → Save typing samples and suggestion outcomes)")
        return ExitCode.failure
    }
    let since = parsed.value("--since").flatMap { ISO8601DateFormatter().date(from: $0 + "T00:00:00Z") }
    let iso = ISO8601DateFormatter()
    var groups: [String: LiveStats] = [:]
    var models: [String: Set<String>] = [:]
    var bad = 0
    for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard let line = try? JSONDecoder().decode(LiveLine.self, from: Data(raw.utf8)) else { bad += 1; continue }
        if let since, let at = iso.date(from: line.at), at < since { continue }
        let key: String = switch by {
        case "config": "\(line.build) · \(line.config)"
        case "model": line.model ?? "-"
        case "app": line.site.map { "\(line.app ?? "-") · \($0)" } ?? (line.app ?? "-")
        case "surface": line.surface
        default: line.build
        }
        groups[key, default: LiveStats()].add(line)
        if let m = line.model { models[key, default: []].insert(m) }
    }
    let report = liveReport(groups: groups, models: models, by: by, source: path, unreadable: bad)
    if let out = parsed.value("--out") {
        do { try report.write(toFile: out, atomically: true, encoding: .utf8) } catch {
            printErr("live: cannot write \(out): \(error)")
            return ExitCode.failure
        }
        printOut("wrote \(out)")
    } else {
        printOut(report)
    }
    return ExitCode.ok
}

func liveReport(groups: [String: LiveStats], models: [String: Set<String>], by: String, source: String,
                unreadable: Int) -> String {
    var md = "# Live outcomes by \(by)\n\nSource: `\(source)`"
    if unreadable > 0 { md += " (\(unreadable) unreadable lines skipped)" }
    md += "\n\n"
    let keys = groups.keys.sorted()
    md += "## Suggestions\n\n"
    md += "| \(by) | shown | accepted | full | chars accepted / 100 typed | chars per accept | regret | unseen (<300 ms) | typed over | typed along | dismissed | latency p50 / p90 | visible p50 |\n"
    md += "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
    for k in keys {
        let s = groups[k]!
        let full = s.results["acceptedFull"] ?? 0
        let per100 = s.keys == 0 ? "n/a" : String(format: "%.1f", 100 * Double(s.acceptedChars) / Double(s.keys))
        let perAccept = s.acceptedSuggestions == 0 ? "-" : String(format: "%.1f", Double(s.acceptedChars) / Double(s.acceptedSuggestions))
        md += "| \(mdEscape(k)) | \(s.shown) | \(fmtPct(s.acceptedSuggestions, s.shown)) | \(fmtPct(full, s.shown)) "
            + "| \(per100) | \(perAccept) | \(fmtPct(s.regret, s.regretKnown)) | \(fmtPct(s.unseen, s.shown)) "
            + "| \(fmtPct(s.results["typedOver"] ?? 0, s.shown)) | \(fmtPct(s.results["typedAlong"] ?? 0, s.shown)) "
            + "| \(fmtPct(s.results["dismissed"] ?? 0, s.shown)) "
            + "| \(fmtMs(percentile(s.latency, 0.5))) / \(fmtMs(percentile(s.latency, 0.9))) "
            + "| \(fmtMs(percentile(s.visible, 0.5))) |\n"
    }
    md += "\n- accepted: taken in full or in part with the accept keys; regret: the taken text was edited within 10 s "
        + "(of those whose text was seen in the field); unseen: gone within 300 ms because the user typed on.\n"
    md += "- chars accepted / 100 typed: characters inserted by accepts per 100 character keys typed in fields "
        + "with suggestions on (the live \"keystrokes saved\").\n"

    md += "\n## Acceptance by first-word confidence\n\n| \(by) | band | shown | accepted |\n|---|---|---|---|\n"
    let bandOrder = StatsBandOrder.labels
    for k in keys {
        let s = groups[k]!
        for b in bandOrder {
            guard let cell = s.bands[b] else { continue }
            md += "| \(mdEscape(k)) | \(b) | \(cell.shown) | \(fmtPct(cell.accepted, cell.shown)) |\n"
        }
    }

    md += "\n## Automatic fixes\n\n| \(by) | fixes | kept | undone | changed | kept and sent |\n|---|---|---|---|---|---|\n"
    for k in keys {
        let s = groups[k]!
        guard s.fixes > 0 else { continue }
        md += "| \(mdEscape(k)) | \(s.fixes) | \(fmtPct(s.fixOutcomes["kept"] ?? 0, s.fixes)) "
            + "| \(fmtPct(s.fixOutcomes["undone"] ?? 0, s.fixes)) | \(fmtPct(s.fixOutcomes["changed"] ?? 0, s.fixes)) "
            + "| \(s.fixesKeptSent) |\n"
    }
    md += "\n- undone: the typed word was back at the end of the message (Hunch's undo or Backspace); changed: "
        + "something else stood there. A wrong fix that was kept and sent is not visible here; label typing samples for that.\n"
    if by != "model" {
        let listed = keys.compactMap { k in models[k].map { "- \(k): \($0.sorted().joined(separator: ", "))" } }
        if !listed.isEmpty { md += "\n## Models\n\n" + listed.joined(separator: "\n") + "\n" }
    }
    return md
}

enum StatsBandOrder {
    static var labels: [String] {
        LiveStats.bandEdges.map { "≥ \($0)" } + ["< \(LiveStats.bandEdges.last!)", "unknown"]
    }
}
