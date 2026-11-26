// GenerationExecutor: the single thread that owns every piece of llama.cpp state (design §5.3).
import Foundation
import HunchCore
import Synchronization

/// Cancellation flags shared between the executor, the running job, and llama's abort callback
/// (which may be invoked from ggml worker threads, hence atomics only).
final class ExecutorCancelState: Sendable {
    /// Sentinel for "the running job is not a request" (internal jobs are never superseded).
    static let noRequest = UInt64.max

    /// Highest RequestID seen so far (latest-wins watermark).
    let latest = Atomic<UInt64>(0)
    /// RequestID of the job that is running now, or `noRequest`.
    let running = Atomic<UInt64>(ExecutorCancelState.noRequest)
    /// Set when the running job's Swift task was cancelled.
    let runningTaskCancelled = Atomic<Bool>(false)
    /// Hard abort (volume eject, explicit unload, shutdown). Overrides `shielded`; cleared by
    /// the job that requested it once it has run.
    let ejectRequested = Atomic<Bool>(false)
    /// True while the running job is inside an uninterruptible section (a model load): request
    /// supersession and task cancellation are ignored there, only `ejectRequested` aborts.
    let shielded = Atomic<Bool>(false)

    var shouldAbort: Bool {
        if ejectRequested.load(ordering: .relaxed) { return true }
        if shielded.load(ordering: .relaxed) { return false }
        if runningTaskCancelled.load(ordering: .relaxed) { return true }
        let id = running.load(ordering: .relaxed)
        return id != Self.noRequest && id < latest.load(ordering: .relaxed)
    }

    /// Whether a request job that ran to the end must still throw its result away: only after an
    /// eject or its own task's cancellation. A newer request alone does not discard it (the work is
    /// complete, and the caller decides whether a late result is still useful).
    var discardsFinishedWork: Bool {
        ejectRequested.load(ordering: .relaxed) || runningTaskCancelled.load(ordering: .relaxed)
    }
}

/// C-compatible abort callback for `llama_set_abort_callback`; `data` is an unretained
/// `ExecutorCancelState` that outlives every context (it is owned by the executor).
let executorAbortCallback: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { data in
    guard let data else { return false }
    return Unmanaged<ExecutorCancelState>.fromOpaque(data).takeUnretainedValue().shouldAbort
}

/// One dedicated `Thread` with a serial FIFO queue and a latest-wins policy for request jobs.
///
/// - Request jobs carry a `RequestID`. Submitting (or `cancel(olderThan:)`) with id N removes
///   queued request jobs with id < N (they throw `CancellationError` without running) and raises
///   the watermark so a running job with id < N observes `isCancellationRequested`. A job that
///   still runs to the end returns its value (a late result); its task's cancellation discards it.
/// - Internal jobs (load, unload, release) carry no id and are never superseded.
final class GenerationExecutor: @unchecked Sendable {
    private struct Job {
        let serial: UInt64
        let requestID: RequestID?
        /// Runs the work and resumes the continuation. Called on the executor thread.
        let run: () -> Void
        /// Resumes the continuation with an error without running. Called off the lock.
        let reject: (any Error) -> Void
    }

    let cancelState = ExecutorCancelState()

    // Guarded by `cond`.
    private let cond = NSCondition()
    private var queue: [Job] = []
    private var nextSerial: UInt64 = 1
    private var runningSerial: UInt64 = 0
    private var preCancelled: Set<UInt64> = []
    private var stopped = false

    private var thread: Thread?

    init(name: String = "Hunch.GenerationExecutor") {
        // The thread retains the executor until `shutdown()` lets the loop return.
        let t = Thread { self.loop() }
        t.name = name
        t.qualityOfService = .userInteractive
        t.stackSize = 8 << 20
        thread = t
        t.start()
    }

    /// Stops the thread after the queued jobs have run. Further submissions are rejected.
    func shutdown() {
        cond.lock()
        stopped = true
        cond.signal()
        cond.unlock()
    }

    var isOnExecutorThread: Bool { Thread.current === thread }

    /// True when the job running now has been superseded or its task was cancelled.
    var isCancellationRequested: Bool { cancelState.shouldAbort }

    /// Raises the latest-wins watermark and drops queued request jobs older than `id`.
    func cancel(olderThan id: RequestID) {
        cond.lock()
        let dropped = raiseWatermarkLocked(id)
        cond.unlock()
        for job in dropped { job.reject(CancellationError()) }
    }

