import HunchCore
@testable import HunchDecode

/// Byte-level toy vocabulary. Every token's bytes and traits are explicit.
struct FakeVocabulary: VocabularyTable {
    var entries: [(bytes: [UInt8], traits: TokenTraits)]

    var count: Int { entries.count }
    func bytes(_ id: TokenID) -> ArraySlice<UInt8> { entries[Int(id)].bytes[...] }
    func traits(_ id: TokenID) -> TokenTraits { entries[Int(id)].traits }
    func admissible(forRequired required: ArraySlice<UInt8>) -> [TokenID] {
        entries.indices.compactMap { i in
            let b = entries[i].bytes
            let n = min(b.count, required.count)
            return b[..<n].elementsEqual(required.prefix(n)) ? TokenID(i) : nil
        }
    }

    static let standard: FakeVocabulary = {
        var e: [(bytes: [UInt8], traits: TokenTraits)] = [
            (Array("<eos>".utf8), [.control, .endOfGeneration]),
            (Array("<|turn>".utf8), [.control]),
            (Array("<unused0>".utf8), [.control, .unused]),
            ([0xE4], [.byteFallback, .invalidUTF8Alone]),
            (Array("\n".utf8), [.containsNewline]),
            ([], []),
            ([0xE6, 0x88], [.invalidUTF8Alone]),   // first two bytes of 我
            ([0x91], [.invalidUTF8Alone]),         // last byte of 我
            ([0xF0, 0x9F], [.invalidUTF8Alone]),   // first half of 😀
            ([0x98, 0x80], [.invalidUTF8Alone]),   // second half of 😀
        ]
        let words = [" ", " a", " an", " apple", "pple", " banana", " is", " red", " one", " two", " three", " four",
                     ".", ",", "!", "?", " It", " works", " Then", " costs", " 3", "14", " Mr", " Smith", " e", "g",
                     " Thanks", " Sam", " ok", "。", "好", "的", "我", "们", "今", "天", ".\n", " zz",
                     // appended for the word-boundary tests (keep earlier ids stable)
                     "note", " another", " engineer", " hea", " he", " hearing", "ring", "aring", " an,", " avid"]
        for w in words { e.append((Array(w.utf8), [])) }
        return FakeVocabulary(entries: e)
    }()

    func id(_ text: String) -> TokenID {
        let bytes = Array(text.utf8)
        guard let i = entries.firstIndex(where: { $0.bytes == bytes && !$0.traits.contains(.byteFallback) }) else {
            fatalError("no token \(text)")
        }
        return TokenID(i)
    }
}

/// Scripted session: `script` maps the text decoded so far in a sequence (concatenated token
/// strings, decoded leniently) to the log-probs of the next tokens; unlisted tokens get -30. A
/// missing entry means "end of generation is most likely". Sequences fork by copying histories.
final class FakeSession: SpeculativeSession {
    let fake: FakeVocabulary
    var script: [String: [TokenID: Float]]
    /// Tokens appended after the prompt, per sequence. Sequence 0 always exists.
    var histories: [Int32: [TokenID]] = [0: []]
    var steps = 0
    /// Number of (sequence, token) pairs decoded across all steps.
    var decodedTokens = 0
    var cancelAfterSteps: Int?
    var logProbCalls = 0
    var forks: [(SeqID, [SeqID])] = []
    /// When set, step N uses `byStep[N]` instead of the text-keyed script.
    var byStep: [[TokenID: Float]]?
    let parallel: Int
    /// Draft tokens pre-decoded after the prompt (not yet part of `histories[0]`).
    var specDraft: [TokenID] = []
    /// When true, `syncPrompt(speculating:)` drops the draft (the real session does when it won't fit).
    var refuseDraft = false
    var cancelAfterLogProbCalls: Int?
    /// Draft positions kept by the last `settleSpeculation`.
    var settledKept: [Int] = []

