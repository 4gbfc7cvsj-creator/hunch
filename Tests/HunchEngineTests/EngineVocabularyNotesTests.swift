// Gated learned-word notes: instruct models (framer lists vocabulary) keep only the mid-word bias,
// base models keep the full bias, also when the model was idle-released and reloads first.
import Foundation
import HunchCore
import HunchLlama
import Testing
@testable import HunchEngine

@Suite struct EngineVocabularyNotesTests {
    let full = LearnedBias(entries: [.init(text: "Microspikes", weight: 1), .init(text: " Riley", weight: 0.3)], strength: 3)

    func request(_ id: UInt64, before: String) -> CompletionRequest {
        var r = makeRequest(id, before: before)
        r.bias = full
        r.input.vocabulary = ["microspikes"]
        return r
    }

    /// Released before the first suggestion: the reload decides the framer, and the bias follows it.
    @Test func instructAfterIdleReleaseKeepsOnlyMidWordBias() async throws {
        let recorder = BiasRecorder()
        let host = ReloadingHost(profile: instructProfile)
        let engine = LocalCompletionEngine(host: host, search: { ScriptedBiasedSearch(text: "ospikes", spans: [], recorder: recorder) })
        let first = Task { try await engine.complete(request(1, before: "I lent my micr")) { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        host.finishLoad()
        _ = try await first.value
        #expect(recorder.all.last?.entries.map(\.text) == ["Microspikes"])
        #expect(recorder.all.last?.strength == 3)

        // Released again and reloaded: same choice, from the remembered profile.
        host.releaseIdle()
        let second = Task { try await engine.complete(request(2, before: "I lent my microsp")) { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        host.finishLoad()
        _ = try await second.value
        #expect(recorder.all.last?.entries.map(\.text) == ["Microspikes"])
    }

    @Test func baseModelKeepsTheFullBias() async throws {
        let recorder = BiasRecorder()
        let host = ReloadingHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host, search: { ScriptedBiasedSearch(text: "ospikes", spans: [], recorder: recorder) })
        let first = Task { try await engine.complete(request(1, before: "I lent my micr")) { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        host.finishLoad()
        _ = try await first.value
        #expect(recorder.all.last == full)
    }

    @Test func learnedWordsInPlayJoinNotesAndBias() {
        var input = PromptInput(before: "x")
        input.vocabulary = ["Emma"]
        #expect(LocalCompletionEngine.learnedWords(input: input, bias: full) == ["Emma", "Microspikes", "Riley"])
        #expect(LocalCompletionEngine.learnedWords(input: input, bias: LearnedBias()) == ["Emma"])
    }
}
