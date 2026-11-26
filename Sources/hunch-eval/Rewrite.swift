// `rewrite`: the whole-field rewrite (autocorrect's Top strength) on messy text. Each case is typed
// sentence by sentence; at every sentence end, and at the end of the text, a pass runs the way the
// app would at a pause: the model rereads the paragraph and `FieldRewrite` keeps the changes that may
// go in. The input is the text as typed, or (`--after`) what fix-as-you-type left of it, from an
// `autocorrect` run's results CSV, since at Top strength both run. Scored against the clean text.
// Writes rewrite-report.md, rewrite-results.jsonl, and a blind set for Opus judges (judge-set.jsonl).
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPrompt
import HunchHistory
import HunchText

private struct RewriteCase: Sendable {
    var id: String
    var set: String
    var surface: SurfaceKind
    var app: String?
    var noisy: NoisyText
    var screen: String?
}

private struct PassRecord: Codable {
    var target: String
    var revised: String
    var applied: [String]
    var rejected: [String]
    var ms: Double
    var prefillMs: Double
    var promptTokens: Int
    var reusedTokens: Int
    /// `--own-fix-arbiter score`: the disagreements scored, and the scoring time (live scores only).
    var disputes: [DisputeRecord]? = nil
    var arbiterMs: Double? = nil
}

/// One own-fix disagreement scored by `--own-fix-arbiter score`.
private struct DisputeRecord: Codable {
    var kind: String
    var typed: String
    var fixed: String
    var model: String
    var readings: [String]
    var scores: [Float]
    var slipCosts: [Float]
    /// The reading taken over the rule's choice (`readings[0]`), nil: the rule's.
    var verdict: String?
}

/// Model scores of own-fix disagreements, recorded (`--arbiter-scores file.jsonl`, read and appended).
private final class ArbiterScores {
    private struct Line: Codable { var key: String; var scores: [Float]; var ms: Double }
    private var known: [String: [Float]] = [:]
    private let path: String?
    init(path: String?) throws {
        self.path = path
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            let l = try JSONDecoder().decode(Line.self, from: Data(line.utf8))
            if known[l.key] == nil { known[l.key] = l.scores }
        }
    }
    func scores(_ key: String) -> [Float]? { known[key] }
    func record(_ key: String, _ scores: [Float], ms: Double) {
        known[key] = scores
        guard let path, let data = try? JSONEncoder().encode(Line(key: key, scores: scores, ms: ms)) else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(data + Data("\n".utf8))
        try? h.close()
    }
}

/// What the model answered for one pass, live or from a recording.
private struct PassAnswer {
    var revised: String
    var ms: Double
    var prefillMs: Double
    var promptTokens: Int
    var reusedTokens: Int

    init(_ pass: LocalRewriter.Pass) {
        self.init(revised: pass.revised, ms: pass.totalMs, prefillMs: pass.prefillMs, promptTokens: pass.promptTokens,
                  reusedTokens: pass.reusedTokens)
    }

    init(revised: String, ms: Double, prefillMs: Double, promptTokens: Int, reusedTokens: Int) {
        self.revised = revised
        self.ms = ms
        self.prefillMs = prefillMs
        self.promptTokens = promptTokens
        self.reusedTokens = reusedTokens
    }
}

/// The model's answers from earlier runs' rewrite-results.jsonl, by style switches and target text
/// (the first recording of a pair wins). The text before the target is not compared: a replayed
/// answer is the one the model gave with the earlier run's fixes before it.
private struct ReplayedPasses {
    private struct Recorded: Decodable { var mode: String?; var passes: [PassRecord] }
    private var answers: [String: PassAnswer] = [:]
    let paths: [String]

    init(paths: [String]) throws {
        self.paths = paths
        for path in paths {
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
                let r = try JSONDecoder().decode(Recorded.self, from: Data(line.utf8))
                for p in r.passes {
                    let key = Self.key(mode: r.mode ?? "app", target: p.target)
                    if answers[key] == nil {
                        answers[key] = PassAnswer(revised: p.revised, ms: p.ms, prefillMs: p.prefillMs,
                                                  promptTokens: p.promptTokens, reusedTokens: p.reusedTokens)
                    }
                }
            }
        }
    }

    var isEmpty: Bool { answers.isEmpty }

    func answer(mode: String, target: String) -> PassAnswer? { answers[Self.key(mode: mode, target: target)] }

    private static func key(mode: String, target: String) -> String { mode + "\u{1}" + target }
}

private struct CaseRecord: Codable {
    var id: String
    /// Style switches the run used (`--switches`): "app" (the surface's defaults), "on", "caps-off",
    /// "punct-off", "shorthand".
    var mode: String = "app"
    /// Spelling only: slips (apostrophes left out of the count) fixed when capitals and punctuation
    /// are ignored.
    var spellingSlips = 0
    var spellingFixed = 0
    var set: String
    var surface: String
    var app: String?
    var clean: String
    var typed: String
    var input: String
    var output: String
    var passes: [PassRecord]
    var fixedBefore: Int
    var fixedAfter: Int
    var slips: Int
    var broken: Int
    var extraBefore: Int
    var extraAfter: Int
}

/// Output words no clean word lines up with (words added, or extra words left in).
private func extraWords(clean: String, output: String) -> Int {
    let a = TypoNoise.words(output), b = TypoNoise.words(clean)
    let n = a.count, m = b.count
    guard n > 0, m > 0 else { return n }
    var l = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            l[i][j] = a[i] == b[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
        }
    }
    return n - l[0][0]
}

