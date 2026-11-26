// `memory`: process footprint across load, completions, idle release, reload and unload, per load
// mode, over several cycles (does the residue after a release stay flat or grow?).
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPrompt

func runMemoryCommand(_ args: [String]) async -> Int32 {
    var model = ""
    var cycles = 3
    var completions = 6
    var idleSeconds = 3.0
    var modes: [ModelLoadMode] = [.mmap, .memory]
    var relief = false
    var i = 0
    func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
    while i < args.count {
        switch args[i] {
        case "--model": model = value() ?? ""
        case "--cycles": cycles = value().flatMap(Int.init) ?? cycles
        case "--completions": completions = value().flatMap(Int.init) ?? completions
        case "--idle": idleSeconds = value().flatMap(Double.init) ?? idleSeconds
        case "--relief": relief = true
        case "--mode": modes = value().flatMap(ModelLoadMode.init(rawValue:)).map { [$0] } ?? modes
        default:
            printErr("unknown option \(args[i])")
            return ExitCode.usage
        }
        i += 1
    }
    guard !model.isEmpty else {
        printErr("usage: hunch-eval memory --model <file.gguf> [--mode mmap|memory] [--cycles 3] [--completions 6] [--idle 3] [--relief]")
        return ExitCode.usage
    }
    let entry = makeEntry(path: model)
    guard entry.validity == .valid, entry.summary != nil else {
        printErr("not a usable model: \(model)")
        return ExitCode.failure
    }
    func mb() -> String {
        String(format: "%.0f", Double(ProcessMemory.snapshot()?.physFootprint ?? 0) / 1_048_576)
    }
    var md = "| mode | cycle | before load | loaded | after \(completions) completions | after idle release | after reload + 1 | after unload |\n"
    md += "|---|---|---|---|---|---|---|---|\n"
    let texts = ["Thanks for the quick reply, I will", "The meeting is moved to Thursday because",
                 "Could you send me the report before", "We should probably start with the",
                 "I think the main problem is that", "Let me know if you have any"]
    var nextID: UInt64 = 0
    for mode in modes {
        for cycle in 1...cycles {
            var row = "| \(mode.rawValue) | \(cycle) | \(mb()) | "
            var options = evalRuntimeOptions
            options.loadMode = mode
            options.idleReleaseAfterSeconds = idleSeconds
            let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
            let loadStart = ContinuousClock.now
            await host.load(entry, options: options)
            printErr("load \(mode.rawValue) cycle \(cycle): \(ContinuousClock.now - loadStart)")
            guard case .ready = await host.state() else {
                printErr("load failed: \(await host.state())")
                return ExitCode.failure
            }
            row += "\(mb()) | "
            let engine = LocalCompletionEngine(host: host, postProcessor: makeEvalPostProcessor(typoCheck: false),
                                               promptTokenBudget: RuntimeOptions.defaultContextTokens - RuntimeOptions.decodeHeadroom,
                                               resultCacheCapacity: 0)
            func complete(_ before: String) async {
                nextID += 1
                let context = TextContext(app: AppIdentity(bundleID: "eval.memory", pid: 1, localizedName: "Mail"),
                                          field: FieldID(pid: 1, elementHash: 1, generation: 1),
                                          before: before, after: "", contentSignature: 0)
                let input = PromptInput(before: before, after: "", surface: .email, preferredLanguages: ["en"],
                                        maxWords: 8, allowNewlines: false, appName: "Mail")
                var decode = DecodeConfig()
                decode.allowNewline = false
                _ = try? await engine.complete(CompletionRequest(id: RequestID(nextID), context: context, input: input,
                                                                 decode: decode)) { _ in }
            }
            for n in 0..<completions { await complete(texts[n % texts.count]) }
            row += "\(mb()) | "
            // Idle release: wait until the host has freed the model on its own.
            let deadline = ContinuousClock.now + .seconds(idleSeconds + 10)
            while ContinuousClock.now < deadline {
                if case .releasedIdle = await host.state() { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            let released: Bool = if case .releasedIdle = await host.state() { true } else { false }
            row += (released ? mb() : "not released") + " | "
            await complete(texts[0])
            row += "\(mb()) | "
            await host.unload()
            try? await Task.sleep(for: .seconds(1))
            row += "\(mb())"
            if relief {
                // Ask malloc to return freed pages: a drop means allocator caching, not a leak.
                malloc_zone_pressure_relief(nil, 0)
                try? await Task.sleep(for: .milliseconds(500))
                row += " (relief: \(mb()))"
            }
            row += " |"
            md += row + "\n"
            printErr("memory \(mode.rawValue) cycle \(cycle) done")
        }
    }
    printOut("Process footprint (MB, phys_footprint):\n\n" + md)
    return ExitCode.ok
}
