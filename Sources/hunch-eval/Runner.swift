// The `run` subcommand: phrase x model x config, a cold pass and a replay pass per phrase.
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPrompt
import HunchText

struct ResultRow: Sendable {
    var model: String
    var config: String
    var framer: String
    var phraseID: String
    var pass: String           // "cold" | "replay"
    var repeatIndex: Int
    var tags: [String]
    var aiTrap: Bool
    var before: String         // the prompt text actually sent (replay includes the typed chars)
    var raw: String
    var shown: String?         // nil when suppressed
    var suppressReason: String?
    var aiRaw: Bool
    var aiShown: Bool
    var hasExpect: Bool
    var matchShown: Bool
    var matchRaw: Bool
    var firstVisibleMs: Double?
    var totalMs: Double?
    var framingMs: Double?
    var syncMs: Double?
    var decodedPromptTokens: Int?
    var path: String
    var error: String?
    var styleInjected = 0
    var styleCopy = false

    var suppressed: Bool { shown == nil }
}

struct RunOptions {
    var models: [String]
    var configPaths: [String]
    var phrasesPath: String
    var subset: String?
    var quick: Bool
    var repeats: Int
    var outDir: String
    var typoCheck: Bool = true
    var styleSnippetsPath: String?
    var styleK: Int = 0
    var styleFill: Bool = false
}

func runCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--models", "--configs", "--phrases", "--subset", "--repeat", "--out", "--style-snippets", "--style-k"])
    guard !parsed.values("--models").isEmpty, !parsed.values("--configs").isEmpty else {
        printErr("usage: hunch-eval run --models <file>... --configs <config.json>... [--phrases eval/phrases.jsonl] "
            + "[--subset tag] [--repeat N] [--quick] [--no-typo-check] [--out dir] "
            + "[--style-snippets file.jsonl --style-k N [--style-fill]]")
        return ExitCode.usage
    }
    guard let repeats = Int(parsed.value("--repeat") ?? "1"), repeats >= 1 else {
        printErr("--repeat needs a positive integer")
        return ExitCode.usage
    }
    let options = RunOptions(
        models: parsed.values("--models"), configPaths: parsed.values("--configs"),
        phrasesPath: parsed.value("--phrases") ?? "eval/phrases.jsonl", subset: parsed.value("--subset"),
        quick: parsed.flags.contains("--quick"), repeats: repeats,
        outDir: parsed.value("--out") ?? "eval/reports/\(timestampString())",
        typoCheck: !parsed.flags.contains("--no-typo-check"),
        styleSnippetsPath: parsed.value("--style-snippets"), styleK: Int(parsed.value("--style-k") ?? "0") ?? 0,
        styleFill: parsed.flags.contains("--style-fill"))
    do {
        return try await execute(options)
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
}

