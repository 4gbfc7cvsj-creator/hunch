// The `styles` subcommand: do the suggestion styles (Casual, Formal, Concise, Detailed) show within
// one suggestion, and do they get watered down when layered on top of the app's own instructions?
// Each case runs with the app's category instructions alone (baseline), then per style twice:
// "layer" (the app's instructions plus the style) and "override" (the style alone). The style text
// sits in the same prompt slot both times, so only the layering differs.
// Writes styles.json, report.md and a blind rating page (rate.html).
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPolicy
import HunchPrompt

struct StyleCase: Codable, Sendable {
    var id: String
    var category: String
    var app: String
    var surface: SurfaceKind
    var before: String
}

struct StyleSample: Codable, Sendable {
    var caseID: String
    /// "baseline", or the style's id.
    var style: String
    /// "baseline", "layer" or "override".
    var mode: String
    var text: String
    /// Suppression reason when nothing was shown.
    var suppressed: String?
}

func runStylesCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--model", "--cases", "--out", "--styles"])
    guard let model = parsed.value("--model") else {
        printErr("usage: hunch-eval styles --model <file> [--cases eval/styles/cases.jsonl] "
            + "[--styles <styles.json>] [--out dir]")
        return ExitCode.usage
    }
    do {
        return try await executeStyles(model: model, casesPath: parsed.value("--cases") ?? "eval/styles/cases.jsonl",
                                       stylesPath: parsed.value("--styles"),
                                       outDir: parsed.value("--out") ?? "eval/reports/styles-\(timestampString())")
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
}

private func executeStyles(model: String, casesPath: String, stylesPath: String?, outDir: String) async throws -> Int32 {
    guard let data = FileManager.default.contents(atPath: casesPath), let text = String(data: data, encoding: .utf8) else {
        throw EvalError("cannot read cases at \(casesPath)")
    }
    let cases = try text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { try JSONDecoder().decode(StyleCase.self, from: Data($0.utf8)) }
    // A styles file (a JSON array of SuggestionStyle) tries other wordings; default: the built-ins.
    let styles: [SuggestionStyle] = try stylesPath.map { path in
        guard let d = FileManager.default.contents(atPath: path) else { throw EvalError("cannot read \(path)") }
        return try JSONDecoder().decode([SuggestionStyle].self, from: d)
    } ?? SuggestionStyle.builtIns

    let entry = makeEntry(path: model)
    guard entry.validity == .valid, entry.summary != nil else { throw EvalError("not a usable model: \(model)") }
    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    await host.load(entry, options: evalRuntimeOptions)
    guard case .ready = await host.state() else { throw EvalError("load failed for \(model)") }
    let engine = LocalCompletionEngine(host: host, registry: DefaultFramerRegistry(),
                                       postProcessor: makeEvalPostProcessor(typoCheck: true),
                                       framerOverride: nil, promptTokenBudget: 3584, confidenceFloor: nil)
    let counter = RequestCounter()

    var samples: [StyleSample] = []
    for c in cases {
        let preset = CategoryPresets.preset(named: c.category)
        let appLength = preset?.length ?? .medium
        func run(style: SuggestionStyle?, mode: String) async -> StyleSample {
            let length = style?.length ?? appLength
            // As the app builds a request (SuggestionCoordinator.makeRequest), with default decoding.
            var decode = DecodeConfig()
            decode.maxWords = length.maxWords
            decode.minWords = min(length.minWords, decode.maxWords)
            decode.maxTokens = max(decode.maxTokens, length.maxTokens)
            decode.holdEndBelowMinWords = length.holdsEnd
            decode.allowNewline = false
            var input = PromptInput(before: c.before, surface: c.surface,
                                    appInstructions: mode == "override" ? nil : preset?.customInstructions,
                                    preferredLanguages: ["en"], maxWords: decode.maxWords, allowNewlines: false,
                                    appName: c.app)
            input.styleInstructions = style?.instructions
            let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: c.app),
                                      field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                      before: c.before, after: "", contentSignature: 0)
            let request = CompletionRequest(id: counter.next(), context: context, input: input, decode: decode)
            var sample = StyleSample(caseID: c.id, style: style?.id ?? "baseline", mode: mode, text: "")
            guard let result = try? await engine.complete(request, partial: { _ in }) else {
                sample.suppressed = "error"
                return sample
            }
            switch result.outcome {
            case .show(let shown): sample.text = shown
            case .suppress(let reason): sample.suppressed = reason.rawValue
            }
            return sample
        }
        let base = await run(style: nil, mode: "baseline")
        samples.append(base)
        printErr("\(c.id) baseline: \(base.text)")
        for style in styles {
            for mode in ["layer", "override"] {
                let s = await run(style: style, mode: mode)
                samples.append(s)
                printErr("\(c.id) \(style.id)/\(mode): \(s.text)\(s.suppressed.map { " [\($0)]" } ?? "")")
            }
        }
    }
    await host.unload()

    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let payload = StylesPayload(model: entry.url.lastPathComponent, cases: cases,
                                styles: styles.map { .init(id: $0.id, name: $0.name, instructions: $0.instructions) },
                                samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try encoder.encode(payload)
    try json.write(to: URL(fileURLWithPath: outDir + "/styles.json"))
    try renderStylesReport(payload).write(toFile: outDir + "/report.md", atomically: true, encoding: .utf8)
    let template = try String(contentsOfFile: "eval/styles/rate-template.html", encoding: .utf8)
    let compact = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        .replacingOccurrences(of: "</", with: "<\\/")
    try template.replacingOccurrences(of: "__DATA__", with: compact)
        .write(toFile: outDir + "/rate.html", atomically: true, encoding: .utf8)
    printOut("report: \(outDir)/report.md\nrating page: \(outDir)/rate.html")
    return ExitCode.ok
}