    init(vocabulary: FakeVocabulary = .standard, script: [String: [TokenID: Float]], parallel: Int = 4) {
        self.fake = vocabulary
        self.script = script
        self.parallel = parallel
    }

    var history: [TokenID] { histories[0] ?? [] }
    var vocabulary: any VocabularyTable { fake }
    var maxParallelSequences: Int { parallel }
    var reuseCapability: ReuseCapability { .trimSuffix }
    var isCancellationRequested: Bool {
        (cancelAfterSteps.map { steps >= $0 } ?? false) || (cancelAfterLogProbCalls.map { logProbCalls >= $0 } ?? false)
    }

    func decodedKey(_ seq: SeqID) -> String {
        String(decoding: (histories[seq.raw] ?? []).flatMap { fake.bytes($0) }, as: UTF8.self)
    }

    func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] { [] }
    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
        PromptSyncReport(decodedTokens: 0, reusedTokens: 0, duration: .zero)
    }
    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan, speculating draft: [TokenID]) throws -> PromptSyncReport {
        specDraft = refuseDraft ? [] : draft
        return PromptSyncReport(decodedTokens: 0, reusedTokens: 0, duration: .zero)
    }
    var speculatedTokens: [TokenID] { specDraft }
    /// Mid-generation drafts passed to `speculate`, in order.
    var midDrafts: [[TokenID]] = []
    func speculate(_ draft: [TokenID]) throws {
        settleSpeculation(keeping: 0)
        midDrafts.append(draft)
        specDraft = refuseDraft ? [] : draft
    }
    func logProbs(speculated count: Int, into buffer: inout [Float]) throws {
        precondition(count >= 0 && count <= specDraft.count, "speculated row out of range")
        let held = histories[0]!
        histories[0] = held + specDraft.prefix(count)
        defer { histories[0] = held }
        try logProbs(.primary, into: &buffer)
    }
    func settleSpeculation(keeping count: Int) {
        guard !specDraft.isEmpty else { return }
        histories[0]!.append(contentsOf: specDraft.prefix(count))
        settledKept.append(count)
        specDraft = []
    }
    func fork(_ source: SeqID, into targets: [SeqID]) throws {
        settleSpeculation(keeping: 0)
        precondition(histories[source.raw] != nil, "fork from an unknown sequence")
        for target in targets {
            precondition(target.raw >= 0 && Int(target.raw) < parallel, "sequence out of range")
            histories[target.raw] = histories[source.raw]
        }
        forks.append((source, targets))
    }
    func step(_ appends: [(SeqID, TokenID)]) throws {
        settleSpeculation(keeping: 0)
        precondition(Set(appends.map(\.0.raw)).count == appends.count, "one token per sequence per step")
        for (seq, token) in appends {
            precondition(histories[seq.raw] != nil, "step on an unknown sequence")
            histories[seq.raw]!.append(token)
        }
        decodedTokens += appends.count
        steps += 1
    }
    func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {
        logProbCalls += 1
        precondition(histories[seq.raw] != nil, "logits of an unknown sequence")
        buffer = [Float](repeating: -30, count: fake.count)
        let entry: [TokenID: Float]
        if let byStep {
            let count = histories[seq.raw]!.count
            entry = count < byStep.count ? byStep[count] : [fake.id("<eos>"): -0.01]
        } else {
            entry = script[decodedKey(seq)] ?? [fake.id("<eos>"): -0.01]
        }
        for (token, value) in entry { buffer[Int(token)] = value }
    }
    func discard(_ seqs: [SeqID]) {
        for seq in seqs where seq != .primary { histories[seq.raw] = nil }
    }
}

/// Builds a script from a readable form: key = decoded text so far, value = [(token text, logprob)].
func makeScript(_ pairs: [String: [(String, Float)]], vocabulary v: FakeVocabulary = .standard) -> [String: [TokenID: Float]] {
    pairs.mapValues { list in
        Dictionary(uniqueKeysWithValues: list.map { (v.id($0.0), $0.1) })
    }
}
