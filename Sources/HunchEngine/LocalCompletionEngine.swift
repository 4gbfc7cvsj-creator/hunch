// The local pipeline: frame → tokenize → KV sync → constrained search → post-process (design §3).
import Foundation
import HunchCore
import HunchDecode
import HunchLlama
import HunchPrompt
import HunchText
import Synchronization

/// Runs completions on the on-device model.
///
/// All framing, tokenizing, prompt sync, and search happen inside one `host.withSession` job on
/// the generation executor, so the latest-wins policy covers the whole request: a superseded
/// request throws `CancellationError`, which `complete` propagates.
///
/// Serve paths: `.cold` when the model had to be (re)loaded for this request, `.reuse` when part of
/// the KV cache was kept, `.fresh` otherwise.
///
/// Never logs prompts, field text, or completions.
public final class LocalCompletionEngine: CompletionEngine {
    public let kind: EngineKind = .local

    let host: any ModelHosting
    let registry: any FramerRegistry
    let planner: any ReusePlanning
    private let makeSearch: @Sendable () -> any CompletionSearching
    private let postProcessor: any SuggestionPostProcessing
    let framerOverride: String?
    let promptTokenBudget: Int
    /// Told what each request cost on the model (benchmark and debug log); nil = not measured.
    private let costObserver: (@Sendable (RequestCost) -> Void)?
    private let confidenceFloor: Float?
    /// The host's last `.ready` profile, kept across idle releases (the host has none while released).
    let lastProfile = Mutex<ModelProfile?>(nil)
    let cache = SessionCache()
    private let results: ResultCache
    private let draftTokenLimit: Int
    /// Draft-and-verify is on by default (see `draftTokenLimit`); 0 turns it off.
    static let defaultDraftTokens = 12
    private static let logDrafts = ProcessInfo.processInfo.environment["HUNCH_DRAFT_LOG"] != nil

    /// - Parameters:
    ///   - draftTokenLimit: draft-and-verify decoding (0 = off, default 12). When the new prompt is a prefix of
    ///     what the session last held (the previous prompt plus its best continuation, i.e. the user
    ///     typed along with the suggestion), up to this many of the previous continuation's tokens
    ///     are decoded together with the prompt in one batch and the search consumes them as far as
    ///     its own rules would have chosen them. The output is identical to a search without a
    ///     draft; only the number of sequential decodes changes.
    ///   - host: its `.ready` profile is the one source for family, chat markers and BOS (build the
    ///     host with a profile detector, e.g. `LlamaModelHost(profileDetector: DefaultModelProfileDetector())`,
    ///     or the framer falls back to the document framer). Build a new engine when the model changes.
    ///   - promptTokenBudget: framer budget; keep it below the runtime context minus `maxTokens`.
    ///   - confidenceFloor: extra floor on the best candidate's mean log-prob, applied on top of
    ///     `DecodeConfig.minMeanLogProb` (which the search already enforces). nil = none.
    ///   - resultCacheCapacity: size of the in-memory LRU of finished completions (0 = off, the
    ///     default, so evals that repeat a phrase still exercise the model). A hit needs the same
    ///     framer, prompt input, decode config, and learned bias; entries expire after 5 minutes.
    /// Tokens per prompt block, in prompt order; neighbouring segments of one block are summed and
    /// unlabeled ones (chat markers, separators) count as "markers".
    static func blockTokens(_ segments: [PromptSegment], counter: any TokenCounting) -> [(label: String, tokens: Int)] {
        var out: [(label: String, tokens: Int)] = []
        for segment in segments {
            let label = segment.label ?? "markers"
            let tokens = counter.tokenCount(segment.text)
            if let last = out.last, last.label == label { out[out.count - 1].tokens += tokens } else { out.append((label, tokens)) }
        }
        return out
    }

