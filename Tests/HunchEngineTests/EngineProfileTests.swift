// Opt-in latency profile against the dev model (set GT_PROFILE=1). Prints where replay time goes.
import Foundation
import HunchCore
import HunchPrompt
import HunchDecode
import HunchText
import Synchronization
import Testing
@testable import HunchEngine
@testable import HunchLlama

final class TimedSession: LanguageModelSession, @unchecked Sendable {
    let inner: any LanguageModelSession
    var nanos: [String: Int64] = [:]
    init(_ inner: any LanguageModelSession) { self.inner = inner }
    func time<T>(_ k: String, _ f: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { nanos[k, default: 0] += Int64(DispatchTime.now().uptimeNanoseconds - t0) }
        return try f()
    }
    var vocabulary: any VocabularyTable { inner.vocabulary }
    var maxParallelSequences: Int { inner.maxParallelSequences }
    var reuseCapability: ReuseCapability { inner.reuseCapability }
    func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] { try inner.tokenize(segments, addBOS: addBOS) }
    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport { try time("sync") { try inner.syncPrompt(tokens, plan: plan) } }
    func fork(_ source: SeqID, into targets: [SeqID]) throws { try time("fork") { try inner.fork(source, into: targets) } }
    func step(_ appends: [(SeqID, TokenID)]) throws { try time("step") { try inner.step(appends) } }
    func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws { try time("logProbs") { try inner.logProbs(seq, into: &buffer) } }
    func discard(_ seqs: [SeqID]) { time("discard") { inner.discard(seqs) } }
    var isCancellationRequested: Bool { inner.isCancellationRequested }
    var retainedPromptTokens: [TokenID] { inner.retainedPromptTokens }
}
let timedSessions = Mutex<[TimedSession]>([])

final class Acc: Sendable {
    let search = Mutex<Int64>(0)
    let post = Mutex<Int64>(0)
}
struct TimedSearch: BiasedCompletionSearching {
    let inner = GreedyConstrainedSearch()
    let acc: Acc
    func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                onPartial: (Candidate) -> Void) throws -> [Candidate] {
        try inner.search(in: session, requiredPrefix: requiredPrefix, config: config, onPartial: onPartial)
    }
    func searchScored(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                      bias: LearnedBias, onPartial: (Candidate) -> Void) throws -> [ScoredCandidate] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { acc.search.withLock { $0 += Int64(DispatchTime.now().uptimeNanoseconds - t0) } }
        let ts = TimedSession(session)
        timedSessions.withLock { $0.append(ts) }
        return try inner.searchScored(in: ts, requiredPrefix: requiredPrefix, config: config, bias: bias, onPartial: onPartial)
    }
}
struct TimedPost: SuggestionPostProcessing {
    let inner = DefaultPostProcessor()
    let acc: Acc
    func process(_ raw: String, meanLogProb: Float?, context: PostContext) -> PostOutcome {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { acc.post.withLock { $0 += Int64(DispatchTime.now().uptimeNanoseconds - t0) } }
        return inner.process(raw, meanLogProb: meanLogProb, context: context)
    }
}

@Suite(.serialized, .enabled(if: DevModels.available && ProcessInfo.processInfo.environment["GT_PROFILE"] != nil))
final class EngineProfileTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }
    @Test func replayProfile() async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        await host.load(DevModels.entry(DevModels.base), options: RuntimeOptions(idleReleaseAfterSeconds: nil))
        let acc = Acc()
        let engine = LocalCompletionEngine(host: host, search: { TimedSearch(acc: acc) },
                                           postProcessor: TimedPost(acc: acc))
        let texts = ["Hi Sarah, thanks for the update on the project. I", "I am a", "Dear team, the launch",
                     "We should schedule a meeting to discuss the", "The quick brown fox jumps over the"]
        var id: UInt64 = 0
        var totals: [Double] = []
        // Warm up.
        id += 1; _ = try await engine.complete(makeRequest(id, before: texts[0], maxWords: 4)) { _ in }
        id += 1; _ = try await host.withSession(RequestID(id)) { s in (s as! LlamaSession).resetProfile() }
        acc.search.withLock { $0 = 0 }; acc.post.withLock { $0 = 0 }
        for t in texts {
            var typed = t
            for ch in [" the", " b", "e"] {
                typed += ch
                id += 1
                let r = try await engine.complete(makeRequest(id, before: typed, maxWords: 4)) { _ in }
                let d = r.timings.total
                totals.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            }
        }
        id += 1; let p = try await host.withSession(RequestID(id)) { s in (s as! LlamaSession).profile }
        let n = Double(totals.count)
        totals.sort()
        print("[HunchProfile] requests=\(Int(n)) total p50=\(totals[totals.count / 2]) ms mean=\(totals.reduce(0, +) / n)")
        print("[HunchProfile] per request: decode calls=\(Double(p.decodeCalls) / n) tokens=\(Double(p.decodeTokens) / n) "
            + "decode ms=\(Double(p.decodeNanos) / 1e6 / n) gpuWait ms=\(Double(p.gpuWaitNanos) / 1e6 / n) logProbs calls=\(Double(p.logProbCalls) / n) ms=\(Double(p.logProbNanos) / 1e6 / n)")
        print("[HunchProfile] per request: search wall ms=\(Double(acc.search.withLock { $0 }) / 1e6 / n) post ms=\(Double(acc.post.withLock { $0 }) / 1e6 / n)")
        var agg: [String: Int64] = [:]
        for t in timedSessions.withLock({ $0 }) { for (k, v) in t.nanos { agg[k, default: 0] += v } }
        print("[HunchProfile] per request session-call ms: " + agg.sorted { $0.key < $1.key }.map { "\($0.key)=\(Double($0.value) / 1e6 / n)" }.joined(separator: " "))
        await host.unload()
    }
}
