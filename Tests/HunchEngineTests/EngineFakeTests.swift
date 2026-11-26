// LocalCompletionEngine logic against an in-memory fake host/session (no model needed).
import Foundation
import HunchCore
import HunchDecode
import HunchPrompt
import HunchText
import Synchronization
import Testing
@testable import HunchEngine

/// Byte-per-token fake. Tracks its "KV cache" exactly like the real session's contract.
final class FakeSession: LanguageModelSession, @unchecked Sendable {
    struct NoVocabulary: VocabularyTable {
        var count: Int { 256 }
        func bytes(_ id: TokenID) -> ArraySlice<UInt8> { [UInt8(truncatingIfNeeded: id)][...] }
        func traits(_ id: TokenID) -> TokenTraits { [] }
        func admissible(forRequired required: ArraySlice<UInt8>) -> [TokenID] { [] }
    }

    var vocabulary: any VocabularyTable { NoVocabulary() }
    var maxParallelSequences: Int { 1 }
    var reuseCapability: ReuseCapability = .trimSuffix
    var isCancellationRequested = false
    var cached: [TokenID] = []
    var syncCalls = 0
    var lastPlan: ReusePlan?
    /// When set, the next sync keeps the reusable prefix, decodes this many more tokens, then
    /// throws `CancellationError` (like a superseded llama decode).
    var failNextSyncAfter: Int?

    func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] {
        (addBOS ? [1000] : []) + segments.flatMap { $0.text.utf8.map { TokenID($0) } }
    }

    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
        syncCalls += 1
        lastPlan = plan
        var keep: Int
        switch plan.action {
        case .appendOnly(let k), .trimAndAppend(let k): keep = k
        default: keep = 0
        }
        let lcp = zip(cached, tokens).prefix { $0 == $1 }.count
        keep = max(0, min(keep, lcp, tokens.count - 1))
        if let extra = failNextSyncAfter {
            failNextSyncAfter = nil
            cached = Array(tokens.prefix(min(tokens.count, keep + extra)))
            throw CancellationError()
        }
        cached = tokens
        return PromptSyncReport(decodedTokens: tokens.count - keep, reusedTokens: keep, duration: .zero)
    }

    func fork(_ source: SeqID, into targets: [SeqID]) throws {}
    func step(_ appends: [(SeqID, TokenID)]) throws {}
    func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {}
    func discard(_ seqs: [SeqID]) {}
}

extension FakeSession {
    var retainedPromptTokens: [TokenID] { cached }
}

final class FakeHost: ModelHosting, @unchecked Sendable {
    var session = FakeSession()
    var loadState: ModelLoadState
    var cancelSupersededBodies = false
    var cancelledBelow: RequestID?
    let profile: ModelProfile

    init(profile: ModelProfile) {
        self.profile = profile
        loadState = .ready(ModelEntryID(relativePath: "fake.gguf"), profile)
    }

    func state() async -> ModelLoadState { loadState }
    func states() -> AsyncStream<ModelLoadState> { AsyncStream { $0.finish() } }
    func load(_ entry: ModelEntry, options: RuntimeOptions) async {}
    func unload() async {}
    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        if let below = cancelledBelow, id < below { throw CancellationError() }
        // Like the real host: a job after an idle release reloads the model first.
        if case .releasedIdle(let id) = loadState { loadState = .ready(id, profile) }
        jobDepth.withLock { $0 += 1 }
        defer { jobDepth.withLock { $0 -= 1 } }
        return try body(session)
    }
    /// Number of `withSession` bodies currently running (the stand-in for "inside the executor job").
    let jobDepth = Mutex(0)
    var insideJob: Bool { jobDepth.withLock { $0 > 0 } }
    func cancel(olderThan id: RequestID) { cancelledBelow = id }
}

/// Emits a fixed candidate (streamed word by word) without touching the model.
struct ScriptedSearch: CompletionSearching {
    var text: String
    var meanLogProb: Float = -0.5
    var stop: StopReason = .wordBudget

    func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                onPartial: (Candidate) -> Void) throws -> [Candidate] {
        var shown = ""
        for piece in text.split(separator: " ", omittingEmptySubsequences: false).dropFirst() {
            shown += " " + piece
            onPartial(Candidate(text: shown, tokens: [], meanLogProb: meanLogProb, totalLogProb: 0, stop: .inProgress))
        }
        let tokens = text.utf8.map { TokenID($0) }
        return [Candidate(text: text, tokens: tokens, meanLogProb: meanLogProb,
                          totalLogProb: meanLogProb * Float(tokens.count), stop: stop)]
    }
}

let baseProfile = ModelProfile(family: .gemma, isInstruct: false, markers: nil, addsBOS: true, contextLength: 8192,
                               slidingWindow: nil, architecture: "gemma4", displayName: "fake")