    static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    public init(host: any ModelHosting,
                registry: any FramerRegistry = DefaultFramerRegistry(),
                planner: any ReusePlanning = DefaultReusePlanner(),
                search: @escaping @Sendable () -> any CompletionSearching = { GreedyConstrainedSearch() },
                postProcessor: any SuggestionPostProcessing = DefaultPostProcessor(),
                framerOverride: String? = nil,
                promptTokenBudget: Int = 1024,
                confidenceFloor: Float? = nil,
                resultCacheCapacity: Int = 0,
                draftTokenLimit: Int? = nil,
                costObserver: (@Sendable (RequestCost) -> Void)? = nil) {
        self.costObserver = costObserver
        // Debug/eval switch: HUNCH_DRAFT_TOKENS=<n> (0 = off) when the caller didn't choose.
        let fromEnvironment = ProcessInfo.processInfo.environment["HUNCH_DRAFT_TOKENS"].flatMap { Int($0) }
        self.draftTokenLimit = max(0, draftTokenLimit ?? fromEnvironment ?? Self.defaultDraftTokens)
        self.results = ResultCache(capacity: resultCacheCapacity)
        self.host = host
        self.registry = registry
        self.planner = planner
        self.makeSearch = search
        self.postProcessor = postProcessor
        self.framerOverride = framerOverride
        self.promptTokenBudget = promptTokenBudget
        self.confidenceFloor = confidenceFloor
    }

    public func complete(_ request: CompletionRequest,
                         partial: @escaping @Sendable (String) -> Void) async throws -> CompletionResult {
        try await run(request, prewarmOnly: request.prewarmOnly, partial: partial)
    }

    public func prewarm(_ request: CompletionRequest) async {
        _ = try? await run(request, prewarmOnly: true, partial: { _ in })
    }

    public func cancel(olderThan id: RequestID) {
        host.cancel(olderThan: id)
    }

    // MARK: - Pipeline

    /// How a request gets onto the model, from the host state it found.
    enum HostAdmission: Equatable {
        /// Run the request's job now.
        case run
        /// The model is idle-released and its profile known: the request's own job reloads it.
        case reloadInJob
        /// Wait for the host first: a load is in flight, or the model was released before this
        /// engine read its profile (the wait reloads it). Then decide again.
        case waitForHost
    }

    /// Pure: what a request does with the host in `state`. `knowsProfile` = the engine kept a
    /// `.ready` profile from earlier (needed to frame the prompt before the job runs).
    static func admission(for state: ModelLoadState, knowsProfile: Bool) -> HostAdmission {
        switch state {
        case .loading: .waitForHost
        case .releasedIdle: knowsProfile ? .reloadInJob : .waitForHost
        default: .run
        }
    }

