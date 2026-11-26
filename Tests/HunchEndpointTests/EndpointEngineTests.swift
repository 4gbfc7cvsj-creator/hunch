import Foundation
import Synchronization
import Testing
@testable import HunchEndpoint
import HunchCore

// MARK: - URLProtocol stub (behavior keyed by the first path component so tests run in parallel)

struct StubBehavior: Sendable {
    var status = 200
    var chunks: [Data] = []
    var chunkDelay: TimeInterval = 0
    var hangAfterChunks = false
    var failure: URLError.Code?
    var redirectTo: String?
}

final class StubState: Sendable {
    let behaviors = Mutex<[String: StubBehavior]>([:])
    let bodies = Mutex<[String: Data]>([:])
    let headers = Mutex<[String: [String: String]]>([:])
    let stopped = Mutex<Set<String>>([])
}
let stubState = StubState()

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private let stopFlag = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var key: String { request.url?.pathComponents.dropFirst().first ?? "" }

    override func startLoading() {
        let key = self.key
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        } else if let b = request.httpBody { body = b }
        stubState.bodies.withLock { $0[key] = body }
        stubState.headers.withLock { $0[key] = request.allHTTPHeaderFields ?? [:] }
        guard let behavior = stubState.behaviors.withLock({ $0[key] }) else { return }
        DispatchQueue.global().async { [self] in
            if let code = behavior.failure {
                client?.urlProtocol(self, didFailWithError: URLError(code)); return
            }
            if let target = behavior.redirectTo {
                let redirect = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: redirect)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: behavior.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in behavior.chunks {
                if stopFlag.withLock({ $0 }) { return }
                client?.urlProtocol(self, didLoad: chunk)
                if behavior.chunkDelay > 0 { Thread.sleep(forTimeInterval: behavior.chunkDelay) }
            }
            if !behavior.hangAfterChunks { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        stopFlag.withLock { $0 = true }
        stubState.stopped.withLock { _ = $0.insert(key) }
    }
}

struct FixedKey: EndpointKeyProviding {
    var key: String?
    func apiKey(forAccount account: String) -> String? { key }
}

