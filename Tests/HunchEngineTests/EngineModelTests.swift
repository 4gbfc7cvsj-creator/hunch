// End-to-end LocalCompletionEngine runs against the dev models. Skipped when the drive is absent.
// Prints an outcome/timing table; the only content assertion is that "I am a" is never shown as AI voice.
import Foundation
import HunchCore
import HunchModels
import HunchPrompt
import HunchText
import Testing
@testable import HunchEngine
@testable import HunchLlama

enum DevModels {
    static let folder = "/Volumes/Samsung 1TB/LLM/GhostType"
    static let base = "gemma-4-E4B.i1-Q5_K_M.gguf"
    static let instruct = "gemma-4-E4B-it-Q5_K_M.gguf"
    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder + "/" + name) }
    /// The base model is required; the instruct model is tested only when it's present.
    /// ggml-metal asserts at process exit (`[rsets->data count] == 0`) when any model buffer is still
    /// registered in a Metal residency set: a test that returns before unloading, or an exit-time
    /// unload slowed by other test processes, aborted the whole run. Residency sets only keep memory
    /// wired between decodes (a speed hint), so test runs turn them off before the first load.
    /// Read at the first check of `available`, which the suites' `.enabled` trait does up front.
    static let noResidency: Void = { setenv("GGML_METAL_NO_RESIDENCY", "1", 1) }()
    static var available: Bool { _ = noResidency; return exists(base) }
    static var present: [String] { [base, instruct].filter(exists) }

    static func entry(_ name: String) -> ModelEntry {
        _ = noResidency
        let url = URL(fileURLWithPath: folder + "/" + name)
        let (validity, summary) = GGUFInspector().inspect(url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ModelEntry(id: ModelEntryID(relativePath: name), url: url,
                          byteSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                          validity: validity, summary: summary)
    }
}

private func ms(_ d: Duration?) -> String {
    guard let d else { return "-" }
    let value = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%.0f", value)
}

private func describe(_ outcome: PostOutcome) -> String {
    switch outcome {
    case .show(let text): return "show \"\(text)\""
    case .suppress(let reason): return "suppress(\(reason.rawValue))"
    }
}

@Suite(.serialized, .enabled(if: DevModels.available, "dev models folder not mounted"))
final class EngineModelTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }
    static let phrases: [(String, String)] = [
        ("I am a", "I am a big"),
        ("Hi Sarah, thanks for the update on the project. I", "Hi Sarah, thanks for the update on the project. I think"),
        ("今天天气很好，我们", "今天天气很好，我们一起"),
    ]

    @Test(arguments: DevModels.present)
    func endToEnd(_ model: String) async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        let options = RuntimeOptions(contextTokens: 2048, batchTokens: 512, gpuLayers: -1, loadMode: .mmap,
                                     fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)
        let loadStart = ContinuousClock.now
        await host.load(DevModels.entry(model), options: options)
        guard case .ready(_, let hostProfile) = await host.state() else {
            Issue.record("load failed: \(await host.state())")
            return
        }
        let loadTime = ContinuousClock.now - loadStart
        let engine = LocalCompletionEngine(host: host)
        let framer = DefaultFramerRegistry().framer(for: hostProfile, override: nil).id
        var lines = ["[HunchEngine] \(model) framer=\(framer) instruct=\(hostProfile.isInstruct) load=\(ms(loadTime)) ms",
                     "  before | outcome | path | framing/sync/firstVisible/total ms | promptTokens decoded"]
        var id: UInt64 = 0
        let classifier = DefaultAIVoiceClassifier()

        func run(_ before: String) async throws -> CompletionResult {
            id += 1
            let request = makeRequest(id, before: before, maxWords: 4)
            let lastPartial = Collected()
            let result = try await engine.complete(request) { lastPartial.add($0) }
            let t = result.timings
            let raw = result.outcome.isShow ? "" : " (raw \"\(lastPartial.all.last ?? "")\")"
            lines.append("  \(before.suffix(28)) | \(describe(result.outcome))\(raw) | \(result.path.rawValue) | "
                + "\(ms(t.framing))/\(ms(t.promptSync))/\(ms(t.firstVisible))/\(ms(t.total)) | \(t.decodedPromptTokens)")
            if case .show(let text) = result.outcome, before == "I am a" {
                #expect(!classifier.isAIVoice(before: before, completion: text))
            }
            return result
        }

        for (first, extended) in Self.phrases {
            _ = try await run(first)
            let second = try await run(extended)
            #expect(second.path == .reuse)
        }

        // Prewarm, then a completion of the same prompt decodes almost nothing.
        id += 1
        await engine.prewarm(makeRequest(id, before: "Dear team, the launch", prewarm: true))
        _ = try await run("Dear team, the launch")

        // Idle release → the next request reloads (cold path).
        host.releaseNow()
        for await state in host.states() {
            if case .releasedIdle = state { break }
        }
        _ = try await run("I am a")

        print(lines.joined(separator: "\n"))
        await host.unload()
    }
}

extension PostOutcome {
    fileprivate var isShow: Bool {
        if case .show = self { return true }
        return false
    }
}
