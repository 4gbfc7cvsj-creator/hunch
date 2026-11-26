import Foundation
import HunchCore

/// Decides when a new capture is allowed: at most one per `interval` per field.
public struct CaptureThrottle: Sendable {
    public let interval: Duration
    private var lastField: FieldID?
    private var lastAt: ContinuousClock.Instant?

    public init(interval: Duration = .seconds(3)) { self.interval = interval }

    public func mayCapture(field: FieldID, now: ContinuousClock.Instant) -> Bool {
        guard lastField == field, let lastAt else { return true }
        return now - lastAt >= interval
    }

    public mutating func recordCapture(field: FieldID, at now: ContinuousClock.Instant) {
        lastField = field
        lastAt = now
    }
}
