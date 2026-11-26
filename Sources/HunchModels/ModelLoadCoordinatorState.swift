import Foundation

/// Bookkeeping that keeps model loads and unloads from racing (design §6).
///
/// Every load, unload, and change of the folder root bumps a generation counter. A load captures
/// the generation when it starts; when the runtime returns, `finishLoad` says whether the result
/// may be published or must be thrown away (unload the runtime, leave the status alone). Pure value
/// type: the app's `ModelController` owns one and drives it from the main actor.
public struct ModelLoadCoordinatorState: Sendable, Equatable {
    /// Identifies one load attempt.
    public struct Token: Sendable, Equatable {
        public let generation: UInt64
    }

    /// What to do once `host.load` has returned.
    public enum Completion: Sendable, Equatable {
        /// The load is still current and succeeded: build the engine and publish `.ready`.
        case commit
        /// The load is still current but the runtime failed: publish the failure.
        case reportFailure(String)
        /// A newer load, an unload, or a folder change superseded this load: unload the runtime
        /// (if anything got loaded) and keep whatever status was published meanwhile.
        case discard
    }

    public private(set) var generation: UInt64 = 0
    /// Root path of the folder while it is available; nil otherwise.
    public private(set) var availableRoot: String?

    public init(availableRoot: String? = nil) {
        self.availableRoot = availableRoot
    }

    public var folderAvailable: Bool { availableRoot != nil }

    /// Starts a load attempt and returns its token. Any older attempt becomes stale.
    public mutating func beginLoad() -> Token {
        generation &+= 1
        return Token(generation: generation)
    }

    /// An unload was requested (user action, volume going away, nothing usable). Stales any load.
    public mutating func noteUnload() {
        generation &+= 1
    }

    /// The folder state changed. Losing the folder or switching to another root stales any load;
    /// a refresh of the same available root does not.
    public mutating func folderChanged(availableRoot root: String?) {
        if root != availableRoot || root == nil { generation &+= 1 }
        availableRoot = root
    }

    /// True while nothing has superseded `token` (the folder may still have become unavailable).
    public func isLatest(_ token: Token) -> Bool { token.generation == generation }

    /// True while `token` is the newest attempt and the folder is still available.
    public func isCurrent(_ token: Token) -> Bool {
        token.generation == generation && folderAvailable
    }

    /// Decides what to do with a finished load. `failure` is the runtime's error message, if any.
    public func finishLoad(_ token: Token, failure: String?) -> Completion {
        guard isCurrent(token) else { return .discard }
        if let failure { return .reportFailure(failure) }
        return .commit
    }
}
