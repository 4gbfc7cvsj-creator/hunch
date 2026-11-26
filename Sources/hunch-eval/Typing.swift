// `typing`: replays realistic typing keystroke by keystroke through the real engine, the way the app
// drives it (a new request per keystroke that doesn't follow the visible ghost; the previous one is
// superseded, and its late result shown when the text typed since is the start of it), and measures
// latency, wasted GPU work, GPU busy % and memory.
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPrompt

struct TypingCase: Codable, Sendable {
    var id: String
    var surface: SurfaceKind
    var app: String?
    var about: String?
    var screen: String?
    /// Text already in the field before typing starts.
    var prefix: String
    /// What is typed, one character per keystroke.
    var text: String
}

/// One request and what became of it.
struct TypingRow: Sendable {
    /// `late`: superseded, but shown because the text typed since its request is the start of it.
    enum Fate: String { case shown, late, suppressed, superseded, failed }
    var caseID: String
    var keystroke: Int
    var id: RequestID
    var fate: Fate = .superseded
    var suppressReason = ""
    var path = ""
    var firstPartialMs: Double?
    var totalMs: Double?
    /// For a late result: from the latest keystroke to the ghost.
    var lateMs: Double?
    /// With `--stream`: when its first checked words showed, and what the final result did to them
    /// (kept, grew, shortened, changed, vanished); empty when nothing streamed was shown.
    var streamFirstMs: Double?
    var streamOutcome = ""
    var framingMs: Double = 0
    var promptSyncMs: Double = 0
    var decodedPromptTokens = 0
    var decodedTokens = 0
    var decodeMs: Double = 0
    var jobFinished = false
}

/// Collects `RequestCost` reports from the engine (they arrive on the executor thread).
final class CostLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var costs: [UInt64: RequestCost] = [:]
    func record(_ cost: RequestCost) { lock.withLock { costs[cost.id.raw] = cost } }
    func cost(_ id: RequestID) -> RequestCost? { lock.withLock { costs[id.raw] } }
}

