import Foundation
import Testing
import HunchCore
@testable import HunchLlama

@Suite struct GenerationExecutorTests {
    @Test func runsOnItsOwnThread() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let onExecutor = try await executor.submit(RequestID(1)) { executor.isOnExecutorThread }
        #expect(onExecutor)
        #expect(!executor.isOnExecutorThread)
    }

    @Test func runningRequestObservesNewerRequest() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let first = Task {
            try await executor.submit(RequestID(1)) { () -> Int in
                let deadline = Date().addingTimeInterval(5)
                while !executor.isCancellationRequested && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                if executor.isCancellationRequested { throw CancellationError() }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        let second = try await executor.submit(RequestID(2)) { 2 }
        #expect(second == 2)
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test func supersededWorkThatFinishesStillReturns() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let first = Task {
            try await executor.submit(RequestID(1)) { () -> Int in
                Thread.sleep(forTimeInterval: 0.15) // never checks for cancellation
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        executor.cancel(olderThan: RequestID(2))
        #expect(try await first.value == 1)
        #expect(try await executor.submit(RequestID(2)) { 2 } == 2)
    }

    @Test func cancelledTaskDiscardsFinishedWork() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let task = Task {
            try await executor.submit(RequestID(1)) { () -> Int in
                Thread.sleep(forTimeInterval: 0.15)
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func queuedOlderRequestNeverRuns() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let ran = Atomicish()
        let blocker = Task { try await executor.submit(nil) { Thread.sleep(forTimeInterval: 0.3) } }
        try await Task.sleep(for: .milliseconds(50))
        let older = Task { try await executor.submit(RequestID(10)) { ran.set(); return 10 } }
        try await Task.sleep(for: .milliseconds(30))
        let newer = try await executor.submit(RequestID(11)) { 11 }
        #expect(newer == 11)
        await #expect(throws: CancellationError.self) { try await older.value }
        #expect(!ran.value)
        try await blocker.value // internal jobs are never superseded

        // Already-superseded ids are rejected; the executor stays usable.
        await #expect(throws: CancellationError.self) { try await executor.submit(RequestID(5)) { 5 } }
        executor.cancel(olderThan: RequestID(20))
        await #expect(throws: CancellationError.self) { try await executor.submit(RequestID(19)) { 19 } }
        #expect(try await executor.submit(RequestID(20)) { 20 } == 20)
    }

    @Test func taskCancellationReachesRunningWork() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let task = Task {
            try await executor.submit(RequestID(1)) { () -> Int in
                let deadline = Date().addingTimeInterval(5)
                while !executor.isCancellationRequested && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                if executor.isCancellationRequested { throw CancellationError() }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await executor.submit(RequestID(2)) { 2 } == 2)
    }

    @Test func abortCallbackReflectsCancelState() {
        let state = ExecutorCancelState()
        let ptr = Unmanaged.passUnretained(state).toOpaque()
        #expect(executorAbortCallback(ptr) == false)
        state.running.store(3, ordering: .relaxed)
        state.latest.store(4, ordering: .relaxed)
        #expect(executorAbortCallback(ptr) == true)
        state.running.store(ExecutorCancelState.noRequest, ordering: .relaxed)
        #expect(executorAbortCallback(ptr) == false)
    }

    @Test func volumePathMatching() {
        #expect(LlamaModelHost.path("/Volumes/Samsung 1TB/LLM/m.gguf", isOnVolume: URL(fileURLWithPath: "/Volumes/Samsung 1TB")))
        #expect(!LlamaModelHost.path("/Volumes/Samsung 1TB2/m.gguf", isOnVolume: URL(fileURLWithPath: "/Volumes/Samsung 1TB")))
        #expect(!LlamaModelHost.path("/Volumes/T7/m.gguf", isOnVolume: URL(fileURLWithPath: "/Volumes/Samsung 1TB")))
        // Prefix trap: a sibling volume whose name starts with the ejected volume's name.
        let samsung = URL(fileURLWithPath: "/Volumes/Samsung 1TB")
        #expect(!LlamaModelHost.path("/Volumes/Samsung 1TB 2/LLM/m.gguf", isOnVolume: samsung))
        #expect(!LlamaModelHost.hostedPath("/Volumes/Samsung 1TB 2/LLM/m.gguf", isOnVolume: samsung))
        #expect(LlamaModelHost.path("/Volumes/Samsung 1TB/m.gguf", isOnVolume: URL(fileURLWithPath: "/Volumes/Samsung 1TB/")))
        #expect(LlamaModelHost.hostedPath("/Volumes/Samsung 1TB/LLM/m.gguf", isOnVolume: samsung))
        #expect(!LlamaModelHost.hostedPath(nil, isOnVolume: samsung))
    }

    @Test func unloadIfModelOnOtherVolumeLeavesRunningJobAlone() async throws {
        let host = LlamaModelHost() // nothing hosted: never matches, never cancels
        #expect(!host.unloadIfModel(onVolume: URL(fileURLWithPath: "/Volumes/Samsung 1TB")))
    }

    @Test func uninterruptibleSectionIgnoresSupersessionButNotEject() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let seen = FlagLog()
        await #expect(throws: CancellationError.self) {
            try await executor.submit(RequestID(1)) { () -> Int in
                executor.uninterruptible {
                    executor.cancel(olderThan: RequestID(2))
                    executor.cancelState.runningTaskCancelled.store(true, ordering: .relaxed)
                    seen.add(executor.isCancellationRequested)  // false: shielded
                    executor.cancelState.ejectRequested.store(true, ordering: .relaxed)
                    seen.add(executor.isCancellationRequested)  // true: eject wins
                    executor.cancelState.ejectRequested.store(false, ordering: .relaxed)
                }
                seen.add(executor.isCancellationRequested)  // true again after the section
                return 1
            }
        }
        #expect(seen.values == [false, true, true])
        #expect(try await executor.submit(RequestID(3)) { 3 } == 3)
    }

    @Test func internalJobIgnoresTaskCancellation() async throws {
        let executor = GenerationExecutor()
        defer { executor.shutdown() }
        let task = Task {
            try await executor.submitInternal { () -> Bool in
                Thread.sleep(forTimeInterval: 0.1)
                return executor.isCancellationRequested
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(try await task.value == false)
    }
}

final class FlagLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func add(_ b: Bool) { lock.withLock { items.append(b) } }
    var values: [Bool] { lock.withLock { items } }
}

final class Atomicish: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
