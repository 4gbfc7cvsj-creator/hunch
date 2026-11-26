import Foundation

/// Pure parts of a model download: URLs, the part file, resume offsets, response handling and
/// Retry-After. `ModelDownloader` does the network and file I/O.
public enum DownloadPlan {
    /// Appended to the model's file name while downloading. `FolderScanner` lists only `.gguf`,
    /// so a part file never shows up as a model.
    public static let partSuffix = ".part"
    /// Longest Retry-After we wait out; anything longer fails the download instead.
    public static let maxRetryDelay: TimeInterval = 60
    /// Wait used when a 429/503 carries no (or an unreadable) Retry-After.
    public static let defaultRetryDelay: TimeInterval = 2

    /// `https://<host>/<repo>/resolve/main/<file>?download=true`, or nil if the repo or file name
    /// could escape their path segments.
    public static func url(repo: String, fileName: String, host: String = ModelCatalog.host) -> URL? {
        let repoParts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard repoParts.count == 2, repoParts.allSatisfy(isSafeComponent), isSafeComponent(Substring(fileName))
        else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/\(repo)/resolve/main/\(fileName)"
        c.queryItems = [URLQueryItem(name: "download", value: "true")]
        return c.url
    }

    public static func url(for model: CatalogModel, host: String = ModelCatalog.host) -> URL? {
        url(repo: model.repo, fileName: model.fileName, host: host)
    }

    /// A single, non-hidden path component (keeps the part and final files inside the folder).
    static func isSafeComponent(_ s: Substring) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\")
            && !s.contains("\0")
    }

    public static func partURL(for fileName: String, in folder: URL) -> URL {
        folder.appendingPathComponent(fileName + partSuffix, isDirectory: false)
    }

    public static func finalURL(for fileName: String, in folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Where to continue given a part file of `partBytes` (0 if there is none). A part longer than
    /// the expected file can't be a prefix of it, so that one restarts from zero.
    public static func resumeOffset(partBytes: Int64, expectedBytes: Int64) -> Int64 {
        (partBytes > 0 && partBytes <= expectedBytes) ? partBytes : 0
    }

    /// `bytes=<offset>-`, or nil for a fresh download.
    public static func rangeHeader(offset: Int64) -> String? {
        offset > 0 ? "bytes=\(offset)-" : nil
    }

    /// What to do with an HTTP response.
    public enum ResponseAction: Sendable, Equatable {
        /// Write the body starting at this offset in the part file (0 means truncate first).
        case write(from: Int64)
        /// Wait this long, then send the same request again.
        case retry(after: TimeInterval)
        /// Give up with this status.
        case fail(status: Int)
    }

    /// - 200: the server sent the whole file (it may have ignored the Range), so write from zero.
    /// - 206: only if `Content-Range` starts where we asked; anything else would corrupt the part.
    /// - 429/503: retry once (`mayRetry`) after Retry-After, if that's at most `maxRetryDelay`.
    public static func action(status: Int, contentRange: String?, retryAfter: String?, requestedOffset: Int64,
                              mayRetry: Bool, now: Date = Date()) -> ResponseAction {
        switch status {
        case 200:
            return .write(from: 0)
        case 206:
            guard requestedOffset > 0, let range = contentRange, contentRangeStart(range) == requestedOffset else {
                return .fail(status: status)
            }
            return .write(from: requestedOffset)
        case 429, 503:
            guard mayRetry, let delay = retryDelay(retryAfter, now: now) else { return .fail(status: status) }
            return .retry(after: delay)
        default:
            return .fail(status: status)
        }
    }

    /// First byte of `bytes <start>-<end>/<total>`.
    public static func contentRangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst("bytes ".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dash].trimmingCharacters(in: .whitespaces))
    }

    /// Seconds to wait for a Retry-After value (delta-seconds or an HTTP date). nil means the wait
    /// is longer than `maxRetryDelay`; a missing or unreadable value waits `defaultRetryDelay`.
    public static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return defaultRetryDelay }
        let delay: TimeInterval
        if let seconds = Int(raw) {
            delay = TimeInterval(max(0, seconds))
        } else if let date = httpDate(raw) {
            delay = max(0, date.timeIntervalSince(now))
        } else {
            return defaultRetryDelay
        }
        return delay <= maxRetryDelay ? delay : nil
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}

/// Progress of one download.
public struct DownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public init(receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 0
    }

    /// "1.2 of 5.8 GB · 35 MB/s".
    public var summary: String {
        let received = String(format: "%.1f", Double(receivedBytes) / 1e9)
        let rate = Int((bytesPerSecond / 1e6).rounded())
        return "\(received) of \(DownloadFormat.gigabytes(totalBytes)) · \(rate) MB/s"
    }
}

/// Decimal sizes, as Finder shows them.
public enum DownloadFormat {
    /// "5.8 GB".
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }
}

/// Bytes per second over a short sliding window, so the rate follows the connection without
/// jumping on every chunk.
public struct ThroughputMeter: Sendable {
    public let window: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    public init(window: TimeInterval = 3) { self.window = window }

    /// Records the running total of bytes received at `time` (seconds, any monotonic origin).
    public mutating func record(totalBytes: Int64, at time: TimeInterval) {
        samples.append((time, totalBytes))
        while let first = samples.first, samples.count > 2, time - first.time > window { samples.removeFirst() }
    }

    public var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }
}