/// Drives one case: owns the keystroke loop, the visible ghost and the request records.
actor TypingSimulator {
    private let engine: LocalCompletionEngine
    private let counter: RequestCounter
    private let decode: DecodeConfig
    private let typingCase: TypingCase
    private var before: String
    /// The suggestion on screen: what still remains of it, and the request that produced it.
    private var ghost: (remaining: String, id: RequestID)?
    private var latest: RequestID?
    private var inflight: Task<Void, Never>?
    /// Show late results (the app's rule); off reproduces the old latest-only behavior.
    private let allowLate: Bool
    private let stream: Bool
    /// Requests whose stream is on screen now, with the last text shown and when it started.
    private var streaming: [UInt64: (last: String, start: ContinuousClock.Instant)] = [:]
    private var starts: [UInt64: ContinuousClock.Instant] = [:]
    private var requestBefore: [UInt64: String] = [:]
    private var shownID = RequestID(0)
    private var lastKeyAt = ContinuousClock.now
    private(set) var rows: [UInt64: TypingRow] = [:]
    private(set) var ghostReuseKeystrokes = 0

    init(engine: LocalCompletionEngine, counter: RequestCounter, decode: DecodeConfig, typingCase: TypingCase,
         allowLate: Bool, stream: Bool) {
        self.engine = engine
        self.allowLate = allowLate
        self.stream = stream
        self.counter = counter
        self.decode = decode
        self.typingCase = typingCase
        self.before = typingCase.prefix
    }

    func input(_ before: String) -> PromptInput {
        PromptInput(before: before, after: "", surface: typingCase.surface, aboutWriter: typingCase.about,
                    preferredLanguages: Locale.preferredLanguages, maxWords: decode.maxWords, allowNewlines: false,
                    screenContext: typingCase.screen, appName: typingCase.app)
    }

    func request(id: RequestID, before: String, stream: Bool = false) -> CompletionRequest {
        let context = TextContext(app: AppIdentity(bundleID: "eval.typing", pid: 1, localizedName: typingCase.app),
                                  field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                  before: before, after: "", contentSignature: 0)
        return CompletionRequest(id: id, context: context, input: input(before), decode: decode,
                                 streamsCheckedPartials: stream)
    }

    /// Focus: the app prewarms the field's prompt before the first keystroke.
    func prewarm() async {
        await engine.prewarm(request(id: counter.next(), before: before))
    }

    /// One keystroke. A character that continues the visible ghost just shrinks it (no request);
    /// anything else starts a new request and supersedes the one in flight.
    func type(_ character: Character, index: Int) {
        before.append(character)
        lastKeyAt = .now
        if let current = ghost, current.remaining.first == character {
            let rest = String(current.remaining.dropFirst())
            ghostReuseKeystrokes += 1
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                ghost = (rest, current.id)
                return
            }
        }
        ghost = nil
        startRequest(keystroke: index)
    }

    private func startRequest(keystroke: Int) {
        // Like the app: a request already at the model keeps running (the engine aborts it at its next
        // decode step if it can), so a late result can still be shown. Here every request is at the
        // model at once (no typing pause).
        if !allowLate { inflight?.cancel() }
        let id = counter.next()
        requestBefore[id.raw] = before
        engine.cancel(olderThan: id)
        latest = id
        rows[id.raw] = TypingRow(caseID: typingCase.id, keystroke: keystroke, id: id)
        let request = request(id: id, before: before, stream: stream)
        let start = ContinuousClock.now
        starts[id.raw] = start
        let firstPartial = PartialTimer(start: start)
        let stream = self.stream
        inflight = Task { [engine] in
            do {
                let result = try await engine.complete(request) { text in
                    if !text.isEmpty { firstPartial.mark() }
                    if stream { Task { await self.streamed(id: id, text: text) } }
                }
                await self.finished(id: id, result: result, firstPartial: firstPartial.value,
                                    total: milliseconds(ContinuousClock.now - start))
            } catch {
                await self.failed(id: id)
            }
        }
    }

    /// The app's `.partial` rule: the first words only, for the latest request, nothing typed since,
    /// never over another ghost.
    private func streamed(id: RequestID, text: String) {
        guard latest == id, rows[id.raw]?.totalMs == nil, before == requestBefore[id.raw],
              ghost == nil, streaming[id.raw] == nil else { return }
        rows[id.raw]?.streamFirstMs = milliseconds(ContinuousClock.now - (starts[id.raw] ?? .now))
        streaming[id.raw] = (text, starts[id.raw] ?? .now)
        ghost = (text, id)
    }

    private func finished(id: RequestID, result: CompletionResult, firstPartial: Double?, total: Double) {
        guard var row = rows[id.raw] else { return }
        if let streamed = streaming.removeValue(forKey: id.raw) {
            finishStream(id: id, result: result, row: &row, last: streamed.last, total: total, firstPartial: firstPartial)
            rows[id.raw] = row
            return
        }
        row.path = result.path.rawValue
        row.firstPartialMs = firstPartial
        row.totalMs = total
        row.framingMs = milliseconds(result.timings.framing)
        row.promptSyncMs = milliseconds(result.timings.promptSync)
        row.decodedPromptTokens = result.timings.decodedPromptTokens
        let shownText: String? = if case .show(let text) = result.outcome { text } else { nil }
        if latest != id {
            if allowLate, ghost == nil, id.raw > shownID.raw, let text = shownText,
               let rest = lateRemainder(text, requestBefore: requestBefore[id.raw] ?? "") {
                row.fate = .late
                row.lateMs = milliseconds(ContinuousClock.now - lastKeyAt)
                ghost = (rest, id)
                shownID = id
            } else {
                row.fate = .superseded      // a newer keystroke came first: never displayed
            }
        } else if let text = shownText {
            // The app drops a result whose field changed since (typed through a late ghost).
            if before == requestBefore[id.raw] {
                row.fate = .shown
                ghost = (text, id)
                shownID = id
            } else {
                row.fate = .superseded
            }
        } else if case .suppress(let reason) = result.outcome {
            row.fate = .suppressed
            row.suppressReason = reason.rawValue
        }
        rows[id.raw] = row
    }

    /// The final result for a streamed ghost: replaces it (after what was typed since) or hides it.
    private func finishStream(id: RequestID, result: CompletionResult, row: inout TypingRow, last: String,
                              total: Double, firstPartial: Double?) {
        row.path = result.path.rawValue
        row.firstPartialMs = firstPartial
        row.totalMs = total
        row.framingMs = milliseconds(result.timings.framing)
        row.promptSyncMs = milliseconds(result.timings.promptSync)
        row.decodedPromptTokens = result.timings.decodedPromptTokens
        let final: String? = if case .show(let text) = result.outcome { text } else { nil }
        row.streamOutcome = switch final {
        case nil: "vanished"
        case last?: "kept"
        case let text? where text.hasPrefix(last): "grew"
        case let text? where last.hasPrefix(text): "shortened"
        default: "changed"
        }
        if case .suppress(let reason) = result.outcome { row.suppressReason = reason.rawValue }
        // Still on screen only if the ghost is this stream's (not typed past its end).
        guard ghost?.id == id else {
            row.fate = final == nil ? .suppressed : .shown
            return
        }
        let base = requestBefore[id.raw] ?? ""
        let rest: String? = final.flatMap { before == base ? $0 : lateRemainder($0, requestBefore: base) }
        ghost = rest.map { ($0, id) }
        row.fate = final == nil ? .suppressed : .shown
    }

    /// The session's late-result rule: the text typed since the request is the start of `text`.
    private func lateRemainder(_ text: String, requestBefore: String) -> String? {
        guard before.hasPrefix(requestBefore) else { return nil }
        let typed = before.dropFirst(requestBefore.count)
        guard !typed.isEmpty, text.hasPrefix(typed) else { return nil }
        let rest = String(text.dropFirst(typed.count))
        return rest.contains(where: { !$0.isWhitespace }) ? rest : nil
    }

    private func failed(id: RequestID) {
        // Cancellation is the normal fate of a superseded request; other errors count as failed.
        if latest == id { rows[id.raw]?.fate = .failed }
    }

    /// Lets the last request finish (up to `limit`).
    func drain(limit: Duration) async {
        let task = inflight
        let waiter = Task { await task?.value }
        let timeout = Task { try? await Task.sleep(for: limit); waiter.cancel(); task?.cancel() }
        await waiter.value
        timeout.cancel()
    }
}

