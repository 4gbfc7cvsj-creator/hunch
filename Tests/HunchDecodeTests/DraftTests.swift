import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private let v = FakeVocabulary.standard

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let pool: [TokenID] = [" a", " an", " apple", "pple", " banana", " is", " red", " one", " two", " three", ".", ",", "!",
                               " It", " works", " Then", " costs", " e", "g", " Sam", " ok", " hea", " he", " hearing", "ring",
                               "\n", "<eos>", " avid", " engineer", "note"].map { v.id($0) }

private struct Case {
    var steps: [[TokenID: Float]]
    var config: DecodeConfig
    var required: [UInt8]
    var bias: LearnedBias
}

private func makeCase(_ rng: inout SplitMix) -> Case {
    var steps: [[TokenID: Float]] = []
    for _ in 0..<40 {
        var entry: [TokenID: Float] = [:]
        for _ in 0..<Int.random(in: 1...5, using: &rng) {
            entry[pool.randomElement(using: &rng)!] = -Float.random(in: 0.05...4, using: &rng)
        }
        steps.append(entry)
    }
    let config = DecodeConfig(minWords: Int.random(in: 1...3, using: &rng), maxWords: Int.random(in: 2...8, using: &rng),
                              maxTokens: Int.random(in: 3...24, using: &rng), firstTokenFanout: [1, 1, 1, 2, 3].randomElement(using: &rng)!,
                              scoring: Bool.random(using: &rng) ? .sum : .mean,
                              minMeanLogProb: -Float.random(in: 1...6, using: &rng),
                              stopAtSentenceEnd: Bool.random(using: &rng), stopAtComma: Bool.random(using: &rng),
                              allowNewline: Bool.random(using: &rng))
    let required = Array(["", "", " a", " ap", " an", " hea", " he", " ", " b"].randomElement(using: &rng)!.utf8)
    var bias = LearnedBias()
    if Int.random(in: 0..<3, using: &rng) == 0 {
        bias = LearnedBias(entries: [.init(text: " banana", weight: 1), .init(text: " engineer", weight: 0.8)], strength: 3,
                           avoid: [" red"], avoidPenalty: 6)
    }
    return Case(steps: steps, config: config, required: required, bias: bias)
}

private struct Outcome: Equatable {
    var texts: [String]
    var tokens: [[TokenID]]
    var stops: [StopReason]
    var means: [Float]
    var spans: [[Int]]
    var partials: [String]
    var history: [TokenID]
}

private func execute(_ c: Case, draft: [TokenID]?, refuse: Bool = false, cancelAfterLogProbs: Int? = nil) throws
    -> (Outcome, FakeSession) {
    let session = FakeSession(script: [:])
    session.byStep = c.steps
    session.refuseDraft = refuse
    session.cancelAfterLogProbCalls = cancelAfterLogProbs
    if let draft { _ = try session.syncPrompt([], plan: ReusePlan(action: .coldPrefill, tokensToDecode: 0), speculating: draft) }
    var partials: [String] = []
    defer { _ = 0 }
    let result: [ScoredCandidate]
    do {
        result = try GreedyConstrainedSearch().searchScored(in: session, requiredPrefix: c.required, config: c.config,
                                                            bias: c.bias) { partials.append($0.text) }
    } catch {
        // State must be consistent even when the search is cancelled.
        #expect(session.specDraft.isEmpty)
        throw error
    }
    let out = Outcome(texts: result.map(\.candidate.text), tokens: result.map(\.candidate.tokens),
                      stops: result.map(\.candidate.stop), means: result.map(\.candidate.meanLogProb),
                      spans: result.map { $0.spans.map(\.byteCount) }, partials: partials, history: session.history)
    return (out, session)
}