func sse(_ pieces: [String], chat: Bool = false) -> [Data] {
    var out = pieces.map { piece -> Data in
        let obj: [String: Any] = chat ? ["choices": [["delta": ["content": piece]]]] : ["choices": [["text": piece]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        return Data("data: \(json)\n\n".utf8)
    }
    out.append(Data("data: [DONE]\n\n".utf8))
    return out
}

func makeEngine(id: String, api: EndpointAPI = .completions, timeout: Double = 5, key: String? = nil,
                        base: String = "http://127.0.0.1:11434") -> EndpointCompletionEngine {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    var config = EndpointConfig(baseURL: URL(string: "\(base)/\(id)/v1")!, model: "test-model", api: api,
                                keychainAccount: key == nil ? nil : "acct", timeoutSeconds: timeout)
    config.allowNonLoopback = false
    return EndpointCompletionEngine(config: config, session: URLSession(configuration: cfg), keys: FixedKey(key: key))
}

private func request(_ id: UInt64 = 1, before: String = "Thanks so much for the ", maxWords: Int = 4) -> CompletionRequest {
    CompletionRequest(id: RequestID(id), context: .sample,
                      input: PromptInput(before: before, maxWords: maxWords),
                      decode: DecodeConfig(maxWords: maxWords))
}

private final class Collector: Sendable {
    let items = Mutex<[String]>([])
    func add(_ s: String) { items.withLock { $0.append(s) } }
}

@Suite struct EndpointEngineTests {
    @Test func streamsPartialsAndFinalResult() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" quick", " reply", " today"])) }
        let engine = makeEngine(id: id)
        let seen = Collector()
        let result = try await engine.complete(request()) { seen.add($0) }
        #expect(result.outcome == .show("quick reply today"))
        #expect(seen.items.withLock { $0 }.last?.hasSuffix("quick reply today") == true)
        #expect(result.timings.firstVisible != nil)
        #expect(engine.kind == .endpoint)
        let body = stubState.bodies.withLock { $0[id] }!
        let o = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(o["stream"] as? Bool == true)
        #expect(o["stop"] as? [String] == ["\n"])
    }

    @Test func sendsBearerKeyOnlyWhenConfigured() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" a b"])) }
        _ = try await makeEngine(id: id, key: "sk-secret").complete(request()) { _ in }
        #expect(stubState.headers.withLock { $0[id] }?["Authorization"] == "Bearer sk-secret")
        let id2 = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id2] = StubBehavior(chunks: sse([" a b"])) }
        _ = try await makeEngine(id: id2).complete(request()) { _ in }
        #expect(stubState.headers.withLock { $0[id2] }?["Authorization"] == nil)
    }

    @Test func chatDeltas() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" great", " news"], chat: true)) }
        let result = try await makeEngine(id: id, api: .chatCompletions).complete(request()) { _ in }
        #expect(result.outcome == .show("great news"))
        let o = try JSONSerialization.jsonObject(with: stubState.bodies.withLock { $0[id] }!) as! [String: Any]
        #expect((o["messages"] as? [[String: String]])?.last?["role"] == "assistant")
    }

    @Test func httpErrorStatus() async {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(status: 500) }
        await #expect(throws: EndpointError.http(status: 500)) {
            _ = try await makeEngine(id: id).complete(request()) { _ in }
        }
    }

    @Test func rejectsRemoteHostBeforeAnyNetwork() async {
        let engine = makeEngine(id: "x", base: "https://example.com")
        await #expect(throws: EndpointError.nonLoopbackNotAllowed) {
            _ = try await engine.complete(request()) { _ in }
        }
    }

    @Test func nonLoopbackRejectedEvenWithFlag() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let config = EndpointConfig(baseURL: URL(string: "https://example.com/nl-flag/v1")!, model: "m",
                                    allowNonLoopback: true)
        let engine = EndpointCompletionEngine(config: config, session: URLSession(configuration: cfg),
                                              keys: FixedKey(key: nil))
        await #expect(throws: EndpointError.nonLoopbackNotAllowed) {
            _ = try await engine.complete(request()) { _ in }
        }
        #expect(stubState.bodies.withLock { $0["nl-flag"] } == nil)
    }

    @Test func redirectStatusIsHTTPError() async {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(status: 307) }
        await #expect(throws: EndpointError.http(status: 307)) {
            _ = try await makeEngine(id: id).complete(request()) { _ in }
        }
    }

    @Test func redirectDelegateRefuses() async {
        let url = URL(string: "http://127.0.0.1/a")!
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: url)
        let next = await NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                         newRequest: URLRequest(url: url))
        #expect(next == nil)
        task.cancel()
    }

    @Test func streamTextIsBoundedAndWordBudgetApplied() async throws {
        let id = "t-" + UUID().uuidString
        let pieces = (0..<2000).map { " w\($0)" }
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse(pieces)) }
        let seen = Collector()
        let result = try await makeEngine(id: id).complete(request(maxWords: 3)) { seen.add($0) }
        #expect(result.outcome == .show("w0 w1 w2"))
        #expect(seen.items.withLock { $0 }.allSatisfy { $0.count < 64 })
    }

    @Test func stopsAtNewlineWhenDisallowed() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" first part", "\nsecond line"])) }
        let result = try await makeEngine(id: id).complete(request(maxWords: 8)) { _ in }
        #expect(result.outcome == .show("first part"))
    }

    @Test func timeoutWhenServerHangs() async {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: [], hangAfterChunks: true) }
        await #expect(throws: EndpointError.timeout) {
            _ = try await makeEngine(id: id, timeout: 0.3).complete(request()) { _ in }
        }
    }

    @Test func taskCancellationStopsTransfer() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" a"]).dropLast().map { $0 }, hangAfterChunks: true) }
        let engine = makeEngine(id: id)
        let task = Task { try await engine.complete(request()) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(stubState.stopped.withLock { $0.contains(id) })
    }

    @Test func newerRequestSupersedesOlder() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: [], hangAfterChunks: true) }
        let engine = makeEngine(id: id)
        let old = Task { try await engine.complete(request(1)) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" new text here"])) }
        let result = try await engine.complete(request(2)) { _ in }
        #expect(result.outcome == .show("new text here"))
        await #expect(throws: CancellationError.self) { _ = try await old.value }
    }

    @Test func explicitCancelOlderThan() async throws {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: [], hangAfterChunks: true) }
        let engine = makeEngine(id: id)
        let task = Task { try await engine.complete(request(5)) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        engine.cancel(olderThan: RequestID(6))
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func prewarmOnlyMakesNoRequest() async throws {
        let id = "t-" + UUID().uuidString
        var r = request(); r.prewarmOnly = true
        let result = try await makeEngine(id: id).complete(r) { _ in }
        #expect(result.outcome == .suppress(.empty))
        #expect(stubState.bodies.withLock { $0[id] } == nil)
    }

    @Test func transportFailureMapsToError() async {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(failure: .cannotConnectToHost) }
        await #expect(throws: EndpointError.self) {
            _ = try await makeEngine(id: id).complete(request()) { _ in }
        }
    }
}

