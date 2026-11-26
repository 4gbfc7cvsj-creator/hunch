import HunchCore
import os

/// Arbiter with the richer verdict the keyboard monitor needs (Escape, global shortcuts).
public protocol ExtendedAcceptanceArbitrating: AcceptanceArbitrating {
    func inputVerdict(for chord: KeyChord, now: UInt64) -> InputVerdict
    /// Global shortcuts only; used by the listen-only path when no ghost is visible.
    func shortcut(for chord: KeyChord) -> GlobalShortcut?
    /// Bound global shortcuts; while non-empty the monitor keeps its consuming tap on.
    var globalShortcutChords: [KeyChord] { get }
}

/// Lock-protected snapshot + bindings. Every method is safe to call from the event-tap thread;
/// none of them blocks on anything but a short unfair lock.
public final class DefaultAcceptanceArbiter: ExtendedAcceptanceArbitrating {
    private struct State {
        var snapshot: ArbiterSnapshot?
        var bindings: AcceptBindings
    }

    private let state: OSAllocatedUnfairLock<State>
    private let maxAgeTicks: UInt64

    public init(bindings: AcceptBindings = AcceptBindings(),
                maxAgeNanoseconds: UInt64 = Freshness.defaultMaxAgeNanoseconds,
                timebase: MachTimebase = .current) {
        state = OSAllocatedUnfairLock(initialState: State(snapshot: nil, bindings: bindings))
        maxAgeTicks = timebase.ticks(fromNanoseconds: maxAgeNanoseconds)
    }

    public func publish(_ snapshot: ArbiterSnapshot?) {
        state.withLock { $0.snapshot = snapshot }
    }

    public func setBindings(_ bindings: AcceptBindings) {
        state.withLock { $0.bindings = bindings }
    }

    public var bindings: AcceptBindings { state.withLock { $0.bindings } }

    public func verdict(for chord: KeyChord, now: UInt64) -> TapVerdict {
        inputVerdict(for: chord, now: now).tapVerdict
    }

    public func inputVerdict(for chord: KeyChord, now: UInt64) -> InputVerdict {
        let current = state.withLock { $0 }
        return ArbiterRules.decide(chord: chord, snapshot: current.snapshot, bindings: current.bindings,
                                   now: now, maxAgeTicks: maxAgeTicks)
    }

    public var globalShortcutChords: [KeyChord] { TapRules.globalShortcutChords(bindings) }

    public func shortcut(for chord: KeyChord) -> GlobalShortcut? {
        ArbiterRules.shortcut(for: chord, bindings: bindings)
    }
}
