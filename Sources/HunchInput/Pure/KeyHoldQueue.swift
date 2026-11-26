/// Holds the user's key presses while Hunch edits text behind the caret (autocorrect catch-up,
/// automatic fixes), then hands them back in order to be posted again ("replayed").
///
/// Pure bookkeeping, generic over the event so it is testable without posting anything. Every held
/// press gets an order number; a replayed press carries it back to the tap, so presses typed while
/// earlier ones are still on their way are held too (`draining`) and posted after them, and a new
/// hold that starts mid-replay keeps everything in typing order.
public struct KeyHoldQueue<Event> {
    public enum Mode: Equatable, Sendable {
        case idle
        /// Holding until released, or until `deadline` (nanoseconds of uptime) at the latest.
        case holding(deadline: UInt64)
        /// Replays posted; new presses wait until the one numbered `lastOrder` has passed the tap.
        case draining(lastOrder: Int, since: UInt64)
    }

    /// The most a hold may last; the caller gives up its edit before this.
    public static var maxHoldNanoseconds: UInt64 { 1_500_000_000 }
    /// Replays that never come back (another tap ate one) stop the draining after this.
    public static var maxDrainNanoseconds: UInt64 { 1_000_000_000 }

    public private(set) var mode: Mode = .idle
    private var queue: [(order: Int, event: Event)] = []
    private var nextOrder = 1

    public init() {}

    /// Keys are being held or replayed: the consuming tap must stay on.
    public var isActive: Bool { mode != .idle }
    public var heldCount: Int { queue.count }

    /// Starts (or extends) a hold. Presses already waiting stay in the queue, in order.
    public mutating func begin(now: UInt64, maxDuration: UInt64 = Self.maxHoldNanoseconds) {
        mode = .holding(deadline: now &+ min(maxDuration, Self.maxHoldNanoseconds))
    }

    /// A key press from the user. True when it is held (the tap consumes it).
    public mutating func userKey(_ event: Event) -> Bool {
        guard mode != .idle else { return false }
        queue.append((nextOrder, event))
        nextOrder += 1
        return true
    }

    /// A replayed press (numbered `order`) reached the tap. True when it is held again (a new hold
    /// began while it was on its way): the tap consumes it.
    public mutating func replayArrived(order: Int, event: Event) -> Bool {
        guard case .holding = mode else { return false }
        let index = queue.firstIndex { $0.order > order } ?? queue.endIndex
        queue.insert((order, event), at: index)
        return true
    }

    /// After the tap handled a replayed press it let through: when it was the last one on its way,
    /// presses typed meanwhile are posted next (returned, numbered) or the queue goes idle.
    public mutating func replayPassed(order: Int, now: UInt64) -> [(order: Int, event: Event)] {
        guard case .draining(let last, _) = mode, order >= last else { return [] }
        return flush(now: now)
    }

    /// The edit is done (or abandoned): the held presses to post, in order. Safe to call when idle.
    public mutating func release(now: UInt64) -> [(order: Int, event: Event)] {
        guard case .holding = mode else { return [] }
        return flush(now: now)
    }

    /// Timer check: a hold past its deadline is released; a drain whose last replay never came back
    /// posts what is waiting and ends.
    public mutating func tick(now: UInt64) -> [(order: Int, event: Event)] {
        switch mode {
        case .idle:
            return []
        case .holding(let deadline):
            return now >= deadline ? flush(now: now) : []
        case .draining(_, let since):
            guard now &- since >= Self.maxDrainNanoseconds else { return [] }
            let out = queue
            queue = []
            mode = .idle
            return out
        }
    }

    private mutating func flush(now: UInt64) -> [(order: Int, event: Event)] {
        let out = queue
        queue = []
        if let last = out.last {
            mode = .draining(lastOrder: last.order, since: now)
        } else {
            mode = .idle
        }
        return out
    }
}
