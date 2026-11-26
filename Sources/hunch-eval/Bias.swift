// The `bias` subcommand: learned-vocabulary bias experiment at several strengths on one model x config.
import Foundation
import HunchCore
import HunchEngine
import HunchHistory
import HunchLlama
import HunchModels
import HunchPrompt
import HunchText

struct BiasCase: Codable, Sendable {
    var id: String
    var kind: String          // "fit" | "nofit"
    var before: String
    var surface: SurfaceKind
    var learned: [String]     // words that fit this context (fit cases)
}

/// Past sentences for the synthetic vocabulary (`bias --gate`), so `VocabularyGate` has lead-ins and topics.
struct BiasHistory: Codable, Sendable {
    var sentences: [String]

    /// Gate candidates: each vocabulary word with the one- and two-word lead-ins it follows in the sentences.
    func candidates(_ vocab: [LearnedBias.Entry]) -> [VocabularyGate.Candidate] {
        vocab.map { e in
            var contexts: [String: Float] = [:]
            for s in sentences {
                let words = s.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
                for (i, w) in words.enumerated() where w == e.text.lowercased() && i > 0 {
                    contexts[words[i - 1], default: 0] += 1
                    if i > 1 { contexts[words[i - 2] + " " + words[i - 1], default: 0] += 1 }
                }
            }
            return VocabularyGate.Candidate(text: e.text, weight: e.weight, contexts: contexts)
        }
    }
}

struct BiasVocab: Codable, Sendable {
    var entries: [LearnedBias.Entry]
}

struct BiasSample {
    var strength: Float
    var id: String
    var group: String         // "fit" | "nofit" | "normal"
    var raw: String
    var shown: String?
    var learnedInRaw: Bool    // any vocabulary word (whole word) in raw
    var fitInRaw: Bool        // a word listed for this case in raw
    var fitInShown: Bool
    var match: Bool?          // first-word match on shown (normal group only)
    var firstVisibleMs: Double?
    var totalMs: Double?
}

/// Lowercased word set of a text (letters/digits/apostrophes), for whole-word vocabulary lookup.
func wordSet(_ text: String) -> Set<String> {
    var out = Set<String>()
    var cur = ""
    for ch in text.lowercased() {
        if ch.isLetter || ch.isNumber || ch == "'" { cur.append(ch) } else { if !cur.isEmpty { out.insert(cur) }; cur = "" }
    }
    if !cur.isEmpty { out.insert(cur) }
    return out
}

/// Bias entries as the app would pass them: a leading space when the caret follows a non-space character.
func biasEntries(_ vocab: [LearnedBias.Entry], before: String) -> [LearnedBias.Entry] {
    let lead = (before.last?.isWhitespace ?? true) ? "" : " "
    return vocab.map { LearnedBias.Entry(text: lead + $0.text, weight: $0.weight) }
}