extension TextContext {
    static var sample: TextContext {
        TextContext(app: AppIdentity(bundleID: "test", pid: 1, localizedName: nil),
                    field: FieldID(pid: 1, elementHash: 1, generation: 1), before: "", after: "", contentSignature: 0)
    }
}

@Suite struct EndpointOutboundTests {
    private let input = PromptInput(before: "Hi ", after: "bye", clipboard: "copied", appName: "Mail", domain: "x.com",
                                    windowTitle: "t", styleExamples: ["I like kilns a lot."])

    @Test func nonLoopbackStripsStyleExamplesAndOtherBackground() {
        let out = EndpointCompletionEngine.outbound(input, isLoopback: false)
        #expect(out.styleExamples.isEmpty)
        #expect(out.after.isEmpty && out.clipboard == nil && out.appName == nil && out.domain == nil)
        #expect(out.before == "Hi ")
    }

    @Test func loopbackKeepsStyleExamples() async throws {
        #expect(EndpointCompletionEngine.outbound(input, isLoopback: true) == input)
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" a b"])) }
        let req = CompletionRequest(id: RequestID(1), context: .sample, input: input, decode: DecodeConfig(maxWords: 4))
        _ = try await makeEngine(id: id).complete(req) { _ in }
        let body = String(decoding: stubState.bodies.withLock { $0[id] }!, as: UTF8.self)
        #expect(body.contains("I like kilns a lot."))
    }
}

@Suite struct EndpointRedactionTests {
    /// Synthetic fixtures assembled from pieces (never real credentials).
    private let aws = "AKIA" + "FAKEFAKEFAKEFAKE"
    private let openAI = "sk-" + "FAKEfake0000FAKEfake0000"
    private let filler = String(repeating: "We met at the cafe and talked for a while. ", count: 8)

    @Test func nonLoopbackRedactsEverythingIncludingTheCaretTail() {
        let input = PromptInput(before: "Old \(aws) " + filler + "the new key is \(openAI)",
                                globalInstructions: "My token: fakeToken99", fieldLabel: "Key \(aws)")
        let out = EndpointCompletionEngine.outbound(input, isLoopback: false)
        #expect(!out.before.contains(aws) && !out.before.contains(openAI))
        #expect(out.before.hasSuffix("the new key is [redacted]"))
        #expect(out.globalInstructions == "My token: [redacted]")
        #expect(out.fieldLabel == "Key [redacted]")
    }

    @Test func loopbackSendsTheFramersOutput() async throws {
        let tail = "and my key is \(openAI) ok"
        let input = PromptInput(before: "Old \(aws) " + filler + tail, after: "Later \(aws)")
        #expect(EndpointCompletionEngine.outbound(input, isLoopback: true) == input)
        let id = "r-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" a b"])) }
        let req = CompletionRequest(id: RequestID(1), context: .sample, input: input, decode: DecodeConfig(maxWords: 4))
        _ = try await makeEngine(id: id).complete(req) { _ in }
        let body = String(decoding: stubState.bodies.withLock { $0[id] }!, as: UTF8.self)
        #expect(!body.contains(aws))         // older text and after-caret text are redacted
        #expect(body.contains(openAI))       // the last characters before the caret stay exact
    }
}

@Suite struct EndpointShutdownTests {
    @Test func shutdownInvalidatesSessionSoRequestsFail() async {
        let id = "t-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse([" a b"])) }
        let engine = makeEngine(id: id)
        engine.shutdown()
        let req = CompletionRequest(id: RequestID(1), context: .sample,
                                    input: PromptInput(before: "Thanks so much for the ", maxWords: 4),
                                    decode: DecodeConfig(maxWords: 4))
        var failed = false
        do { _ = try await engine.complete(req) { _ in } } catch { failed = true }
        #expect(failed)
        engine.shutdown()  // idempotent
    }
}
