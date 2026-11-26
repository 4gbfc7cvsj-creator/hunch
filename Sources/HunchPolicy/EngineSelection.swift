import Foundation
import HunchCore

/// Which engine serves a request: the per-app override wins over the global choice, and the
/// endpoint is only used when one is configured. Everything else falls back to the local model.
public enum EngineSelection {
    public static func kind(globalEngine: EngineKind, endpointConfigured: Bool, appOverride: EngineKind?) -> EngineKind {
        let wanted = appOverride ?? globalEngine
        return wanted == .endpoint && endpointConfigured ? .endpoint : .local
    }

    /// Whether the local model should be loaded up front. Not needed while the global engine is a
    /// usable endpoint and no app or site override asks for `.local`. Requests that still need
    /// the local engine (shell prompts, a freshly added override) load it on demand.
    public static func localModelWanted(globalEngine: EngineKind, endpointConfigured: Bool,
                                        anyLocalOverride: Bool) -> Bool {
        if globalEngine == .local || !endpointConfigured { return true }
        return anyLocalOverride
    }
}

/// Whether an endpoint is worth trying: after a failure it is skipped for `retryAfter`, then tried
/// again; a success clears the failure.
public struct EndpointHealth: Sendable, Equatable {
    public static let retryAfter: Duration = .seconds(30)
    public private(set) var failedAt: ContinuousClock.Instant?

    public init() {}

    public func isAvailable(now: ContinuousClock.Instant = .now) -> Bool {
        guard let failedAt else { return true }
        return now - failedAt >= Self.retryAfter
    }

    public mutating func markFailed(now: ContinuousClock.Instant = .now) { failedAt = now }
    public mutating func markSucceeded() { failedAt = nil }
}