func makeRequest(_ id: UInt64, before: String, maxWords: Int = 4, prewarm: Bool = false) -> CompletionRequest {
    let context = TextContext(app: AppIdentity(bundleID: "test", pid: 1, localizedName: nil),
                              field: FieldID(pid: 1, elementHash: 1, generation: 1),
                              before: before, after: "", contentSignature: 0)
    return CompletionRequest(id: RequestID(id), context: context,
                             input: PromptInput(before: before, maxWords: maxWords),
                             decode: DecodeConfig(maxWords: maxWords), prewarmOnly: prewarm)
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Suite struct EngineFakeTests {
    @Test func freshThenReuseWithSmallDelta() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " student at UCLA") })
        let first = try await engine.complete(makeRequest(1, before: "I am a")) { _ in }
        #expect(first.path == .fresh)
        #expect(first.outcome == .show(" student at UCLA"))
        #expect(first.timings.firstVisible != nil)
        #expect(first.timings.total >= first.timings.promptSync)

        let second = try await engine.complete(makeRequest(2, before: "I am a big")) { _ in }
        #expect(second.path == .reuse)
        #expect(second.timings.decodedPromptTokens < 10)
        #expect(second.timings.decodedPromptTokens < first.timings.decodedPromptTokens)
    }

    @Test func partialsStreamUnprocessed() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " one two three") })
        let seen = Collected()
        _ = try await engine.complete(makeRequest(1, before: "Count:")) { seen.add($0) }
        #expect(seen.all == [" one", " one two", " one two three"])
    }

    @Test func aiVoiceIsSuppressed() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " bot.") })
        let result = try await engine.complete(makeRequest(1, before: "I am a")) { _ in }
        #expect(result.outcome == .suppress(.aiVoice))
    }

    @Test func lowConfidenceStopAndFloorSuppress() async throws {
        let host = FakeHost(profile: baseProfile)
        let stopped = LocalCompletionEngine(host: host, search: {
            ScriptedSearch(text: " maybe so", stop: .lowConfidence)
        })
        #expect(try await stopped.complete(makeRequest(1, before: "Well")) { _ in }.outcome
            == .suppress(.lowConfidence))
        let floored = LocalCompletionEngine(host: host, search: {
            ScriptedSearch(text: " maybe so", meanLogProb: -1.5)
        }, confidenceFloor: -1.0)
        #expect(try await floored.complete(makeRequest(2, before: "Well")) { _ in }.outcome
            == .suppress(.lowConfidence))
    }

    @Test func coldWhenHostReleasedOrSessionReplaced() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " there") })
        _ = try await engine.complete(makeRequest(1, before: "Hi")) { _ in }
        host.session = FakeSession()  // a reload creates a new session
        #expect(try await engine.complete(makeRequest(2, before: "Hi")) { _ in }.path == .cold)
        host.loadState = .releasedIdle(ModelEntryID(relativePath: "fake.gguf"))
        #expect(try await engine.complete(makeRequest(3, before: "Hi")) { _ in }.path == .cold)
    }

    /// Regression (2026-10-16): the model was idle-released before the engine's first request, so
    /// the engine had never seen a `.ready` profile and every request failed with `.notLoaded`.
    @Test func releasedBeforeFirstRequestStillCompletes() async throws {
        let host = FakeHost(profile: baseProfile)
        host.loadState = .releasedIdle(ModelEntryID(relativePath: "fake.gguf"))
        let engine = LocalCompletionEngine(host: host, search: { ScriptedSearch(text: " there") })
        let result = try await engine.complete(makeRequest(1, before: "Hi")) { _ in }
        #expect(result.outcome == .show(" there"))
        #expect(result.path == .cold)
        await engine.prewarm(makeRequest(2, before: "Hi"))  // prewarm takes the same path
    }

    @Test func prewarmSyncsWithoutSearching() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " unused") })
        await engine.prewarm(makeRequest(1, before: "Dear team,"))
        #expect(host.session.syncCalls == 1)
        let result = try await engine.complete(makeRequest(2, before: "Dear team, I")) { _ in }
        #expect(result.path == .reuse)
        #expect(result.timings.decodedPromptTokens <= 3)
    }

    @Test func failedSyncKeepsRetainedPrefixForNextPlan() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " soon") })
        _ = try await engine.complete(makeRequest(1, before: "See you at the station")) { _ in }
        host.session.failNextSyncAfter = 2
        await #expect(throws: CancellationError.self) {
            _ = try await engine.complete(makeRequest(2, before: "See you at the station tomorrow")) { _ in }
        }
        let retained = host.session.cached.count
        #expect(retained > 0)

        let next = try await engine.complete(makeRequest(3, before: "See you at the station tomorrow at")) { _ in }
        switch host.session.lastPlan?.action {
        case .appendOnly(let keep), .trimAndAppend(let keep):
            #expect(keep > 0 && keep <= retained)
        default:
            Issue.record("expected a reuse plan after a failed sync, got \(String(describing: host.session.lastPlan))")
        }
        #expect(next.path == .reuse)
    }

    @Test func failedSyncFallbackWithoutReporterKeepsCommonPrefix() {
        final class Plain: LanguageModelSession {
            var vocabulary: any VocabularyTable { FakeSession.NoVocabulary() }
            var maxParallelSequences: Int { 1 }
            var reuseCapability: ReuseCapability { .trimSuffix }
            var isCancellationRequested: Bool { false }
            func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] { [] }
            func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
                PromptSyncReport(decodedTokens: 0, reusedTokens: 0, duration: .zero)
            }
            func fork(_ source: SeqID, into targets: [SeqID]) throws {}
            func step(_ appends: [(SeqID, TokenID)]) throws {}
            func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {}
            func discard(_ seqs: [SeqID]) {}
        }
        let cache = SessionCache()
        cache.tokens = [1, 2, 3, 4, 5]
        cache.recordAfterFailure(session: Plain(), attempted: [1, 2, 3, 9])
        #expect(cache.tokens == [1, 2, 3])
        let fake = FakeSession()
        fake.cached = [7, 8]
        cache.recordAfterFailure(session: fake, attempted: [1, 2])
        #expect(cache.tokens == [7, 8])
    }

    @Test func cancellationPropagates() async throws {
        let host = FakeHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " x") })
        engine.cancel(olderThan: RequestID(5))
        await #expect(throws: CancellationError.self) {
            _ = try await engine.complete(makeRequest(4, before: "Hi")) { _ in }
        }
    }
}