private func execute(_ options: RunOptions) async throws -> Int32 {
    var phrases = try loadPhrases(path: options.phrasesPath)
    if let subset = options.subset { phrases = phrases.filter { $0.tags.contains(subset) } }
    if options.quick {
        phrases = Array(phrases.filter { $0.tags.contains("quick") }.prefix(12))
    }
    guard !phrases.isEmpty else { throw EvalError("no phrases selected") }

    var configs: [EvalConfig] = []
    for path in options.configPaths {
        guard FileManager.default.fileExists(atPath: path) else {
            printErr("skip: config not found: \(path)")
            continue
        }
        var loaded = try EvalConfig.load(path: path)
        if options.styleSnippetsPath != nil { loaded.name += "+style\(options.styleK)\(options.styleFill ? "f" : "")" }
        configs.append(loaded)
    }
    var style: StyleSetting?
    if let path = options.styleSnippetsPath {
        style = StyleSetting(snippets: try loadSnippets(path: path), k: options.styleK, fill: options.styleFill)
    }
    guard !configs.isEmpty else { throw EvalError("no usable configs") }
    // Instructions are read once per config, never echoed.
    var instructions: [String: String] = [:]
    for config in configs {
        if let text = try config.loadInstructions() { instructions[config.name] = text }
    }

    try FileManager.default.createDirectory(atPath: options.outDir, withIntermediateDirectories: true)
    let registry = DefaultFramerRegistry()
    let counter = RequestCounter()
    var rows: [ResultRow] = []
    var cells: [CellInfo] = []
    var ranAny = false
    var errorCount = 0

    for modelPath in options.models {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            printErr("skip: model file not found: \(modelPath)")
            continue
        }
        let entry = makeEntry(path: modelPath)
        guard entry.validity == .valid, entry.summary != nil else {
            printErr("skip: not a usable model (\(describe(entry.validity))): \(modelPath)")
            continue
        }
        let fileName = entry.url.lastPathComponent
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        let loadStart = ContinuousClock.now
        await host.load(entry, options: evalRuntimeOptions)
        guard case .ready(_, let hostProfile) = await host.state() else {
            printErr("skip: load failed for \(fileName): \(await host.state())")
            await host.unload()
            continue
        }
        printErr("loaded \(fileName) in \(fmtMs(milliseconds(ContinuousClock.now - loadStart))) ms "
            + "(\(hostProfile.isInstruct ? "instruct" : "base"), vocab addBOS=\(hostProfile.addsBOS))")

        for config in configs {
            let engineHost: any ModelHosting = config.addBOS.map { BOSOverridingHost(host, addsBOS: $0) } ?? host
            let effectiveFramer = registry.framer(for: hostProfile, override: config.framerOverride).id
            let requested = config.framerOverride
            let engine = LocalCompletionEngine(
                host: engineHost, registry: registry,
                postProcessor: makeEvalPostProcessor(typoCheck: options.typoCheck), framerOverride: requested,
                promptTokenBudget: config.promptTokenBudget, confidenceFloor: config.postConfidenceFloor)
            let cellRows = await runCell(
                engine: engine, phrases: phrases, config: config, instructions: instructions[config.name],
                model: fileName, framer: effectiveFramer, repeats: options.repeats, counter: counter, style: style)
            errorCount += cellRows.filter { $0.error != nil }.count
            rows += cellRows
            cells.append(CellInfo(model: fileName, config: config.name, framer: effectiveFramer,
                                  requestedFramer: config.framer, isInstruct: hostProfile.isInstruct,
                                  addBOSOverride: config.addBOS, usesInstructions: instructions[config.name] != nil))
            ranAny = true
            printErr("done \(fileName) x \(config.name) (framer \(effectiveFramer)): \(cellRows.count) rows")
        }
        await host.unload()
    }

    guard ranAny else { throw EvalError("nothing ran (no usable model)") }
    let csv = renderCSV(rows)
    try csv.write(toFile: options.outDir + "/results.csv", atomically: true, encoding: .utf8)
    let report = renderReport(rows: rows, cells: cells, phraseCount: phrases.count, options: options)
    try report.write(toFile: options.outDir + "/report.md", atomically: true, encoding: .utf8)
    printOut("report: \(options.outDir)/report.md")
    printOut("csv:    \(options.outDir)/results.csv")
    if errorCount > 0 { printErr("warning: \(errorCount) request(s) failed; see the error column") }
    return errorCount > 0 ? ExitCode.failure : ExitCode.ok
}

private func runCell(engine: LocalCompletionEngine, phrases: [Phrase], config: EvalConfig, instructions: String?,
                     model: String, framer: String, repeats: Int, counter: RequestCounter,
                     style: StyleSetting?) async -> [ResultRow] {
    var rows: [ResultRow] = []
    let classifier = DefaultAIVoiceClassifier()
    for rep in 0..<repeats {
        for (index, phrase) in phrases.enumerated() {
            let cold = await onePass(engine: engine, phrase: phrase, before: phrase.before, pass: "cold", rep: rep,
                                     config: config, instructions: instructions, model: model, framer: framer,
                                     classifier: classifier, counter: counter, style: style)
            rows.append(cold)
            // Replay: the user types 1-3 more characters of the suggestion and the engine re-runs
            // on the extended text (warm KV path).
            let typed = String(cold.raw.prefix(1 + index % 3))
            rows.append(await onePass(engine: engine, phrase: phrase, before: phrase.before + typed, pass: "replay",
                                      rep: rep, config: config, instructions: instructions, model: model,
                                      framer: framer, classifier: classifier, counter: counter, style: style))
        }
    }
    return rows
}

