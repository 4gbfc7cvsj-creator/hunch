// ModelHosting over llama.cpp: load/unload, executor-confined sessions, idle and pressure release.
import Dispatch
import Foundation
import HunchCore
import Synchronization

/// Executor-confined holder of the loaded runtime. Only touched on the executor thread.
private final class RuntimeSlot: @unchecked Sendable {
    var runtime: LlamaRuntime?
    /// What to reload after an idle/pressure release. nil after an explicit unload.
    var reloadTarget: (entry: ModelEntry, options: RuntimeOptions)?
}

/// Hosts one model at a time on a dedicated `GenerationExecutor` thread (design §5.3).
///
/// Release and reload policy:
/// - After `idleReleaseAfterSeconds` without work, or immediately on a memory-pressure warning,
///   the context and model are freed and the state becomes `.releasedIdle(id)`.
/// - The next `withSession` RELOADS transparently (publishing `.loading` then `.ready`) before
///   running its body; the first request pays the load time. The reload is uninterruptible by
///   request cancellation: if that request is superseded or cancelled meanwhile, the load still
///   completes (later requests reuse it) and the request then throws `CancellationError`. Only
///   an eject (`unloadIfModel`), `unload()`, or host teardown aborts a load. If the reload fails,
///   the state becomes `.failed` and `withSession` throws `LlamaError.loadFailed`.
/// - After an explicit `unload()` (or `unloadIfModel(onVolume:)`), nothing is reloaded and
///   `withSession` throws `LlamaError.notLoaded` until `load` is called again.
public final class LlamaModelHost: ModelHosting {
    private struct Observers {
        var current: ModelLoadState = .unloaded
        var continuations: [UUID: AsyncStream<ModelLoadState>.Continuation] = [:]
    }

    private let executor = GenerationExecutor()
    private let slot = RuntimeSlot()
    private let observers = Mutex(Observers())
    private let activity = Atomic<UInt64>(0)
    private let pressureSource: any DispatchSourceMemoryPressure
    private let timerQueue = DispatchQueue(label: "Hunch.LlamaModelHost.timers", qos: .utility)
    /// Path of the loaded or reloadable model (mirror of the slot, readable from any thread).
    private let hostedPath = Mutex<String?>(nil)

    /// Detects family, instruct tuning and chat markers from the GGUF summary (HunchPrompt's
    /// `DefaultModelProfileDetector` in the app). nil keeps the minimal runtime-read profile.
    private let profileDetector: (any ModelProfileDetecting)?

