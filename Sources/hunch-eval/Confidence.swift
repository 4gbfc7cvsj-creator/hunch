// Confidence recording for `replay` and `rate`: each suggestion's mean log-prob and per-token
// log-probs, written to `confidence.jsonl` next to the report, plus the decode switches for the
// confidence trim and floor.
import Foundation
import HunchCore
import HunchDecode
import Synchronization

/// The engine's search, keeping the last result so the eval can read the scores of the suggestion
/// it just got. Requests in the eval are awaited one at a time, so "last" is that request's.
final class RecordingSearch: BiasedCompletionSearching, Sendable {
    private let last = Mutex<ScoredCandidate?>(nil)

    func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                onPartial: (Candidate) -> Void) throws -> [Candidate] {
        try searchScored(in: session, requiredPrefix: requiredPrefix, config: config, bias: LearnedBias(),
                         onPartial: onPartial).map(\.candidate)
    }

    func searchScored(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                      bias: LearnedBias, onPartial: (Candidate) -> Void) throws -> [ScoredCandidate] {
        let found = try GreedyConstrainedSearch().searchScored(in: session, requiredPrefix: requiredPrefix,
                                                               config: config, bias: bias, onPartial: onPartial)
        last.withLock { $0 = found.first }
        return found
    }

    /// The best candidate of the last search, cleared on read (nil after a result-cache hit).
    func take() -> ScoredCandidate? { last.withLock { value in defer { value = nil }; return value } }
}

/// One suggestion's scores as the search produced them (before post-processing).
struct ConfidenceRecord: Codable, Sendable {
    struct Token: Codable, Sendable {
        /// The token's visible text (lossy where a token splits a character).
        var t: String
        var bytes: Int
        var lp: Float
    }
    /// The candidate text the search returned (after the confidence trim, if any).
    var raw: String
    /// The text before the trim cut it (nil when not trimmed).
    var untrimmed: String?
    var mean: Float
    var total: Float
    var stop: String
    /// Every visible token of the decoded path, also past a trim.
    var tokens: [Token]

    init(_ scored: ScoredCandidate) {
        let candidate = scored.candidate
        raw = candidate.text
        untrimmed = scored.untrimmedText
        mean = candidate.meanLogProb
        total = candidate.totalLogProb
        stop = candidate.stop.rawValue
        let bytes = Array((scored.untrimmedText ?? candidate.text).utf8)
        var offset = 0
        tokens = scored.spans.map { span in
            let lo = min(offset, bytes.count), hi = min(offset + span.byteCount, bytes.count)
            offset += span.byteCount
            return Token(t: String(decoding: bytes[lo..<hi], as: UTF8.self), bytes: span.byteCount, lp: span.logProb)
        }
    }
}

/// A line of `confidence.jsonl`.
struct ConfidenceLine: Codable {
    /// "probe" (a rating-page moment; `moment` is its item id on the page) or "event" (a replay suggestion).
    var kind: String
    var model: String
    var profile: String
    var caseID: String
    var moment: Int?
    var before: String
    /// What the app would show (nil: nothing shown).
    var shown: String?
    var confidence: ConfidenceRecord?
}

func confidenceJSONL(_ runs: [ReplayModelRun], probeProfile: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    var lines: [String] = []
    func add(_ line: ConfidenceLine) {
        if let data = try? encoder.encode(line) { lines.append(String(decoding: data, as: UTF8.self)) }
    }
    for run in runs {
        for (index, probe) in run.probes.enumerated() {
            add(ConfidenceLine(kind: "probe", model: run.model, profile: probeProfile, caseID: probe.caseID, moment: index,
                               before: probe.before, shown: probe.suggestion, confidence: probe.confidence))
        }
        for event in run.events {
            add(ConfidenceLine(kind: "event", model: run.model, profile: event.profile, caseID: event.caseID, moment: nil,
                               before: event.before, shown: event.suggestion, confidence: event.confidence))
        }
    }
    return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
}

/// `--trim on|off`, `--trim-drop <log-prob>`, `--trim-window <n>`, `--floor <mean log-prob>`:
/// overrides of the app's decode defaults for the confidence trim and floor.
/// `--fanout <k>`, `--scoring sum|mean`: the search's first-token fan-out and ranking rule.
/// `--first-floor <log-prob>|off`, `--midword-floor <mean log-prob>|off`: the split floor
/// (word-start first-token floor; mid-word floor, off = the plain `--floor` applies mid-word too).
struct ConfidenceOverrides {
    var trim: Bool?
    var trimDrop: Float?
    var trimWindow: Int?
    var floor: Float?
    var holdEnd: Bool?
    var holdTail: Float?
    var fanout: Int?
    var scoring: ScoringRule?
    /// Outer nil = no override; inner nil = off.
    var firstFloor: Float??
    var midWordFloor: Float??

    static let options: Set<String> = ["--trim", "--trim-drop", "--trim-window", "--floor", "--hold-end", "--hold-tail",
                                       "--fanout", "--scoring", "--first-floor", "--midword-floor"]
    static let usage = "[--trim on|off] [--trim-drop -3] [--trim-window 1] [--floor -2.5] [--hold-end on|off] [--hold-tail -1.4] "
        + "[--fanout 1] [--scoring sum|mean] [--first-floor -1.0|off] [--midword-floor -8|off]"

