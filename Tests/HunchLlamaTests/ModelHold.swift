// Test-only: model-loading suites hold a process-wide lock for the lifetime of each suite
// instance (swift-testing creates one per test), so two Metal models never decode at once even
// when suites are scheduled in parallel. (A TestScoping trait crashes this toolchain.)
import Foundation

final class ModelHold: @unchecked Sendable {
    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private static let gate = Gate()

    init() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let g = Self.gate
            g.lock.lock()
            if g.held { g.waiters.append(c); g.lock.unlock() } else { g.held = true; g.lock.unlock(); c.resume() }
        }
    }

    deinit {
        let g = Self.gate
        g.lock.lock()
        if g.waiters.isEmpty { g.held = false; g.lock.unlock() } else { let c = g.waiters.removeFirst(); g.lock.unlock(); c.resume() }
    }
}
