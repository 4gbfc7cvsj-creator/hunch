import Foundation

public enum ServePath: String, Sendable, Codable { case typeThrough, cache, reuse, fresh, cold }

public struct Suggestion: Sendable, Equatable {
    public let requestID: RequestID
    public let anchorSignature: UInt64
    /// Display text, already post-processed.
    public var text: String
    public var alternatives: [String]
    public var servePath: ServePath
    public init(requestID: RequestID, anchorSignature: UInt64, text: String, alternatives: [String] = [],
                servePath: ServePath) {
        self.requestID = requestID
        self.anchorSignature = anchorSignature
        self.text = text
        self.alternatives = alternatives
        self.servePath = servePath
    }
}

/// How model weights are brought into memory. b11552 replaced `use_mmap` with a load mode.
/// Decision 8 (revised 2026-10-11): `.mmap` is the default (file-backed, reclaimable by macOS,
/// small app footprint like competitors'). `.memory` reads the weights fully into app memory.
public enum ModelLoadMode: String, Codable, Sendable, CaseIterable { case memory, mmap }

public enum ModelLoadState: Sendable, Equatable {
    case unloaded
    case loading(ModelEntryID, progress: Double)
    case ready(ModelEntryID, ModelProfile)
    case failed(ModelEntryID, String)
    case releasedIdle(ModelEntryID)
}

public struct RuntimeOptions: Codable, Sendable, Equatable {
    public var contextTokens: Int
    /// Room for long prompts: every setting (How I write, About me, app notes, the screen, the
    /// clipboard) plus the text before the caret. Capped by the model's trained length at load.
    public static let defaultContextTokens = 4096
    /// Tokens kept free for the suggestion itself and alternative branches.
    public static let decodeHeadroom = 512
    public var batchTokens: Int
    /// -1 = offload all layers to Metal.
    public var gpuLayers: Int
    public var loadMode: ModelLoadMode
    public var fullSlidingWindowCache: Bool
    public var maxSequences: Int
    public var idleReleaseAfterSeconds: Double?
    public init(contextTokens: Int = RuntimeOptions.defaultContextTokens, batchTokens: Int = 512, gpuLayers: Int = -1, loadMode: ModelLoadMode = .mmap,
                fullSlidingWindowCache: Bool = true, maxSequences: Int = 4, idleReleaseAfterSeconds: Double? = 600) {
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
        self.gpuLayers = gpuLayers
        self.loadMode = loadMode
        self.fullSlidingWindowCache = fullSlidingWindowCache
        self.maxSequences = maxSequences
        self.idleReleaseAfterSeconds = idleReleaseAfterSeconds
    }
}

public protocol ModelHosting: Sendable {
    func state() async -> ModelLoadState
    func states() -> AsyncStream<ModelLoadState>
    func load(_ entry: ModelEntry, options: RuntimeOptions) async
    func unload() async
    /// Runs `body` on the generation executor with exclusive access to the session.
    /// Work superseded by a newer request throws `CancellationError`.
    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T
    func cancel(olderThan id: RequestID)
}

public struct CompletionRequest: Sendable {
    public var id: RequestID
    public var context: TextContext
    public var input: PromptInput
    public var decode: DecodeConfig
    public var prewarmOnly: Bool
    /// Learned vocabulary to favor while decoding (local engine only; endpoints ignore it).
    public var bias: LearnedBias
    /// Show the start of the suggestion while it is written: `partial` then gets, once, the first
    /// whole words that passed the post-processing checks (never raw model text). Off: `partial` gets the
    /// raw text as decoded. Local engine only.
    public var streamsCheckedPartials: Bool
    /// Diagnostic console only (filled while it is open): which learned words the gate put in the prompt and why.
    public var learnedNotes: LearnedNoteDiagnostics?
    public init(id: RequestID, context: TextContext, input: PromptInput, decode: DecodeConfig, prewarmOnly: Bool = false,
                bias: LearnedBias = LearnedBias(), streamsCheckedPartials: Bool = false) {
        self.streamsCheckedPartials = streamsCheckedPartials
        self.id = id
        self.context = context
        self.input = input
        self.decode = decode
        self.prewarmOnly = prewarmOnly
        self.bias = bias
    }
}