/// The app's Chats defaults (no capital or punctuation fixes, shorthand kept); all on elsewhere.
/// `mode` other than "app": the same switches for every text.
private func options(for surface: SurfaceKind, mode: String = "app") -> RewriteOptions {
    var o = RewriteOptions()
    switch mode {
    case "on": return o
    case "caps-off": o.fixesCapitals = false; return o
    case "punct-off": o.fixesPunctuation = false; return o
    case "shorthand": o.leavesShorthand = true; return o
    case "all-off": o.fixesCapitals = false; o.fixesPunctuation = false; o.leavesShorthand = true; return o
    default: break
    }
    if surface == .chat {
        o.fixesCapitals = false
        o.fixesPunctuation = false
        o.leavesShorthand = true
    }
    return o
}

/// Scores spelling alone: words compared lowercased, without punctuation or apostrophes; slips
/// that are only a left-out apostrophe don't count.
private func spellingScore(_ noisy: NoisyText, output: String) -> (fixed: Int, slips: Int) {
    func norm(_ t: String) -> String {
        t.split(whereSeparator: \.isWhitespace).map { w -> String in
            let n = w.lowercased().filter { $0.isLetter || $0.isNumber }
            return n.isEmpty ? "_" : n
        }.joined(separator: " ")
    }
    let slips = noisy.slips.filter { $0.kind != .apostropheDropped }
    let score = TypoScore.score(NoisyText(clean: norm(noisy.clean), typed: norm(noisy.typed), slips: slips),
                                output: norm(output))
    return (score.fixed.filter { $0 }.count, slips.count)
}

/// Names and terms on the screen: capitalized words, words with digits, underscores or inner
/// capitals (an approximation of the app's `ScreenWords`, which asks the spell checker).
private func screenTerms(_ screen: String?) -> [String] {
    guard let screen else { return [] }
    var seen = Set<String>(), out: [String] = []
    for raw in screen.split(whereSeparator: { $0.isWhitespace }) {
        let w = raw.trimmingCharacters(in: .punctuationCharacters)
        guard w.count >= 3, let f = w.first, f.isLetter else { continue }
        let term = f.isUppercase || w.contains(where: \.isNumber) || w.contains("_") || w.dropFirst().contains(where: \.isUppercase)
        if term, seen.insert(w).inserted { out.append(w) }
    }
    return out
}

/// The typed text split where passes run: after each sentence end ("." "!" "?" and a space).
private func chunks(_ text: String) -> [String] {
    let ns = text as NSString
    var cuts = RewriteTarget.sentenceEndsPublic(in: text)
    cuts.append(ns.length)
    var out: [String] = [], last = 0
    for c in cuts where c > last {
        out.append(ns.substring(with: NSRange(location: last, length: c - last)))
        last = c
    }
    return out
}

/// The `own_fixes` column of an autocorrect results CSV.
private func parseOwnFixes(_ json: String) -> [OwnFix] {
    guard let items = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
    return items.compactMap { d in
        guard let at = d["at"] as? Int, let typed = d["typed"] as? String, let fixed = d["fixed"] as? String else { return nil }
        return OwnFix(range: at..<(at + fixed.utf16.count), typed: typed, fixed: fixed,
                      confidence: (d["confidence"] as? String).flatMap(FixConfidence.init(rawValue:)))
    }
}

