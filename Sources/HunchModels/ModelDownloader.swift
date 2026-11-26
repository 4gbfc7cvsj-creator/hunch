import CryptoKit
import Foundation

/// Why a download stopped.
public enum DownloadError: Error, Sendable, Equatable {
    /// The same file is already downloading.
    case alreadyRunning
    /// The catalog entry's repo or file name can't form a safe URL or path.
    case invalidEntry
    /// The server answered with this status (after the one Retry-After retry, for 429/503).
    case http(status: Int)
    /// The finished file didn't match the catalog's SHA-256 (or was longer than its size). The part
    /// file has been deleted.
    case hashMismatch
    /// The connection ended early. The part file is kept; downloading again resumes it.
    case incomplete(receivedBytes: Int64, expectedBytes: Int64)
    /// Cancelled by the user. The part file is kept.
    case cancelled
    case network(String)
    case fileSystem(String)

    /// One line for Settings.
    public var message: String {
        switch self {
        case .alreadyRunning: "This model is already downloading."
        case .invalidEntry: "This catalog entry is invalid."
        case .http(let status): "\(ModelCatalog.host) answered HTTP \(status)."
        case .hashMismatch: "The file didn't match its checksum and was deleted."
        case .incomplete: "The connection ended early."
        case .cancelled: "Cancelled."
        case .network(let message): message
        case .fileSystem(let message): "Couldn't write the file: \(message)"
        }
    }
}

/// A running download: progress, the result, and cancellation.
public struct ModelDownload: Sendable {
    /// Ends when the download ends, however it ends.
    public let progress: AsyncStream<DownloadProgress>
    /// The final file's URL, or a `DownloadError`.
    public let task: Task<URL, any Error>

    public func cancel() { task.cancel() }
    public var result: URL { get async throws { try await task.value } }
}

/// Downloads catalog models into the models folder; only ever started by the user.
///
/// Streams to `<file>.gguf.part` (invisible to `FolderScanner`), resuming from an existing part
/// with a Range request after hashing the bytes already there, so the final SHA-256 covers the
/// whole file. On a match the part is renamed to its final name and FSEvents rescans the folder;
/// on a mismatch the part is deleted. Cancelling keeps the part for the next attempt.
public actor ModelDownloader {
    private let session: URLSession
    private let chunkSize: Int
    private let progressInterval: TimeInterval
    private var running: Set<String> = []

    /// - Parameters:
    ///   - session: injected in tests (a `URLProtocol` stub); defaults to an uncached ephemeral session.
    ///   - chunkSize: bytes buffered before each write and hash update.
    ///   - progressInterval: minimum seconds between progress values (the last one is always sent).
    public init(session: URLSession? = nil, chunkSize: Int = 1 << 20, progressInterval: TimeInterval = 0.25) {
        self.session = session ?? Self.makeSession()
        self.chunkSize = max(1, chunkSize)
        self.progressInterval = progressInterval
    }

    /// No URL cache (multi-GB bodies) and no cookies. Redirects are followed, which Hugging Face
    /// needs: `resolve/main` answers with a redirect to its CDN.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }

    /// Starts, or resumes, downloading `model` into `folder`.
    public func download(_ model: CatalogModel, into folder: URL) -> ModelDownload {
        let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !running.contains(model.fileName) else {
            continuation.finish()
            return ModelDownload(progress: stream, task: Task { throw DownloadError.alreadyRunning })
        }
        running.insert(model.fileName)
        let job = Job(session: session, model: model, folder: folder, chunkSize: chunkSize,
                      progressInterval: progressInterval, progress: continuation)
        // Isolated to the actor only for the bookkeeping; `run` streams on the concurrent pool.
        let task = Task<URL, any Error> {
            defer {
                continuation.finish()
                self.finished(model.fileName)
            }
            return try await job.run()
        }
        return ModelDownload(progress: stream, task: task)
    }

    private func finished(_ fileName: String) { running.remove(fileName) }
}

/// One download's I/O, off the actor so streaming doesn't hold it.
private struct Job: Sendable {
    let session: URLSession
    let model: CatalogModel
    let folder: URL
    let chunkSize: Int
    let progressInterval: TimeInterval
    let progress: AsyncStream<DownloadProgress>.Continuation