struct StylesPayload: Codable {
    struct Style: Codable { var id: String; var name: String; var instructions: String }
    var model: String
    var cases: [StyleCase]
    var styles: [Style]
    var samples: [StyleSample]
}

/// Counts that hint at each style showing (no judgment of quality): words, contractions, slang,
/// lowercase starts, and how often layer and override gave the same text.
private func renderStylesReport(_ p: StylesPayload) -> String {
    let slang: Set<String> = ["gonna", "wanna", "kinda", "tbh", "lol", "idk", "ngl", "yeah", "yep", "nah", "gotta",
                              "lemme", "u", "ur", "btw", "omg", "haha", "cuz", "rn"]
    func words(_ t: String) -> [String] {
        t.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }.map(String.init)
    }
    var out = "# Suggestion styles: layer vs override\n\nModel: \(p.model). \(p.cases.count) cases.\n\n"
    out += "| style | mode | shown | avg words | contractions | slang | same as baseline | same as other mode |\n"
    out += "|---|---|---|---|---|---|---|---|\n"
    let byKey = Dictionary(grouping: p.samples) { "\($0.style)/\($0.mode)" }
    let baseline = Dictionary(uniqueKeysWithValues: (byKey["baseline/baseline"] ?? []).map { ($0.caseID, $0.text) })
    for style in [StylesPayload.Style(id: "baseline", name: "baseline", instructions: "")] + p.styles {
        for mode in style.id == "baseline" ? ["baseline"] : ["layer", "override"] {
            let rows = byKey["\(style.id)/\(mode)"] ?? []
            let shown = rows.filter { $0.suppressed == nil && !$0.text.isEmpty }
            let ws = shown.map { words($0.text) }
            let avg = ws.isEmpty ? 0 : Double(ws.map(\.count).reduce(0, +)) / Double(ws.count)
            let contractions = ws.flatMap { $0 }.filter { $0.contains("'") || $0.contains("\u{2019}") }.count
            let slangCount = ws.flatMap { $0 }.filter(slang.contains).count
            let same = rows.filter { baseline[$0.caseID] == $0.text }.count
            let other = mode == "layer" ? "override" : "layer"
            let otherText = Dictionary(uniqueKeysWithValues: (byKey["\(style.id)/\(other)"] ?? []).map { ($0.caseID, $0.text) })
            let sameOther = mode == "baseline" ? "-" : "\(rows.filter { otherText[$0.caseID] == $0.text }.count)"
            out += "| \(style.name) | \(mode) | \(shown.count)/\(rows.count) | \(String(format: "%.1f", avg)) | "
                + "\(contractions) | \(slangCount) | \(same) | \(sameOther) |\n"
        }
    }
    out += "\n## All suggestions\n"
    let samplesByCase = Dictionary(grouping: p.samples, by: \.caseID)
    for c in p.cases {
        out += "\n### \(c.id) (\(c.category), \(c.app))\n`\(c.before.replacingOccurrences(of: "\n", with: "⏎"))`\n\n"
        for s in samplesByCase[c.id] ?? [] {
            out += "- \(s.style)/\(s.mode): \(s.suppressed.map { "_(\($0))_" } ?? "`\(s.text)`")\n"
        }
    }
    return out
}
