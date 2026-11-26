// Prewarm against the real model: it prefills without decoding and a real request supersedes it.
import Foundation
import HunchCore
import HunchPrompt
import Testing
@testable import HunchEngine
@testable import HunchLlama

@Suite(.serialized, .enabled(if: DevModels.available, "dev models folder not mounted"))
final class EnginePrewarmModelTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }
    @Test func prewarmPrefillsThenRequestDecodesAlmostNothing() async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        await host.load(DevModels.entry(DevModels.base), options: RuntimeOptions(idleReleaseAfterSeconds: nil))
        let engine = LocalCompletionEngine(host: host)
        let text = "Hi Sarah, thanks for the update on the project. I will send the"
        await engine.prewarm(makeRequest(1, before: text, prewarm: true))
        let real = try await engine.complete(makeRequest(2, before: text)) { _ in }
        #expect(real.path == .reuse)
        #expect(real.timings.decodedPromptTokens <= 1)

        // A real request issued right after a prewarm supersedes it: the prewarm ends quietly and the
        // request still completes against a consistent cache.
        let warm = Task { await engine.prewarm(makeRequest(3, before: text + " report", prewarm: true)) }
        let after = try await engine.complete(makeRequest(4, before: text + " report")) { _ in }
        await warm.value
        #expect(after.timings.decodedPromptTokens <= 4)
        await host.unload()
    }
}
