// OpenAI-compatible endpoint engine (design §5, decision 6). Never logs prompts, completions, or keys.
import Foundation
import HunchCore
import HunchPrompt
import HunchText
import Synchronization

public final class EndpointCompletionEngine: CompletionEngine {
    public let kind: EngineKind = .endpoint

    let config: EndpointConfig
    let session: URLSession
    let keys: any EndpointKeyProviding
    private let registry: any FramerRegistry
    private let postProcessor: any SuggestionPostProcessing
    private let promptTokenBudget: Int
    private let isShutDown = Mutex(false)
    private let active = Mutex<[UInt64: Task<CompletionResult, Error>]>([:])
    /// The write-for-me draft in flight, if any.
    let writes = Mutex<Task<String, any Error>?>(nil)

    var isShutDownNow: Bool { isShutDown.withLock { $0 } }
    /// Write prompts carry long reference text: the remote model's context minus room for the draft.
    var promptBudgetForWrites: Int { 6000 }

    /// - Parameter session: inject a stubbed session in tests. The default session has no cache
    ///   and no cookies.
    public init(config: EndpointConfig,
                session: URLSession? = nil,
                keys: any EndpointKeyProviding = KeychainKeyStore(),
                registry: any FramerRegistry = DefaultFramerRegistry(),
                postProcessor: any SuggestionPostProcessing = DefaultPostProcessor(),
                promptTokenBudget: Int = RuntimeOptions.defaultContextTokens - RuntimeOptions.decodeHeadroom) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = config.timeoutSeconds
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
        self.keys = keys
        self.registry = registry
        self.postProcessor = postProcessor
        self.promptTokenBudget = promptTokenBudget
    }

    public func prewarm(_ request: CompletionRequest) async {}

    public func cancel(olderThan id: RequestID) {
        let victims = active.withLock { tasks in tasks.filter { $0.key < id.raw }.map(\.value) }
        victims.forEach { $0.cancel() }
    }

    /// Cancels everything in flight and invalidates the URLSession. The engine can't be used
    /// afterwards (requests fail); call it when the engine is replaced or dropped.
    public func shutdown() {
        // Flag first: starting a task on an invalidated session raises an Objective-C exception.
        isShutDown.withLock { $0 = true }
        cancel(olderThan: RequestID(.max))
        cancelWrites()
        session.invalidateAndCancel()
    }

    public func complete(_ request: CompletionRequest,
                         partial: @escaping @Sendable (String) -> Void) async throws -> CompletionResult {
        if isShutDown.withLock({ $0 }) { throw CancellationError() }
        try EndpointURLPolicy.validate(config.baseURL, allowNonLoopback: config.allowNonLoopback)
        let clock = ContinuousClock()
        if request.prewarmOnly {
            return CompletionResult(id: request.id, outcome: .suppress(.empty), path: .fresh,
                                    timings: CompletionTimings())
        }
        cancel(olderThan: request.id)  // a newer request supersedes older ones
        let task = Task { try await self.run(request, clock: clock, partial: partial) }
        let raw = request.id.raw
        let superseded = active.withLock { tasks -> Bool in
            if let newest = tasks.keys.max(), newest > raw { return true }
            tasks[raw] = task
            return false
        }
        if superseded { task.cancel() }
        defer { active.withLock { _ = $0.removeValue(forKey: raw) } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The prompt input as it may leave this Mac: after-caret, screen, clipboard, style examples, and
    /// where-you-write details only go to loopback hosts. Text sent to any other host is redacted in
    /// full, including the characters right at the caret the framer otherwise keeps exact.
    static func outbound(_ original: PromptInput, isLoopback: Bool) -> PromptInput {
        var input = original
        if !isLoopback {
            input.after = ""
            input.screenContext = nil
            input.clipboard = nil
            input.styleExamples = []  // the user's past sentences never leave this Mac
            input.windowTitle = nil
            input.domain = nil      // which sites the user writes on stays on this Mac
            input.appName = nil
            func redact(_ text: String) -> String { SecretSanitizer.redact(text, surface: input.surface) }
            input.before = redact(input.before)
            input.globalInstructions = input.globalInstructions.map(redact)
            input.appInstructions = input.appInstructions.map(redact)
            input.aboutWriter = input.aboutWriter.map(redact)
            input.fieldLabel = input.fieldLabel.map(redact)
        }
        return input
    }

    private func run(_ request: CompletionRequest, clock: ContinuousClock,
                     partial: @escaping @Sendable (String) -> Void) async throws -> CompletionResult {
        let start = clock.now
        let isLoopback = EndpointURLPolicy.isLoopback(config.baseURL)
        let input = Self.outbound(request.input, isLoopback: isLoopback)
        let allowNewlines = input.allowNewlines && request.decode.allowNewline

        let framingStart = clock.now
        let profile = EndpointRequestBuilder.profile(for: config.api)
        let framer = registry.framer(for: profile, override: nil)
        let framed = framer.frame(input, profile: profile, budget: promptTokenBudget, counter: CharacterTokenCounter())
        let prompt = EndpointRequestBuilder.prompt(from: framed, api: config.api)
        let body = try EndpointRequestBuilder.body(config: config, prompt: prompt, decode: request.decode,
                                                   allowNewlines: allowNewlines)
        var urlRequest = URLRequest(url: EndpointRequestBuilder.endpointURL(base: config.baseURL, api: config.api))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = config.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let account = config.keychainAccount, let key = keys.apiKey(forAccount: account) {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let framing = clock.now - framingStart
        let wireRequest = urlRequest

        let required = framed.requiredPrefix
        if isShutDown.withLock({ $0 }) { throw CancellationError() }
        let session = self.session
        let timeout = config.timeoutSeconds
        let maxWords = request.decode.maxWords

        let streamed: StreamOutcome = try await withThrowingTaskGroup(of: StreamOutcome?.self) { group in
            group.addTask {
                try await Self.stream(session: session, request: wireRequest, required: required,
                                      allowNewlines: allowNewlines, maxWords: maxWords, start: start,
                                      clock: clock, partial: partial)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw EndpointError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw EndpointError.badResponse }
            return value
        }

        var outcome: PostOutcome = .suppress(.empty)
        if !streamed.mismatch, let text = streamed.text {
            let context = PostContext(before: request.input.before, after: request.input.after,
                                      requiredPrefix: required, allowNewlines: allowNewlines,
                                      maxWords: request.decode.maxWords,
                                      styleExamples: input.styleExamples,
                                      allowedScripts: request.input.allowedScripts,
                                      preferredHanScript: request.input.preferredHanScript,
                                      quoteStyle: request.input.quoteStyle,
                                      allowsURLs: PostContext.allowsURLs(on: request.input.surface),
                                      surface: request.input.surface, screenText: input.screenContext)
            outcome = postProcessor.process(text, meanLogProb: nil, context: context)
        }
        let timings = CompletionTimings(framing: framing, promptSync: .zero, firstVisible: streamed.firstVisible,
                                        total: clock.now - start, decodedPromptTokens: 0)
        return CompletionResult(id: request.id, outcome: outcome, path: .fresh, timings: timings)
    }

    struct StreamOutcome: Sendable {
        var text: String?
        var mismatch: Bool
        var firstVisible: Duration?
    }

    private static func stream(session: URLSession, request: URLRequest, required: String, allowNewlines: Bool,
                               maxWords: Int, start: ContinuousClock.Instant, clock: ContinuousClock,
                               partial: @Sendable (String) -> Void) async throws -> StreamOutcome {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: NoRedirectDelegate())
        } catch let error as URLError {
            throw map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw EndpointError.http(status: http.statusCode) }

        var parser = SSEParser()
        var accumulated = ""
        var firstVisible: Duration?
        var lastShown = ""
        var mismatch = false
        var capped = false
        var pending = Data()
        let cap = max(256, maxWords * 12 + required.count + 64)  // bound on accumulated text

        func consume(_ events: [SSEEvent]) -> Bool {  // true = finished
            for event in events {
                if event.isDone { return true }
                guard let piece = EndpointRequestBuilder.delta(fromEventData: event.data) else { continue }
                accumulated += piece
                if accumulated.count > cap { accumulated = String(accumulated.prefix(cap)); capped = true }
                let stripped = EndpointRequestBuilder.stripRequiredPrefix(accumulated, required: required)
                if stripped.mismatch { mismatch = true; return true }
                guard var text = stripped.text else { continue }
                var hitNewline = false
                if !allowNewlines, let newline = text.firstIndex(where: \.isNewline) {
                    text = String(text[..<newline])
                    hitNewline = true
                }
                var hitBudget = false
                if maxWords > 0 {
                    var trimmed = text
                    while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
                    let clamped = TextMeasure.clamp(trimmed, maxWords: maxWords)
                    if clamped.count < trimmed.count { text = clamped; hitBudget = true }
                }
                if text != lastShown, text.contains(where: { !$0.isWhitespace }) {
                    lastShown = text
                    if firstVisible == nil { firstVisible = clock.now - start }
                    partial(text)
                }
                if hitNewline || capped || hitBudget { return true }
            }
            return false
        }

        do {
            var finished = false
            for try await byte in bytes {
                pending.append(byte)
                if byte == 0x0A {
                    finished = consume(parser.feed(pending))
                    pending.removeAll(keepingCapacity: true)
                    if finished { break }
                }
            }
            if !finished, !pending.isEmpty { _ = consume(parser.feed(pending)) }
            if !finished { _ = consume(parser.feed(Data("\n\n".utf8))) }
        } catch let error as URLError {
            throw map(error)
        }
        try Task.checkCancellation()
        let final = EndpointRequestBuilder.stripRequiredPrefix(accumulated, required: required)
        return StreamOutcome(text: final.text, mismatch: mismatch || final.mismatch, firstVisible: firstVisible)
    }

    static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .timedOut: EndpointError.timeout
        default: EndpointError.transport("\(error.code.rawValue)")
        }
    }
}

