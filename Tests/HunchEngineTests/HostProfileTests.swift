import Foundation
import HunchCore
import HunchLlama
import HunchPrompt
import Testing
@testable import HunchEngine

@Suite struct HostProfileTests {
    /// Gemma 4 base GGUFs report add_bos_token = false in the header while the loaded vocabulary
    /// adds BOS: the host's profile keeps the detector's markers and takes BOS from the vocabulary.
    @Test func gemma4HeaderSaysNoBOSVocabularyWins() {
        let summary = GGUFSummary(version: 3, architecture: "gemma4", name: "Gemma 4 E4B", addBOS: false)
        let detected = DefaultModelProfileDetector().detect(summary, fileName: "gemma-4-E4B-Q5_K_M.gguf")
        #expect(!detected.addsBOS)
        let resolved = LlamaModelHost.resolveProfile(detected: detected, vocabAddsBOS: true)
        #expect(resolved.addsBOS)
        var expected = detected
        expected.addsBOS = true
        #expect(resolved == expected)
        #expect(resolved.family == .gemma)
    }

    /// The engine tokenizes with the BOS flag of the host ready profile (no second source).
    @Test func engineTakesBOSFromTheHostProfile() async throws {
        for bos in [true, false] {
            var profile = baseProfile
            profile.addsBOS = bos
            let host = FakeHost(profile: profile)
            let engine = LocalCompletionEngine(host: host, search: { ScriptedSearch(text: " one two") })
            _ = try await engine.complete(makeRequest(1, before: "hello")) { _ in }
            let first = host.session.retainedPromptTokens.first
            #expect(bos ? first == 1000 : first != 1000)
        }
    }
}
