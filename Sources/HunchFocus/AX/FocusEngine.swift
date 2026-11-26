import ApplicationServices
import Foundation
import HunchCore
import HunchPolicy

/// The AX-thread half of `AXFocusTracker`. Every method runs on the tracker's AX thread;
/// `@unchecked Sendable` only so run-loop blocks can carry it there.
final class FocusEngine: @unchecked Sendable {
    private unowned let owner: AXFocusTracker
    private let gate: any SecureGating
    private let policies: any AppPolicyResolving
    private let client: AXClient
    private let reader: ContextReader
    private let waker: ChromiumWaker
    private let systemWide: AXUIElement

    private(set) var stopRequested = false
    private var timer: CFRunLoopTimer?
    private var runLoop: CFRunLoop?

    // Observer state.
    private var observer: AXObserver?
    private var observerPID: pid_t?
    private var observerSourceAttached = false
    private var observedElement: AXUIElement?

    // Field identity.
    private var lastElement: AXUIElement?
    private var lastElementPID: pid_t?
    private var generation: UInt32 = 0

    private var deduper = EmissionDeduper()
    private var backoff = HangBackoff()
    private var backoffPID: pid_t?
    private var cooldownUntil: ContinuousClock.Instant?

    init(owner: AXFocusTracker, gate: any SecureGating, policies: any AppPolicyResolving) {
        self.owner = owner
        self.gate = gate
        self.policies = policies
        self.client = AXClient(timeout: owner.configuration.messagingTimeout)
        self.reader = ContextReader(client: client)
        self.reader.windowTitleEnabled = owner.windowTitleEnabled
        self.reader.shellCommandMode = { [policies] bundleID in
            policies.resolve(bundleID: bundleID, urlHost: nil).policy.shellCommandMode
        }
        self.waker = ChromiumWaker(client: client)
        self.systemWide = AXUIElementCreateSystemWide()
    }

    // MARK: Run loop wiring