final class FlagBox: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var value: Bool { flag.withLock { $0 } }
}

/// Records whether it ran while the host's session job was active.
private struct JobProbePost: SuggestionPostProcessing {
    let host: FakeHost
    let sawInsideJob: FlagBox
    let result: PostOutcome
    func process(_ raw: String, meanLogProb: Float?, context: PostContext) -> PostOutcome {
        if host.insideJob { sawInsideJob.set() }
        return result
    }
}

@Suite struct EnginePostProcessingPlacementTests {
    /// Post-processing may hop to the main thread (spell checker); it must never run inside the
    /// executor job, or a main thread blocked on the executor would deadlock.
    @Test func postProcessingRunsAfterTheSessionJob() async throws {
        let host = FakeHost(profile: baseProfile)
        let flag = FlagBox()
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " one two") },
                                           postProcessor: JobProbePost(host: host, sawInsideJob: flag,
                                                                       result: .show(" one two")))
        let result = try await engine.complete(makeRequest(1, before: "Count:")) { _ in }
        #expect(result.outcome == .show(" one two"))
        #expect(flag.value == false)
    }

    @Test func typoSuppressionIsNotCached() async throws {
        let host = FakeHost(profile: baseProfile)
        let flag = FlagBox()
        let engine = LocalCompletionEngine(host: host,
                                           search: { ScriptedSearch(text: " one two") },
                                           postProcessor: JobProbePost(host: host, sawInsideJob: flag,
                                                                       result: .suppress(.likelyTypo)),
                                           resultCacheCapacity: 8)
        let first = try await engine.complete(makeRequest(1, before: "Count:")) { _ in }
        let second = try await engine.complete(makeRequest(2, before: "Count:")) { _ in }
        #expect(first.outcome == .suppress(.likelyTypo))
        #expect(second.path != .cache)
    }
}

/// Counts post-processor calls; shows everything.
private final class CountingProcessor: SuggestionPostProcessing, @unchecked Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func process(_ raw: String, meanLogProb: Float?, context: PostContext) -> PostOutcome {
        calls.withLock { $0 += 1 }
        return .show(raw)
    }
}

private final class Sink: Sendable {
    private let items = Mutex<[String]>([])
    var values: [String] { items.withLock { $0 } }
    func add(_ text: String) { items.withLock { $0.append(text) } }
}

@Suite struct PartialCheckerTests {
    private func make(_ processor: CountingProcessor, delivered: Sink) -> PartialChecker {
        PartialChecker(input: PromptInput(before: "Hi"), decode: DecodeConfig(),
                       postProcessor: processor) { text in delivered.add(text) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func checksOnlyAtWordBoundariesAndDeliversOnce() async {
        let processor = CountingProcessor()
        let delivered = Sink()
        let checker = make(processor, delivered: delivered)
        for raw in [" he", " hell", " hello"] { checker.offer(raw, requiredPrefix: "") }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(processor.count == 0)
        #expect(delivered.values.isEmpty)
        checker.offer(" hello wor", requiredPrefix: "")
        await waitUntil { !delivered.values.isEmpty }
        #expect(delivered.values == [" hello"])
        checker.offer(" hello world and", requiredPrefix: "")
        checker.stop()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(delivered.values.count == 1)
        #expect(processor.count == 1)
    }

    @Test func offerCostIsSmall() {
        let checker = make(CountingProcessor(), delivered: Sink())
        checker.stop()
        let took = ContinuousClock().measure {
            for i in 0..<10_000 { checker.offer(String(repeating: "word ", count: 20) + "w\(i)", requiredPrefix: "") }
        }
        #expect(took < .seconds(1))
    }
}
