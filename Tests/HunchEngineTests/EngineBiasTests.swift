// Bias pass-through and word scores in LocalCompletionEngine (fake host), plus a real-vocabulary
// overhead measurement when the dev models are mounted.
import Foundation
import HunchCore
@testable import HunchDecode
import HunchLlama
import HunchPrompt
import HunchText
import Testing
@testable import HunchEngine

final class BiasRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [LearnedBias] = []
    func add(_ bias: LearnedBias) { lock.withLock { seen.append(bias) } }
    var all: [LearnedBias] { lock.withLock { seen } }
}

/// A search that returns a fixed scored candidate and records the bias it was given.
struct ScriptedBiasedSearch: BiasedCompletionSearching {
    var text: String
    var spans: [TokenSpan]
    var recorder: BiasRecorder

    func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                onPartial: (Candidate) -> Void) throws -> [Candidate] { [] }

    func searchScored(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                      bias: LearnedBias, onPartial: (Candidate) -> Void) throws -> [ScoredCandidate] {
        recorder.add(bias)
        let candidate = Candidate(text: text, tokens: [], meanLogProb: -0.5, totalLogProb: -1, stop: .wordBudget)
        return [ScoredCandidate(candidate: candidate, spans: spans)]
    }
}

@Suite struct EngineBiasTests {
    @Test func biasIsPassedToTheSearchAndWordScoresFollowTheShownText() async throws {
        let recorder = BiasRecorder()
        let spans = [TokenSpan(byteCount: 8, logProb: -1.0), TokenSpan(byteCount: 3, logProb: -0.5),
                     TokenSpan(byteCount: 4, logProb: -2.0)]
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host, search: {
            ScriptedBiasedSearch(text: " student at UCLA", spans: spans, recorder: recorder)
        })
        var request = makeRequest(1, before: "I am a", maxWords: 2)
        let learned = LearnedBias(entries: [.init(text: " UCLA", weight: 1)], strength: 2)
        request.bias = learned
        let result = try await engine.complete(request) { _ in }
        #expect(recorder.all == [learned])
        // maxWords 2 trims " UCLA": only the aligned words keep scores.
        #expect(result.outcome == .show(" student at"))
        #expect(result.wordScores.map(\.text) == [" student", " at"])
        #expect(result.wordScores.map(\.logProb) == [-1.0, -0.5])
    }

    @Test func searchWithoutScoresLeavesWordScoresEmpty() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host, search: { ScriptedSearch(text: " one two") })
        let result = try await engine.complete(makeRequest(1, before: "Count:")) { _ in }
        #expect(result.wordScores.isEmpty)
    }

    @Test func suppressedResultsCarryNoWordScores() async throws {
        let recorder = BiasRecorder()
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host, search: {
            ScriptedBiasedSearch(text: " .", spans: [TokenSpan(byteCount: 2, logProb: -1)], recorder: recorder)
        })
        let result = try await engine.complete(makeRequest(1, before: "Hi")) { _ in }
        #expect(result.outcome != .show(" ."))
        #expect(result.wordScores.isEmpty)
    }
}

@Suite(.serialized, .enabled(if: DevModels.available, "dev models folder not mounted"))
final class BiasOverheadTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }
    @Test func perStepOverheadOnTheRealVocabulary() async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        await host.load(DevModels.entry(DevModels.base),
                        options: RuntimeOptions(contextTokens: 1024, batchTokens: 256, maxSequences: 2,
                                                idleReleaseAfterSeconds: nil))
        guard case .ready = await host.state() else {
            Issue.record("load failed")
            return
        }
        let words = ["Kubernetes", "Postgres", "Grafana", "OAuth", "Terraform", "Jenkins", "Rustacean", "gRPC"]
        var entries: [LearnedBias.Entry] = []
        for i in 0..<300 {
            let base = words[i % words.count]
            entries.append(.init(text: " " + base + (i < words.count ? "" : String(i)), weight: 0.5 + Float(i % 5) / 10))
        }
        entries.append(.init(text: " Mr Smith", weight: 1))
        let learned = LearnedBias(entries: entries, strength: 2)
        let report: String
        do { report = try await host.withSession(RequestID(1)) { session -> String in
            let vocabulary = session.vocabulary
            let classes = TokenClassCache.shared.classes(for: vocabulary)
            let clock = ContinuousClock()
            let compileStart = clock.now
            let compiled = try #require(CompiledBias.make(vocabulary: vocabulary, classes: classes, entries: learned.entries))
            let compile = clock.now - compileStart
            let cachedStart = clock.now
            _ = CompiledBias.make(vocabulary: vocabulary, classes: classes, entries: learned.entries)
            let cachedLookup = clock.now - cachedStart

            // A typical walk: boundary, partial entries, a word boundary again.
            let pieces = [" I", " use", " Kub", "ernetes", " and", " Mr", " Smith", " for", " Post", "gres"]
            var state = BiasState()
            var worst = Duration.zero
            var total = Duration.zero
            var steps = 0
            var maxMap = 0
            for _ in 0..<20 {
                state = BiasState()
                for piece in pieces {
                    let begin = clock.now
                    let map = compiled.map(state, strength: learned.strength)
                    let elapsed = clock.now - begin
                    maxMap = max(maxMap, map.count)
                    total += elapsed
                    worst = max(worst, elapsed)
                    steps += 1
                    compiled.advance(&state, Array(piece.utf8)[...])
                }
            }
            func ms(_ d: Duration) -> String {
                String(format: "%.3f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            }
            return "[HunchEngine] bias compile=\(ms(compile)) ms cachedLookup=\(ms(cachedLookup)) ms "
                + "vocab=\(vocabulary.count) perStep(map, avg)=\(ms(total / steps)) ms worst=\(ms(worst)) ms "
                + "maxCandidates=\(maxMap)"
        } } catch {
            await host.unload()
            throw error
        }
        print(report)
        await host.unload()  // a model left resident trips ggml-metal's assert at process exit
    }
}