    init(_ parsed: ParsedArgs) throws {
        if let value = parsed.value("--trim") {
            guard value == "on" || value == "off" else { throw EvalError("--trim takes on or off") }
            trim = value == "on"
        }
        trimDrop = try parsed.value("--trim-drop").map { try Self.number($0, "--trim-drop") }
        trimWindow = try parsed.value("--trim-window").map { value in
            guard let n = Int(value), n >= 1 else { throw EvalError("--trim-window takes a whole number ≥ 1") }
            return n
        }
        floor = try parsed.value("--floor").map { try Self.number($0, "--floor") }
        if let value = parsed.value("--hold-end") {
            guard value == "on" || value == "off" else { throw EvalError("--hold-end takes on or off") }
            holdEnd = value == "on"
        }
        holdTail = try parsed.value("--hold-tail").map { try Self.number($0, "--hold-tail") }
        fanout = try parsed.value("--fanout").map { value in
            guard let n = Int(value), n >= 1 else { throw EvalError("--fanout takes a whole number ≥ 1") }
            return n
        }
        scoring = try parsed.value("--scoring").map { value in
            guard let rule = ScoringRule(rawValue: value) else { throw EvalError("--scoring takes sum or mean") }
            return rule
        }
        firstFloor = try parsed.value("--first-floor").map { $0 == "off" ? nil : try Self.number($0, "--first-floor") }
        midWordFloor = try parsed.value("--midword-floor").map { $0 == "off" ? nil : try Self.number($0, "--midword-floor") }
    }

    init() {}

    private static func number(_ text: String, _ flag: String) throws -> Float {
        guard let value = Float(text) else { throw EvalError("\(flag) takes a number") }
        return value
    }

    func apply(to decode: inout DecodeConfig) {
        if let trim { decode.trimEnabled = trim }
        if let trimDrop { decode.trimDropLogProb = trimDrop }
        if let trimWindow { decode.trimWindow = trimWindow }
        if let floor { decode.minMeanLogProb = floor }
        if let holdEnd { decode.holdEndBelowMinWords = holdEnd }
        if let holdTail { decode.holdTailMinLogProb = holdTail }
        if let fanout { decode.firstTokenFanout = fanout }
        if let scoring { decode.scoring = scoring }
        if let firstFloor { decode.wordStartMinFirstLogProb = firstFloor }
        if let midWordFloor { decode.midWordMinMeanLogProb = midWordFloor }
    }
}

// MARK: - trim-grid

/// `trim-grid`: the confidence trim (the app's own code) over recorded suggestions, for a grid of
/// drop thresholds and windows, so settings can be tuned against earlier judgments without the
/// model. Reads `confidence.jsonl` files written with `--trim off`; prints one JSON line per
/// recorded suggestion and setting: the kept text and its mean log-prob (`trimmed` false = unchanged).
func runTrimGridCommand(_ args: [String]) -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--drops", "--windows", "--min-words", "--in"])
    let drops = parsed.values("--drops").flatMap { $0.split(separator: ",") }.compactMap { Float($0) }
    let windows = parsed.values("--windows").flatMap { $0.split(separator: ",") }.compactMap { Int($0) }
    let minWords = parsed.value("--min-words").flatMap(Int.init) ?? 2
    let files = parsed.values("--in")
    guard !files.isEmpty, parsed.positionals.isEmpty, !drops.isEmpty, !windows.isEmpty else {
        printErr("usage: hunch-eval trim-grid --drops -2.5,-3 --windows 1,2 [--min-words 2] --in <confidence.jsonl>...")
        return ExitCode.usage
    }
    struct Out: Encodable {
        var file: String, kind: String, model: String, moment: Int?, caseID: String, before: String
        var drop: Float, window: Int, trimmed: Bool, text: String, mean: Float
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    for path in files {
        guard let data = FileManager.default.contents(atPath: path) else {
            printErr("trim-grid: cannot read \(path)")
            return ExitCode.failure
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let record = try? JSONDecoder().decode(ConfidenceLine.self, from: Data(line.utf8)),
                  let scores = record.confidence else { continue }
            let text = scores.untrimmed ?? scores.raw
            let spans = scores.tokens.map { TokenSpan(byteCount: $0.bytes, logProb: $0.lp) }
            for drop in drops {
                for window in windows {
                    let cut = ConfidenceTrim.trim(text: text, spans: spans, dropLogProb: drop, window: window,
                                                  minWords: minWords)
                    let out = Out(file: path, kind: record.kind, model: record.model, moment: record.moment,
                                  caseID: record.caseID, before: String(record.before.suffix(60)), drop: drop,
                                  window: window, trimmed: cut != nil, text: cut?.text ?? text,
                                  mean: cut?.meanLogProb ?? scores.mean)
                    if let encoded = try? encoder.encode(out) { printOut(String(decoding: encoded, as: UTF8.self)) }
                }
            }
        }
    }
    return ExitCode.ok
}