private func onePass(engine: LocalCompletionEngine, phrase: Phrase, before: String, pass: String, rep: Int,
                     config: EvalConfig, instructions: String?, model: String, framer: String,
                     classifier: DefaultAIVoiceClassifier, counter: RequestCounter,
                     style: StyleSetting?) async -> ResultRow {
    let chosen = style.map { selectSnippets($0, before: before) } ?? []
    let id = counter.next()
    let after = phrase.after ?? ""
    let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: nil),
                              field: FieldID(pid: 1, elementHash: 1, generation: 1),
                              before: before, after: after, contentSignature: 0)
    let input = PromptInput(before: before, after: after, surface: phrase.surface, globalInstructions: instructions,
                            appInstructions: phrase.appInstructions, aboutWriter: phrase.about, preferredLanguages: [],
                            maxWords: config.length.maxWords, allowNewlines: false,
                            screenContext: phrase.screen.map { screenLines(appScreenLines($0), limit: config.screenCharLimit) },
                            clipboard: phrase.clipboard,
                            appName: phrase.app, domain: phrase.domain, styleExamples: chosen.map(\.text))
    let request = CompletionRequest(id: id, context: context, input: input, decode: config.decode)
    let collector = PartialCollector()
    var row = ResultRow(model: model, config: config.name, framer: framer, phraseID: phrase.id, pass: pass,
                        repeatIndex: rep, tags: phrase.tags, aiTrap: phrase.aiTrap, before: before, raw: "",
                        shown: nil, suppressReason: nil, aiRaw: false, aiShown: false,
                        hasExpect: phrase.expect != nil, matchShown: false, matchRaw: false, firstVisibleMs: nil,
                        totalMs: nil, framingMs: nil, syncMs: nil, decodedPromptTokens: nil, path: "-", error: nil)
    do {
        let result = try await engine.complete(request) { collector.set($0) }
        // The winner's raw text; with k >= 2 the last streamed partial can be another branch.
        let raw = result.rawText.isEmpty ? collector.value : result.rawText
        row.raw = raw
        row.aiRaw = classifier.isAIVoice(before: before, completion: raw)
        row.styleInjected = chosen.count
        row.styleCopy = copiesSnippet(raw, chosen)
        switch result.outcome {
        case .show(let text):
            row.shown = text
            row.aiShown = classifier.isAIVoice(before: before, completion: text)
        case .suppress(let reason):
            row.suppressReason = reason.rawValue
        }
        if let expect = phrase.expect {
            row.matchRaw = firstWordMatches(expect: expect, before: before, completion: raw)
            if let shown = row.shown { row.matchShown = firstWordMatches(expect: expect, before: before, completion: shown) }
        }
        let t = result.timings
        row.firstVisibleMs = t.firstVisible.map(milliseconds)
        row.totalMs = milliseconds(t.total)
        row.framingMs = milliseconds(t.framing)
        row.syncMs = milliseconds(t.promptSync)
        row.decodedPromptTokens = t.decodedPromptTokens
        row.path = result.path.rawValue
    } catch {
        row.error = "\(error)"
        row.suppressReason = "error"
    }
    return row
}

/// Screen text as the app sends it: web addresses removed line by line (`ScreenTextPipeline`), layout
/// markers (`ScreenMarker`) dropped.
func appScreenLines(_ text: String) -> String {
    ScreenMarker.strip(text).split(separator: "\n", omittingEmptySubsequences: false)
        .map { URLShape.removingURLs(String($0)) }.joined(separator: "\n")
}

/// The newest screen lines (the end of the text) that fit in `limit` characters, whole lines only,
/// in reading order; the whole text when `limit` is nil.
func screenLines(_ text: String, limit: Int?) -> String {
    guard let limit, text.count > limit else { return text }
    var kept: [Substring] = []
    var used = 0
    for line in text.split(separator: "\n").reversed() {
        let cost = line.count + (kept.isEmpty ? 0 : 1)
        if used + cost > limit { break }
        kept.append(line)
        used += cost
    }
    return kept.reversed().joined(separator: "\n")
}
