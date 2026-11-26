// The `copy` subcommand: does the model copy screen text or saved sentences word for word?
// Each case is typed on by accepting every shown suggestion whole, up to `--steps` times, so a copy
// that leaks a few words per suggestion is caught. Run per guard variant x screen token cap.
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPrompt
import HunchScreen
import HunchText

struct CopyCase: Codable, Sendable {
    var id: String
    /// "chat" (busy conversation, copying is bad) or "topic" (single-topic window, screen wording helps).
    var kind: String
    var before: String
    var surface: SurfaceKind
    var app: String?
    var about: String?
    var screen: String?
    var style: [String]?
    /// Topic cases: words from the screen a good continuation is likely to use (any one counts).
    var expect: [String]?
    /// Words that mean the continuation took on someone else's story (any one counts).
    var avoid: [String]?
}

/// Guard variant: "old" (completion-only style guard, no screen guard) or "newN" (typed words count,
/// screen run N words; "new0" = style fix only).
struct CopyVariant: Sendable {
    var name: String
    var countsTyped: Bool
    var screenRun: Int

    init(_ spec: String) throws {
        name = spec
        if spec == "old" {
            countsTyped = false
            screenRun = 0
        } else if spec.hasPrefix("new"), let n = Int(spec.dropFirst(3)) {
            countsTyped = true
            screenRun = n
        } else {
            throw EvalError("unknown variant '\(spec)' (use old or newN)")
        }
    }
}

struct CopySample: Sendable {
    var caseID: String
    var kind: String
    var variant: String
    var screenLimit: Int
    var accepted: String
    var steps: Int
    var stopReason: String
    var screenRun: Int
    var styleRun: Int
    var expectHit: Bool?
    var adopted: Bool?
    var ms: Double
}

func runCopyCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--model", "--config", "--cases", "--variants", "--screen-limits",
                                                 "--steps", "--out", "--subset", "--framers", "--screen-lines"])
    guard let model = parsed.value("--model") else {
        printErr("usage: hunch-eval copy --model <file> [--config eval/configs/app-instruct.json] "
            + "[--cases eval/copy/cases.jsonl] [--variants old new6] [--screen-limits 3500 800] [--steps 4] [--out dir]")
        return ExitCode.usage
    }
    do {
        let variants = try (parsed.values("--variants").isEmpty ? ["old", "new6"] : parsed.values("--variants"))
            .map(CopyVariant.init)
        let limits = (parsed.values("--screen-limits").isEmpty ? ["3500"] : parsed.values("--screen-limits"))
            .compactMap(Int.init)
        let out = parsed.value("--out") ?? "eval/reports/copy-\(timestampString())"
        // Newest screen lines kept per run ("0" = the whole screen).
        let screenLines = (parsed.values("--screen-lines").isEmpty ? ["0"] : parsed.values("--screen-lines")).compactMap(Int.init)
        let framers: [String?] = parsed.values("--framers").isEmpty ? [nil] : parsed.values("--framers").map { $0 }
        return try await executeCopy(model: model, configPath: parsed.value("--config") ?? "eval/configs/app-instruct.json",
                                     casesPath: parsed.value("--cases") ?? "eval/copy/cases.jsonl",
                                     subset: parsed.value("--subset"), variants: variants, limits: limits,
                                     framers: framers, screenLines: screenLines,
                                     steps: Int(parsed.value("--steps") ?? "4") ?? 4, outDir: out)
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
}

private func executeCopy(model: String, configPath: String, casesPath: String, subset: String?,
                         variants: [CopyVariant], limits: [Int], framers: [String?], screenLines: [Int],
                         steps: Int, outDir: String) async throws -> Int32 {
    guard let data = FileManager.default.contents(atPath: casesPath), let text = String(data: data, encoding: .utf8) else {
        throw EvalError("cannot read cases at \(casesPath)")
    }
    var cases = try text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { try JSONDecoder().decode(CopyCase.self, from: Data($0.utf8)) }
    if let subset { cases = cases.filter { $0.kind == subset || $0.id.hasPrefix(subset) } }
    let config = try EvalConfig.load(path: configPath)
    let instructions = try config.loadInstructions()

    let entry = makeEntry(path: model)
    guard entry.validity == .valid, entry.summary != nil else { throw EvalError("not a usable model: \(model)") }
    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    await host.load(entry, options: evalRuntimeOptions)
    guard case .ready = await host.state() else { throw EvalError("load failed for \(model)") }
    let counter = RequestCounter()

    var samples: [CopySample] = []
    for variant in variants {
      for framer in framers {
       for lineCap in screenLines {
        var post = makeEvalPostProcessor(typoCheck: true)
        post.copyGuardCountsTypedWords = variant.countsTyped
        post.screenCopyRun = variant.screenRun
        let engine = LocalCompletionEngine(
            host: host, registry: DefaultFramerRegistry(), postProcessor: post,
            framerOverride: framer ?? config.framerOverride, promptTokenBudget: config.promptTokenBudget,
            confidenceFloor: config.postConfidenceFloor)
        let label = variant.name + (framer.map { "/" + $0.replacingOccurrences(of: "chat-prefill-", with: "") } ?? "")
            + (lineCap > 0 ? "/lines\(lineCap)" : "")
        for limit in limits {
            for c in cases {
                let start = ContinuousClock.now
                var before = c.before
                var accepted = ""
                var taken = 0
                var stop = "steps"
                for _ in 0..<steps {
                    let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: c.app),
                                              field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                              before: before, after: "", contentSignature: 0)
                    var screen = c.screen.map(appScreenLines)
                    if lineCap > 0, let s = screen {
                        screen = s.split(separator: "\n").suffix(lineCap).joined(separator: "\n")
                    }
                    var input = PromptInput(before: before, surface: c.surface, globalInstructions: instructions,
                                            aboutWriter: c.about, preferredLanguages: [],
                                            maxWords: config.length.maxWords, allowNewlines: false,
                                            screenContext: screen, appName: c.app,
                                            styleExamples: c.style ?? [])
                    input.screenTokenLimit = limit
                    let request = CompletionRequest(id: counter.next(), context: context, input: input,
                                                    decode: config.decode)
                    guard let result = try? await engine.complete(request, partial: { _ in }) else {
                        stop = "error"
                        break
                    }
                    guard case .show(let shown) = result.outcome else {
                        if case .suppress(let reason) = result.outcome { stop = reason.rawValue }
                        break
                    }
                    before += shown
                    accepted += shown
                    taken += 1
                }
                let all = TextMeasure.normalizedWords(c.before + accepted)
                let newFrom = TextMeasure.normalizedWords(c.before).count
                let sample = CopySample(
                    caseID: c.id, kind: c.kind, variant: label, screenLimit: limit, accepted: accepted,
                    steps: taken, stopReason: stop,
                    screenRun: longestCopiedRun(all, newFrom: newFrom, sources: c.screen.map { [$0] } ?? []),
                    styleRun: longestCopiedRun(all, newFrom: newFrom, sources: c.style ?? []),
                    expectHit: c.expect.map { terms in terms.contains { accepted.lowercased().contains($0.lowercased()) } },
                    adopted: c.avoid.map { terms in terms.contains { accepted.lowercased().contains($0.lowercased()) } },
                    ms: milliseconds(ContinuousClock.now - start))
                samples.append(sample)
                printErr("\(label) cap\(limit) \(c.id): run screen \(sample.screenRun) style \(sample.styleRun) | \(accepted)")
            }
        }
       }
      }
    }
    await host.unload()

    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    try renderCopyReport(samples, cases: cases, model: entry.url.lastPathComponent, steps: steps)
        .write(toFile: outDir + "/copy-report.md", atomically: true, encoding: .utf8)
    printOut("report: \(outDir)/copy-report.md")
    return ExitCode.ok
}