@Suite struct DraftExactnessTests {
    @Test func randomizedCasesMatchThePlainSearch() throws {
        var rng = SplitMix(state: 0xD0A1)
        var accepted = 0
        var savedDecodes = 0
        for _ in 0..<1500 {
            let c = makeCase(&rng)
            let (plain, plainSession) = try execute(c, draft: nil)
            let best = plain.tokens.first ?? []
            var draft: [TokenID]
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: draft = best                                        // perfect draft
            case 1: draft = Array(best.prefix(Int.random(in: 0...max(0, best.count), using: &rng)))
            case 2:                                                     // one wrong token
                draft = best
                if !draft.isEmpty { draft[Int.random(in: 0..<draft.count, using: &rng)] = pool.randomElement(using: &rng)! }
            case 3: draft = best + (0..<Int.random(in: 1...4, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            case 4: draft = (0..<Int.random(in: 1...8, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            default: draft = []
            }
            let (speculated, session) = try execute(c, draft: draft)
            #expect(speculated == plain, "draft \(draft) changed the result")
            #expect(session.specDraft.isEmpty || c.config.firstTokenFanout > 1 || session.steps == 0)
            #expect(session.steps <= plainSession.steps)
            if let kept = session.settledKept.last { accepted += kept }
            savedDecodes += plainSession.steps - session.steps
            // Same outcome when the session refuses the draft.
            let (refused, _) = try execute(c, draft: draft, refuse: true)
            #expect(refused == plain)
        }
        #expect(accepted > 100)
        #expect(savedDecodes > 100)
    }

    @Test func perfectDraftReplacesEveryStepWithOneBatch() throws {
        let session = FakeSession(script: makeScript([
            "": [(" banana", -0.1)], " banana": [(" is", -0.2)], " banana is": [(" red", -0.3)],
        ]))
        _ = try session.syncPrompt([], plan: ReusePlan(action: .coldPrefill, tokensToDecode: 0),
                                   speculating: [v.id(" banana"), v.id(" is"), v.id(" red")])
        let c = try #require(GreedyConstrainedSearch().search(in: session, requiredPrefix: [], config: DecodeConfig(minWords: 1, maxWords: 10, minMeanLogProb: -10)) { _ in }.first)
        #expect(c.text == " banana is red")
        #expect(session.steps == 0)
        #expect(session.history == c.tokens)
        #expect(session.settledKept == [3])
    }

    @Test func rejectedDraftRollsBackToTheAcceptedPrefix() throws {
        let session = FakeSession(script: makeScript([
            "": [(" banana", -0.1)], " banana": [(" is", -0.2)], " banana is": [(" one", -0.3)],
        ]))
        _ = try session.syncPrompt([], plan: ReusePlan(action: .coldPrefill, tokensToDecode: 0),
                                   speculating: [v.id(" banana"), v.id(" is"), v.id(" red")])
        let c = try #require(GreedyConstrainedSearch().search(in: session, requiredPrefix: [], config: DecodeConfig(minWords: 1, maxWords: 10, minMeanLogProb: -10)) { _ in }.first)
        #expect(c.text == " banana is one")
        // " red" was rejected: only two draft tokens are kept, " one" came from a real step.
        #expect(session.settledKept == [2])
        #expect(session.history == c.tokens)
        #expect(session.steps == 1)
    }

    @Test func draftThatContradictsTheRequiredPrefixIsHarmless() throws {
        let c = Case(steps: [[v.id(" apple"): -0.1], [v.id(" is"): -0.2]], config: DecodeConfig(minWords: 1, maxWords: 10, minMeanLogProb: -10),
                     required: Array(" a".utf8), bias: LearnedBias())
        let (plain, _) = try execute(c, draft: nil)
        let (drafted, session) = try execute(c, draft: [v.id(" banana"), v.id(" red")])
        #expect(drafted == plain)
        #expect(session.settledKept == [0])
    }

    @Test func cancellationMidVerifyLeavesNoDraftBehind() throws {
        var rng = SplitMix(state: 77)
        var cancelled = 0
        for _ in 0..<200 {
            let c = makeCase(&rng)
            let (plain, _) = try execute(c, draft: nil)
            let draft = plain.tokens.first ?? []
            do {
                _ = try execute(c, draft: draft, cancelAfterLogProbs: Int.random(in: 1...6, using: &rng))
            } catch is CancellationError {
                cancelled += 1
            }
        }
        #expect(cancelled > 20)
    }
}