/// First streamed text time for one request (set from the engine's partial callback).
final class PartialTimer: @unchecked Sendable {
    private let lock = NSLock()
    private let start: ContinuousClock.Instant
    private var first: Double?
    init(start: ContinuousClock.Instant) { self.start = start }
    func mark() { lock.withLock { if first == nil { first = milliseconds(ContinuousClock.now - start) } } }
    var value: Double? { lock.withLock { first } }
}

struct TypingOptions {
    var model = ""
    var casesPath = "eval/typing/cases.jsonl"
    var charsPerSecond = 6.0
    var budget = RuntimeOptions.defaultContextTokens - RuntimeOptions.decodeHeadroom
    var outDir = ""
    var seed: UInt64 = 1
    var allowLate = true
    var stream = false
}

func runTypingCommand(_ args: [String]) async -> Int32 {
    var options = TypingOptions()
    var i = 0
    func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
    while i < args.count {
        switch args[i] {
        case "--model": options.model = value() ?? ""
        case "--cases": options.casesPath = value() ?? options.casesPath
        case "--cps": options.charsPerSecond = value().flatMap(Double.init) ?? options.charsPerSecond
        case "--budget": options.budget = value().flatMap(Int.init) ?? options.budget
        case "--seed": options.seed = value().flatMap(UInt64.init) ?? options.seed
        case "--out": options.outDir = value() ?? ""
        case "--no-late": options.allowLate = false
        case "--stream": options.stream = true
        default:
            printErr("unknown option \(args[i])")
            return ExitCode.usage
        }
        i += 1
    }
    guard !options.model.isEmpty else {
        printErr("usage: hunch-eval typing --model <file.gguf> [--cases eval/typing/cases.jsonl] [--cps 6] "
            + "[--budget N] [--seed N] [--out dir] [--no-late] [--stream]")
        return ExitCode.usage
    }
    do {
        try await typing(options)
        return ExitCode.ok
    } catch {
        printErr("typing: \(error)")
        return ExitCode.failure
    }
}