    @concurrent func run() async throws -> URL {
        guard let url = DownloadPlan.url(for: model) else { throw DownloadError.invalidEntry }
        let part = DownloadPlan.partURL(for: model.fileName, in: folder)
        let final = DownloadPlan.finalURL(for: model.fileName, in: folder)
        let fm = FileManager.default
        let expected = model.byteSize

        let partBytes = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        var offset = DownloadPlan.resumeOffset(partBytes: partBytes, expectedBytes: expected)
        if !fm.fileExists(atPath: part.path) {
            guard fm.createFile(atPath: part.path, contents: nil) else {
                throw DownloadError.fileSystem("can't create \(part.lastPathComponent)")
            }
        }
        let handle: FileHandle
        do { handle = try FileHandle(forUpdating: part) } catch { throw DownloadError.fileSystem(error.localizedDescription) }
        defer { try? handle.close() }

        // Re-hash what an earlier attempt left, so the digest covers the whole file.
        var hasher = SHA256()
        do {
            try handle.truncate(atOffset: UInt64(offset))
            try hasher.updateFromStart(of: handle, length: offset, cancellable: true)
        } catch is CancellationError {
            throw DownloadError.cancelled
        } catch {
            throw DownloadError.fileSystem(error.localizedDescription)
        }

        var meter = ThroughputMeter()
        let clock = ContinuousClock()
        let start = clock.now
        func seconds() -> TimeInterval {
            let d = clock.now - start
            return TimeInterval(d.components.seconds) + TimeInterval(d.components.attoseconds) / 1e18
        }
        var lastSent = -TimeInterval.infinity
        func report(_ received: Int64, force: Bool) {
            let now = seconds()
            meter.record(totalBytes: received, at: now)
            guard force || now - lastSent >= progressInterval else { return }
            lastSent = now
            progress.yield(DownloadProgress(receivedBytes: received, totalBytes: expected,
                                            bytesPerSecond: meter.bytesPerSecond))
        }
        report(offset, force: true)

        if offset < expected {
            offset = try await fetch(url: url, from: offset, into: handle, hasher: &hasher, report: report)
        }
        try? handle.close()

        guard offset >= expected else {
            throw DownloadError.incomplete(receivedBytes: offset, expectedBytes: expected)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard offset == expected, digest == model.sha256.lowercased() else {
            try? fm.removeItem(at: part)
            throw DownloadError.hashMismatch
        }
        do {
            try fm.moveItem(at: part, to: final)
        } catch {
            throw DownloadError.fileSystem(error.localizedDescription)
        }
        report(offset, force: true)
        return final
    }

    /// Sends the request (retrying once on 429/503) and appends the body to the part file.
    /// Returns the part file's length afterwards.
    private func fetch(url: URL, from requested: Int64, into handle: FileHandle, hasher: inout SHA256,
                       report: (Int64, Bool) -> Void) async throws -> Int64 {
        var request = URLRequest(url: url)
        if let range = DownloadPlan.rangeHeader(offset: requested) { request.setValue(range, forHTTPHeaderField: "Range") }

        var retried = false
        while true {
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                throw Self.map(error)
            }
            let http = response as? HTTPURLResponse
            let action = DownloadPlan.action(status: http?.statusCode ?? 0,
                                             contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                             retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                             requestedOffset: requested, mayRetry: !retried)
            switch action {
            case .fail(let status):
                bytes.task.cancel()
                throw DownloadError.http(status: status)
            case .retry(let delay):
                bytes.task.cancel()
                retried = true
                do { try await Task.sleep(for: .seconds(delay)) } catch { throw DownloadError.cancelled }
                continue
            case .write(let from):
                if from != requested {
                    // The server ignored the Range and sent the whole file: start over.
                    do {
                        try handle.truncate(atOffset: 0)
                    } catch {
                        throw DownloadError.fileSystem(error.localizedDescription)
                    }
                    hasher = SHA256()
                }
                return try await stream(bytes, from: from, into: handle, hasher: &hasher, report: report)
            }
        }
    }

    private func stream(_ bytes: URLSession.AsyncBytes, from start: Int64, into handle: FileHandle,
                        hasher: inout SHA256, report: (Int64, Bool) -> Void) async throws -> Int64 {
        var received = start
        var buffer: [UInt8] = []
        buffer.reserveCapacity(chunkSize)
        func flush() throws {
            guard !buffer.isEmpty else { return }
            let data = Data(buffer)
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= chunkSize {
                    try flush()
                    // More than the catalog size can't hash right; stop reading.
                    if received > model.byteSize { break }
                    report(received, false)
                }
            }
            try flush()
        } catch {
            // Keep whatever arrived: it is a valid prefix for the next attempt.
            try? flush()
            if Task.isCancelled { throw DownloadError.cancelled }
            if let mapped = error as? DownloadError { throw mapped }
            if error is CocoaError { throw DownloadError.fileSystem(error.localizedDescription) }
            throw Self.map(error)
        }
        if received > model.byteSize { bytes.task.cancel() }
        if Task.isCancelled, received < model.byteSize { throw DownloadError.cancelled }
        report(received, true)
        return received
    }

    static func map(_ error: any Error) -> DownloadError {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            return .cancelled
        }
        return .network(error.localizedDescription)
    }
}

private extension SHA256 {
    /// Hashes the first `length` bytes of `handle`, leaving it positioned at `length`.
    mutating func updateFromStart(of handle: FileHandle, length: Int64, cancellable: Bool) throws {
        try handle.seek(toOffset: 0)
        var left = length
        while left > 0 {
            if cancellable { try Task.checkCancellation() }
            let n = Int(min(left, 4 << 20))
            guard let data = try handle.read(upToCount: n), !data.isEmpty else { break }
            update(data: data)
            left -= Int64(data.count)
        }
        try handle.seek(toOffset: UInt64(length))
    }
}