    private func run(_ request: CompletionRequest, prewarmOnly: Bool,
                     partial: @escaping @Sendable (String) -> Void) async throws -> CompletionResult {
        let clock = ContinuousClock()
        let start = clock.now

        var state = await host.state()
        var admission = Self.admission(for: state, knowsProfile: lastProfile.withLock { $0 } != nil)
        let waited = admission == .waitForHost
        if waited {
            // An empty job queues behind the load in flight, or reloads the model (released before
            // this engine ever saw it ready), FIFO on the executor. Latest-wins drops it with
            // `CancellationError` once a newer request arrives, so only the newest request runs
            // after the load and the user sees a suggestion without typing another key.
            try await host.withSession(request.id) { _ in }
            state = await host.state()
            if case .ready(_, let loaded) = state { lastProfile.withLock { $0 = loaded } }
            admission = Self.admission(for: state, knowsProfile: lastProfile.withLock { $0 } != nil)
            // Another load started meanwhile (a model swap): give up; the next keystroke retries.
            if admission == .waitForHost { throw LlamaError.loading }
        }
        // A request that waited for the load (or whose job reloads) pays for it: a cold serve.
        let needsLoad = waited || admission == .reloadInJob
        // Remember the profile across idle releases, when the host has no `.ready` profile to read.
        if case .ready(_, let loaded) = state { lastProfile.withLock { $0 = loaded } }
        guard let profile = lastProfile.withLock({ $0 }) else { throw LlamaError.notLoaded }
        let framer = registry.framer(for: profile, override: framerOverride)
        // The diagnostic console records only while its window is open (one atomic read otherwise).
        let capture: PromptCapture? = !prewarmOnly && DiagnosticRecorder.shared.isEnabled ? PromptCapture() : nil
        let input = request.input
        let decode = request.decode
        let budget = promptTokenBudget
        let cache = self.cache
        let planner = self.planner
        let makeSearch = self.makeSearch
        let floor = confidenceFloor
        let postProcessor = self.postProcessor
        let draftLimit = request.decode.firstTokenFanout <= 1 && !prewarmOnly
            ? min(draftTokenLimit, request.decode.maxTokens) : 0
        // The learned bias steers the search and is part of the result-cache key. The KV record
        // below follows the tokens actually decoded, so a biased and an unbiased request never
        // share anything but the (bias-independent) prompt prefix.
        // Instruct framers that name the learned words in the prompt keep only the bias that finishes a
        // half-typed learned word; the document framer (base models) keeps the full bias, as before.
        let bias = framer.listsVocabulary ? request.bias.midWordOnly(before: input.before) : request.bias
        let learnedWords = Self.learnedWords(input: input, bias: bias)
        // Console only: the request as the model saw it (the bias in effect, and whether the framer named
        // the learned words), so the console shows the mid-word boost and the gated notes.
        let request: CompletionRequest = {
            guard capture != nil || DiagnosticRecorder.shared.isEnabled else { return request }
            var r = request
            r.bias = bias
            if var notes = r.learnedNotes {   // the app sends these only with learning on
                notes.framerListsVocabulary = framer.listsVocabulary
                r.learnedNotes = notes
            }
            return r
        }()

        let resultKey = results.capacity > 0 && !prewarmOnly
            ? ResultCacheKey(framerID: framer.id, addsBOS: profile.addsBOS, promptTokenBudget: budget,
                             confidenceFloor: floor, input: input, decode: decode, bias: bias)
            : nil
        if let key = resultKey, let hit = results.value(for: key) {
            host.cancel(olderThan: request.id) // a served request still supersedes older work
            if let text = hit.partialText, !request.streamsCheckedPartials { partial(text) }
            let elapsed = clock.now - start
            let timings = CompletionTimings(framing: .zero, promptSync: .zero, firstVisible: elapsed, total: elapsed)
            if capture != nil {
                DiagnosticRecorder.shared.record(DiagnosticCapture.cacheHit(
                    request, outcome: hit.outcome, rawText: hit.rawText, timings: timings, model: profile.displayName))
            }
            return CompletionResult(id: request.id, outcome: hit.outcome, alternatives: hit.alternatives, path: .cache,
                                    timings: timings, wordScores: hit.wordScores, rawText: hit.rawText)
        }

        let checker = request.streamsCheckedPartials && !prewarmOnly
            ? PartialChecker(input: input, decode: decode, postProcessor: postProcessor, learnedWords: learnedWords, deliver: partial) : nil
        defer { checker?.stop() }
        let job: @Sendable (any LanguageModelSession) throws -> JobOutput = { session in
            let reloaded = cache.adopt(session) || needsLoad

            // Framing + tokenizing (the tokenizer is executor-confined, hence inside the job).
            let framingStart = clock.now
            let counter = SessionTokenCounter(session: session)
            let framed = framer.frame(input, profile: profile, budget: budget, counter: counter)
            let tokens = try session.tokenize(framed.segments, addBOS: profile.addsBOS)
            let framing = clock.now - framingStart

            // KV sync against what this session last held.
            let plan = planner.plan(cached: cache.tokens, next: tokens, capability: session.reuseCapability)
            // From here on, any error (a cancelled sync is the common case) must leave the record
            // matching what the session really kept, so the next plan reuses that prefix instead
            // of falling back to a cold prefill.
            do {
                let syncStart = clock.now
                var draft: [TokenID] = []
                if draftLimit > 0, !reloaded, session is any SpeculativeSession {
                    let required = Array(framed.requiredPrefix.utf8)
                    draft = cache.draft(for: tokens, required: required, vocabulary: session.vocabulary, limit: draftLimit)
                    if draft.isEmpty, let text = cache.draftText(before: input.before, required: framed.requiredPrefix),
                       let guess = try? session.tokenize([PromptSegment(text: text, kind: .content, stability: .perKeystroke)],
                                                         addBOS: false) {
                        draft = SessionCache.compatible(Array(guess.prefix(draftLimit)), required: required,
                                                        vocabulary: session.vocabulary)
                    }
                }
                let report: PromptSyncReport
                if !draft.isEmpty, let speculative = session as? any SpeculativeSession {
                    report = try speculative.syncPrompt(tokens, plan: plan, speculating: draft)
                } else {
                    report = try session.syncPrompt(tokens, plan: plan)
                }
                let promptSync = clock.now - syncStart
                cache.set(prompt: tokens)
                if PromptDebugLog.isEnabled {
                    PromptDebugLog.note(PromptDebugLog.line(
                        promptTokens: tokens.count, budget: budget, decoded: report.decodedTokens,
                        reused: report.reusedTokens, syncMilliseconds: Self.milliseconds(promptSync),
                        framingMilliseconds: Self.milliseconds(framing), prewarm: prewarmOnly,
                        blocks: Self.blockTokens(framed.segments, counter: counter)))
                }

                capture?.set(prompt: DiagnosticCapture.prompt(framed, promptTokens: tokens.count, budget: budget,
                                                              report: report))
                let path: ServePath = reloaded ? .cold : (report.reusedTokens > 0 ? .reuse : .fresh)
                var timings = CompletionTimings(framing: framing, promptSync: promptSync, firstVisible: nil,
                                                total: .zero, decodedPromptTokens: report.decodedTokens)
                if prewarmOnly {
                    timings.total = clock.now - start
                    return .done(CompletionResult(id: request.id, outcome: .suppress(.empty), path: path, timings: timings))
                }

                // Search, streaming partials.
                var firstVisible: Duration?
                var lastPartial: String?
                let midWord = ConfidenceFloor.isMidWord(requiredPrefix: Array(framed.requiredPrefix.utf8))
                let onPartial: (Candidate) -> Void = { candidate in
                    lastPartial = candidate.text
                    capture?.set(partial: candidate.text)
                    if firstVisible == nil, TextMeasure.wordCount(candidate.text) >= 1 {
                        firstVisible = clock.now - start
                    }
                    if let checker {
                        // A start the word-start floor rejects is never streamed: the finished
                        // result would hide it again (a flash).
                        guard ConfidenceFloor.firstTokenFailure(text: candidate.text, firstLogProb: candidate.firstLogProb,
                                                                midWord: midWord, config: decode) == nil else { return }
                        checker.offer(candidate.text, requiredPrefix: framed.requiredPrefix)
                    } else {
                        partial(candidate.text)
                    }
                }
                let search = makeSearch()
                let scored: [ScoredCandidate]
                if let biased = search as? any BiasedCompletionSearching {
                    scored = try biased.searchScored(in: session, requiredPrefix: Array(framed.requiredPrefix.utf8),
                                                     config: decode, bias: bias, onPartial: onPartial)
                } else {
                    scored = try search.search(in: session, requiredPrefix: Array(framed.requiredPrefix.utf8),
                                               config: decode, onPartial: onPartial)
                        .map { ScoredCandidate(candidate: $0, spans: []) }
                }
                if Self.logDrafts, let llama = session as? LlamaSession {
                    let p = llama.profile   // counters only, no text
                    FileHandle.standardError.write(Data(("draft-stats offered=\(draft.count) promptTokens=\(tokens.count) decodeCalls=\(p.decodeCalls) requests=\(p.draftRequests) "
                        + "tokens=\(p.draftTokens) kept=\(p.draftKept) framingMs=\(String(format: "%.2f", Double(framing.components.attoseconds) / 1e15 + Double(framing.components.seconds) * 1e3)) "
                        + "tokenizeCalls=\(p.tokenizeCalls) tokenizeHits=\(p.tokenizeHits) "
                        + "tokenizeMs=\(String(format: "%.2f", Double(p.tokenizeNanos) / 1e6))\n").utf8))
                    if p.checkpointSaves > 0 {
                        let ms = String(format: "%.2f", Double(p.checkpointNanos) / 1e6)
                        let line = "checkpoint-stats saves=\(p.checkpointSaves) restores=\(p.checkpointRestores) "
                            + "replayed=\(p.replayedTokens) ms=\(ms)\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                }
                let candidates = scored.map(\.candidate)
                // The primary sequence now holds the best greedy path; remember it for the next plan
                // (the session clamps any plan to what its cache really holds).
                if let best = candidates.first { cache.set(prompt: tokens, continuation: best.tokens, before: input.before, text: best.text) }
                timings.firstVisible = firstVisible
                // Post-processing is NOT done here: it may consult the spell checker, which can hop
                // to the main thread, and the main thread may be blocked waiting for this job
                // (e.g. an unload on volume unmount). Nothing that runs inside the executor job may
                // wait on the main thread, so hand the raw material back and finish outside.
                return JobOutput.searched(Searched(scored: scored, requiredPrefix: framed.requiredPrefix,
                                                   path: path, timings: timings, lastPartial: lastPartial,
                                                   cancelled: session.isCancellationRequested,
                                                   prompt: capture?.prompt))
            } catch {
                cache.recordAfterFailure(session: session, attempted: tokens)
                throw error
            }
        }
        let observer = costObserver
        let requestID = request.id
        let output: JobOutput
        do { output = try await host.withSession(request.id) { session in
            guard let observer, let llama = session as? LlamaSession else { return try job(session) }
            let before = llama.profile
            func report(finished: Bool) {
                let after = llama.profile
                observer(RequestCost(id: requestID, decodedTokens: after.decodeTokens - before.decodeTokens,
                                     // Metal returns from llama_decode early; the GPU wait shows up when
                                     // logits are read, so model time counts both.
                                     decodeMilliseconds: Double(after.decodeNanos - before.decodeNanos
                                                                + after.logProbNanos - before.logProbNanos) / 1e6,
                                     finished: finished, prewarm: prewarmOnly))
            }
            do {
                let output = try job(session)
                report(finished: true)
                return output
            } catch {
                report(finished: false)
                throw error
            }
        }
        } catch {
            // Console only: a request that got as far as a prompt and was then cancelled or failed.
            if let capture, let prompt = capture.prompt {
                DiagnosticRecorder.shared.record(DiagnosticCapture.interrupted(
                    request, prompt: prompt, partial: capture.partial, error: error, model: profile.displayName))
            }
            throw error
        }
        // Nothing more is delivered once the job is over, and a check still running must not
        // compete with `finish` (it may be waiting on the same main thread for the spell checker).
        checker?.stop()
        switch output {
        case .done(let result): return result
        case .searched(let found):
            return finish(found, request: request, framerInput: input, decode: decode, floor: floor,
                          resultKey: resultKey, start: start, clock: clock, bias: bias, postProcessor: postProcessor,
                          recordFor: capture == nil ? nil : profile.displayName)
        }
    }

    /// Post-processing, word scores and the result cache: runs on the caller's task, after the
    /// executor job has ended (never inside it; see the comment at the job's return).
    private func finish(_ found: Searched, request: CompletionRequest, framerInput input: PromptInput,
                        decode: DecodeConfig, floor: Float?, resultKey: ResultCacheKey?,
                        start: ContinuousClock.Instant, clock: ContinuousClock, bias: LearnedBias,
                        postProcessor: any SuggestionPostProcessing, recordFor model: String? = nil) -> CompletionResult {
        let scored = found.scored
        let candidates = scored.map(\.candidate)
        var timings = found.timings
        var postContext = Self.postContext(input, decode: decode, requiredPrefix: found.requiredPrefix)
        postContext.learnedWords = Self.learnedWords(input: input, bias: bias)
        let outcome: PostOutcome
        var alternatives: [String] = []
        // Console only: what the post-processor cut, noted while it runs (same outcome either way).
        let trace = model != nil ? DefaultPostProcessor.Trace() : nil
        if let best = candidates.first {
            if best.stop == .lowConfidence || (floor.map { best.meanLogProb < $0 } ?? false) {
                outcome = .suppress(.lowConfidence)
            } else if let trace, let detailed = postProcessor as? DefaultPostProcessor {
                outcome = detailed.process(best.text, meanLogProb: best.meanLogProb, context: postContext, trace: trace)
            } else {
                outcome = postProcessor.process(best.text, meanLogProb: best.meanLogProb, context: postContext)
            }
            for other in candidates.dropFirst() where other.stop != .lowConfidence {
                if case .show(let text) = postProcessor.process(other.text, meanLogProb: other.meanLogProb,
                                                                context: postContext),
                   outcome != .show(text), !alternatives.contains(text) {
                    alternatives.append(text)
                }
            }
        } else {
            outcome = .suppress(.empty)
        }
        timings.total = clock.now - start
        var wordScores: [WordScore] = []
        if case .show(let shown) = outcome, let best = scored.first, !best.spans.isEmpty {
            wordScores = WordScoring.scores(shown: shown, for: best)
        }
        // A typo suppression depends on the learned-word set and the dictionaries, which can change
        // without the key changing: never cache it.
        if let key = resultKey, !found.cancelled, outcome != .suppress(.likelyTypo) {
            results.store(CachedCompletion(outcome: outcome, alternatives: alternatives,
                                           wordScores: wordScores, partialText: found.lastPartial,
                                           rawText: candidates.first?.text ?? ""), for: key)
        }
        if let model {
            DiagnosticRecorder.shared.record(DiagnosticCapture.record(
                request, found: found, outcome: outcome, alternatives: alternatives, trace: trace, timings: timings,
                decode: decode, floor: floor, model: model))
        }
        return CompletionResult(id: request.id, outcome: outcome, alternatives: alternatives, path: found.path,
                                timings: timings, wordScores: wordScores,
                                rawText: candidates.first?.text ?? "")
    }
}

extension LocalCompletionEngine {
    /// Learned words this request names (notes) or boosts (bias entries), for the post-processor.
    static func learnedWords(input: PromptInput, bias: LearnedBias) -> [String] {
        guard bias.strength > 0 || !input.vocabulary.isEmpty else { return input.vocabulary }
        return input.vocabulary + (bias.strength > 0 ? bias.entries.map { $0.text.trimmingCharacters(in: .whitespaces) } : [])
    }

    static func postContext(_ input: PromptInput, decode: DecodeConfig, requiredPrefix: String) -> PostContext {
        PostContext(before: input.before, after: input.after, requiredPrefix: requiredPrefix,
                    allowNewlines: input.allowNewlines && decode.allowNewline,
                    maxWords: decode.maxWords, styleExamples: input.styleExamples,
                    allowedScripts: input.allowedScripts,
                    preferredHanScript: input.preferredHanScript,
                    quoteStyle: input.quoteStyle, allowsURLs: PostContext.allowsURLs(on: input.surface),
                    surface: input.surface, screenText: input.screenContext)
    }
}

/// Checks streamed text off the executor (post-processing may hop to the main thread, which may be
/// waiting for the job; see `finish`). Only the newest text waits; older offers are skipped.
/// Hands on the first whole words that pass the checks, once (the app shows only the start early;
/// the rest comes with the finished result).
final class PartialChecker: Sendable {
    private let continuation: AsyncStream<(raw: String, requiredPrefix: String)>.Continuation
    private let task: Task<Void, Never>
    private let gate = GateBox()

    /// Executor-side bookkeeping: what was last offered, and whether anything is still wanted.
    private struct Gate {
        var finished = false
        var last = ""
    }
    private final class GateBox: Sendable { let state = Mutex<Gate>(Gate()) }

    init(input: PromptInput, decode: DecodeConfig, postProcessor: any SuggestionPostProcessing,
         learnedWords: [String] = [], deliver: @escaping @Sendable (String) -> Void) {
        let (stream, continuation) = AsyncStream<(raw: String, requiredPrefix: String)>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        let gate = self.gate
        task = Task.detached(priority: .userInitiated) {
            var checked = ""
            for await offer in stream {
                let words = StreamWords.complete(offer.raw)
                guard !Task.isCancelled else { return }
                guard !words.isEmpty, words != checked else { continue }
                checked = words
                var context = LocalCompletionEngine.postContext(input, decode: decode,
                                                                requiredPrefix: offer.requiredPrefix)
                context.learnedWords = learnedWords
                // No confidence floor here: only the finished suggestion has a mean score.
                guard case .show(let text) = postProcessor.process(words, meanLogProb: nil, context: context),
                      !Task.isCancelled else { continue }
                gate.state.withLock { $0.finished = true }
                deliver(text)
                return
            }
        }
    }

    /// Called on the executor thread, never blocks. Costs next to nothing when no new whole word can
    /// have appeared (the text only grew inside a word) or once the words were delivered.
    func offer(_ raw: String, requiredPrefix: String) {
        let wanted = gate.state.withLock { gate -> Bool in
            guard !gate.finished else { return false }
            let grew = StreamWords.mayHaveNewWord(raw, after: gate.last)
            gate.last = raw
            return grew
        }
        if wanted { continuation.yield((raw, requiredPrefix)) }
    }

    /// The finished result is ready: nothing more is delivered.
    func stop() {
        gate.state.withLock { $0.finished = true }
        continuation.finish()
        task.cancel()
    }
}

/// What the executor job hands back: either a finished result (prewarm) or raw search output.
private enum JobOutput: Sendable {
    case done(CompletionResult)
    case searched(Searched)
}

struct Searched: Sendable {
    let scored: [ScoredCandidate]
    let requiredPrefix: String
    let path: ServePath
    let timings: CompletionTimings
    let lastPartial: String?
    let cancelled: Bool
    /// The framed prompt, collected for the diagnostic console (nil while it is closed).
    var prompt: DiagnosticPrompt?
}

extension LlamaSession: SpeculativeSession {}
extension LlamaSession: PromptParkingSession {}

/// What the executor's session held after the last request. Touched only inside `withSession`
/// jobs, which the generation executor runs one at a time on its own thread.
final class SessionCache: @unchecked Sendable {
    private weak var session: AnyObject?
    private var hadSession = false
    /// Tokens of sequence 0 as of the last request (prompt, then the best greedy path).
    var tokens: [TokenID] = []
    /// How many leading entries of `tokens` are the prompt (the rest is the best continuation).
    private(set) var promptCount = 0

    /// Field text before the cursor of the last finished search, and the continuation it found.
    /// Only kept in memory, to guess what a following request will generate; never logged.
    private var lastBefore: String?
    private var lastText = ""

    func set(prompt: [TokenID], continuation: [TokenID] = [], before: String? = nil, text: String = "") {
        tokens = prompt + continuation
        promptCount = prompt.count
        lastBefore = before
        lastText = text
    }

    /// Text-level draft: when the field now reads the previous text plus the first characters of the
    /// previous continuation (the user typed along with the suggestion), the rest of that
    /// continuation, preceded by the healed required prefix, is what the search should generate.
    /// This also covers multi-character tokens that the typed characters split differently
    /// (CJK), where the token-level draft above doesn't line up.
    func draftText(before: String, required: String) -> String? {
        guard let old = lastBefore, !lastText.isEmpty else { return nil }
        let new = Array(before.utf8), prev = Array(old.utf8), predicted = Array(lastText.utf8)
        guard new.count >= prev.count, new.starts(with: prev) else { return nil }
        let typed = new[prev.count...]
        guard typed.count < predicted.count, predicted.starts(with: typed) else { return nil }
        let rest = String(decoding: predicted[typed.count...], as: UTF8.self)
        return required + rest
    }

    /// `tokens` if their bytes can start with `required` (see `draft(for:...)`), else nothing.
    static func compatible(_ tokens: [TokenID], required: [UInt8], vocabulary: any VocabularyTable) -> [TokenID] {
        var bytes: [UInt8] = []
        for token in tokens where bytes.count < required.count {
            guard Int(token) >= 0, Int(token) < vocabulary.count else { return [] }
            bytes.append(contentsOf: vocabulary.bytes(token))
        }
        let n = min(bytes.count, required.count)
        return bytes[..<n].elementsEqual(required[..<n]) ? tokens : []
    }

    /// Tokens worth speculating on for a request whose prompt is `next`: the previous continuation
    /// minus what `next` already contains, when `next` is a prefix of the cached tokens that
    /// reaches at least the previous prompt (the user typed along with the suggestion; a healed
    /// partial word stays in the required prefix, so the prompt itself doesn't change). Dropped
    /// when its bytes can't start with the required prefix, since the search would reject it at once.
    func draft(for next: [TokenID], required: [UInt8], vocabulary: any VocabularyTable, limit: Int) -> [TokenID] {
        guard limit > 0, next.count >= promptCount, tokens.count > next.count,
              tokens.starts(with: next) else { return [] }
        return Self.compatible(Array(tokens[next.count...].prefix(limit)), required: required, vocabulary: vocabulary)
    }

    /// Records `session` as current. Returns true when it replaced an earlier session (the
    /// model was reloaded); the token record is reset in that case.
    func adopt(_ current: any LanguageModelSession) -> Bool {
        if let known = session, known === current { return false }
        let replaced = hadSession
        session = current
        hadSession = true
        tokens = []
        promptCount = 0
        lastBefore = nil
        return replaced
    }

    /// After an error at or past the prompt sync: take the session's own record when it reports
    /// one; a session that reports nothing (test fakes, or truly empty) falls back to the prefix
    /// shared by the old record and the attempted prompt (anything beyond it may have been
    /// trimmed). The session itself clamps reuse to its real common prefix, so this is safe.
    func recordAfterFailure(session: any LanguageModelSession, attempted: [TokenID]) {
        let reported = session.retainedPromptTokens
        if !reported.isEmpty {
            tokens = reported
        } else {
            let common = zip(tokens, attempted).prefix { $0 == $1 }.count
            tokens = Array(attempted.prefix(common))
        }
        promptCount = tokens.count
        lastBefore = nil
    }
}

/// `TokenCounting` over the session's tokenizer. Only valid inside the `withSession` job that
/// created it (the session is executor-confined); content is tokenized without special parsing.
struct SessionTokenCounter: TokenCounting, @unchecked Sendable {
    let session: any LanguageModelSession

    func tokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let segment = PromptSegment(text: text, kind: .content, stability: .perKeystroke)
        if let tokens = try? session.tokenize([segment], addBOS: false) { return tokens.count }
        // Conservative estimate if tokenizing fails: about 3 UTF-8 bytes per token.
        return (text.utf8.count + 2) / 3
    }
}
