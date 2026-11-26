import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import HunchModels
import HunchCore

/// What the stub server does for one request.
private enum StubReply: Sendable {
    /// Sends the response and body, then finishes; `stall` keeps the connection open after the body.
    case respond(status: Int, headers: [String: String], body: Data, stall: Bool = false)
    case redirect(to: URL)
}

/// Serves `huggingface.co` requests from per-repo handlers, so suites running in parallel don't
/// see each other's traffic. Records every request it gets.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubReply
    static let handlers = Mutex<[String: Handler]>([:])
    static let requests = Mutex<[String: [URLRequest]]>([:])

    static func register(repo: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[repo] = handler }
    }

    static func requests(for repo: String) -> [URLRequest] { requests.withLock { $0[repo] ?? [] } }

    /// "owner/name" from `/owner/name/resolve/main/file`.
    static func repo(of url: URL?) -> String {
        let parts = url?.path.split(separator: "/") ?? []
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : ""
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let repo = Self.repo(of: request.url)
        Self.requests.withLock { $0[repo, default: []].append(request) }
        guard let handler = Self.handlers.withLock({ $0[repo] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch handler(request) {
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .respond(let status, let headers, let body, let stall):
            // A content type stops URLSession from holding back the first 512 bytes to sniff one.
            let fields = headers.merging(["Content-Type": "application/octet-stream"]) { a, _ in a }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            if !stall { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {}
}

/// Counts every request; used only by the at-rest test.
private final class CountingProtocol: URLProtocol, @unchecked Sendable {
    static let count = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool {
        count.withLock { $0 += 1 }
        return false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
}

private func session<P: URLProtocol>(_ type: P.Type) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [type]
    config.urlCache = nil
    return URLSession(configuration: config)
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("gt-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u.resolvingSymlinksInPath()
}

private func payload(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

private func model(repo: String, body: Data, sha256: String? = nil) -> CatalogModel {
    CatalogModel(displayName: "Test", repo: repo, fileName: "test.gguf", sha256: sha256 ?? sha(body),
                 byteSize: Int64(body.count), parameterBillions: 1, parameterLabel: "1B", quantization: "Q4_K_M",
                 family: .gemma, isInstruct: false, minimumRAMBytes: 0, recommendedTier: nil)
}

private func uniqueRepo() -> String { "stub/\(UUID().uuidString)" }

private func downloader(chunk: Int = 64) -> ModelDownloader {
    ModelDownloader(session: session(StubProtocol.self), chunkSize: chunk, progressInterval: 0)
}

private func fullBody(_ body: Data) -> StubReply {
    .respond(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
}

@Suite(.timeLimit(.minutes(1))) struct ModelDownloaderTests {
    @Test func happyPath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(1000)
        let repo = uniqueRepo()
        StubProtocol.register(repo: repo) { _ in fullBody(body) }

        let job = await downloader().download(model(repo: repo, body: body), into: dir)
        var last: DownloadProgress?
        for await p in job.progress { last = p }
        let url = try await job.result

        #expect(url == dir.appendingPathComponent("test.gguf"))
        #expect(try Data(contentsOf: url) == body)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("test.gguf.part").path))
        #expect(last?.receivedBytes == 1000 && last?.totalBytes == 1000)
        let sent = StubProtocol.requests(for: repo)
        #expect(sent.count == 1)
        #expect(sent.first?.value(forHTTPHeaderField: "Range") == nil)
        #expect(sent.first?.url?.absoluteString == "https://huggingface.co/\(repo)/resolve/main/test.gguf?download=true")
    }

    @Test func resumesFromPartWithRangeAndHashesWholeFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(1000)
        try body.prefix(300).write(to: dir.appendingPathComponent("test.gguf.part"))
        let repo = uniqueRepo()
        StubProtocol.register(repo: repo) { request in
            guard request.value(forHTTPHeaderField: "Range") == "bytes=300-" else { return fullBody(Data()) }
            return .respond(status: 206, headers: ["Content-Range": "bytes 300-999/1000", "Content-Length": "700"],
                            body: body.suffix(from: 300))
        }

        let job = await downloader().download(model(repo: repo, body: body), into: dir)
        var first: DownloadProgress?
        for await p in job.progress where first == nil { first = p }
        let url = try await job.result

        #expect(first?.receivedBytes == 300)
        #expect(try Data(contentsOf: url) == body)
        #expect(StubProtocol.requests(for: repo).map { $0.value(forHTTPHeaderField: "Range") } == ["bytes=300-"])
    }

    @Test func serverIgnoringRangeRestartsFromZero() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(500)
        try Data(repeating: 0xEE, count: 200).write(to: dir.appendingPathComponent("test.gguf.part"))
        let repo = uniqueRepo()
        StubProtocol.register(repo: repo) { _ in fullBody(body) }

        let url = try await downloader().download(model(repo: repo, body: body), into: dir).result
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func hashMismatchDeletesPart() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(1000)
        let repo = uniqueRepo()
        StubProtocol.register(repo: repo) { _ in fullBody(body) }

        let job = await downloader().download(model(repo: repo, body: body, sha256: String(repeating: "0", count: 64)),
                                              into: dir)
        await #expect(throws: DownloadError.hashMismatch) { try await job.result }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.isEmpty)
    }

    @Test func cancelKeepsPart() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(1000)
        let repo = uniqueRepo()
        // Sends the first 256 bytes, then hangs.
        StubProtocol.register(repo: repo) { _ in
            .respond(status: 200, headers: ["Content-Length": "1000"], body: body.prefix(256), stall: true)
        }

        let job = await downloader(chunk: 64).download(model(repo: repo, body: body), into: dir)
        for await p in job.progress where p.receivedBytes >= 256 {
            job.cancel()
            break
        }
        await #expect(throws: DownloadError.cancelled) { try await job.result }
        let part = try Data(contentsOf: dir.appendingPathComponent("test.gguf.part"))
        #expect(part == body.prefix(256))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("test.gguf").path))

        // The next attempt resumes from the kept bytes.
        StubProtocol.register(repo: repo) { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=256-")
            return .respond(status: 206, headers: ["Content-Range": "bytes 256-999/1000"], body: body.suffix(from: 256))
        }
        let url = try await downloader().download(model(repo: repo, body: body), into: dir).result
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func followsRedirects() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(400)
        let repo = uniqueRepo()
        let cdn = URL(string: "https://huggingface.co/\(repo)/cdn/object")!
        StubProtocol.register(repo: repo) { request in
            request.url?.path.contains("/resolve/") == true ? .redirect(to: cdn) : fullBody(body)
        }
        let url = try await downloader().download(model(repo: repo, body: body), into: dir).result
        #expect(try Data(contentsOf: url) == body)
        #expect(StubProtocol.requests(for: repo).count == 2)
    }

    @Test func retryAfterIsHonouredOnce() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(100)
        let repo = uniqueRepo()
        let calls = Mutex(0)
        StubProtocol.register(repo: repo) { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1 ? .respond(status: 429, headers: ["Retry-After": "0"], body: Data()) : fullBody(body)
        }
        let url = try await downloader().download(model(repo: repo, body: body), into: dir).result
        #expect(try Data(contentsOf: url) == body)

        let busy = uniqueRepo()
        StubProtocol.register(repo: busy) { _ in .respond(status: 503, headers: ["Retry-After": "0"], body: Data()) }
        let failing = await downloader().download(model(repo: busy, body: body), into: dir)
        await #expect(throws: DownloadError.http(status: 503)) { try await failing.result }
        #expect(StubProtocol.requests(for: busy).count == 2)
    }

    @Test func secondConcurrentDownloadOfSameFileIsRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = payload(1000)
        let repo = uniqueRepo()
        StubProtocol.register(repo: repo) { _ in
            .respond(status: 200, headers: [:], body: body.prefix(64), stall: true)
        }
        let d = downloader()
        let first = await d.download(model(repo: repo, body: body), into: dir)
        let second = await d.download(model(repo: repo, body: body), into: dir)
        await #expect(throws: DownloadError.alreadyRunning) { try await second.result }
        first.cancel()
        await #expect(throws: DownloadError.cancelled) { try await first.result }
    }

    /// Nothing at rest touches the network: building the downloader and asking the catalog and
    /// the recommender for everything Settings shows.
    @Test func noNetworkAtRest() async throws {
        let counting = session(CountingProtocol.self)
        _ = ModelDownloader(session: counting)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = ModelRecommender.recommend(ramBytes: MachineFacts.physicalMemory, chipBrand: MachineFacts.chipBrand,
                                       freeDiskBytes: MachineFacts.freeDiskBytes(at: dir))
        for entry in ModelCatalog.entries {
            _ = ModelRecommender.warnings(for: entry, ramBytes: 16 << 30, chipBrand: "Apple M1", freeDiskBytes: nil)
            _ = DownloadPlan.url(for: entry)
        }
        _ = ModelCatalog.downloaded(relativePaths: ["gemma-4-E4B.i1-Q5_K_M.gguf"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(CountingProtocol.count.withLock { $0 } == 0)
    }
}