    /// Submits `work` to run on the executor thread and awaits its result.
    func submit<T: Sendable>(_ requestID: RequestID?, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let serial = allocateSerial()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                let state = cancelState
                let job = Job(
                    serial: serial,
                    requestID: requestID,
                    run: {
                        if state.shouldAbort {
                            cont.resume(throwing: CancellationError())
                            return
                        }
                        do {
                            let value = try work()
                            if requestID != nil && state.discardsFinishedWork {
                                cont.resume(throwing: CancellationError())
                            } else {
                                cont.resume(returning: value)
                            }
                        } catch {
                            cont.resume(throwing: error)
                        }
                    },
                    reject: { cont.resume(throwing: $0) }
                )
                enqueue(job)
            }
        } onCancel: {
            self.cancelJob(serial)
        }
    }

    /// Awaits an internal job that is never superseded and ignores the awaiting task's
    /// cancellation (it always runs once queued). Throws only `executorStopped`.
    func submitInternal<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            enqueue(Job(serial: allocateSerial(), requestID: nil,
                        run: { cont.resume(with: Result { try work() }) },
                        reject: { cont.resume(throwing: $0) }))
        }
    }

    /// Runs `body` (on the executor thread, inside the running job) so that request
    /// supersession and task cancellation cannot abort it; only `ejectRequested` can. Used for
    /// model (re)loads. Cancellation that arrived meanwhile is observed again afterwards.
    func uninterruptible<T>(_ body: () throws -> T) rethrows -> T {
        precondition(isOnExecutorThread, "uninterruptible must run on the generation executor")
        let wasShielded = cancelState.shielded.exchange(true, ordering: .relaxed)
        defer { cancelState.shielded.store(wasShielded, ordering: .relaxed) }
        return try body()
    }

    /// Fire-and-forget internal job (never superseded). Dropped silently after `shutdown()`.
    func post(_ work: @escaping @Sendable () -> Void) {
        enqueue(Job(serial: allocateSerial(), requestID: nil, run: work, reject: { _ in }))
    }

    /// Blocks the calling thread until `work` has run on the executor. Must not be called from
    /// the executor thread itself (it would deadlock); in that case `work` runs inline.
    func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        if isOnExecutorThread { return work() }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        post {
            box.value = work()
            done.signal()
        }
        cond.lock()
        let wasStopped = stopped
        cond.unlock()
        if wasStopped { return nil }
        done.wait()
        return box.value
    }

    // MARK: - Private

    private func allocateSerial() -> UInt64 {
        cond.lock()
        defer { cond.unlock() }
        let serial = nextSerial
        nextSerial += 1
        return serial
    }

    private func enqueue(_ job: Job) {
        cond.lock()
        if stopped || preCancelled.remove(job.serial) != nil {
            let wasStopped = stopped
            cond.unlock()
            job.reject(wasStopped ? LlamaError.executorStopped : CancellationError())
            return
        }
        var dropped: [Job] = []
        if let id = job.requestID {
            if id.raw < cancelState.latest.load(ordering: .relaxed) {
                // Already superseded before it was queued.
                cond.unlock()
                job.reject(CancellationError())
                return
            }
            dropped = raiseWatermarkLocked(id)
        }
        queue.append(job)
        cond.signal()
        cond.unlock()
        for d in dropped { d.reject(CancellationError()) }
    }

    /// Must hold `cond`. Returns the queued jobs that were removed.
    private func raiseWatermarkLocked(_ id: RequestID) -> [Job] {
        if id.raw > cancelState.latest.load(ordering: .relaxed) {
            cancelState.latest.store(id.raw, ordering: .relaxed)
        }
        var dropped: [Job] = []
        queue.removeAll { job in
            guard let rid = job.requestID, rid < id else { return false }
            dropped.append(job)
            return true
        }
        return dropped
    }

    private func cancelJob(_ serial: UInt64) {
        cond.lock()
        if let index = queue.firstIndex(where: { $0.serial == serial }) {
            let job = queue.remove(at: index)
            cond.unlock()
            job.reject(CancellationError())
            return
        }
        if runningSerial == serial {
            cancelState.runningTaskCancelled.store(true, ordering: .relaxed)
        } else {
            // Not queued yet (or already finished). Remember it so a late enqueue is rejected;
            // entries for finished jobs are harmless, and the set is capped.
            if preCancelled.count > 1024 { preCancelled.removeAll() }
            preCancelled.insert(serial)
        }
        cond.unlock()
    }

    private func loop() {
        while true {
            cond.lock()
            while queue.isEmpty && !stopped { cond.wait() }
            if queue.isEmpty && stopped {
                cond.unlock()
                return
            }
            let job = queue.removeFirst()
            runningSerial = job.serial
            cancelState.runningTaskCancelled.store(false, ordering: .relaxed)
            cancelState.running.store(job.requestID?.raw ?? ExecutorCancelState.noRequest, ordering: .relaxed)
            cond.unlock()

            autoreleasepool { job.run() }

            cond.lock()
            runningSerial = 0
            cancelState.running.store(ExecutorCancelState.noRequest, ordering: .relaxed)
            cancelState.runningTaskCancelled.store(false, ordering: .relaxed)
            cancelState.shielded.store(false, ordering: .relaxed)
            cond.unlock()
        }
    }
}

/// Hand-off cell for `runBlocking`; written on the executor before the semaphore signals.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