/// Minimal CSV reader (quoted fields, doubled quotes).
private func readCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    var it = Array(text).makeIterator()
    var pending: Character?
    while let c = pending ?? it.next() {
        pending = nil
        if quoted {
            if c == "\"" {
                if let n = it.next() {
                    if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                } else { quoted = false }
            } else { field.append(c) }
        } else if c == "\"" { quoted = true
        } else if c == "," { row.append(field); field = ""
        } else if c == "\n" { row.append(field); rows.append(row); row = []; field = ""
        } else { field.append(c) }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

func runRewriteCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--model", "--sets", "--corpus", "--synthetic", "--seed", "--rate",
                                                 "--after", "--out", "--only", "--switches", "--replay", "--as-typed", "--own-fix-rules",
                                                 "--fix-capacity", "--kept-typed", "--history-terms",
                                                 "--own-fix-arbiter", "--arbiter-kinds", "--arbiter-margin", "--arbiter-slip-weight",
                                                 "--arbiter-scores", "--arbiter-context", "--fix-confidence"])
    // Recorded passes (`--replay rewrite-results.jsonl`, repeatable): the model's answer for a pass
    // with the same switches and target is reused, so a guard change is scored without the model.
    let replay: ReplayedPasses
    do { replay = try ReplayedPasses(paths: parsed.values("--replay")) } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
    let model = parsed.value("--model")
    guard model != nil || !replay.isEmpty else {
        printErr("usage: hunch-eval rewrite --model <file.gguf> [--sets a.jsonl,b.jsonl] [--synthetic N] "
                 + "[--after autocorrect-results.csv ...] [--only id-prefix] [--out dir] "
                 + "[--replay rewrite-results.jsonl ...] (--model optional with --replay)")
        return ExitCode.usage
    }
    let out = parsed.value("--out") ?? "eval/reports/rewrite-\(timestampString())"
    let setPaths = (parsed.value("--sets") ?? "eval/autocorrect/samples.jsonl,eval/rewrite/cases.jsonl,"
                    + "eval/autocorrect/confused-fixes.jsonl,eval/autocorrect/confused-clean.jsonl")
        .split(separator: ",").map(String.init)
    var cases: [RewriteCase] = []
    do {
        for path in setPaths where FileManager.default.fileExists(atPath: path) {
            let set = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
                let s = try JSONDecoder().decode(AutocorrectSample.self, from: Data(line.utf8))
                let slips = s.slips.map { TypoSlip(kind: $0.kind, words: $0.words[0]..<$0.words[1]) }
                cases.append(RewriteCase(id: s.id, set: set, surface: s.surface ?? .chat, app: s.app,
                                         noisy: NoisyText(clean: s.clean, typed: s.typed, slips: slips), screen: s.screen))
            }
        }
        let synthetic = Int(parsed.value("--synthetic") ?? "40") ?? 40
        if synthetic > 0 {
            let corpus = parsed.value("--corpus") ?? "eval/replay/cases.jsonl"
            var screens: [String: String] = [:]
            for line in try String(contentsOfFile: corpus, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
                let c = try JSONDecoder().decode(ReplayCase.self, from: Data(line.utf8))
                screens[c.id] = c.screen
            }
            let noisy = try loadAutocorrectCases(corpora: [corpus], samples: "", variants: 1,
                                                 seed: UInt64(parsed.value("--seed") ?? "1") ?? 1,
                                                 rate: Double(parsed.value("--rate") ?? "0.25") ?? 0.25, limit: synthetic)
            cases += noisy.map { c in
                RewriteCase(id: c.id, set: "synthetic", surface: c.surface, app: c.app, noisy: c.noisy,
                            screen: screens[String(c.id.split(separator: "#").first ?? "")])
            }
        }
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
    if let only = parsed.value("--only") { cases = cases.filter { $0.id.hasPrefix(only) || $0.set == only } }
    // What fix-as-you-type left: id → output, from autocorrect results CSVs (reads 1 rows), and its
    // own fixes there (`own_fixes`, for `--as-typed keep|revert`).
    var after: [String: String] = [:]
    var ownFixes: [String: [OwnFix]] = [:]
    let asTyped: RewriteOwnFixes.KeptTyped? = parsed.value("--as-typed").map { $0 == "revert" ? .revert : .keepFix }
    let fixCapacity = Int(parsed.value("--fix-capacity") ?? "") ?? FixHistory<Int>.capacity
    // `--as-typed`: a change over an own fix needs real words (`--no-word-check`: any the guard allows).
    // `--learned`: the user's learned words count as real words, as in the app (its spell checker has them).
    let learned = parsed.flags.contains("--learned") ? loadLearnedPlaces().words : []
    let spell: any SpellChecking = learned.isEmpty ? SystemSpellChecker.cached()
        : LearnedWordsChecker(base: SystemSpellChecker.cached(), words: learned)
    // `--own-fix-rules none|typed|count|two|all` (default all): when a model change may replace an own fix.
    let ownFixRules: RewriteOwnFixes.Rules = switch parsed.value("--own-fix-rules") ?? "all" {
    case "none": []
    case "typed": .typedWordsStay
    case "count": .sameWordCount
    case "two": [.typedWordsStay, .sameWordCount]
    default: .all
    }
    // `--kept-typed keep|app|realword|realword-any|realword-drop|term|both|both-any|both-drop` (default keep): with `--as-typed
    // keep`, which more own fixes the model kept as typed are taken back (`KeptTypedRules`; app: as the app).
    var keptRules: RewriteOwnFixes.KeptTypedRules = switch parsed.value("--kept-typed") ?? "keep" {
    case "realword": .realWord
    case "realword-any": [.realWord, .anyRealWord]
    case "term": .term
    case "both": [.realWord, .term]
    case "both-any": [.realWord, .anyRealWord, .term]
    case "realword-drop", "app": .app
    case "both-drop": [.realWord, .droppedLetterStays, .term]
    default: []
    }
    // `--fix-confidence off|on` (default off): an own fix fix-as-you-type was unsure of (`FixConfidence`)
    // is taken back when the model kept the typed form. Results without a recorded confidence get it
    // from the same test here (learned words with `--learned`).
    let fixConfidence = parsed.value("--fix-confidence") ?? "off"
    switch fixConfidence {
    case "off": break
    case "on": keptRules.insert(.unsureFix)
    default: printErr("unknown --fix-confidence \(fixConfidence)"); return ExitCode.usage
    }
    // `--own-fix-arbiter off|score` (default off): where the pass and an own fix disagree and a rule
    // decided (`--arbiter-kinds app|blocked,kept,accepted` or kind names; default app), the model
    // scores the real-word readings in the corrected sentence on the pass's prompt, minus
    // `--arbiter-slip-weight` × slip cost; a reading beating the rule's choice by `--arbiter-margin` wins.
    // `--arbiter-scores file.jsonl`: scores recorded and reused (tuning without the model).
    let arbiterOn = parsed.value("--own-fix-arbiter") == "score"
    var arbiterKinds = Set<OwnFixDispute.Kind>()
    for k in (parsed.value("--arbiter-kinds") ?? "app").split(separator: ",").map(String.init) {
        switch k {
        case "blocked": arbiterKinds.formUnion(OwnFixDispute.Kind.blocked)
        case "kept": arbiterKinds.insert(.keptTyped)
        case "app": arbiterKinds.formUnion(OwnFixDispute.Kind.app)
        default:
            guard let kind = OwnFixDispute.Kind(rawValue: k) else { printErr("unknown --arbiter-kinds \(k)"); return ExitCode.usage }
            arbiterKinds.insert(kind)
        }
    }
    if !arbiterOn { arbiterKinds = [] }
    // `--arbiter-context pass|plain` (default pass): scored on the pass's prompt after its corrected
    // copy so far, or as plain text after the field (the suggestion prompt, as fix-as-you-type's
    // ambiguous words), which doesn't see what was typed.
    let arbiterPlain = parsed.value("--arbiter-context") == "plain"
    let arbiterMargin = Float(parsed.value("--arbiter-margin") ?? "") ?? RewriteOwnFixes.arbiterMargin
    let arbiterSlipWeight = Float(parsed.value("--arbiter-slip-weight") ?? "") ?? RewriteOwnFixes.arbiterSlipWeight
    let arbiterScores: ArbiterScores
    do { arbiterScores = try ArbiterScores(path: parsed.value("--arbiter-scores")) } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
    var scoredDisputes = 0, cachedDisputes = 0, unscoredDisputes = 0
    var arbiterTimes: [Double] = [], passTimes: [Double] = []
    var learnedTerms = Set(learned.map { $0.lowercased() })
    // `--history-terms N`: words seen in the typing history N+ times but not learned yet (not blocked,
    // not likely typos) count as the writer's terms too. The eval's history includes later typing.
    if let n = parsed.value("--history-terms").flatMap(Int.init) {
        let (model, _) = EncryptedHistoryStore().loadResult()
        let seen = model.entries.values.filter { !$0.active && !$0.blocked && !$0.likelyTypo && $0.positive >= n && !$0.text.contains(" ") }
        learnedTerms.formUnion(seen.map { $0.text.lowercased() })
        printErr("history terms (seen \(n)+, not learned): \(seen.count); "
                 + ["gguf", "worktree", "md", "mashuga", "dock", "gig"].map { w in
                     "\(w) \(model.entries.values.first { $0.text.lowercased() == w }.map { "\($0.positive)+/\($0.negative)- active \($0.active)" } ?? "none")"
                 }.joined(separator: ", "))
    }
    let knownWord: ((String) -> Bool)? = parsed.flags.contains("--no-word-check") ? nil
        : { !spell.isMisspelled($0, languages: ["en"]) }
    // `--no-rare-fix`: a fix that put in a rare word gets no exception from the slip-cost rule.
    let commonWord: ((String) -> Bool)? = parsed.flags.contains("--no-rare-fix") ? nil : { CommonEnglish.contains($0) }
    let learnedLower = Set(learned.map { $0.lowercased() })
    var recordedConfidence = 0
    for path in parsed.values("--after") {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { printErr("cannot read \(path)"); return ExitCode.failure }
        let rows = readCSV(text)
        guard let head = rows.first, let id = head.firstIndex(of: "id"), let reads = head.firstIndex(of: "reads"),
              let output = head.firstIndex(of: "output") else { printErr("\(path) is not an autocorrect results CSV"); return ExitCode.failure }
        let fixes = head.firstIndex(of: "own_fixes")
        for r in rows.dropFirst() where r.count > output && Double(r[reads]) == 1 {
            after[r[id]] = r[output]
            if let fixes, r.count > fixes {
                ownFixes[r[id]] = parseOwnFixes(r[fixes]).map { f in
                    guard f.confidence == nil else { return f }
                    var g = f
                    g.confidence = FixConfidence.of(typed: f.typed, fixed: f.fixed, isEveryday: { CommonEnglish.contains($0) },
                                                    isLearned: { learnedLower.contains($0) })
                    return g
                }
                recordedConfidence += parseOwnFixes(r[fixes]).filter { $0.confidence != nil }.count
            }
        }
    }
    if fixConfidence != "off" {
        let all = ownFixes.values.flatMap { $0 }
        printErr("fix confidence \(fixConfidence): \(all.filter { $0.confidence == .unsure }.count) of \(all.count) own fixes unsure "
                 + "(\(recordedConfidence) recorded by autocorrect, the rest from the same test here)")
    }
    if asTyped != nil, ownFixes.isEmpty {
        printErr("--as-typed needs --after results with an own_fixes column (rerun `autocorrect`)")
        return ExitCode.failure
    }

    // The model loads at the first pass no recording answers (never, when every pass is replayed).
    var host: LlamaModelHost?
    var rewriter: LocalRewriter?
    // `--with-suggestions`: a suggestion request for the text so far before every pass, as typing
    // in the app makes them (measures the pass's prompt reuse next to suggestions).
    let withSuggestions = parsed.flags.contains("--with-suggestions")
    var suggest: ((SurfaceKind, String?, String) async -> Void)?
    var triedLoading = false
    var plainScore: ((SurfaceKind, String?, String, [String]) async throws -> [Float]?)?
    func liveRewriter() async -> LocalRewriter? {
        if let rewriter { return rewriter }
        guard let model, !triedLoading else { return nil }
        triedLoading = true
        let entry = makeEntry(path: model)
        guard entry.validity == .valid, entry.summary != nil else { printErr("not a usable model: \(model)"); return nil }
        var runtime = evalRuntimeOptions
        runtime.maxSequences = 1
        // A pass's prompt is a few hundred tokens: a small context keeps GPU memory low next to other
        // loaded models (the app, other evals).
        runtime.contextTokens = 2048
        // Plain scoring forks the suggestion prompt.
        if arbiterPlain { runtime.maxSequences = 4 }
        if withSuggestions {
            // As the app: suggestions share the context (branches, its context size).
            runtime.maxSequences = 4
            runtime.contextTokens = RuntimeOptions.defaultContextTokens
        }
        let loaded = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        await loaded.load(entry, options: runtime)
        guard case .ready = await loaded.state() else { printErr("load failed: \(await loaded.state())"); return nil }
        let counter = RequestCounter()
        host = loaded
        rewriter = LocalRewriter(host: loaded, nextID: { counter.next() })
        if arbiterPlain {
            let engine = LocalCompletionEngine(host: loaded)
            plainScore = { surface, app, head, continuations in
                let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: app),
                                          field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                          before: head, after: "", contentSignature: 0)
                let request = CompletionRequest(id: counter.next(), context: context,
                                                input: PromptInput(before: head, surface: surface, appName: app),
                                                decode: DecodeConfig(maxWords: 6))
                return try await engine.scoreContinuations(request, continuations: continuations)
            }
        }
        if withSuggestions {
            let engine = LocalCompletionEngine(host: loaded)
            suggest = { surface, app, head in
                let context = TextContext(app: AppIdentity(bundleID: "eval", pid: 1, localizedName: app),
                                          field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                          before: head, after: "", contentSignature: 0)
                let request = CompletionRequest(id: counter.next(), context: context,
                                                input: PromptInput(before: head, surface: surface, appName: app),
                                                decode: DecodeConfig(maxWords: 6))
                _ = try? await engine.complete(request) { _ in }
            }
        }
        return rewriter
    }
    var replayedPasses = 0, ranPasses = 0, unansweredPasses = 0
    if let model, replay.isEmpty, await liveRewriter() == nil {
        printErr("cannot load \(model)")
        return ExitCode.failure
    }
    printErr("rewrite: \(cases.count) cases, input \(after.isEmpty ? "as typed" : "after fix-as-you-type (\(after.count) texts)")"
             + (asTyped.map { ", own fixes sent as typed (kept typed form: \($0.rawValue), capacity \(fixCapacity))" } ?? ""))

    // The guard's real-word check, as the app's (the spell checker, English; with `--learned`, the
    // user's learned words too).
    let speller = spell
    let isKnownWord: @Sendable (String) -> Bool = { !speller.isMisspelled($0, languages: ["en"]) }
    var records: [CaseRecord] = []
    let ownFixDump: FileHandle? = ProcessInfo.processInfo.environment["GT_OWNFIX_DUMP"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    var failedPasses = 0
    let modes = (parsed.value("--switches") ?? "app").split(separator: ",").map(String.init)
    for mode in modes {
    for (n, c) in cases.enumerated() {
        let input = after[c.id] ?? c.noisy.typed
        var opts = options(for: c.surface, mode: mode)
        opts.isKnownWord = isKnownWord
        // `--kept-typed term`: the writer's words besides the field, as the app has them (the screen's
        // distinctive words, learned words).
        let writerTerms = keptRules.contains(.term)
            ? learnedTerms.union(c.screen.map { ScreenWords(text: $0, isMisspelled: { speller.isMisspelled($0, languages: ["en"]) }).words } ?? [])
            : []
        var field = ""
        var checked: String?
        var passes: [PassRecord] = []
        // Own fixes get ids, so a "kept as typed" decision can follow its fix through later passes.
        var nextFixID = 0
        func numbered(_ list: [OwnFix]) -> [OwnFix] {
            list.map { f in
                guard f.id == nil else { return f }
                var g = f
                g.id = nextFixID
                nextFixID += 1
                return g
            }
        }
        var fixes = numbered(ownFixes[c.id] ?? [])
        // With `keep`: the fixes whose typed form the model kept at their last pass ("+revert" record).
        var keptTyped = Set<Int>()
        // `GT_OWNFIX_DUMP`: what the model offered over each own fix at its last pass (rules aside).
        var offered: [Int: String] = [:]
        let originalFixes = fixes.count
        let pieces = chunks(input)
        for (k, piece) in pieces.enumerated() {
            field += piece
            let finished = k == pieces.count - 1
            guard let target = RewriteTarget.find(before: field, checked: checked, finished: finished) else { continue }
            // `--as-typed`: the own fixes the app's history would still hold (the newest, up to the caret)
            // go to the model as typed.
            let present = fixes.filter { $0.range.upperBound <= field.utf16.count }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }.suffix(fixCapacity)
            let sent = asTyped == nil ? AsTypedTarget(unchanged: target)
                : RewriteOwnFixes.asTyped(target, fixes: Array(present))
            let request = RewriteRequest(target: sent.target.text, before: target.before, surface: c.surface, appName: c.app,
                                         screenWords: screenTerms(c.screen), fixesCapitals: opts.fixesCapitals,
                                         fixesPunctuation: opts.fixesPunctuation, keepsShorthand: opts.leavesShorthand)
            do {
                let pass: PassAnswer
                if let recorded = replay.answer(mode: mode, target: sent.target.text) {
                    pass = recorded
                    replayedPasses += 1
                } else if let live = await liveRewriter() {
                    await suggest?(c.surface, c.app, field)
                    // A failed decode (GPU memory pressure) gets one retry after a moment.
                    let answer: LocalRewriter.Pass
                    do { answer = try await live.rewrite(request) } catch {
                        try? await Task.sleep(for: .seconds(2))
                        answer = try await live.rewrite(request)
                    }
                    pass = PassAnswer(answer)
                    ranPasses += 1
                } else {
                    // Replay without a model: a pass no recording answers is left out.
                    unansweredPasses += 1
                    continue
                }
                let result = FieldRewrite.edits(target: sent.target, revised: pass.revised, options: opts)
                var passDisputes: [DisputeRecord]?
                var passArbiterMs: Double?
                var applied = result.edits.map { "\($0.original.isEmpty ? "+" : $0.original) → \($0.replacement.isEmpty ? "∅" : $0.replacement.trimmingCharacters(in: .whitespaces)) [\($0.kind.rawValue)]" }
                if let asTyped {
                    var mapped = RewriteOwnFixes.mapBack(result, revised: pass.revised, on: sent, options: opts, kept: .revert,
                                                         isKnownWord: knownWord, isCommonWord: commonWord, rules: ownFixRules)
                    if asTyped == .keepFix {
                        let reverts = mapped.filter(\.revertsFix).flatMap(\.replacesFixes)
                        for id in sent.placed.compactMap(\.fix.id) {
                            if reverts.contains(id) { keptTyped.insert(id) } else { keptTyped.remove(id) }
                        }
                        // As the app: only a fix that is no known word is taken back.
                        var disputes: [OwnFixDispute] = []
                        mapped = RewriteOwnFixes.mapBack(result, revised: pass.revised, on: sent, options: opts, kept: .keepFix,
                                                         isKnownWord: knownWord, isCommonWord: commonWord, rules: ownFixRules,
                                                         keptRules: keptRules, writerTerms: writerTerms,
                                                         arbitrated: arbiterKinds, disputes: { disputes.append($0) })
                        if !disputes.isEmpty {
                            var verdicts: [Range<Int>: String] = [:]
                            var records: [DisputeRecord] = []
                            var liveMs = 0.0
                            for d in disputes {
                                var (head, continuations) = d.scoring
                                if arbiterPlain {
                                    head = target.before + head
                                    // The suggestion prompt's healed trailing space: continuations start with it.
                                    continuations = continuations.map { $0.hasPrefix(" ") ? String($0.dropFirst()) : $0 }
                                    head += d.scoring.continuations.first?.hasPrefix(" ") == true ? " " : ""
                                }
                                let key = [mode, arbiterPlain ? "plain" : target.before, arbiterPlain ? "" : sent.target.text,
                                           head, continuations.joined(separator: "\u{2}")].joined(separator: "\u{1}")
                                var scores = arbiterScores.scores(key)
                                if scores != nil {
                                    cachedDisputes += 1
                                } else if let live = await liveRewriter() {
                                    let start = ContinuousClock.now
                                    if arbiterPlain {
                                        scores = (try? await plainScore?(c.surface, c.app, head, continuations)) ?? nil
                                    } else {
                                        scores = try? await live.score(request, head: head, continuations: continuations)
                                    }
                                    let ms = milliseconds(ContinuousClock.now - start)
                                    if let scores {
                                        arbiterScores.record(key, scores, ms: ms)
                                        liveMs += ms
                                        scoredDisputes += 1
                                    }
                                }
                                guard let scores else { unscoredDisputes += 1; continue }
                                let verdict = RewriteOwnFixes.arbitrate(d, scores: scores, margin: arbiterMargin,
                                                                        slipWeight: arbiterSlipWeight)
                                if let verdict { verdicts[d.range] = verdict }
                                records.append(DisputeRecord(kind: d.kind.rawValue, typed: d.typed, fixed: d.fixed, model: d.model,
                                                             readings: d.readings, scores: scores,
                                                             slipCosts: d.readings.indices.map(d.slipCost), verdict: verdict))
                            }
                            passDisputes = records
                            if liveMs > 0 { passArbiterMs = liveMs; arbiterTimes.append(liveMs) }
                            if !verdicts.isEmpty {
                                mapped = RewriteOwnFixes.mapBack(result, revised: pass.revised, on: sent, options: opts, kept: .keepFix,
                                                                 isKnownWord: knownWord, isCommonWord: commonWord, rules: ownFixRules,
                                                                 keptRules: keptRules, writerTerms: writerTerms,
                                                                 arbitrated: arbiterKinds, verdicts: verdicts)
                            }
                        }
                        for id in mapped.filter(\.revertsFix).flatMap(\.replacesFixes) { keptTyped.remove(id) }
                        if ownFixDump != nil {
                            let free = RewriteOwnFixes.mapBack(result, revised: pass.revised, on: sent, options: opts, kept: .keepFix,
                                                               isKnownWord: knownWord, isCommonWord: commonWord, rules: [])
                            let took = Set(mapped.flatMap(\.replacesFixes))
                            for id in sent.placed.compactMap(\.fix.id) { offered[id] = nil }
                            for m in free where !m.revertsFix {
                                for id in m.replacesFixes where !took.contains(id) { offered[id] = m.edit.replacement }
                            }
                        }
                    }
                    applied = mapped.map { m in
                        let e = m.edit
                        let typed = m.typed.map { $0 != e.original ? " (typed \($0))" : "" } ?? ""
                        return "\(e.original.isEmpty ? "+" : e.original)\(typed) → \(e.replacement.isEmpty ? "∅" : e.replacement.trimmingCharacters(in: .whitespaces)) "
                            + "[\(m.revertsFix ? "revert" : m.typed != nil ? "own-fix" : e.kind.rawValue)]"
                    }
                    fixes = numbered(RewriteOwnFixes.fixesAfter(fixes, edits: mapped, in: field, capacity: .max))
                    field = FieldRewrite.apply(mapped.map(\.edit), to: field)
                } else {
                    field = FieldRewrite.apply(result.edits, to: field)
                }
                checked = field
                passes.append(PassRecord(target: sent.target.text, revised: pass.revised,
                                         applied: applied,
                                         rejected: result.rejected.map { "\($0.original) → \($0.replacement) [\($0.reason.rawValue)]" },
                                         ms: pass.ms, prefillMs: pass.prefillMs, promptTokens: pass.promptTokens,
                                         reusedTokens: pass.reusedTokens, disputes: passDisputes, arbiterMs: passArbiterMs))
                passTimes.append(pass.ms + (passArbiterMs ?? 0))
            } catch {
                printErr("\(c.id): \(error)")
                failedPasses += 1
            }
        }
        let before = TypoScore.score(c.noisy, output: input), score = TypoScore.score(c.noisy, output: field)
        let spelling = spellingScore(c.noisy, output: field)
        var rec = CaseRecord(id: c.id, set: c.set, surface: c.surface.rawValue, app: c.app, clean: c.noisy.clean,
                             typed: c.noisy.typed, input: input, output: field, passes: passes,
                             fixedBefore: before.fixed.filter { $0 }.count, fixedAfter: score.fixed.filter { $0 }.count,
                             slips: c.noisy.slips.count, broken: score.damaged,
                             extraBefore: extraWords(clean: c.noisy.clean, output: input),
                             extraAfter: extraWords(clean: c.noisy.clean, output: field))
        rec.mode = mode
        rec.spellingFixed = spelling.fixed
        rec.spellingSlips = spelling.slips
        records.append(rec)
        if asTyped == .keepFix {
            // The same, with the fixes the model kept as typed taken back afterwards.
            let back = fixes.filter { $0.id.map(keptTyped.contains) ?? false }
                .map { RewriteEdit(range: $0.range, original: $0.fixed, replacement: $0.typed, kind: .word) }
            var alt = rec
            alt.mode = mode + "+revert"
            alt.output = FieldRewrite.apply(back, to: field)
            let altScore = TypoScore.score(c.noisy, output: alt.output), altSpelling = spellingScore(c.noisy, output: alt.output)
            alt.fixedAfter = altScore.fixed.filter { $0 }.count
            alt.broken = altScore.damaged
            alt.extraAfter = extraWords(clean: c.noisy.clean, output: alt.output)
            alt.spellingFixed = altSpelling.fixed
            alt.passes = []
            records.append(alt)
        }
        if let ownFixDump {
            for f in fixes {
                guard let id = f.id else { continue }
                let typedWords = f.typed.split(separator: " ").map(String.init)
                let line: [String: Any] = [
                    "case": c.id, "set": c.set, "mode": mode, "typed": f.typed, "fixed": f.fixed, "at": f.range.lowerBound,
                    "finder": id < originalFixes, "kept": keptTyped.contains(id), "offered": offered[id] ?? NSNull(),
                    "output": field, "clean": c.noisy.clean,
                    "typedKnown": !typedWords.isEmpty && typedWords.allSatisfy { !speller.isMisspelled($0.trimmingCharacters(in: .punctuationCharacters), languages: ["en"]) },
                    "slipCost": SlipCost.cost(typed: f.typed.lowercased().filter { $0.isLetter || $0.isNumber },
                                              candidate: f.fixed.lowercased().filter { $0.isLetter || $0.isNumber }),
                    "fixedLearned": f.fixed.split(separator: " ").allSatisfy { learnedTerms.contains(String($0).trimmingCharacters(in: .punctuationCharacters).lowercased()) },
                    "fixedCommon": f.fixed.split(separator: " ").allSatisfy { CommonEnglish.contains(String($0).trimmingCharacters(in: .punctuationCharacters).lowercased()) },
                ]
                if let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    ownFixDump.write(d + Data("\n".utf8))
                }
            }
        }
        printErr("[\(mode) \(n + 1)/\(cases.count)] \(c.id): \(rec.fixedBefore)→\(rec.fixedAfter)/\(rec.slips) fixed, broken \(rec.broken), "
                 + "\(passes.map { String(format: "%.0f", $0.ms) }.joined(separator: "/")) ms")
    }
    }
    await host?.unload()

    do {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try records.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n")
            .appending("\n").write(toFile: out + "/rewrite-results.jsonl", atomically: true, encoding: .utf8)
        let judging = judgeSet(records.filter { $0.mode == modes[0] })
        try judging.set.write(toFile: out + "/judge-set.jsonl", atomically: true, encoding: .utf8)
        try judging.key.write(toFile: out + "/judge-key.json", atomically: true, encoding: .utf8)
        var report = rewriteReport(records, model: model ?? replay.paths.joined(separator: ", "), layered: !after.isEmpty)
        if !replay.isEmpty {
            report = "Passes replayed from recordings: \(replayedPasses); run on the model: \(ranPasses)"
                + (unansweredPasses > 0 ? "; **left out (no recording, no model): \(unansweredPasses)**" : "") + ".\n\n" + report
            printErr("passes replayed \(replayedPasses), run \(ranPasses), left out \(unansweredPasses)")
        }
        if arbiterOn {
            func pct(_ v: [Double], _ p: Double) -> Double {
                let s = v.sorted()
                return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
            }
            let verdicts = records.flatMap { $0.passes.flatMap { $0.disputes ?? [] } }
            let line = "Own-fix arbiter (margin \(arbiterMargin), slip weight \(arbiterSlipWeight), kinds "
                + arbiterKinds.map(\.rawValue).sorted().joined(separator: ",") + "): disputes scored live \(scoredDisputes), "
                + "from recordings \(cachedDisputes), unscored \(unscoredDisputes); overruled \(verdicts.filter { $0.verdict != nil }.count). "
                + "Passes with a live score: \(arbiterTimes.count) of \(passTimes.count); scoring ms p50 "
                + String(format: "%.0f", pct(arbiterTimes, 0.5)) + ", p95 " + String(format: "%.0f", pct(arbiterTimes, 0.95))
                + "; pass + scoring ms p50 " + String(format: "%.0f", pct(passTimes, 0.5)) + ", p95 "
                + String(format: "%.0f", pct(passTimes, 0.95)) + ".\n\n"
            report = line + report
            printErr(line)
        }
        if failedPasses > 0 {
            report = "**\(failedPasses) passes failed (model errors): the numbers below miss them.**\n\n" + report
            printErr("\(failedPasses) passes failed")
        }
        try report.write(toFile: out + "/rewrite-report.md", atomically: true, encoding: .utf8)
        printOut(report)
        printErr("wrote \(out)/rewrite-report.md")
    } catch {
        printErr("error: \(error)")
        return ExitCode.failure
    }
    return ExitCode.ok
}