/// Longest run of consecutive words that ends among the new words (index >= `newFrom`) and appears
/// consecutively in a source. Runs over 16 words count as 16.
func longestCopiedRun(_ words: [String], newFrom: Int, sources: [String]) -> Int {
    guard newFrom < words.count, !sources.isEmpty else { return 0 }
    let maxRun = 16
    var runs = Set<String>()
    for source in sources {
        let sw = TextMeasure.normalizedWords(source)
        for i in 0..<sw.count {
            for n in 1...maxRun where i + n <= sw.count { runs.insert(sw[i..<(i + n)].joined(separator: " ")) }
        }
    }
    var best = 0
    for end in newFrom..<words.count {
        var n = best + 1
        while n <= min(maxRun, end + 1), runs.contains(words[(end - n + 1)...end].joined(separator: " ")) {
            best = n
            n += 1
        }
    }
    return best
}

private func renderCopyReport(_ samples: [CopySample], cases: [CopyCase], model: String, steps: Int) -> String {
    var md = "# Copy eval\n\nModel `\(model)`, \(cases.count) cases, up to \(steps) accepted suggestions each.\n\n"
    md += "Copied run = longest run of words in the accepted text (with the words typed before it) that appears "
    md += "word for word in the screen text or a saved sentence.\n\n"
    md += "| variant | screen cap | kind | cases | words accepted (mean) | screen run ≥5 | screen run ≥7 | style run ≥4 | expect hit | took on others' story |\n"
    md += "|---|---|---|---|---|---|---|---|---|---|\n"
    let groups = Dictionary(grouping: samples) { "\($0.variant)|\($0.screenLimit)|\($0.kind)" }
    for key in groups.keys.sorted() {
        let g = groups[key]!
        let parts = key.split(separator: "|")
        let words = Double(g.map { TextMeasure.normalizedWords($0.accepted).count }.reduce(0, +)) / Double(g.count)
        let withScreen = g.filter { c in cases.first { $0.id == c.caseID }?.screen != nil }
        let withStyle = g.filter { c in !(cases.first { $0.id == c.caseID }?.style ?? []).isEmpty }
        func share(_ xs: [CopySample], _ f: (CopySample) -> Bool) -> String {
            xs.isEmpty ? "-" : "\(xs.filter(f).count)/\(xs.count)"
        }
        let expects = g.compactMap(\.expectHit)
        md += "| \(parts[0]) | \(parts[1]) | \(parts[2]) | \(g.count) | \(String(format: "%.1f", words)) | "
        md += "\(share(withScreen) { $0.screenRun >= 5 }) | \(share(withScreen) { $0.screenRun >= 7 }) | "
        md += "\(share(withStyle) { $0.styleRun >= 4 }) | "
        md += expects.isEmpty ? "- | " : "\(expects.filter { $0 }.count)/\(expects.count) | "
        let adopted = g.compactMap(\.adopted)
        md += adopted.isEmpty ? "- |\n" : "\(adopted.filter { $0 }.count)/\(adopted.count) |\n"
    }
    md += "\n## Accepted text per case\n\n"
    for c in cases {
        md += "### \(c.id) (\(c.kind))\n\nBefore: `\(c.before)`\n\n"
        for s in samples where s.caseID == c.id {
            md += "- \(s.variant) cap \(s.screenLimit): `\(s.accepted)` (screen run \(s.screenRun), style run \(s.styleRun), stop \(s.stopReason))\n"
        }
        md += "\n"
    }
    return md
}