public struct CompletionTimings: Sendable, Equatable {
    public var framing: Duration
    public var promptSync: Duration
    public var firstVisible: Duration?
    public var total: Duration
    public var decodedPromptTokens: Int
    public init(framing: Duration = .zero, promptSync: Duration = .zero, firstVisible: Duration? = nil,
                total: Duration = .zero, decodedPromptTokens: Int = 0) {
        self.framing = framing
        self.promptSync = promptSync
        self.firstVisible = firstVisible
        self.total = total
        self.decodedPromptTokens = decodedPromptTokens
    }
}

public struct CompletionResult: Sendable, Equatable {
    public var id: RequestID
    public var outcome: PostOutcome
    public var alternatives: [String]
    public var path: ServePath
    public var timings: CompletionTimings
    /// Per-word model log-probabilities of the shown text, in order, WITHOUT the learned bias
    /// applied (raw model belief). Empty when unknown (endpoint engines).
    public var wordScores: [WordScore]
    /// Raw text of the winning candidate before post-processing (eval reporting only; never log it
    /// in the app). Empty when unknown.
    public var rawText: String
    public init(id: RequestID, outcome: PostOutcome, alternatives: [String] = [], path: ServePath,
                timings: CompletionTimings, wordScores: [WordScore] = [], rawText: String = "") {
        self.rawText = rawText
        self.id = id
        self.outcome = outcome
        self.alternatives = alternatives
        self.path = path
        self.timings = timings
        self.wordScores = wordScores
    }
}

public protocol CompletionEngine: Sendable {
    var kind: EngineKind { get }
    func complete(_ request: CompletionRequest,
                  partial: @escaping @Sendable (String) -> Void) async throws -> CompletionResult
    func prewarm(_ request: CompletionRequest) async
    func cancel(olderThan id: RequestID)
}

/// Compares ways a text could go on, by the local model's probability (autocorrect choosing among
/// fixes for an ambiguous word).
public protocol ContinuationScoring: Sendable {
    /// For each continuation, the sum of the natural-log probabilities of its tokens right after
    /// `request.input.before`, framed like a suggestion. nil when the model isn't loaded right now:
    /// this never loads it.
    func scoreContinuations(_ request: CompletionRequest, continuations: [String]) async throws -> [Float]?
}

public enum EndpointAPI: String, Codable, Sendable { case completions, chatCompletions }

public struct EndpointConfig: Codable, Sendable, Equatable {
    public var baseURL: URL
    public var model: String
    public var api: EndpointAPI
    /// Decision 6: loopback only at first. Remote hosts stay off unless this is set.
    public var allowNonLoopback: Bool
    public var keychainAccount: String?
    public var timeoutSeconds: Double
    public init(baseURL: URL, model: String, api: EndpointAPI = .completions, allowNonLoopback: Bool = false,
                keychainAccount: String? = nil, timeoutSeconds: Double = 10) {
        self.baseURL = baseURL
        self.model = model
        self.api = api
        self.allowNonLoopback = allowNonLoopback
        self.keychainAccount = keychainAccount
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

public protocol SSEParsing: Sendable {
    mutating func feed(_ bytes: Data) -> [SSEEvent]
}

/// What one request cost on the model, reported by engines that can measure it (profiling only, no
/// text). Covers every token decoded for the request: prompt, draft, suggestion and branches.
public struct RequestCost: Sendable, Equatable {
    public var id: RequestID
    public var decodedTokens: Int
    /// Model time: `llama_decode` calls plus reading their results (which waits for the GPU).
    public var decodeMilliseconds: Double
    /// The job ran to its end; false when it was cancelled or failed part way.
    public var finished: Bool
    public var prewarm: Bool
    public init(id: RequestID, decodedTokens: Int, decodeMilliseconds: Double, finished: Bool, prewarm: Bool) {
        self.id = id
        self.decodedTokens = decodedTokens
        self.decodeMilliseconds = decodeMilliseconds
        self.finished = finished
        self.prewarm = prewarm
    }
}