    func install(on rl: CFRunLoop) {
        runLoop = rl
        // Repeating with a huge interval so the timer stays valid; every tick sets the next fire date.
        let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.05, 1e9, 0, 0) { [weak self] _ in
            self?.tick()
        }
        timer = t
        CFRunLoopAddTimer(rl, t, .defaultMode)
    }

    func requestStop() {
        stopRequested = true
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    func teardown() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
        detachObserver()
        reader.forgetField()
    }

    func tickSoon(after delay: Double) {
        guard let timer else { return }
        let target = CFAbsoluteTimeGetCurrent() + delay
        if CFRunLoopTimerGetNextFireDate(timer) > target {
            CFRunLoopTimerSetNextFireDate(timer, target)
        }
    }

    private func scheduleNext() {
        guard let timer else { return }
        let schedule = owner.configuration.schedule
        let interval = owner.isPaused ? schedule.medium : schedule.interval(sinceActivity: owner.timeSinceActivity)
        owner.setPollIsSlow(interval > schedule.fast)
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + interval.seconds)
    }

    // MARK: Lifecycle events (AX thread)

    /// Paused: drop the observer's run-loop source (no AX IPC) and forget the field.
    func didPause() {
        if let observer, observerSourceAttached, let runLoop {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            observerSourceAttached = false
        }
        deduper.record(.blocked(.trackingPaused, nil))
        forgetElement()
    }

    func didResume() {
        deduper.reset()
        forgetElement()
        tickSoon(after: 0)
    }

    func frontmostChanged() {
        forgetElement()
        tickSoon(after: 0.01)
    }

    fileprivate func observerFired(_ notification: String) {
        if notification != AXName.focusedUIElementChanged { owner.noteActivity() }
        tickSoon(after: 0.015)
    }

    // MARK: Tick

    private func tick() {
        guard !stopRequested else { return }
        defer { scheduleNext() }
        guard !owner.isPaused else { return }
        if let until = cooldownUntil, ContinuousClock.now < until { return }
        cooldownUntil = nil
        client.resetTimeoutFlag()
        let started = ContinuousClock.now
        runGatedRead()
        if client.sawTimeout {
            noteHang()
        } else {
            backoff.recordSuccess()
        }
        owner.log.debug("tick \(ContinuousClock.now - started)")
    }

    private func runGatedRead() {
        // Stage 1: system state only. No element access.
        guard let front = owner.currentFrontmost else {
            emit(.focusLost)
            return
        }
        if front.pid == owner.ownPID {
            detachObserver()
            forgetElement()
            emit(.blocked(.ownProcess, front))
            return
        }
        var app = front
        var policy = policies.resolve(bundleID: front.bundleID, urlHost: nil)
        if let reason = systemBlock(app: app, policy: policy) {
            detachObserver()
            forgetElement()
            emit(.blocked(reason, app))
            return
        }

        // Stage 2: focused element and metadata.
        ensureObserver(pid: front.pid)
        if policy.policy.wakeChromiumAX || waker.isElectron(pid: front.pid) { waker.wakeIfNeeded(pid: front.pid) }
        guard let element = focusedElement(frontPID: front.pid), !owner.isPaused else {
            GeometryDebugLog.shared.note("\(front.bundleID) noFocusedElement timeout=\(client.sawTimeout)")
            forgetElement()
            emit(.focusLost)
            return
        }
        guard let pid = client.pid(element) else {
            forgetElement()
            emit(.focusLost)
            return
        }
        if pid != front.pid {
            // Focus lives in another process (e.g. a launcher panel): gate that app instead.
            if pid == owner.ownPID {
                // One of this app's panels has the keyboard for a moment: keep the field.
                if owner.isLendingFocus { return }
                forgetElement()
                emit(.blocked(.ownProcess, front))
                return
            }
            app = reader.appIdentity(for: pid)
            policy = policies.resolve(bundleID: app.bundleID, urlHost: nil)
            if let reason = systemBlock(app: app, policy: policy) {
                forgetElement()
                emit(.blocked(reason, app))
                return
            }
        }

        let field = fieldID(for: element, pid: pid)
        observeElement(element)

        // Domain policy: resolve with the web area's host (URL metadata, not field text) and
        // re-run the system stage so domain exclusions apply before any text is read.
        if let host = reader.webHost(for: element, field: field) {
            let domainPolicy = policies.resolve(bundleID: app.bundleID, urlHost: host)
            if domainPolicy != policy {
                policy = domainPolicy
                if let reason = systemBlock(app: app, policy: policy) {
                    emit(.blocked(reason, app))
                    return
                }
            }
        }

        // A terminal that exposes no text to Accessibility: nothing to probe or read.
        if TerminalHosts.profile(for: app.bundleID) == .unsupported {
            emit(.blocked(.hostExposesNoText, app))
            return
        }

        let probe = reader.probe(element)
        if client.sawTimeout {
            GeometryDebugLog.shared.note("\(app.bundleID) probeTimeout")
            return
        }
        owner.log.debug("probe role=\(probe.role ?? "-") subrole=\(probe.subrole ?? "-") editable=\(probe.isEditable)")

        let pass: SecureGatePass
        switch gate.evaluateElement(probe, field: field, policy: policy) {
        case .failure(let error):
            GeometryDebugLog.shared.note("\(app.bundleID) blocked=\(error.reason) role=\(probe.role ?? "-") "
                + "subrole=\(probe.subrole ?? "-") editable=\(probe.isEditable)")
            emit(.blocked(error.reason, app))
            return
        case .success(let p):
            pass = p
        }

        // Stage 3: last-moment re-check of pause and Secure Input, then read.
        guard !owner.isPaused else { return }
        if let reason = systemBlock(app: app, policy: policy) {
            emit(.blocked(reason, app))
            return
        }
        do {
            let context = try reader.read(element, field: field, pass: pass, limits: owner.configuration.limits, app: app)
            if client.sawTimeout {
                GeometryDebugLog.shared.note("\(app.bundleID) readTimeout role=\(probe.role ?? "-")")
                return
            }
            // The line's start costs one more AX read: apps set to mirror ask for it, and every app
            // while the caret is early on a field's first line (where an empty field's text starts,
            // for dictation's effect).
            let firstLine = context.before.utf16.count <= 40 && !context.before.contains(where: \.isNewline)
            let geometry = reader.caret(element, field: field, pass: pass,
                                        lineStart: policy.policy.overlay == .mirror || firstLine,
                                        estimatedOnly: policy.policy.estimatedGeometryOnly)
            owner.log.debug("context quality=\(geometry.quality)")
            emit(.context(context, geometry))
        } catch {
            owner.log.debug("read failed: \(error)")
            GeometryDebugLog.shared.note("\(app.bundleID) readFailed=\(error) role=\(probe.role ?? "-") "
                + "subrole=\(probe.subrole ?? "-")")
            if !client.sawTimeout { emit(.blocked(.notEditable, app)) }
        }
    }

    /// For `AXFocusTracker.selectAroundCaret`: a fresh pass for `field`, then the selection.
    func selectAroundCaret(field: FieldID, backward: Int, forward: Int,
                           expected: String) -> Result<Void, CaretSelection.Failure> {
        guard let pass = freshPass(for: field), let element = lastElement else { return .failure(.focusMoved) }
        return reader.selectAroundCaret(element, field: field, pass: pass, backward: backward, forward: forward,
                                        expected: expected)
    }

    /// For `AXFocusTracker.selectBehindCaret`: a fresh pass for `field`, then the checked selection.
    func selectBehindCaret(field: FieldID, expectedSpan: String, expectedWord: String) -> Result<Int, CaretSelection.Failure> {
        guard let pass = freshPass(for: field), let element = lastElement else { return .failure(.focusMoved) }
        return reader.selectBehindCaret(element, field: field, pass: pass, expectedSpan: expectedSpan,
                                        expectedWord: expectedWord)
    }

    /// For `AXFocusTracker.placeCaret`: a fresh pass for `field`, then the checked caret move.
    func placeCaret(field: FieldID, location: Int, expectedBefore: String, highlightStartBack: Int,
                    highlightUTF16: Int) -> Result<CGRect?, CaretSelection.Failure> {
        guard let pass = freshPass(for: field), let element = lastElement else { return .failure(.focusMoved) }
        return reader.placeCaret(element, field: field, pass: pass, location: location, expectedBefore: expectedBefore,
                                 highlightStartBack: highlightStartBack, highlightUTF16: highlightUTF16)
    }

    /// For `AXFocusTracker.moveCaretForward`.
    func moveCaretForward(field: FieldID, forward: Int, expectedBefore: String) -> Result<Void, CaretSelection.Failure> {
        guard let pass = freshPass(for: field), let element = lastElement else { return .failure(.focusMoved) }
        return reader.moveCaretForward(element, field: field, pass: pass, forward: forward, expectedBefore: expectedBefore)
    }

    /// For `AXFocusTracker.wordBoundsBehindCaret`.
    func wordBoundsBehindCaret(field: FieldID, textToCaret: String, word: String) -> Result<CGRect, BehindCaret.BoundsMiss> {
        guard let pass = freshPass(for: field), let element = lastElement else { return .failure(.focusMoved) }
        return reader.wordBoundsBehindCaret(element, field: field, pass: pass, textToCaret: textToCaret, word: word)
    }

    /// For `AXFocusTracker.boundsBehindCaret`.
    func boundsBehindCaret(field: FieldID, back: Int, length: Int) -> Result<CGRect, BehindCaret.BoundsMiss> {
        guard let pass = freshPass(for: field), let element = lastElement else { return .failure(.focusMoved) }
        return reader.boundsBehindCaret(element, field: field, pass: pass, back: back, length: length)
    }

    /// For `AXFocusTracker.read(field:limits:)`: a fresh pass for `field`, then one read with `limits`.
    /// Emits nothing.
    func read(field: FieldID, limits: ContextLimits) -> TextContext? {
        guard let pass = freshPass(for: field), let element = lastElement else { return nil }
        let app = reader.appIdentity(for: field.pid)
        guard let context = try? reader.read(element, field: field, pass: pass, limits: limits, app: app),
              !client.sawTimeout else { return nil }
        return context
    }

    /// For `AXFocusTracker.currentPass`: the same gate order as a tick (system stage, then
    /// metadata-only element stage), for the element focused now. Reads no text, emits nothing,
    /// and never changes field identity: a different element (or generation) yields nil.
    func freshPass(for field: FieldID) -> SecureGatePass? {
        guard !stopRequested, !owner.isPaused else { return nil }
        guard let front = owner.currentFrontmost, front.pid != owner.ownPID else { return nil }
        client.resetTimeoutFlag()
        var app = front
        var policy = policies.resolve(bundleID: front.bundleID, urlHost: nil)
        guard systemBlock(app: app, policy: policy) == nil else { return nil }

        guard let element = focusedElement(frontPID: front.pid), !client.sawTimeout,
              let pid = client.pid(element), pid == field.pid, pid != owner.ownPID else { return nil }
        if pid != front.pid {
            app = reader.appIdentity(for: pid)
            policy = policies.resolve(bundleID: app.bundleID, urlHost: nil)
            guard systemBlock(app: app, policy: policy) == nil else { return nil }
        }
        // Same element as the tracked field, same generation; otherwise the caller's field is stale.
        guard let last = lastElement, lastElementPID == pid, CFEqual(last, element) else { return nil }
        let current = FieldID(pid: pid, elementHash: Int(bitPattern: UInt(CFHash(element))), generation: generation)
        guard current == field else { return nil }

        if let host = reader.webHost(for: element, field: field) {
            policy = policies.resolve(bundleID: app.bundleID, urlHost: host)
            guard systemBlock(app: app, policy: policy) == nil else { return nil }
        }
        guard TerminalHosts.profile(for: app.bundleID) != .unsupported else { return nil }
        let probe = reader.probe(element)
        guard !client.sawTimeout else { return nil }
        guard case .success(let pass) = gate.evaluateElement(probe, field: field, policy: policy) else { return nil }
        // Last-moment re-check (Secure Input may have turned on while we probed).
        guard !owner.isPaused, systemBlock(app: app, policy: policy) == nil else { return nil }
        return pass
    }

    private func systemBlock(app: AppIdentity, policy: ResolvedPolicy) -> BlockReason? {
        let secure = owner.secureInput()
        let probe = SystemProbe(secureEventInputEnabled: secure.enabled, secureInputOwnerPID: secure.ownerPID,
                                frontmost: app, ownPID: owner.ownPID, trackingPaused: owner.isPaused,
                                globallyEnabled: owner.globallyEnabled(),
                                autocorrectActive: owner.autocorrectActive())
        if case .block(let reason) = gate.evaluateSystem(probe, policy: policy) { return reason }
        return nil
    }

    private func focusedElement(frontPID: pid_t) -> AXUIElement? {
        if let e = client.element(systemWide, AXName.focusedUIElement) { return e }
        if client.sawTimeout { return nil }
        // Fallback: ask the frontmost app directly (more reliable for some Electron hosts).
        let app = AXUIElementCreateApplication(frontPID)
        if let e = client.element(app, AXName.focusedUIElement) { return e }
        if client.sawTimeout { return nil }
        // Only web-engine apps misreport focus this way; elsewhere "no focused element" is real
        // (desktop, games, non-text focus) and a tree walk would be wasted AX work.
        guard waker.isElectron(pid: frontPID) else { return nil }
        return focusedDescendant(app: app, pid: frontPID)
    }

    /// Some Chromium-based apps (the ChatGPT app) expose their text field with AXFocused = true but
    /// never answer AXFocusedUIElement. Find that field inside the focused window: a cached hit is
    /// re-validated with one AXFocused read; a full search is bounded (nodes, depth, AX timeouts)
    /// and throttled per app.
    private func focusedDescendant(app: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let cached = deepFocus, cached.pid == pid {
            if client.bool(cached.element, AXName.focused) == true { return cached.element }
            deepFocus = nil
        }
        let now = ContinuousClock.now
        if let last = deepSearchAt, last.pid == pid, now - last.at < Self.deepSearchInterval { return nil }
        deepSearchAt = (pid, now)
        guard let window = client.element(app, AXName.focusedWindow) ?? client.element(app, AXName.mainWindow)
        else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var next = 0
        var visited = 0
        while next < queue.count, visited < Self.deepSearchNodeLimit {
            let (node, depth) = queue[next]
            next += 1
            visited += 1
            if client.sawTimeout { return nil }
            if let role = client.string(node, AXName.role), Self.textRoles.contains(role),
               client.bool(node, AXName.focused) == true {
                deepFocus = (pid, node)
                return node
            }
            if depth < Self.deepSearchDepthLimit {
                queue.append(contentsOf: client.children(node).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private var deepFocus: (pid: pid_t, element: AXUIElement)?
    private var deepSearchAt: (pid: pid_t, at: ContinuousClock.Instant)?
    static let deepSearchInterval: Duration = .milliseconds(1500)
    static let deepSearchNodeLimit = 2_000
    static let deepSearchDepthLimit = 60
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    private func fieldID(for element: AXUIElement, pid: pid_t) -> FieldID {
        let same = lastElementPID == pid && lastElement.map { CFEqual($0, element) } == true
        if !same {
            generation &+= 1
            lastElement = element
            lastElementPID = pid
            reader.forgetField()
        }
        return FieldID(pid: pid, elementHash: Int(bitPattern: UInt(CFHash(element))), generation: generation)
    }

    private func forgetElement() {
        lastElement = nil
        lastElementPID = nil
        reader.forgetField()
    }

    private func emit(_ event: FocusEvent) {
        guard deduper.shouldEmit(event) else { return }
        owner.emit(event)
    }

    private func noteHang() {
        let pid = owner.currentFrontmost?.pid
        if pid != backoffPID {
            backoff = HangBackoff()
            backoffPID = pid
        }
        let cooldown = backoff.recordTimeout()
        cooldownUntil = .now + cooldown
        owner.log.debug("AX timeout; cooling down \(cooldown)")
        GeometryDebugLog.shared.note("\(owner.currentFrontmost?.bundleID ?? "?") axTimeout cooldown=\(cooldown)")
    }

    // MARK: Observer

    private func ensureObserver(pid: pid_t) {
        if observerPID == pid, let observer {
            if !observerSourceAttached, let runLoop {
                CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
                observerSourceAttached = true
            }
            return
        }
        detachObserver()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let engine = Unmanaged<FocusEngine>.fromOpaque(refcon).takeUnretainedValue()
            engine.observerFired(notification as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created, let runLoop else { return }
        let app = AXUIElementCreateApplication(pid)
        client.prepare(app)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [AXName.focusedUIElementChanged, AXName.valueChanged, AXName.selectedTextChanged] {
            _ = AXObserverAddNotification(obs, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observerPID = pid
        observerSourceAttached = true
    }

    /// Registers value/selection notifications on the focused element itself (many hosts only
    /// deliver them element-level).
    private func observeElement(_ element: AXUIElement) {
        guard let observer, observerPID == client.pid(element) else { return }
        if let current = observedElement, CFEqual(current, element) { return }
        if let old = observedElement {
            for name in [AXName.valueChanged, AXName.selectedTextChanged] {
                _ = AXObserverRemoveNotification(observer, old, name as CFString)
            }
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        client.prepare(element)
        for name in [AXName.valueChanged, AXName.selectedTextChanged] {
            _ = AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        observedElement = element
    }

    /// Drops the observer without AX IPC; releasing it unregisters its notifications.
    private func detachObserver() {
        if let observer, observerSourceAttached, let runLoop {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observerPID = nil
        observerSourceAttached = false
        observedElement = nil
    }
}
