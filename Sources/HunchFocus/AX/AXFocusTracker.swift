import AppKit
import ApplicationServices
import Foundation
import HunchCore
import HunchPolicy

/// Secure Event Input state, supplied by the app (wired to HunchPolicy's probe).
public struct SecureInputState: Sendable, Equatable {
    public var enabled: Bool
    public var ownerPID: pid_t?
    public init(enabled: Bool, ownerPID: pid_t? = nil) {
        self.enabled = enabled
        self.ownerPID = ownerPID
    }
}

/// Focus tracker: AXObserver notifications plus an adaptive poll, all on one dedicated AX thread
/// with its own run loop. AX is never touched on the main thread.
///
/// Per tick (design §7.1): system gate (no element access) → focused element → metadata probe →
/// element gate → only with a pass, read text and caret → emit (deduplicated).
public final class AXFocusTracker: FocusTracking, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var limits: ContextLimits
        public var schedule: PollSchedule
        /// Per-element AX messaging timeout, in seconds.
        public var messagingTimeout: Float
        public init(limits: ContextLimits = ContextLimits(), schedule: PollSchedule = PollSchedule(),
                    messagingTimeout: Float = 0.1) {
            self.limits = limits
            self.schedule = schedule
            self.messagingTimeout = messagingTimeout
        }
    }

    let configuration: Configuration
    let secureInput: @Sendable () -> SecureInputState
    let globallyEnabled: @Sendable () -> Bool
    /// Autocorrect may read fields even where suggestions are off (false during a timed pause).
    let autocorrectActive: @Sendable () -> Bool
    /// Read on the AX thread before each window-title read; false skips the AX call.
    let windowTitleEnabled: @Sendable () -> Bool
    let log: FocusLog
    let ownPID = ProcessInfo.processInfo.processIdentifier

    // Guarded by `lock`.
    private let lock = NSLock()
    private var pauseReasons: Set<PauseReason> = []
    /// A small panel of this app has the keyboard for a moment (the menu under a fixed word): its
    /// own text field being focused is not "focus left the field".
    private var lendingFocus = false
    private var lastActivity: ContinuousClock.Instant = .now
    private var continuation: AsyncStream<FocusEvent>.Continuation?
    private var frontmost: AppIdentity?
    private var runLoop: CFRunLoop?
    private var engine: FocusEngine?
    private var thread: Thread?
    private var workspaceObserver: NSObjectProtocol?
    private var pollIsSlow = true

    public init(configuration: Configuration = Configuration(),
                secureInput: @escaping @Sendable () -> SecureInputState,
                globallyEnabled: @escaping @Sendable () -> Bool,
                autocorrectActive: @escaping @Sendable () -> Bool = { false },
                debugLogging: @escaping @Sendable () -> Bool = { false },
                windowTitleEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.configuration = configuration
        self.secureInput = secureInput
        self.globallyEnabled = globallyEnabled
        self.autocorrectActive = autocorrectActive
        self.windowTitleEnabled = windowTitleEnabled
        self.log = FocusLog(enabled: debugLogging)
    }

    deinit {
        continuation?.finish()
    }

    // MARK: FocusTracking

    public func start(gate: any SecureGating, policies: any AppPolicyResolving) {
        let alreadyRunning: Bool = lock.withLock { thread != nil }
        guard !alreadyRunning else { return }

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            self.runThread(gate: gate, policies: policies, ready: ready)
        }
        t.name = "Hunch.AX"
        t.qualityOfService = .userInteractive
        lock.withLock { thread = t }
        t.start()
        ready.wait()
        observeWorkspace()
    }

    public func stop() {
        let (rl, observer) = lock.withLock { () -> (CFRunLoop?, NSObjectProtocol?) in
            let r = (runLoop, workspaceObserver)
            thread = nil
            workspaceObserver = nil
            return r
        }
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let rl {
            perform(on: rl) { engine in engine.requestStop() }
        }
        emit(.focusLost)
    }

    public func pause(_ reason: PauseReason) {
        // Insert the reason and emit the pause notice under one lock hold, so a concurrent
        // tick's `emit(.context)` (which checks the paused state under the same lock) is
        // either delivered before the notice or dropped after it. Yielding never blocks on
        // the AX thread, so a panel opening on main cannot deadlock here.
        let wasRunning: Bool = lock.withLock {
            let was = pauseReasons.isEmpty
            pauseReasons.insert(reason)
            if was { continuation?.yield(.blocked(.trackingPaused, nil)) }
            return was
        }
        guard wasRunning else { return }
        performOnEngine { $0.didPause() }
    }

    public func resume(_ reason: PauseReason) {
        let nowRunning: Bool = lock.withLock {
            guard pauseReasons.remove(reason) != nil else { return false }
            return pauseReasons.isEmpty
        }
        guard nowRunning else { return }
        noteActivity()
        performOnEngine { $0.didResume() }
    }

    public func events() -> AsyncStream<FocusEvent> {
        let (stream, cont) = AsyncStream<FocusEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let old: AsyncStream<FocusEvent>.Continuation? = lock.withLock {
            let o = continuation
            continuation = cont
            return o
        }
        old?.finish()
        return stream
    }

    public func noteTypingActivity() {
        let slow = noteActivity()
        if slow {
            performOnEngine { $0.tickSoon(after: 0.02) }
        }
    }

    /// Re-runs the system stage and the element stage (metadata only, never text) for the element
    /// that is focused RIGHT NOW, on the AX thread. Returns a fresh pass only if focus is still on
    /// `field` and both stages allow; nil if tracking is stopped or paused, focus moved, a gate
    /// blocks, or the AX thread doesn't answer within `timeout`.
    public func currentPass(for field: FieldID, timeout: Duration = .milliseconds(500)) async -> SecureGatePass? {
        guard !isPaused, let rl = lock.withLock({ runLoop }) else { return nil }
        let box = OneShotReply<SecureGatePass?>(fallback: nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<SecureGatePass?, Never>) in
            box.install(continuation)
            perform(on: rl) { engine in box.resolve(engine.freshPass(for: field)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds) {
                box.resolve(nil)
            }
        }
    }

    /// Selects `backward` UTF-16 units before the caret of `field` and `forward` after it, through
    /// `AXSelectedTextRange`, and confirms the host now has `expected` selected. Same gates as
    /// `currentPass`; the caret is put back on any mismatch. After `.timedOut` the selection may still
    /// change, so re-read the field before deleting with keys.
    public func selectAroundCaret(field: FieldID, backward: Int, forward: Int, expected: String,
                                  timeout: Duration = .milliseconds(500)) async -> Result<Void, CaretSelection.Failure> {
        guard !isPaused, let rl = lock.withLock({ runLoop }) else { return .failure(.focusMoved) }
        typealias Answer = Result<Void, CaretSelection.Failure>
        let box = OneShotReply<Answer>(fallback: .failure(.timedOut))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            box.install(continuation)
            perform(on: rl) { engine in
                box.resolve(engine.selectAroundCaret(field: field, backward: backward, forward: forward,
                                                     expected: expected))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds) {
                box.resolve(.failure(.timedOut))
            }
        }
    }

    /// Reads `field` once with `limits` (wider than the tracker's own, for write for me), with the
    /// same gates as `currentPass`. Nothing is emitted; nil when a gate blocks, focus moved, the
    /// read fails or the AX thread doesn't answer within `timeout`.
    public func read(field: FieldID, limits: ContextLimits, timeout: Duration = .milliseconds(500)) async -> TextContext? {
        guard !isPaused, let rl = lock.withLock({ runLoop }) else { return nil }
        let box = OneShotReply<TextContext?>(fallback: nil)
        return await withCheckedContinuation { (continuation: CheckedContinuation<TextContext?, Never>) in
            box.install(continuation)
            perform(on: rl) { engine in box.resolve(engine.read(field: field, limits: limits)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds) {
                box.resolve(nil)
            }
        }
    }

    /// Autocorrect catch-up: checks the text from a word up to the caret of `field` is
    /// `expectedSpan`, then selects the word (`expectedWord`, the start of the span) through
    /// `AXSelectedTextRange` and confirms it. Returns the caret's UTF-16 offset from before. The caret
    /// is put back on any mismatch; after `.timedOut` re-read before acting.
    public func selectBehindCaret(field: FieldID, expectedSpan: String, expectedWord: String,
                                  timeout: Duration = .milliseconds(400)) async -> Result<Int, CaretSelection.Failure> {
        await onAXThread(timeout: timeout, fallback: .failure(.timedOut)) { engine in
            engine.selectBehindCaret(field: field, expectedSpan: expectedSpan, expectedWord: expectedWord)
        } ?? .failure(.focusMoved)
    }

    /// Collapses the caret of `field` at `location` and confirms the text before it ends with
    /// `expectedBefore`. Success carries the highlight bounds (AppKit coordinates) of
    /// `highlightUTF16` units starting `highlightStartBack` before `location`, when usable.
    public func placeCaret(field: FieldID, location: Int, expectedBefore: String, highlightStartBack: Int,
                           highlightUTF16: Int, timeout: Duration = .milliseconds(400)) async
        -> Result<CGRect?, CaretSelection.Failure> {
        await onAXThread(timeout: timeout, fallback: .failure(.timedOut)) { engine in
            engine.placeCaret(field: field, location: location, expectedBefore: expectedBefore,
                              highlightStartBack: highlightStartBack, highlightUTF16: highlightUTF16)
        } ?? .failure(.focusMoved)
    }

    /// Moves the collapsed caret of `field` `forward` UTF-16 units and confirms the text before it
    /// then ends with `expectedBefore`.
    public func moveCaretForward(field: FieldID, forward: Int, expectedBefore: String,
                                 timeout: Duration = .milliseconds(400)) async -> Result<Void, CaretSelection.Failure> {
        await onAXThread(timeout: timeout, fallback: .failure(.timedOut)) { engine in
            engine.moveCaretForward(field: field, forward: forward, expectedBefore: expectedBefore)
        } ?? .failure(.focusMoved)
    }

    /// Bounds (AppKit coordinates) of `word`, which starts `textToCaret` before the caret of `field`
    /// (the faint line under a fixed word). Falls back to text markers in Chromium hosts.
    public func wordBoundsBehindCaret(field: FieldID, textToCaret: String, word: String,
                                      timeout: Duration = .milliseconds(250)) async -> Result<CGRect, BehindCaret.BoundsMiss> {
        await onAXThread(timeout: timeout, fallback: .failure(.timedOut)) { engine in
            engine.wordBoundsBehindCaret(field: field, textToCaret: textToCaret, word: word)
        } ?? .failure(.focusMoved)
    }

    /// Bounds (AppKit coordinates) of `length` UTF-16 units starting `back` before the caret of
    /// `field`, for highlighting a word just changed there; why not when the host has none worth drawing.
    public func boundsBehindCaret(field: FieldID, back: Int, length: Int,
                                  timeout: Duration = .milliseconds(200)) async -> Result<CGRect, BehindCaret.BoundsMiss> {
        await onAXThread(timeout: timeout, fallback: .failure(.timedOut)) { engine in
            engine.boundsBehindCaret(field: field, back: back, length: length)
        } ?? .failure(.focusMoved)
    }

    /// Runs `body` on the AX thread; `fallback` after `timeout`, nil when tracking is stopped or paused.
    private func onAXThread<Value: Sendable>(timeout: Duration, fallback: Value,
                                             _ body: @escaping @Sendable (FocusEngine) -> Value) async -> Value? {
        guard !isPaused, let rl = lock.withLock({ runLoop }) else { return nil }
        let box = OneShotReply<Value>(fallback: fallback)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            box.install(continuation)
            perform(on: rl) { engine in box.resolve(body(engine)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds) {
                box.resolve(fallback)
            }
        }
    }

    // MARK: Shared state (any thread)

    /// Records activity; returns whether the poll was running slower than the fast rate.
    @discardableResult
    func noteActivity() -> Bool {
        lock.withLock {
            lastActivity = .now
            let wasSlow = pollIsSlow
            pollIsSlow = false
            return wasSlow
        }
    }

    var isPaused: Bool { lock.withLock { !pauseReasons.isEmpty } }
    var isLendingFocus: Bool { lock.withLock { lendingFocus } }

    /// On while one of this app's panels holds the keyboard without activating it (the host stays
    /// frontmost): reads that find this app's own element focused are skipped instead of reporting
    /// the field as left, so the field and its fixes are still there when the panel closes and the
    /// host gets the keyboard back. Nothing is read or changed meanwhile.
    public func setLendingFocus(_ on: Bool) {
        lock.withLock { lendingFocus = on }
        if !on { _ = noteActivity() }
    }
    var timeSinceActivity: Duration { lock.withLock { ContinuousClock.now - lastActivity } }
    var currentFrontmost: AppIdentity? { lock.withLock { frontmost } }

    func setPollIsSlow(_ slow: Bool) { lock.withLock { pollIsSlow = slow } }

    func emit(_ event: FocusEvent) {
        lock.withLock {
            guard FocusEmissionGate.shouldDeliver(event, paused: !pauseReasons.isEmpty) else { return }
            continuation?.yield(event)
        }
    }

    // MARK: Threading

    private func runThread(gate: any SecureGating, policies: any AppPolicyResolving, ready: DispatchSemaphore) {
        guard let rl = CFRunLoopGetCurrent() else {
            ready.signal()
            return
        }
        let engine = FocusEngine(owner: self, gate: gate, policies: policies)
        lock.withLock {
            runLoop = rl
            self.engine = engine
        }
        engine.install(on: rl)
        ready.signal()

        while !engine.stopRequested {
            _ = CFRunLoopRunInMode(.defaultMode, 1.0, false)
        }
        engine.teardown()
        lock.withLock {
            if self.engine === engine {
                self.engine = nil
                runLoop = nil
            }
        }
    }

    private func performOnEngine(_ body: @escaping @Sendable (FocusEngine) -> Void) {
        guard let rl = lock.withLock({ runLoop }) else { return }
        perform(on: rl, body)
    }

    private func perform(on rl: CFRunLoop, _ body: @escaping @Sendable (FocusEngine) -> Void) {
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            guard let engine = lock.withLock({ self.engine }) else { return }
            body(engine)
        }
        CFRunLoopWakeUp(rl)
    }

    // MARK: Frontmost app (NSWorkspace, main thread)

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                       queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // The screenshot UI briefly activates; keep tracking the app being captured.
            if let id = app.bundleIdentifier, Self.transientSystemUI.contains(id) { return }
            self.setFrontmost(Self.identity(of: app))
        }
        lock.withLock { workspaceObserver = token }
        let readInitial: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let app = NSWorkspace.shared.frontmostApplication else { return }
                self?.setFrontmost(Self.identity(of: app))
            }
        }
        if Thread.isMainThread { readInitial() } else { DispatchQueue.main.async(execute: readInitial) }
    }

    private func setFrontmost(_ identity: AppIdentity) {
        lock.withLock { frontmost = identity }
        noteActivity()
        performOnEngine { $0.frontmostChanged() }
    }

    static let transientSystemUI: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher"]

    private static func identity(of app: NSRunningApplication) -> AppIdentity {
        AppIdentity(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier, localizedName: app.localizedName)
    }
}

/// One-shot reply for calls answered on the AX thread: the first of (AX answer, timeout) wins.
private final class OneShotReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved = false
    private let fallback: Value

    init(fallback: Value) { self.fallback = fallback }

    func install(_ c: CheckedContinuation<Value, Never>) {
        let early: Bool = lock.withLock {
            if resolved { return true }
            continuation = c
            return false
        }
        if early { c.resume(returning: fallback) }
    }

    func resolve(_ value: Value) {
        let c: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !resolved else { return nil }
            resolved = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
