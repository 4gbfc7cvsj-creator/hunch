// Copy decoding for the whole-field rewrite: the draft lookup (pure), and on the real model the
// same answer as the plain greedy loop in fewer decodes. The model test is skipped when the dev
// models folder is absent.
import Foundation
import HunchCore
import HunchDecode
import HunchModels
import HunchPrompt
import Synchronization
import Testing
@testable import HunchEngine
@testable import HunchLlama

struct LocalRewriterCopyDraftTests {
    @Test func startsWithTheWholeTarget() {
        var cursor = 0
        #expect(LocalRewriter.copyDraft(answer: [], target: [5, 6, 7], cursor: &cursor) == [5, 6, 7])
    }

    @Test func continuesAfterTheMatchedTail() {
        var cursor = 0
        #expect(LocalRewriter.copyDraft(answer: [5, 6], target: [5, 6, 7, 8], cursor: &cursor) == [7, 8])
        #expect(cursor == 2)
    }

    @Test func aFixedWordResyncsOnTheNextMatchingToken() {
        // Target "a b X c d", the answer wrote Y for X and then c: the draft goes on after c.
        var cursor = 2
        #expect(LocalRewriter.copyDraft(answer: [1, 2, 99, 4], target: [1, 2, 3, 4, 5], cursor: &cursor) == [5])
        #expect(cursor == 4)
    }

    @Test func prefersTheOccurrenceNearTheCursor() {
        // "the" appears twice; past the first one the second is the one that continues the copy.
        var cursor = 4
        #expect(LocalRewriter.copyDraft(answer: [9], target: [9, 1, 2, 3, 9, 7], cursor: &cursor) == [7])
    }

    @Test func nothingWhenNoTokenMatches() {
        var cursor = 0
        #expect(LocalRewriter.copyDraft(answer: [42], target: [1, 2, 3], cursor: &cursor).isEmpty)
    }
}

private enum RewriteModel {
    static let name = "gemma-4-E4B-it.i1-Q5_K_M.gguf"
    static var present: Bool { DevModels.exists(name) }
}

@Suite(.serialized, .enabled(if: RewriteModel.present, "dev model not present"))
final class LocalRewriterCopyModelTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }

    static let targets = [
        "i realy think we shoud move the the meeting form monday, its to early",
        "Thanks for the update. I'll send teh report tomorow morning.",
        "Can you check wether the build passed? It failed yesterday becuase of a missing file.",
        "sounds good, see you then",
        "We need to finalise the budget before the end of the month and i havent heard back from finance yet",
    ]

    @Test func copyDecodingGivesTheGreedyAnswerInFewerDecodes() async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        let options = RuntimeOptions(contextTokens: 2048, batchTokens: 512, gpuLayers: -1, loadMode: .mmap,
                                     fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)
        _ = DevModels.noResidency
        await host.load(DevModels.entry(RewriteModel.name), options: options)
        guard case .ready(_, let profile) = await host.state(), let markers = profile.markers else {
            Issue.record("load failed")
            return
        }
        var id: UInt64 = 0
        var plainDecodes = 0, copyDecodes = 0
        for target in Self.targets {
            id += 1
            let request = RewriteRequest(target: target, before: "", surface: .chat, appName: nil, screenWords: [],
                                         fixesCapitals: true, fixesPunctuation: false, keepsShorthand: true)
            let framed = RewriteFramer().frame(request, markers: markers)
            let budget = (target.utf8.count + 2) / 3 * 3 / 2 + 24
            let counts = try await host.withSession(RequestID(id)) { session -> (Int, Int) in
                let tokens = try session.tokenize(framed.segments, addBOS: profile.addsBOS)
                let cold = ReusePlan(action: .coldPrefill, tokensToDecode: tokens.count)
                _ = try session.syncPrompt(tokens, plan: cold)
                var plain: [UInt8] = []
                let p = try LocalRewriter.greedy(session, budget: budget, singleLine: true, into: &plain)
                _ = try session.syncPrompt(tokens, plan: cold)
                let draft = try session.tokenize([PromptSegment(text: target, kind: .content, stability: .perKeystroke)], addBOS: false)
                var copied: [UInt8] = []
                let speculative = try #require(session as? any SpeculativeSession)
                let c = try LocalRewriter.copyDecode(speculative, copying: draft, budget: budget, singleLine: true, into: &copied)
                let a = String(decoding: plain, as: UTF8.self), b = String(decoding: copied, as: UTF8.self)
                print("[rewrite-copy] \(p.decodes) → \(c.decodes) decodes: \(b)")
                #expect(a == b)
                #expect(p.generated == c.generated)
                return (p.decodes, c.decodes)
            }
            plainDecodes += counts.0
            copyDecodes += counts.1
        }
        print("[rewrite-copy] decodes: plain \(plainDecodes), copy \(copyDecodes)")
        #expect(copyDecodes * 2 < plainDecodes)
    }

    /// Scoring right after a pass (on its cache, one speculative decode per reading) gives what a
    /// cold prompt plus step-by-step decoding gives, and the model's own reading scores best.
    @Test func scoringAfterThePassMatchesAColdScore() async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        let options = RuntimeOptions(contextTokens: 2048, batchTokens: 512, gpuLayers: -1, loadMode: .mmap,
                                     fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)
        _ = DevModels.noResidency
        await host.load(DevModels.entry(RewriteModel.name), options: options)
        guard case .ready(_, let profile) = await host.state(), let markers = profile.markers else {
            Issue.record("load failed")
            return
        }
        let ids = Mutex<UInt64>(100)
        let rewriter = LocalRewriter(host: host, nextID: { RequestID(ids.withLock { $0 += 1; return $0 }) })
        let request = RewriteRequest(target: "what teos it mean for the build", before: "", surface: .chat, appName: nil,
                                     screenWords: [], fixesCapitals: true, fixesPunctuation: false, keepsShorthand: true)
        let pass = try await rewriter.rewrite(request)
        print("[rewrite-score] answer: \(pass.revised)")
        let continuations = [" does it mean for the build", " toes it mean for the build"]
        let warm = try await rewriter.score(request, head: "what", continuations: continuations)
        // Cold: the same prompt and head, every continuation stepped token by token.
        let framed = RewriteFramer().frame(request, markers: markers)
        let cold = try await host.withSession(RequestID(999)) { session -> [Float] in
            var segments = framed.segments
            segments.append(PromptSegment(text: "what", kind: .content, stability: .perKeystroke))
            let tokens = try session.tokenize(segments, addBOS: profile.addsBOS)
            var out: [Float] = []
            var buffer: [Float] = []
            for c in continuations {
                _ = try session.syncPrompt(tokens, plan: ReusePlan(action: .coldPrefill, tokensToDecode: tokens.count))
                let tail = try session.tokenize([PromptSegment(text: c, kind: .content, stability: .perKeystroke)], addBOS: false)
                var sum: Float = 0
                for t in tail {
                    try session.logProbs(.primary, into: &buffer)
                    sum += buffer[Int(t)]
                    try session.step([(.primary, t)])
                }
                out.append(sum)
            }
            return out
        }
        print("[rewrite-score] warm \(warm) cold \(cold)")
        #expect(warm.count == 2)
        for (w, c) in zip(warm, cold) { #expect(abs(w - c) < 0.5) }
        #expect(warm[0] > warm[1])
    }
}
