// Write for me on a local model: one long generation on the host's executor, streamed.
import Foundation
import HunchCore
import HunchPrompt
import HunchLlama
import HunchText
import Synchronization

/// Generates write-for-me drafts with a local model. An instruct model gets the chat prompt; a base
/// model (the user's "try the base model" choice) gets the document prompt, which is weaker.
///
/// Decoding is greedy with a light repetition penalty, stops at the end-of-generation token, a
/// token cap, or (base models) where the document would start a new entry. Never logs text.
public final class LocalWriter: WriteGenerating {
    private let host: any ModelHosting
    private let framer = WriteForMeFramer()
    private let promptTokenBudget: Int
    private let maxTokens: Int
    /// Request ids for the host's latest-wins executor. A dedicated host counts from 1; the shared
    /// autocomplete host passes the coordinator's current id so the write isn't cancelled at once.
    private let nextID: @Sendable () -> RequestID
    private let lastProfile = Mutex<ModelProfile?>(nil)
    private let active = Mutex<Task<String, any Error>?>(nil)
    fileprivate let lastReplyScoresBox = Mutex<[ReplyScore]>([])
    /// The scores of the replies the last suggested-replies request wrote (`ReplyScoring`).
    public var lastReplyScores: [ReplyScore] { lastReplyScoresBox.withLock { $0 } }

    public init(host: any ModelHosting, promptTokenBudget: Int, maxTokens: Int = 900,
                nextID: @escaping @Sendable () -> RequestID) {
        self.host = host
        self.promptTokenBudget = promptTokenBudget
        self.maxTokens = maxTokens
        self.nextID = nextID
    }

    public func cancelWrites() {
        active.withLock { $0?.cancel() }
    }