/// Every text the rewrite changed, for blind judges: what was in the field, what the rewrite made of
/// it, and each change. No clean text and no set names: judges look for changes a careful person
/// would never make to their own text, not for missed fixes.
private func judgeSet(_ records: [CaseRecord]) -> (set: String, key: String) {
    struct Item: Encodable { var item: String; var place: String; var before: String; var after: String; var changes: [String] }
    var items: [Item] = []
    for r in records where r.output != r.input {
        let changes = r.passes.flatMap(\.applied).map { $0.replacingOccurrences(of: #" \[[a-z]+\]$"#, with: "", options: .regularExpression) }
        let place = [r.surface, r.app].compactMap { $0 }.joined(separator: " in ")
        items.append(Item(item: r.id, place: place, before: r.input, after: r.output, changes: changes))
    }
    // Stable shuffle and anonymous ids, so nothing says where an item came from; the key maps back.
    items.sort { $0.item.hashValueStable < $1.item.hashValueStable }
    var key: [String: String] = [:]
    for k in items.indices {
        let anon = String(format: "t%03d", k + 1)
        key[anon] = items[k].item
        items[k].item = anon
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (items.compactMap { try? String(decoding: enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n",
            String(decoding: (try? enc.encode(key)) ?? Data(), as: UTF8.self))
}

private func rewriteReport(_ all: [CaseRecord], model: String, layered: Bool) -> String {
    var modeOrder: [String] = []
    for r in all where !modeOrder.contains(r.mode) { modeOrder.append(r.mode) }
    var head: [String] = []
    if modeOrder.count > 1 || modeOrder.first != "app" {
        head = ["## Spelling slips left unfixed, by style switch", "",
                "Every text with the same switches (app: each surface's defaults). Spelling only: capitals, punctuation and "
                + "apostrophes ignored; left-out apostrophes not counted.", "",
                "| switches | spelling slips fixed | left unfixed | clean words broken | texts changed |", "|---|---|---|---|---|"]
        for m in modeOrder {
            let rs = all.filter { $0.mode == m }
            let slips = rs.reduce(0) { $0 + $1.spellingSlips }, fixed = rs.reduce(0) { $0 + $1.spellingFixed }
            head.append("| \(m) | \(fmtPct(fixed, slips)) | \(slips - fixed) | \(rs.reduce(0) { $0 + $1.broken }) | "
                        + "\(rs.filter { $0.output != $0.input }.count) |")
        }
        head.append("")
        head.append("Everything below: switches `\(modeOrder[0])`.")
        head.append("")
    }
    let records = all.filter { $0.mode == modeOrder.first }
    var lines = ["# Whole-field rewrite eval", "",
                 "Model: \((model as NSString).lastPathComponent). Input: \(layered ? "after fix-as-you-type (`--after`)" : "as typed"). "
                 + "A pass runs at every sentence end and at the end of the text; chats keep capitals, punctuation and shorthand.", "",
                 ] + head + [
                 "| set | texts | slips fixed: input → rewrite | clean words broken | extra words: input → rewrite | texts fully right | texts changed |",
                 "|---|---|---|---|---|---|---|"]
    var sets: [String] = []
    for r in records where !sets.contains(r.set) { sets.append(r.set) }
    for set in sets + ["all"] {
        let rs = set == "all" ? records : records.filter { $0.set == set }
        let slips = rs.reduce(0) { $0 + $1.slips }
        lines.append("| \(set) | \(rs.count) | \(fmtPct(rs.reduce(0) { $0 + $1.fixedBefore }, slips)) → "
            + "\(fmtPct(rs.reduce(0) { $0 + $1.fixedAfter }, slips)) | \(rs.reduce(0) { $0 + $1.broken }) | "
            + "\(rs.reduce(0) { $0 + $1.extraBefore }) → \(rs.reduce(0) { $0 + $1.extraAfter }) | "
            + "\(fmtPct(rs.filter { $0.output.split(separator: " ") == $0.clean.split(separator: " ") }.count, rs.count)) | "
            + "\(rs.filter { $0.output != $0.input }.count) |")
    }
    let passes = records.flatMap(\.passes)
    let ms = passes.map(\.ms), pre = passes.map(\.prefillMs)
    lines += ["", "Passes: \(passes.count); time p50 \(fmtMs(percentile(ms, 0.5))) ms, p95 \(fmtMs(percentile(ms, 0.95))) ms, "
              + "max \(fmtMs(ms.max())) ms; prompt prefill p50 \(fmtMs(percentile(pre, 0.5))) ms; prompt tokens reused "
              + "\(fmtPct(passes.reduce(0) { $0 + $1.reusedTokens }, passes.reduce(0) { $0 + $1.promptTokens })).", ""]
    var reasons: [String: Int] = [:]
    for p in passes { for r in p.rejected { reasons[String(r.split(separator: "[").last?.dropLast() ?? ""), default: 0] += 1 } }
    lines.append("Model changes thrown out: " + (reasons.isEmpty ? "none" : reasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) + ".")
    lines += ["", "## Texts the rewrite changed or broke", ""]
    for r in records where r.output != r.input || r.broken > 0 {
        lines.append("- **\(r.id)** (\(r.set)) \(r.fixedBefore)→\(r.fixedAfter)/\(r.slips) fixed, \(r.broken) broken")
        lines.append("  - input: `\(r.input)`")
        lines.append("  - output: `\(r.output)`")
        if r.output.split(separator: " ") != r.clean.split(separator: " ") { lines.append("  - clean: `\(r.clean)`") }
        let applied = r.passes.flatMap(\.applied), rejected = r.passes.flatMap(\.rejected)
        if !applied.isEmpty { lines.append("  - applied: " + applied.joined(separator: "; ")) }
        if !rejected.isEmpty { lines.append("  - thrown out: " + rejected.joined(separator: "; ")) }
    }
    lines += ["", "## Texts still wrong, unchanged by the rewrite", ""]
    for r in records where r.output == r.input && r.fixedAfter < r.slips {
        lines.append("- **\(r.id)** (\(r.set)) `\(r.input)` → clean `\(r.clean)`")
        let rejected = r.passes.flatMap(\.rejected)
        if !rejected.isEmpty { lines.append("  - thrown out: " + rejected.joined(separator: "; ")) }
    }
    return lines.joined(separator: "\n") + "\n"
}