/// Mid-word only: the vocabulary words that finish the partial word at the caret, written whole without a
/// leading space (as `BiasBuilder` step 1); none when the caret isn't inside a word.
func midWordEntries(_ vocab: [LearnedBias.Entry], before: String) -> [LearnedBias.Entry] {
    let partial = String(before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" }.reversed()).lowercased()
    guard !partial.isEmpty else { return [] }
    return vocab.filter { $0.text.lowercased().hasPrefix(partial) && $0.text.lowercased() != partial }
}

func parseStrengths(_ text: String) -> [Float]? {
    let parts = text.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.isEmpty, !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
    return parts.map { $0! }
}

func runBiasCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--model", "--config", "--vocab", "--cases", "--phrases", "--strengths", "--out", "--gate"])
    guard let modelPath = parsed.value("--model"), let configPath = parsed.value("--config") else {
        printErr("usage: hunch-eval bias --model <file> --config <config.json> [--vocab eval/bias/vocab.json] "
            + "[--cases eval/bias/cases.jsonl] [--phrases eval/phrases.jsonl] [--strengths 0,1.5,3] [--no-typo-check] "
            + "[--midword] [--notes | --gate eval/bias/history.json] [--out dir]")
        return ExitCode.usage
    }
    guard let strengths = parseStrengths(parsed.value("--strengths") ?? "0,1.5,3") else {
        printErr("--strengths needs comma-separated non-negative numbers")
        return ExitCode.usage
    }
    do {
        return try await biasExperiment(
            modelPath: modelPath, configPath: configPath, vocabPath: parsed.value("--vocab") ?? "eval/bias/vocab.json",
            casesPath: parsed.value("--cases") ?? "eval/bias/cases.jsonl",
            phrasesPath: parsed.value("--phrases") ?? "eval/phrases.jsonl", strengths: strengths,
            typoCheck: !parsed.flags.contains("--no-typo-check"),
            midWord: parsed.flags.contains("--midword"), notes: parsed.flags.contains("--notes"),
            gatePath: parsed.value("--gate"),
            outDir: parsed.value("--out") ?? "eval/reports/bias-\(timestampString())")
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
}

private func biasExperiment(modelPath: String, configPath: String, vocabPath: String, casesPath: String,
                            phrasesPath: String, strengths: [Float], typoCheck: Bool, midWord: Bool = false,
                            notes: Bool = false, gatePath: String? = nil, outDir: String) async throws -> Int32 {
    let history = try gatePath.map { path -> BiasHistory in
        guard let d = FileManager.default.contents(atPath: path) else { throw EvalError("cannot read \(path)") }
        return try JSONDecoder().decode(BiasHistory.self, from: d)
    }
    guard let vdata = FileManager.default.contents(atPath: vocabPath),
          let vocab = try? JSONDecoder().decode(BiasVocab.self, from: vdata), !vocab.entries.isEmpty else {
        throw EvalError("cannot read a non-empty vocabulary at \(vocabPath)")
    }
    guard let cdata = FileManager.default.contents(atPath: casesPath), let ctext = String(data: cdata, encoding: .utf8) else {
        throw EvalError("cannot read cases at \(casesPath)")
    }
    let cases = try ctext.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { try JSONDecoder().decode(BiasCase.self, from: Data($0.utf8)) }
    let normal = try loadPhrases(path: phrasesPath).filter {
        $0.expect != nil && !$0.tags.contains("typo") && !$0.tags.contains("rare") && !$0.tags.contains("zh")
    }
    let config = try EvalConfig.load(path: configPath)
    let instructions = try config.loadInstructions()
    let vocabWords = Set(vocab.entries.map { $0.text.lowercased() })

    guard FileManager.default.fileExists(atPath: modelPath) else { throw EvalError("model not found: \(modelPath)") }
    let entry = makeEntry(path: modelPath)
    guard entry.validity == .valid, entry.summary != nil else { throw EvalError("not a usable model: \(modelPath)") }
    let fileName = entry.url.lastPathComponent
    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    await host.load(entry, options: evalRuntimeOptions)
    guard case .ready = await host.state() else { throw EvalError("load failed for \(fileName)") }
    let engineHost: any ModelHosting = config.addBOS.map { BOSOverridingHost(host, addsBOS: $0) } ?? host
    let engine = LocalCompletionEngine(
        host: engineHost, registry: DefaultFramerRegistry(),
        postProcessor: makeEvalPostProcessor(typoCheck: typoCheck), framerOverride: config.framerOverride,
        promptTokenBudget: config.promptTokenBudget, confidenceFloor: config.postConfidenceFloor)
    let counter = RequestCounter()

    struct Item { var id: String; var group: String; var before: String; var surface: SurfaceKind; var fit: [String]; var expect: [String]? }
    var items = cases.map { Item(id: $0.id, group: $0.kind, before: $0.before, surface: $0.surface, fit: $0.learned.map { $0.lowercased() }, expect: nil) }
    items += normal.map { Item(id: $0.id, group: "normal", before: $0.before, surface: $0.surface, fit: [], expect: $0.expect) }

    var samples: [BiasSample] = []
    for (index, item) in items.enumerated() {
        // Rotate the strength order so no strength always runs first on a cold KV cache.
        let order = (0..<strengths.count).map { strengths[($0 + index) % strengths.count] }
        for strength in order {
            let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: nil),
                                      field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                      before: item.before, after: "", contentSignature: 0)
            var input = PromptInput(before: item.before, after: "", surface: item.surface, globalInstructions: instructions,
                                    preferredLanguages: [], maxWords: config.length.maxWords, allowNewlines: false)
            // --notes: the vocabulary as notes (shown by framers with a vocabulary label, e.g. chat-prefill-i1n1).
            if notes { input.vocabulary = vocab.entries.map(\.text) }
            // --gate: only the words `VocabularyGate` passes for this text (no screen in these cases).
            if let history {
                input.vocabulary = VocabularyGate.select(history.candidates(vocab.entries), sentences: history.sentences,
                                                         before: item.before, screen: nil).map(\.text)
            }
            let entries = midWord ? midWordEntries(vocab.entries, before: item.before) : biasEntries(vocab.entries, before: item.before)
            let bias = LearnedBias(entries: entries, strength: strength)
            let request = CompletionRequest(id: counter.next(), context: context, input: input, decode: config.decode, bias: bias)
            let collector = PartialCollector()
            guard let result = try? await engine.complete(request, partial: { collector.set($0) }) else { continue }
            let raw = collector.value
            var shown: String?
            if case .show(let text) = result.outcome { shown = text }
            let rawWords = wordSet(raw), shownWords = wordSet(shown ?? "")
            samples.append(BiasSample(
                strength: strength, id: item.id, group: item.group, raw: raw, shown: shown,
                learnedInRaw: !rawWords.isDisjoint(with: vocabWords),
                fitInRaw: item.fit.contains(where: rawWords.contains), fitInShown: item.fit.contains(where: shownWords.contains),
                match: item.expect.map { e in shown.map { firstWordMatches(expect: e, before: item.before, completion: $0) } ?? false },
                firstVisibleMs: result.timings.firstVisible.map(milliseconds), totalMs: milliseconds(result.timings.total)))
        }
    }
    await host.unload()

    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let report = renderBiasReport(samples: samples, strengths: strengths, model: fileName,
                                  config: config.name + (midWord ? ", mid-word bias only" : "") + (notes ? ", vocabulary notes" : "") + (history != nil ? ", gated vocabulary notes" : ""),
                                  vocab: vocab.entries, typoCheck: typoCheck)
    try report.write(toFile: outDir + "/bias-report.md", atomically: true, encoding: .utf8)
    var csv = "strength,id,group,raw,shown,learned_in_raw,fit_in_raw,fit_in_shown,match,total_ms\n"
    for s in samples {
        csv += [String(s.strength), s.id, s.group, s.raw, s.shown ?? "", String(s.learnedInRaw), String(s.fitInRaw),
                String(s.fitInShown), s.match.map(String.init) ?? "", s.totalMs.map { String(format: "%.1f", $0) } ?? ""]
            .map(csvEscape).joined(separator: ",") + "\n"
    }
    try csv.write(toFile: outDir + "/bias-results.csv", atomically: true, encoding: .utf8)
    printOut(report)
    printOut("report: \(outDir)/bias-report.md")
    return ExitCode.ok
}

