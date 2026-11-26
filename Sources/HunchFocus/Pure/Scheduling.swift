import Foundation

/// Adaptive poll interval: fast right after typing activity, backing off when idle.
public struct PollSchedule: Sendable, Equatable {
    public var fast: Duration
    public var medium: Duration
    public var slow: Duration
    /// How long after activity the fast rate holds.
    public var fastWindow: Duration
    /// How long after activity the medium rate holds (after that, slow).
    public var mediumWindow: Duration

    public init(fast: Duration = .milliseconds(50), medium: Duration = .milliseconds(250), slow: Duration = .seconds(1),
                fastWindow: Duration = .seconds(2), mediumWindow: Duration = .seconds(10)) {
        self.fast = fast
        self.medium = medium
        self.slow = slow
        self.fastWindow = fastWindow
        self.mediumWindow = mediumWindow
    }

    public func interval(sinceActivity elapsed: Duration) -> Duration {
        if elapsed < fastWindow { return fast }
        if elapsed < mediumWindow { return medium }
        return slow
    }
}

/// Cooldown after an AX messaging timeout, so a hung app doesn't stall every tick.
/// Doubles per consecutive timeout up to `maximum`; a successful tick resets it.
public struct HangBackoff: Sendable, Equatable {
    public var base: Duration
    public var maximum: Duration
    public private(set) var consecutive = 0

    public init(base: Duration = .milliseconds(500), maximum: Duration = .seconds(8)) {
        self.base = base
        self.maximum = maximum
    }

    public mutating func recordTimeout() -> Duration {
        consecutive += 1
        var d = base
        for _ in 1..<consecutive {
            d = d * 2
            if d >= maximum { return maximum }
        }
        return min(d, maximum)
    }

    public mutating func recordSuccess() { consecutive = 0 }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