    /// The `.ready` profile is the single source of truth for the loaded model: the detector's
    /// profile (family, markers, ...) with `addsBOS` taken from the loaded vocabulary, which is
    /// authoritative (the GGUF header can disagree, e.g. Gemma 4 base reports `add_bos_token = false`
    /// while its tokenizer adds BOS).
    public init(profileDetector: (any ModelProfileDetecting)? = nil) {
        self.profileDetector = profileDetector
        pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: timerQueue)
        pressureSource.setEventHandler { [weak self] in self?.releaseNow() }
        pressureSource.activate()
    }

    deinit {
        pressureSource.cancel()
        let slot = self.slot
        executor.cancelState.ejectRequested.store(true, ordering: .relaxed) // abort any load in progress
        executor.post {
            slot.runtime?.close()
            slot.runtime = nil
        }
        executor.shutdown()
    }

    // MARK: - ModelHosting

    public func state() async -> ModelLoadState {
        observers.withLock { $0.current }
    }

    public func states() -> AsyncStream<ModelLoadState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelLoadState.self, bufferingPolicy: .bufferingNewest(32))
        let key = UUID()
        observers.withLock {
            continuation.yield($0.current)
            $0.continuations[key] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.observers.withLock { $0.continuations.removeValue(forKey: key) }
        }
        return stream
    }

    public func load(_ entry: ModelEntry, options: RuntimeOptions) async {
        _ = try? await executor.submitInternal { [self] in
            closeRuntime()
            slot.reloadTarget = (entry, options)
            syncHostedPath()
            _ = try? loadOnExecutor(entry: entry, options: options)
        }
    }

    /// While the model is released (idle or memory pressure), changes what the next request
    /// reloads without loading anything, and publishes `.releasedIdle` for the new entry. Returns
    /// false, changing nothing, when a model is loaded or nothing is set to reload: load instead.
    public func retargetIfReleased(_ entry: ModelEntry, options: RuntimeOptions) async -> Bool {
        (try? await executor.submitInternal { [self] in
            guard slot.runtime == nil, slot.reloadTarget != nil else { return false }
            slot.reloadTarget = (entry, options)
            syncHostedPath()
            publish(.releasedIdle(entry.id))
            return true
        }) ?? false
    }

    public func unload() async {
        // Aborts a running load or request; the unload job itself clears the flag.
        executor.cancelState.ejectRequested.store(true, ordering: .relaxed)
        _ = try? await executor.submitInternal { [self] in
            executor.cancelState.ejectRequested.store(false, ordering: .relaxed)
            slot.reloadTarget = nil
            closeRuntime()
            publish(.unloaded)
        }
    }

    public func withSession<T: Sendable>(_ id: RequestID,
                                         _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        try await executor.submit(id) { [self] in
            // Counted as Hunch's own GPU work (Dynamic Power Mode leaves it out of GPU load).
            LocalWork.begin()
            defer { LocalWork.end() }
            let runtime = try ensureRuntime()
            if executor.isCancellationRequested { throw CancellationError() }
            defer { scheduleIdleRelease(after: runtime.options.idleReleaseAfterSeconds) }
            return try body(runtime.session)
        }
    }

    public func cancel(olderThan id: RequestID) {
        executor.cancel(olderThan: id)
    }

    // MARK: - Volume ejection and release

    /// For `NSWorkspace.willUnmountNotification`: if the loaded (or reloadable) model lives on the
    /// volume at `volumeURL`, aborts the running job (request or load), frees context and model on
    /// the executor, and returns only after they are freed. Blocks the calling thread (typically
    /// main) for at most one decode call, or until an in-progress load is aborted. If the model is
    /// elsewhere it returns false immediately and touches nothing. Returns true if it unloaded.
    /// Safe to call from any thread.
    @discardableResult
    public func unloadIfModel(onVolume volumeURL: URL) -> Bool {
        guard Self.hostedPath(hostedPath.withLock { $0 }, isOnVolume: volumeURL) else { return false }
        let state = executor.cancelState
        state.ejectRequested.store(true, ordering: .relaxed)
        return executor.runBlocking { [self] in
            state.ejectRequested.store(false, ordering: .relaxed)
            let path = slot.runtime?.entry.url.path ?? slot.reloadTarget?.entry.url.path
            guard Self.hostedPath(path, isOnVolume: volumeURL) else { return false }
            slot.reloadTarget = nil
            closeRuntime()
            publish(.unloaded)
            return true
        } ?? false
    }

    /// Frees context and model now (memory pressure or idle) and publishes `.releasedIdle`.
    /// The next `withSession` reloads.
    func releaseNow() {
        executor.post { [self] in releaseOnExecutor() }
    }

    /// Pure decision for `unloadIfModel`: nil (nothing hosted) never matches.
    static func hostedPath(_ path: String?, isOnVolume volumeURL: URL) -> Bool {
        guard let path else { return false }
        return self.path(path, isOnVolume: volumeURL)
    }

    static func path(_ path: String, isOnVolume volumeURL: URL) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let volume = volumeURL.standardizedFileURL.resolvingSymlinksInPath().path
        if volume == "/" { return true }
        let prefix = volume.hasSuffix("/") ? volume : volume + "/"
        return file.hasPrefix(prefix)
    }

    // MARK: - Executor-confined helpers

    private func ensureRuntime() throws -> LlamaRuntime {
        if let runtime = slot.runtime { return runtime }
        guard let target = slot.reloadTarget else { throw LlamaError.notLoaded }
        return try loadOnExecutor(entry: target.entry, options: target.options)
    }

    /// The detector's profile with the loaded vocabulary's BOS flag; pure.
    public static func resolveProfile(detected: ModelProfile, vocabAddsBOS: Bool) -> ModelProfile {
        var profile = detected
        profile.addsBOS = vocabAddsBOS
        return profile
    }

    /// Loads inside an uninterruptible section: request cancellation cannot abort it, only
    /// `ejectRequested` (eject, explicit unload, teardown).
    @discardableResult
    private func loadOnExecutor(entry: ModelEntry, options: RuntimeOptions) throws -> LlamaRuntime {
        publish(.loading(entry.id, progress: 0))
        LocalWork.begin()
        defer { LocalWork.end() }
        let state = executor.cancelState
        var lastReported = -1.0
        do {
            let runtime = try executor.uninterruptible {
                try LlamaRuntime.load(entry: entry, options: options, executor: executor,
                                              profileDetector: profileDetector) { [self] p in
                    if p - lastReported >= 0.02 || p >= 1 {
                        lastReported = p
                        publish(.loading(entry.id, progress: p))
                    }
                    return !state.ejectRequested.load(ordering: .relaxed)
                }
            }
            slot.runtime = runtime
            syncHostedPath()
            publish(.ready(entry.id, runtime.profile))
            scheduleIdleRelease(after: options.idleReleaseAfterSeconds)
            return runtime
        } catch {
            let message = (error as? LlamaError)?.description ?? String(describing: error)
            publish(.failed(entry.id, message))
            throw error
        }
    }

    private func closeRuntime() {
        activity.add(1, ordering: .relaxed) // invalidates pending idle timers
        slot.runtime?.close()
        slot.runtime = nil
        syncHostedPath()
    }

    private func syncHostedPath() {
        let path = slot.runtime?.entry.url.path ?? slot.reloadTarget?.entry.url.path
        hostedPath.withLock { $0 = path }
    }

    private func releaseOnExecutor() {
        guard let runtime = slot.runtime else { return }
        let id = runtime.entry.id
        closeRuntime()
        publish(.releasedIdle(id))
    }

    private func scheduleIdleRelease(after seconds: Double?) {
        let generation = activity.add(1, ordering: .relaxed).newValue
        guard let seconds, seconds > 0 else { return }
        timerQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.activity.load(ordering: .relaxed) == generation else { return }
            self.executor.post { [weak self] in
                guard let self, self.activity.load(ordering: .relaxed) == generation else { return }
                self.releaseOnExecutor()
            }
        }
    }

    private func publish(_ state: ModelLoadState) {
        observers.withLock {
            $0.current = state
            for c in $0.continuations.values { c.yield(state) }
        }
    }
}