private func typing(_ options: TypingOptions) async throws {
    let data = try String(contentsOfFile: options.casesPath, encoding: .utf8)
    let cases = try data.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { try JSONDecoder().decode(TypingCase.self, from: Data($0.utf8)) }
    let outDir = options.outDir.isEmpty
        ? "eval/reports/typing-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        : options.outDir
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let entry = makeEntry(path: options.model)
    guard entry.validity == .valid, entry.summary != nil else { throw EvalError("not a usable model: \(options.model)") }
    // The GPU figure covers the whole GPU (display, other apps): measure it idle first.
    let idleSampler = GPUSampler()
    idleSampler.start()
    try await Task.sleep(for: .seconds(5))
    let idleGPU = idleSampler.stop()
    let memoryBefore = ProcessMemory.snapshot()?.physFootprint ?? 0
    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    await host.load(entry, options: evalRuntimeOptions)
    guard case .ready = await host.state() else { throw EvalError("load failed: \(await host.state())") }
    let memoryLoaded = ProcessMemory.snapshot()?.physFootprint ?? 0

    let ledger = CostLedger()
    let engine = LocalCompletionEngine(host: host, postProcessor: makeEvalPostProcessor(typoCheck: true),
                                       promptTokenBudget: options.budget, resultCacheCapacity: 32,
                                       costObserver: { ledger.record($0) })
    var decode = DecodeConfig()
    decode.minWords = LengthPreset.medium.minWords
    decode.maxWords = LengthPreset.medium.maxWords
    decode.allowNewline = false
    let counter = RequestCounter()
    var rng = SplitMix64(seed: options.seed)
    var allRows: [TypingRow] = []
    var reuse: [String: Int] = [:]
    var keystrokes: [String: Int] = [:]

    let gpu = GPUSampler()
    gpu.start()
    let runStart = ContinuousClock.now
    for typingCase in cases {
        let simulator = TypingSimulator(engine: engine, counter: counter, decode: decode, typingCase: typingCase,
                                        allowLate: options.allowLate, stream: options.stream)
        await simulator.prewarm()
        for (index, character) in typingCase.text.enumerated() {
            await simulator.type(character, index: index)
            // Human pace with ±40 % jitter, and a longer pause after punctuation.
            var interval = 1 / options.charsPerSecond * (0.6 + 0.8 * rng.nextUnit())
            if ".,!?。，！？".contains(character) { interval *= 2.5 }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        await simulator.drain(limit: .seconds(5))
        var rows = Array(await simulator.rows.values).sorted { $0.id.raw < $1.id.raw }
        for index in rows.indices {
            if let cost = ledger.cost(rows[index].id) {
                rows[index].decodedTokens = cost.decodedTokens
                rows[index].decodeMs = cost.decodeMilliseconds
                rows[index].jobFinished = cost.finished
            }
        }
        allRows += rows
        reuse[typingCase.id] = await simulator.ghostReuseKeystrokes
        keystrokes[typingCase.id] = typingCase.text.count
        printErr("typed \(typingCase.id): \(typingCase.text.count) keystrokes, \(rows.count) requests")
    }
    let elapsed = milliseconds(ContinuousClock.now - runStart)
    let gpuStats = gpu.stop()
    let memoryAfterRun = ProcessMemory.snapshot()?.physFootprint ?? 0
    await host.unload()
    try? await Task.sleep(for: .seconds(1))
    let memoryUnloaded = ProcessMemory.snapshot()?.physFootprint ?? 0

    try typingCSV(allRows).write(toFile: outDir + "/typing-results.csv", atomically: true, encoding: .utf8)
    let report = typingReport(rows: allRows, cases: cases, reuse: reuse, keystrokes: keystrokes, options: options,
                              model: entry.url.lastPathComponent, elapsedMs: elapsed, gpu: gpuStats, idleGPU: idleGPU,
                              memory: (memoryBefore, memoryLoaded, memoryAfterRun, memoryUnloaded))
    try report.write(toFile: outDir + "/typing-report.md", atomically: true, encoding: .utf8)
    printOut(report)
    printErr("report: \(outDir)/typing-report.md")
}

/// Deterministic jitter for the typing pace.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

func typingCSV(_ rows: [TypingRow]) -> String {
    var out = "case,keystroke,request,fate,suppress_reason,path,first_partial_ms,total_ms,late_ms,framing_ms,prompt_sync_ms,"
        + "decoded_prompt_tokens,decoded_tokens,decode_ms,job_finished,stream_first_ms,stream_outcome\n"
    func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
    for r in rows {
        out += "\(r.caseID),\(r.keystroke),\(r.id.raw),\(r.fate.rawValue),\(r.suppressReason),\(r.path),"
            + "\(f(r.firstPartialMs)),\(f(r.totalMs)),\(f(r.lateMs)),\(f(r.framingMs)),\(f(r.promptSyncMs)),"
            + "\(r.decodedPromptTokens),\(r.decodedTokens),\(f(r.decodeMs)),\(r.jobFinished),\(f(r.streamFirstMs)),\(r.streamOutcome)\n"
    }
    return out
}

func typingReport(rows: [TypingRow], cases: [TypingCase], reuse: [String: Int], keystrokes: [String: Int],
                  options: TypingOptions, model: String, elapsedMs: Double, gpu: (mean: Double, p95: Int, count: Int),
                  idleGPU: (mean: Double, p95: Int, count: Int),
                  memory: (before: UInt64, loaded: UInt64, afterRun: UInt64, unloaded: UInt64)) -> String {
    func pct(_ values: [Double], _ q: Double) -> String {
        let v = values.sorted()
        guard !v.isEmpty else { return "–" }
        return String(format: "%.0f", v[min(v.count - 1, Int(q * Double(v.count)))])
    }
    func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
    let totalKeys = keystrokes.values.reduce(0, +)
    let totalReuse = reuse.values.reduce(0, +)
    let shown = rows.filter { $0.fate == .shown }
    let tokens = rows.reduce(0) { $0 + $1.decodedTokens }
    let wastedSuperseded = rows.filter { $0.fate == .superseded || $0.fate == .failed }.reduce(0) { $0 + $1.decodedTokens }
    let wastedSuppressed = rows.filter { $0.fate == .suppressed }.reduce(0) { $0 + $1.decodedTokens }
    let decodeMs = rows.reduce(0) { $0 + $1.decodeMs }

    var md = "# Typing benchmark\n\n"
    md += "- model: \(model); prompt budget \(options.budget) tokens; n_ctx \(evalRuntimeOptions.contextTokens); "
        + String(format: "%.1f", options.charsPerSecond) + " characters/s (±40 %, seed \(options.seed))\n"
    md += String(format: "- wall time %.1f s for %d keystrokes in %d cases\n", elapsedMs / 1000, totalKeys, cases.count)
    md += "- late results: \(options.allowLate ? "shown when the text typed since is the start of them" : "off (--no-late)")\n"
    md += "- streaming: \(options.stream ? "on (--stream): checked whole words show while the suggestion is written" : "off")\n\n"

    md += "## Requests\n\n| | count | share of keystrokes |\n|---|---|---|\n"
    md += "| keystrokes | \(totalKeys) | |\n"
    md += "| typed through the ghost (no request) | \(totalReuse) | \(totalKeys > 0 ? totalReuse * 100 / totalKeys : 0) % |\n"
    md += "| requests | \(rows.count) | |\n"
    for fate in [TypingRow.Fate.shown, .late, .suppressed, .superseded, .failed] {
        let n = rows.filter { $0.fate == fate }.count
        md += "| \(fate.rawValue) | \(n) | \(totalKeys > 0 ? n * 100 / totalKeys : 0) % |\n"
    }

    md += "\n## Latency of shown suggestions (ms)\n\nThe app shows a suggestion when it is finished (total); the first streamed word is what streaming could show.\n\n| path | n | first streamed word p50 | p95 | total (shown) p50 | p95 | prompt sync p50 |\n|---|---|---|---|---|---|---|\n"
    let paths = ["all"] + Array(Set(shown.map(\.path))).sorted()
    for path in paths {
        let group = path == "all" ? shown : shown.filter { $0.path == path }
        let first = group.compactMap(\.firstPartialMs)
        let total = group.compactMap(\.totalMs)
        md += "| \(path) | \(group.count) | \(pct(first, 0.5)) | \(pct(first, 0.95)) | \(pct(total, 0.5)) | \(pct(total, 0.95)) | "
            + "\(pct(group.map(\.promptSyncMs), 0.5)) |\n"
    }

    let streamedRows = rows.filter { !$0.streamOutcome.isEmpty }
    if !streamedRows.isEmpty {
        let first = streamedRows.compactMap(\.streamFirstMs)
        let counts = Dictionary(grouping: streamedRows, by: \.streamOutcome).mapValues(\.count)
        md += "\nStreamed ghosts (\(streamedRows.count)): first words visible \(pct(first, 0.5)) ms p50 / \(pct(first, 0.95)) ms p95 "
            + "after the request. Final result: "
            + ["kept", "grew", "shortened", "changed", "vanished"].map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ") + ".\n"
    }
    let late = rows.compactMap(\.lateMs)
    if !late.isEmpty {
        md += "\nLate results (\(late.count)): shown \(pct(late, 0.5)) ms p50 / \(pct(late, 0.95)) ms p95 after the latest keystroke.\n"
    }

    md += "\n## GPU work\n\n| | tokens | share | per keystroke |\n|---|---|---|---|\n"
    func row(_ name: String, _ n: Int) -> String {
        "| \(name) | \(n) | \(tokens > 0 ? n * 100 / tokens : 0) % | " + String(format: "%.1f", Double(n) / Double(max(1, totalKeys))) + " |\n"
    }
    md += row("decoded, all requests", tokens)
    md += row("shown", tokens - wastedSuperseded - wastedSuppressed)
    md += row("wasted: superseded or cancelled", wastedSuperseded)
    md += row("wasted: suppressed (nothing shown)", wastedSuppressed)
    md += String(format: "\nModel time (decode + waiting for results): %.1f s of %.1f s wall time (%.0f %%).\n", decodeMs / 1000,
                 elapsedMs / 1000, elapsedMs > 0 ? decodeMs * 100 / elapsedMs : 0)
    md += String(format: "GPU busy (whole GPU, all processes): mean %.0f %%, p95 %d %% while typing; idle before the run: "
                 + "mean %.0f %%, p95 %d %%.\n", gpu.mean, gpu.p95, idleGPU.mean, idleGPU.p95)

    md += "\n## Memory (process footprint)\n\n| before load | loaded | after typing | after unload |\n|---|---|---|---|\n"
    md += "| \(mb(memory.before)) | \(mb(memory.loaded)) | \(mb(memory.afterRun)) | \(mb(memory.unloaded)) |\n"

    md += "\n## Per case\n\n| case | keystrokes | through ghost | requests | shown | late | suppressed | superseded | shown after p50 (ms) | tokens | wasted |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
    for c in cases {
        let r = rows.filter { $0.caseID == c.id }
        let s = r.filter { $0.fate == .shown }
        let w = r.filter { $0.fate != .shown && $0.fate != .late }.reduce(0) { $0 + $1.decodedTokens }
        md += "| \(c.id) | \(keystrokes[c.id] ?? 0) | \(reuse[c.id] ?? 0) | \(r.count) | \(s.count) | "
            + "\(r.filter { $0.fate == .late }.count) | "
            + "\(r.filter { $0.fate == .suppressed }.count) | \(r.filter { $0.fate == .superseded }.count) | "
            + "\(pct(s.compactMap(\.totalMs), 0.5)) | \(r.reduce(0) { $0 + $1.decodedTokens }) | \(w) |\n"
    }
    let reasons = Dictionary(grouping: rows.filter { $0.fate == .suppressed }, by: \.suppressReason).mapValues(\.count)
    if !reasons.isEmpty {
        md += "\nSuppress reasons: " + reasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"
    }
    return md
}