    public func write(_ request: WriteRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let task = Task { try await self.run(request, partial: partial) }
        let previous = active.withLock { slot -> Task<String, any Error>? in
            let old = slot
            slot = task
            return old
        }
        previous?.cancel()
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func run(_ request: WriteRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let id = nextID()
        var state = await host.state()
        // Released while idle (or never seen ready): load it the way any request would, to read its profile.
        if lastProfile.withLock({ $0 }) == nil, !Self.isReady(state) {
            try await host.withSession(id) { _ in }
            state = await host.state()
        }
        if case .ready(_, let loaded) = state { lastProfile.withLock { $0 = loaded } }
        guard let profile = lastProfile.withLock({ $0 }) else { throw WriteError.failed("the model is not loaded") }

        let clock = ContinuousClock()
        let started = clock.now
        // The diagnostic console records only while its window is open (one atomic read otherwise).
        let capture = DiagnosticRecorder.shared.isEnabled ? WriterCapture() : nil
        let framed = framer.frame(request, profile: profile, budget: promptTokenBudget,
                                  counter: ApproximateTokenCounter())
        // A dictation's document prompt ends its line with the cleaned text.
        let stops = framed.style == .document ? (request.dictation == nil ? Self.documentStops : ["\n"]) : []
        let maxTokens = request.replies.map { min(self.maxTokens, $0.maxTokens) } ?? self.maxTokens
        let mode = request.mode, shape = request.shape
        // Suggested replies are a list the app parses: no draft clean-up.
        let isReplies = request.replies != nil
        let clean: @Sendable (String) -> String = { isReplies ? $0 : DraftCleanup.clean($0, mode: mode, shape: shape) }
        let raw = try await host.withSession(id) { session -> String in
            let tokens = try session.tokenize(framed.segments, addBOS: profile.addsBOS)
            _ = try session.syncPrompt(tokens, plan: ReusePlan(action: .coldPrefill, tokensToDecode: tokens.count))
            capture?.promptTokens = tokens.count
            capture?.prefilled = clock.now - started
            // Replies repeat their openers on purpose ("Skip testing…" after "Done testing…"): no penalty,
            // or the next reply swerves ("Okip").
            var steps: [ReplyStep] = []
            let text = try Self.decode(session, maxTokens: maxTokens, stops: stops, penalty: isReplies ? 0 : Self.penalty,
                                       progress: { text in
                partial(clean(text))
            }, finished: { reason, count in capture?.set(stop: reason, tokens: count) },
                                       trace: isReplies ? { steps.append($0) } : nil)
            if isReplies { self.lastReplyScoresBox.withLock { $0 = ReplyScoring.score(steps) } }
            return text
        }
        try Task.checkCancellation()
        let cleaned = clean(raw)
        if let capture {
            DiagnosticRecorder.shared.record(Self.diagnosticRecord(
                request, framed: framed, budget: promptTokenBudget, raw: raw, cleaned: cleaned, capture: capture,
                scores: isReplies ? lastReplyScores : [],
                model: profile.displayName, elapsed: clock.now - started))
        }
        return cleaned
    }

    /// Why a draft stopped.
    enum StopCause: Sendable {
        case endOfGeneration, stopSequence, tokenCap, contextFull

        var words: String {
            switch self {
            case .endOfGeneration: "The model ended its turn."
            case .stopSequence: "The text reached a point where a base model's document would start something new, so writing stopped there."
            case .tokenCap: "The draft hit the token limit."
            case .contextFull: "The model's context filled up, so the draft stopped there."
            }
        }
    }

    /// Dictation cleanup and Write for me keep no per-token scores (the decode only keeps the best token
    /// after a repetition penalty), so the console shows their text and stop reason without percentages.
    private static func diagnosticRecord(_ request: WriteRequest, framed: FramedPrompt, budget: Int, raw: String,
                                         cleaned: String, capture: WriterCapture, scores: [ReplyScore], model: String,
                                         elapsed: Duration) -> DiagnosticRecord {
        let prompt = DiagnosticCapture.prompt(framed, promptTokens: capture.promptTokens ?? 0, budget: budget, report: nil)
        let kind: DiagnosticKind = request.dictation != nil ? .dictation
            : request.replies != nil ? .suggestedReplies : .writeForMe
        var sections = request.dictation.map(DiagnosticSections.forDictation)
            ?? request.replies.map { DiagnosticSections.forReplies(request, replies: $0, raw: raw, scores: scores) }
            ?? DiagnosticSections.forWrite(request)
        sections.insert(DiagnosticSection("Framer and model", [.init("Framer", prompt.framerName), .init("Model", model)]), at: 1)
        sections.append(DiagnosticSections.budget(prompt))
        let (stop, count) = capture.stop ?? (nil, 0)
        let output = DiagnosticOutput(text: raw, stopText: stop?.words, generatedTokens: count)
        let context = request.context
        let dictation = request.dictation?.context
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        // Replies: the app fills in what became of the bubble (`.pending` until then), found by the
        // request's id.
        let replies = request.replies != nil
        return DiagnosticRecord(
            requestKey: replies ? request.id.raw : nil,
            kind: kind, appName: dictation?.appName ?? context.appName, domain: context.domain,
            windowTitle: context.windowTitle, model: model, sections: sections, prompt: prompt, output: output,
            fate: replies ? .pending : .notApplicable,
            timing: DiagnosticTiming(totalMs: ms(elapsed), promptSyncMs: capture.prefilled.map(ms)),
            note: cleaned == raw ? nil : "The model's text is shown above; the draft the app uses is that text after clean-up.")
    }

    private static func isReady(_ state: ModelLoadState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    /// Where a base model's document would go on past the draft.
    static let documentStops = ["\n\n\n", "\nTheir quick note", "\nTheir rough draft", "\nWhat they had to answer",
                                "\nThe full message", "\nThe same text after", "\nThe finished", "\nAbout the writer",
                                "\nHow they write", "\nForm:"]

    /// Greedy decode with a repetition penalty; `progress` gets the text so far every few tokens.
    static func decode(_ session: any LanguageModelSession, maxTokens: Int, stops: [String],
                       penalty: Float = LocalWriter.penalty, progress: (String) -> Void, finished: ((StopCause, Int) -> Void)? = nil,
                       trace: ((ReplyStep) -> Void)? = nil) throws -> String {
        let vocab = session.vocabulary
        // Suggested replies: each chosen token's log-prob and the chance of ending the turn there.
        let stopIDs: [Int] = trace == nil ? [] : endOfGenerationIDs(vocab)
        var logProbs: [Float] = []
        var bytes: [UInt8] = []
        var recent: [TokenID] = []
        var sinceReport = 0
        var cause = StopCause.tokenCap
        var generated = 0
        func text() -> String { String(decoding: validPrefix(bytes), as: UTF8.self) }
        for _ in 0..<maxTokens {
            if session.isCancellationRequested { throw CancellationError() }
            try session.logProbs(.primary, into: &logProbs)
            if penalty > 0 {
                for t in Set(recent.suffix(penaltyWindow)) where Int(t) < logProbs.count { logProbs[Int(t)] -= penalty }
            }
            var best: TokenID = -1
            var bestScore = -Float.infinity
            for i in logProbs.indices where logProbs[i] > bestScore {
                let traits = vocab.traits(TokenID(i))
                if traits.contains(.unused) || (traits.contains(.control) && !traits.contains(.endOfGeneration)) {
                    continue
                }
                best = TokenID(i)
                bestScore = logProbs[i]
            }
            guard best >= 0, !vocab.traits(best).contains(.endOfGeneration) else {
                cause = .endOfGeneration
                break
            }
            if let trace {
                let stop = stopIDs.lazy.filter { $0 < logProbs.count }.map { logProbs[$0] }.max() ?? -.infinity
                trace(ReplyStep(bytes: Array(vocab.bytes(best)), logProb: bestScore, stopLogProb: stop))
            }
            bytes.append(contentsOf: vocab.bytes(best))
            recent.append(best)
            generated += 1
            if !stops.isEmpty {
                let current = text()
                if let stop = stops.compactMap({ current.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    finished?(.stopSequence, generated)
                    return String(current[..<stop.lowerBound])
                }
            }
            sinceReport += 1
            if sinceReport >= 3 {
                sinceReport = 0
                progress(text())
            }
            do {
                try session.step([(.primary, best)])
            } catch LlamaError.contextFull {
                cause = .contextFull
                break  // the draft so far is all that fits
            }
        }
        finished?(cause, generated)
        return text()
    }

    /// End-of-turn token ids, found once per vocabulary (by size: one model family shares them).
    private static let stopIDCache = Mutex<[Int: [Int]]>([:])
    static func endOfGenerationIDs(_ vocab: any VocabularyTable) -> [Int] {
        if let ids = stopIDCache.withLock({ $0[vocab.count] }) { return ids }
        let ids = (0..<vocab.count).filter { vocab.traits(TokenID($0)).contains(.endOfGeneration) }
        stopIDCache.withLock { $0[vocab.count] = ids }
        return ids
    }

    /// Penalty on the log-prob of tokens used in the last `penaltyWindow` tokens: enough to stop
    /// greedy loops, small enough to leave names and numbers alone.
    static let penalty: Float = 0.6
    static let penaltyWindow = 48

    /// Bytes up to the last complete UTF-8 character (a token can end mid-character).
    static func validPrefix(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        var i = bytes.count - 1
        var steps = 0
        while i >= 0, steps < 4, bytes[i] & 0xC0 == 0x80 {
            i -= 1
            steps += 1
        }
        guard i >= 0 else { return bytes[...] }
        let lead = bytes[i]
        let need = lead & 0x80 == 0 ? 1 : lead & 0xE0 == 0xC0 ? 2 : lead & 0xF0 == 0xE0 ? 3 : 4
        return bytes.count - i < need ? bytes[..<i] : bytes[...]
    }
}

/// About four characters per token: framing only needs a safe upper bound for prose.
struct ApproximateTokenCounter: TokenCounting {
    func tokenCount(_ text: String) -> Int { (text.utf8.count + 2) / 3 }
}

/// A draft's prompt size and stop reason, collected for the diagnostic console.
final class WriterCapture: Sendable {
    private struct State {
        var promptTokens: Int?
        var stop: (LocalWriter.StopCause, Int)?
        var prefilled: Duration?
    }
    private let state = Mutex(State())
    var promptTokens: Int? {
        get { state.withLock { $0.promptTokens } }
        set { state.withLock { $0.promptTokens = newValue } }
    }
    /// Time from the request's start to the prompt being read (queueing for the model included).
    var prefilled: Duration? {
        get { state.withLock { $0.prefilled } }
        set { state.withLock { $0.prefilled = newValue } }
    }
    var stop: (LocalWriter.StopCause, Int)? { state.withLock { $0.stop } }
    func set(stop: LocalWriter.StopCause, tokens: Int) { state.withLock { $0.stop = (stop, tokens) } }
}