func renderBiasReport(samples: [BiasSample], strengths: [Float], model: String, config: String,
                      vocab: [LearnedBias.Entry], typoCheck: Bool) -> String {
    var md = "# bias experiment\n\n- model \(model), config \(config), typo check \(typoCheck ? "on" : "off")\n"
    md += "- synthetic vocabulary: \(vocab.map { "\($0.text) (\($0.weight))" }.joined(separator: ", "))\n"
    md += "- one cold request per phrase and strength (strength order rotated per phrase). \"appears\" = a vocabulary word listed "
        + "for that case occurs as a whole word in the raw / shown suggestion; \"intrusion\" = any vocabulary word occurs in a "
        + "suggestion where none fits (no-fit cases and the normal English set).\n\n"
    md += "| strength | fit: appears (raw) | fit: appears (shown) | intrusion on no-fit | intrusion on normal set | "
        + "normal first-word match | delta vs base | total ms p50/p95 | first-visible p50 |\n|---|---|---|---|---|---|---|---|---|\n"
    func rate(_ n: Int, _ d: Int) -> String { fmtPct(n, d) }
    var baseAccuracy: Double?
    for s in strengths {
        let mine = samples.filter { $0.strength == s }
        let fit = mine.filter { $0.group == "fit" }
        let nofit = mine.filter { $0.group == "nofit" }
        let normal = mine.filter { $0.group == "normal" }
        let matches = normal.filter { $0.match == true }.count
        let acc = normal.isEmpty ? nil : Double(matches) / Double(normal.count)
        if baseAccuracy == nil { baseAccuracy = acc }
        let delta = (acc != nil && baseAccuracy != nil) ? String(format: "%+.1f pts", (acc! - baseAccuracy!) * 100) : "-"
        let totals = mine.compactMap(\.totalMs), fv = mine.compactMap(\.firstVisibleMs)
        md += "| \(s) | \(rate(fit.filter(\.fitInRaw).count, fit.count)) | \(rate(fit.filter(\.fitInShown).count, fit.count)) "
            + "| \(rate(nofit.filter(\.learnedInRaw).count, nofit.count)) | \(rate(normal.filter(\.learnedInRaw).count, normal.count)) "
            + "| \(rate(matches, normal.count)) | \(delta) | \(fmtMs(percentile(totals, 0.5)))/\(fmtMs(percentile(totals, 0.95))) "
            + "| \(fmtMs(percentile(fv, 0.5))) |\n"
    }
    md += "\n(delta and latency are relative to the first listed strength; the first listed strength should be 0.)\n"
    md += "\nFit-case outputs (raw):\n\n| id | " + strengths.map { "s=\($0)" }.joined(separator: " | ") + " |\n|---|" + strengths.map { _ in "---" }.joined(separator: "|") + "|\n"
    let fitIDs = Array(NSOrderedSet(array: samples.filter { $0.group == "fit" }.map(\.id))) as? [String] ?? []
    for id in fitIDs {
        md += "| \(id) | " + strengths.map { s in mdEscape(samples.first { $0.id == id && $0.strength == s }?.raw ?? "-") }.joined(separator: " | ") + " |\n"
    }
    let intrusions = samples.filter { $0.group != "fit" && $0.learnedInRaw && $0.strength > 0 }
    if !intrusions.isEmpty {
        md += "\nIntrusions:\n\n"
        for s in intrusions { md += "- s=\(s.strength) \(s.id): `\(mdEscape(s.raw))`\n" }
    }
    return md
}
