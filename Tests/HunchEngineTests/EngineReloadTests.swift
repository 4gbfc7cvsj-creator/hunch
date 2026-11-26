// Typing through a model reload: requests made while the host loads wait for it (no model needed).
import Foundation
import HunchCore
import HunchLlama
import Synchronization
import Testing
@testable import HunchEngine

/// Opens once; waiters before that are resumed together, waiters after pass straight through.
final class Gate: @unchecked Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }
}

/// Like `LlamaModelHost` after an idle release: the first job reloads (publishing `.loading` until
/// the test calls `finishLoad`), later jobs queue behind the load, and latest-wins rejects any job
/// older than the newest request submitted, including the one that started the load.
final class ReloadingHost: ModelHosting, @unchecked Sendable {
    let session = FakeSession()
    let profile: ModelProfile
    private let entry = ModelEntryID(relativePath: "fake.gguf")
    private let current: Mutex<ModelLoadState>
    private let latest = Mutex<UInt64>(0)
    /// The load in flight (a new one after each idle release).
    private let loaded = Mutex(Gate())

    init(profile: ModelProfile) {
        self.profile = profile
        current = Mutex(.releasedIdle(entry))
    }

    func finishLoad() {
        current.withLock { $0 = .ready(entry, profile) }
        loaded.withLock { $0 }.open()
    }

    func releaseIdle() {
        loaded.withLock { $0 = Gate() }
        current.withLock { $0 = .releasedIdle(entry) }
    }

    var isLoading: Bool { if case .loading = current.withLock({ $0 }) { true } else { false } }

    func state() async -> ModelLoadState { current.withLock { $0 } }
    func states() -> AsyncStream<ModelLoadState> { AsyncStream { $0.finish() } }
    func load(_ entry: ModelEntry, options: RuntimeOptions) async {}
    func unload() async {}
    func cancel(olderThan id: RequestID) { latest.withLock { $0 = max($0, id.raw) } }

    private func superseded(_ id: RequestID) -> Bool { latest.withLock { id.raw < $0 } }

    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        if superseded(id) { throw CancellationError() }
        cancel(olderThan: id)
        let startsLoad = current.withLock { s -> Bool in
            guard case .releasedIdle(let e) = s else { return false }
            s = .loading(e, progress: 0)
            return true
        }
        if startsLoad || isLoading { await loaded.withLock { $0 }.wait() }
        if superseded(id) { throw CancellationError() }
        return try body(session)
    }
}

/// Waits (briefly) until `condition` holds.
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

@Suite struct EngineReloadTests {
    @Test func admissionTable() {
        let entry = ModelEntryID(relativePath: "m.gguf")
        typealias A = LocalCompletionEngine.HostAdmission
        let cases: [(ModelLoadState, Bool, A)] = [
            (.loading(entry, progress: 0.3), true, .waitForHost),
            (.loading(entry, progress: 0.3), false, .waitForHost),
            (.releasedIdle(entry), false, .waitForHost),
            (.releasedIdle(entry), true, .reloadInJob),
            (.ready(entry, baseProfile), false, .run),
            (.ready(entry, baseProfile), true, .run),
            (.unloaded, true, .run),
            (.failed(entry, "x"), true, .run),
        ]
        for (state, knows, expected) in cases {
            #expect(LocalCompletionEngine.admission(for: state, knowsProfile: knows) == expected)
        }
    }

    /// Idle-released before the engine's first request: request 1 starts the reload, request 2
    /// comes while it loads. Request 2 must wait and show; request 1 is superseded.
    @Test func typingThroughReloadBeforeFirstUseShowsLatest() async throws {
        let host = ReloadingHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host, search: { ScriptedSearch(text: " there") })
        let first = Task { try await engine.complete(makeRequest(1, before: "Hi")) { _ in } }
        await eventually { host.isLoading }
        #expect(host.isLoading)
        let second = Task { try await engine.complete(makeRequest(2, before: "Hi t")) { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        host.finishLoad()

        await #expect(throws: CancellationError.self) { try await first.value }
        let result = try await second.value
        #expect(result.outcome == .show(" there"))
    }

    /// Same, after the engine has served before (profile known) and the model was idle-released.
    /// Several keystrokes come during the load; only the newest runs, the others are cancelled.
    @Test func typingThroughIdleReloadShowsOnlyNewest() async throws {
        let host = ReloadingHost(profile: baseProfile)
        let engine = LocalCompletionEngine(host: host, search: { ScriptedSearch(text: " there") })
        let warm = Task { try await engine.complete(makeRequest(1, before: "Hi")) { _ in } }
        await eventually { host.isLoading }
        host.finishLoad()
        #expect(try await warm.value.outcome == .show(" there"))

        host.releaseIdle()
        let starter = Task { try await engine.complete(makeRequest(2, before: "Hi t")) { _ in } }
        await eventually { host.isLoading }
        #expect(host.isLoading)
        let middle = Task { try await engine.complete(makeRequest(3, before: "Hi th")) { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        let newest = Task { try await engine.complete(makeRequest(4, before: "Hi the")) { _ in } }
        try? await Task.sleep(for: .milliseconds(20))
        host.finishLoad()

        await #expect(throws: CancellationError.self) { try await starter.value }
        await #expect(throws: CancellationError.self) { try await middle.value }
        #expect(try await newest.value.outcome == .show(" there"))
    }
}