/// Refuses every redirect so credentials and text never follow a Location header.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Rough token estimate (about 4 characters per token); the remote tokenizer is unknown.
struct CharacterTokenCounter: TokenCounting {
    func tokenCount(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}

// MARK: - Write for me

extension EndpointCompletionEngine: WriteGenerating {
    /// Longest draft, in tokens, and the shortest time a draft may take before it counts as failed
    /// (a long draft streams for a while; the suggestion timeout is far too short for it).
    static let writeMaxTokens = 1200
    static let writeMinTimeoutSeconds: Double = 90

    public func cancelWrites() {
        writes.withLock { $0?.cancel() }
    }

    public func write(_ request: WriteRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        if isShutDownNow { throw CancellationError() }
        try EndpointURLPolicy.validate(config.baseURL, allowNonLoopback: config.allowNonLoopback)
        let task = Task { try await self.runWrite(request, partial: partial) }
        let previous = writes.withLock { slot -> Task<String, any Error>? in
            let old = slot
            slot = task
            return old
        }
        previous?.cancel()
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The write request as it may leave this Mac: the same rules as suggestions (screen, clipboard,
    /// style and place only to loopback hosts), and secrets in the source masked for remote hosts.
    static func outbound(_ request: WriteRequest, isLoopback: Bool) -> WriteRequest {
        var out = request
        out.context = outbound(request.context, isLoopback: isLoopback)
        if !isLoopback, var dictation = request.dictation {
            // Like screen text for suggestions: what was on screen or in the field stays on this Mac.
            dictation.context.screenNames = []
            dictation.context.textBefore = nil
            dictation.context.aboutMe = nil
            dictation.transcript = SecretSanitizer.redact(dictation.transcript, surface: request.context.surface)
            out.dictation = dictation
        }
        if !isLoopback {
            let surface = request.context.surface
            out.source = SecretSanitizer.redact(request.source, surface: surface)
            out.previousDraft = request.previousDraft.map { SecretSanitizer.redact($0, surface: surface) }
            out.refinements = request.refinements.map { SecretSanitizer.redact($0, surface: surface) }
            out.instruction = request.instruction.map { SecretSanitizer.redact($0, surface: surface) }
        }
        return out
    }

    private func runWrite(_ request: WriteRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let isLoopback = EndpointURLPolicy.isLoopback(config.baseURL)
        let outgoing = Self.outbound(request, isLoopback: isLoopback)
        let profile = EndpointRequestBuilder.profile(for: config.api)
        let framed = WriteForMeFramer().frame(outgoing, profile: profile,
                                              budget: max(1024, promptBudgetForWrites),
                                              counter: CharacterTokenCounter())
        let prompt = EndpointRequestBuilder.prompt(from: framed, api: config.api)
        var decode = DecodeConfig()
        decode.maxTokens = request.replies.map { min(Self.writeMaxTokens, $0.maxTokens) } ?? Self.writeMaxTokens
        let body = try EndpointRequestBuilder.writeBody(config: config, prompt: prompt, decode: decode,
                                                        stops: framed.style != .document ? []
                                                            : request.dictation == nil ? LocalWriterStops.document : ["\n"],
                                                        // A dictation cleanup is a fixed transform: no sampling.
                                                        temperature: request.dictation == nil ? 0.3 : 0)
        let timeout = max(config.timeoutSeconds, Self.writeMinTimeoutSeconds)
        var urlRequest = URLRequest(url: EndpointRequestBuilder.endpointURL(base: config.baseURL, api: config.api))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let account = config.keychainAccount, let key = keys.apiKey(forAccount: account) {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let wire = urlRequest
        let session = self.session
        let mode = request.mode, shape = request.shape
        // Suggested replies are a list the app parses: no draft clean-up.
        let isReplies = request.replies != nil
        let clean: @Sendable (String) -> String = { isReplies ? $0 : DraftCleanup.clean($0, mode: mode, shape: shape) }
        let raw: String = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await Self.streamWrite(session: session, request: wire) { text in
                    partial(clean(text))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw EndpointError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw EndpointError.badResponse }
            return value
        }
        try Task.checkCancellation()
        return clean(raw)
    }

    private static func streamWrite(session: URLSession, request: URLRequest,
                                    progress: @Sendable (String) -> Void) async throws -> String {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: NoRedirectDelegate())
        } catch let error as URLError {
            throw map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw EndpointError.http(status: http.statusCode) }
        var parser = SSEParser()
        var accumulated = ""
        var pending = Data()
        let cap = writeMaxTokens * 8
        func consume(_ events: [SSEEvent]) -> Bool {
            for event in events {
                if event.isDone { return true }
                guard let piece = EndpointRequestBuilder.delta(fromEventData: event.data) else { continue }
                accumulated += piece
                if accumulated.count > cap { accumulated = String(accumulated.prefix(cap)); return true }
                progress(accumulated)
            }
            return false
        }
        do {
            var finished = false
            for try await byte in bytes {
                pending.append(byte)
                if byte == 0x0A {
                    finished = consume(parser.feed(pending))
                    pending.removeAll(keepingCapacity: true)
                    if finished { break }
                }
            }
            if !finished, !pending.isEmpty { _ = consume(parser.feed(pending)) }
            if !finished { _ = consume(parser.feed(Data("\n\n".utf8))) }
        } catch let error as URLError {
            throw map(error)
        }
        try Task.checkCancellation()
        return accumulated
    }
}

/// Where a base-style (completions API) write document goes on past the draft.
enum LocalWriterStops {
    static let document = ["\n\n\n", "\nThe finished", "\nAbout the writer", "\nTheir quick note"]
}
