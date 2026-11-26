// Decision 6: loopback only at first. Pure.
import Foundation

public enum EndpointError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    /// Any non-loopback host (`EndpointConfig.allowNonLoopback` is ignored until a redactor ships).
    case nonLoopbackNotAllowed
    /// Plain http to a non-loopback host is never allowed.
    case insecureRemote
    case http(status: Int)
    case timeout
    case badResponse
    case transport(String)
}

extension EndpointError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The endpoint URL is not valid."
        case .unsupportedScheme: "The endpoint URL must use http or https."
        case .nonLoopbackNotAllowed: "Remote endpoints are disabled. Only localhost addresses are allowed."
        case .insecureRemote: "Remote endpoints must use https."
        case .http(let status): "The endpoint answered with HTTP status \(status)."
        case .timeout: "The endpoint did not answer in time."
        case .badResponse: "The endpoint sent a response that could not be understood."
        case .transport(let message): "Could not reach the endpoint: \(message)"
        }
    }
}

public enum EndpointURLPolicy {
    /// Loopback is exactly: `localhost`, a canonical dotted-quad in 127.0.0.0/8, or `::1`
    /// (also `0:0:0:0:0:0:0:1`, bracketed or not). Everything else is rejected: `*.localhost`,
    /// a trailing dot, short forms such as `127.1`, IPv4-mapped IPv6 (`::ffff:127.0.0.1`), and
    /// any hostname that merely resolves to loopback.
    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return true }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return false }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 4 && numbers.allSatisfy { (0...255).contains($0) } && numbers[0] == 127
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        return isLoopbackHost(host)
    }

    /// Throws when `url` may not be used. Only loopback hosts are allowed. `allowNonLoopback` is
    /// deliberately ignored until a secret redactor exists (design decision 6).
    public static func validate(_ url: URL, allowNonLoopback: Bool = false) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw EndpointError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else { throw EndpointError.unsupportedScheme }
        guard isLoopbackHost(host) else { throw EndpointError.nonLoopbackNotAllowed }
    }
}
