/// "Fix automatically": which Backspace after an automatic fix undoes it. With no window the first
/// plain Backspace does (it is consumed); with a window the first one reaches the app as usual and
/// only a second one within the window undoes. Held-down (auto-repeat) Backspace never undoes.
/// Pure: both taps ask `decide` with the event's own timestamp, so they agree; the consuming tap
/// then calls `apply`.
public struct BackspaceUndoGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Not the undo: the key does what it always does (and ends the undo, see `apply`).
        case none
        /// The first of the double-tap: it reaches the app; the undo stays armed.
        case firstTap
        /// Consume this Backspace and undo the fix.
        case undo
    }

    public private(set) var armed = false
    /// Further undo presses after the first undo (a reread put back in stages): each must follow the
    /// one before within the window.
    public private(set) var followUps = 0
    /// 0: a single Backspace undoes. Otherwise the second within this many nanoseconds.
    public private(set) var windowNanoseconds: UInt64 = 0
    private var firstTapAt: UInt64?

    public init() {}

    public mutating func arm(_ on: Bool, doubleTapMilliseconds: Int = 0, followUps: Int = 0) {
        armed = on
        self.followUps = on && doubleTapMilliseconds > 0 ? max(0, followUps) : 0
        windowNanoseconds = UInt64(max(0, doubleTapMilliseconds)) * 1_000_000
        firstTapAt = nil
    }

    public func decide(plainBackspace: Bool, autorepeat: Bool, now: UInt64) -> Decision {
        guard armed, plainBackspace, !autorepeat else { return .none }
        guard windowNanoseconds > 0 else { return .undo }
        guard let first = firstTapAt else { return .firstTap }
        return now >= first && now - first <= windowNanoseconds ? .undo : .none
    }

    /// The consuming tap saw a key that `decide` judged: only the first tap keeps the undo armed.
    public mutating func apply(_ decision: Decision, now: UInt64) {
        guard armed else { return }
        switch decision {
        case .firstTap: firstTapAt = now
        case .undo where followUps > 0:
            // Stays armed: the next press within the window undoes the next stage.
            followUps -= 1
            firstTapAt = now
        case .none, .undo:
            armed = false
            firstTapAt = nil
        }
    }
}
