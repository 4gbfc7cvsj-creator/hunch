import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HunchCore
import HunchText

public enum KeyboardMonitorError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning
    /// The listen-only tap could not be created: Input Monitoring is not granted.
    case listenTapUnavailable
    /// The consuming tap could not be created: Accessibility / Input Monitoring is not granted.
    case acceptTapUnavailable

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "Keyboard monitor is already running."
        case .listenTapUnavailable:
            return "Cannot observe the keyboard. Grant Hunch Input Monitoring in System Settings > Privacy & Security."
        case .acceptTapUnavailable:
            return "Cannot intercept Tab for accepting suggestions. Grant Hunch Accessibility and Input Monitoring in System Settings > Privacy & Security."
        }
    }
}

/// Global keyboard observation on a dedicated thread with its own run loop.
///
/// - A listen-only session tap (head) reports typing activity, mouse-downs and global shortcuts.
///   It never emits characters; it only classifies whether a key typed something. For autocorrect's
///   key timing it keeps the last few dozen key codes with their press/release times in memory
///   (`KeyTimingLog`), never written anywhere, cleared on clicks and Secure Input.
/// - A consuming session tap (tail, keyDown only), created once and enabled only while a ghost
///   is visible, asks the arbiter synchronously and consumes accept/Escape/shortcut chords.
///   Anything else, and every failure, passes through (fail open).
///
/// Call `stop()` when done: a running monitor keeps itself alive for its tap callbacks.
public final class KeyboardMonitor: KeyboardMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    // All fields below are guarded by `lock`.
    private var arbiter: (any AcceptanceArbitrating)?
    private var listenTap: CFMachPort?
    private var acceptTap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// The coordinator's ghost signal (`setAcceptTapEnabled`).
    private var ghostVisible = false
    private var editableFocus = false
    /// Effective consuming-tap state: ghost visible OR any global shortcut bound.
    private var acceptTapRunning = false
    /// Key codes of bound global shortcuts; cheap early-exit when no ghost is visible.
    private var shortcutKeyCodes: Set<UInt16> = []
    private var lastSecureInput: Bool?
    private var eventSinks: [UUID: AsyncStream<TypingEvent>.Continuation] = [:]
    private var commandSinks: [UUID: AsyncStream<InputCommand>.Continuation] = [:]
    /// The user's key presses held while Hunch edits text behind the caret.
    private var holdQueue = KeyHoldQueue<CGEvent>()
    /// Autocorrect catch-up: a missed fix is waiting, so its shortcut is consumed.
    private var catchUpWaiting = false
    private var revertWaiting = false
    /// The suggested-replies bubble shows (it takes Tab, Escape and, with a reply highlighted, Return).
    private var repliesShown = false
    private var replyHighlighted = false
    private var replyArrows: ReplyArrows = []
    /// "Fix automatically": which Backspace undoes the fix (the next one, or a quick second one).
    private var undoGate = BackspaceUndoGate()
    /// The user's recent key presses with their timing, for autocorrect's keyboard prior
    /// (`KeyTimingLog`): memory only, a few dozen keys, cleared on clicks and Secure Input.
    private var keyTiming = KeyTimingLog()
    /// Every key press since the last drain, while "Save typing samples" is on (nil: off).
    private var sampleKeys: [KeyStroke]?
    private static let sampleKeysCap = 5000

    public static let secureInputPollInterval: CFTimeInterval = 0.25

    public init() {}

    deinit {
        for sink in eventSinks.values { sink.finish() }
        for sink in commandSinks.values { sink.finish() }
    }

    // MARK: KeyboardMonitoring

    public func start(arbiter: any AcceptanceArbitrating) throws {
        lock.lock()
        defer { lock.unlock() }
        guard listenTap == nil else { throw KeyboardMonitorError.alreadyRunning }

        let refcon = Unmanaged.passRetained(self).toOpaque()
        let listenMask = Self.mask([.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown])
        guard let listen = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: listenMask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue().handleListen(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon)
        else {
            Unmanaged<KeyboardMonitor>.fromOpaque(refcon).release()
            throw KeyboardMonitorError.listenTapUnavailable
        }
        guard let accept = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: Self.mask([.keyDown]),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue().handleAccept(type: type, event: event)
            },
            userInfo: refcon)
        else {
            CFMachPortInvalidate(listen)
            Unmanaged<KeyboardMonitor>.fromOpaque(refcon).release()
            throw KeyboardMonitorError.acceptTapUnavailable
        }
        CGEvent.tapEnable(tap: accept, enable: false)

        self.arbiter = arbiter
        self.listenTap = listen
        self.acceptTap = accept
        self.ghostVisible = false
        self.editableFocus = false
        self.acceptTapRunning = false
        self.lastSecureInput = nil

        let parts = ThreadParts(
            listenSource: CFMachPortCreateRunLoopSource(kCFAllocatorDefault, listen, 0),
            acceptSource: CFMachPortCreateRunLoopSource(kCFAllocatorDefault, accept, 0),
            loopBox: LoopBox())
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let loop = CFRunLoopGetCurrent() else { ready.signal(); return }
            CFRunLoopAddSource(loop, parts.listenSource, .commonModes)
            CFRunLoopAddSource(loop, parts.acceptSource, .commonModes)
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.secureInputPollInterval,
                Self.secureInputPollInterval, 0, 0) { _ in self?.pollSecureInput() }
            CFRunLoopAddTimer(loop, timer, .commonModes)
            parts.loopBox.loop = loop
            ready.signal()
            CFRunLoopRun()
            CFRunLoopTimerInvalidate(timer)
        }
        thread.name = "Hunch.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()   // the thread doesn't take `lock` before signalling, so holding it here is safe
        runLoop = parts.loopBox.loop
        applyTapStateLocked()
    }

    public func stop() {
        lock.lock()
        guard let listen = listenTap else { lock.unlock(); return }
        let accept = acceptTap
        let loop = runLoop
        listenTap = nil
        acceptTap = nil
        runLoop = nil
        arbiter = nil
        ghostVisible = false
        repliesShown = false
        replyHighlighted = false
        acceptTapRunning = false
        shortcutKeyCodes = []
        lock.unlock()

        CGEvent.tapEnable(tap: listen, enable: false)
        CFMachPortInvalidate(listen)
        if let accept {
            CGEvent.tapEnable(tap: accept, enable: false)
            CFMachPortInvalidate(accept)
        }
        if let loop { CFRunLoopStop(loop) }
        Unmanaged.passUnretained(self).release()   // balances passRetained in start
    }

    /// Ghost-visible signal. The monitor decides the effective tap state: it also keeps the
    /// consuming tap on while any global shortcut is bound.
    public func setAcceptTapEnabled(_ on: Bool) {
        lock.withLock {
            ghostVisible = on
            applyTapStateLocked()
        }
    }

    /// Editable-focus signal (thread-safe). The coordinator passes true on a focus `.context`
    /// and false on `.blocked`/`.focusLost`. With no ghost visible, global shortcuts are
    /// consumed only while this is true (toggle-global excepted), so system chords like
    /// Control+Tab keep working elsewhere.
    public func setEditableFocus(_ on: Bool) {
        lock.withLock {
            editableFocus = on
            applyTapStateLocked()
        }
    }

    /// Autocorrect catch-up: whether a missed fix is waiting. Only then is the catch-up shortcut
    /// consumed; otherwise it reaches the app.
    public func setCatchUpWaiting(_ on: Bool) {
        lock.withLock {
            catchUpWaiting = on
            applyTapStateLocked()
        }
    }

    /// Autocorrect: whether a fix that can be put back is waiting in the field. Only then is the
    /// revert shortcut consumed; otherwise it reaches the app.
    public func setRevertWaiting(_ on: Bool) {
        lock.withLock {
            revertWaiting = on
            applyTapStateLocked()
        }
    }

    /// Suggested replies: while `shown`, plain Tab and Escape are the bubble's, and so are Return and
    /// the arrows along `arrows` once a reply is `highlighted`. Everything else reaches the app.
    public func setReplyKeys(shown: Bool, highlighted: Bool, arrows: ReplyArrows = []) {
        lock.withLock {
            repliesShown = shown
            replyHighlighted = shown && highlighted
            replyArrows = shown ? arrows : []
            applyTapStateLocked()
        }
    }

    /// "Fix automatically": consume the next key press if it is a plain Backspace (emitting
    /// `InputCommand.undoAutoFix`); any other key ends this. False ends it too. A double-tap window
    /// (ms, > 0) lets the first Backspace through and consumes only a second one within the window.
    public func armBackspaceUndo(_ on: Bool, doubleTapMilliseconds: Int = 0, followUps: Int = 0) {
        lock.withLock {
            undoGate.arm(on, doubleTapMilliseconds: doubleTapMilliseconds, followUps: followUps)
            applyTapStateLocked()
        }
    }

    /// Starts holding the user's key presses (at most `KeyHoldQueue.maxHoldNanoseconds`). The
    /// catch-up shortcut starts a hold by itself when consumed. Always end it with `releaseHeldKeys`.
    public func holdKeys() {
        lock.withLock {
            holdQueue.begin(now: Self.uptimeNanoseconds())
            applyTapStateLocked()
        }
    }

    /// Ends a hold: the held presses are posted again, in order, ahead of anything typed meanwhile.
    public func releaseHeldKeys() {
        guard let loop = lock.withLock({ runLoop }) else {
            let events = lock.withLock { holdQueue.release(now: Self.uptimeNanoseconds()) }
            postReplays(events)
            return
        }
        // On the tap thread, so the release is ordered with the tap callbacks.
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let events = self.lock.withLock {
                defer { self.applyTapStateLocked() }
                return self.holdQueue.release(now: Self.uptimeNanoseconds())
            }
            self.postReplays(events)
        }
        CFRunLoopWakeUp(loop)
    }

    /// Whether key presses are held right now (a hold that hit its time limit was released).
    public var isHoldingKeys: Bool {
        lock.withLock {
            if case .holding = holdQueue.mode { return true }
            return false
        }
    }

    /// Re-reads the arbiter's bindings. Call after `DefaultAcceptanceArbiter.setBindings`;
    /// the tap thread also re-checks every `secureInputPollInterval`.
    public func bindingsDidChange() {
        lock.withLock { applyTapStateLocked() }
    }

    /// Reduces the arbiter's bound chords to what TapRules needs (toggle-global is detected via
    /// the arbiter's shortcut lookup).
    private func boundChords(_ chords: [KeyChord]) -> AcceptBindings {
        var b = AcceptBindings()
        b.forceActivate = nil
        b.toggleCurrentApp = nil
        b.toggleGlobal = nil
        b.writeForMe = nil
        b.catchUp = nil
        b.revertFix = nil
        guard let extended = arbiter as? any ExtendedAcceptanceArbitrating else { return b }
        for chord in chords {
            switch extended.shortcut(for: chord) {
            case .forceActivate: b.forceActivate = chord
            case .toggleCurrentApp: b.toggleCurrentApp = chord
            case .toggleGlobal: b.toggleGlobal = chord
            case .writeForMe: b.writeForMe = chord
            case .catchUp: b.catchUp = chord
            case .revertFix: b.revertFix = chord
            case nil: break
            }
        }
        return b
    }

    private func applyTapStateLocked() {
        guard let tap = acceptTap else { return }
        let chords = (arbiter as? any ExtendedAcceptanceArbitrating)?.globalShortcutChords ?? []
        shortcutKeyCodes = Set(chords.map(\.keyCode))
        let shouldRun = TapRules.tapShouldRun(ghostVisible: ghostVisible, editableFocus: editableFocus,
                                              bindings: boundChords(chords))
            || holdQueue.isActive || undoGate.armed || repliesShown
        if shouldRun != acceptTapRunning || CGEvent.tapIsEnabled(tap: tap) != shouldRun {
            acceptTapRunning = shouldRun
            CGEvent.tapEnable(tap: tap, enable: shouldRun)
        }
    }

    public func events() -> AsyncStream<TypingEvent> {
        let (stream, continuation) = AsyncStream<TypingEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        lock.withLock { eventSinks[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.eventSinks.removeValue(forKey: id) }
        }
        return stream
    }

    /// Escape dismissals and global shortcuts. Interim channel until TypingEvent gains cases.
    public func commands() -> AsyncStream<InputCommand> {
        let (stream, continuation) = AsyncStream<InputCommand>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        lock.withLock { commandSinks[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.commandSinks.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Tap thread

    private struct ThreadParts: @unchecked Sendable {
        let listenSource: CFRunLoopSource
        let acceptSource: CFRunLoopSource
        let loopBox: LoopBox
    }

    /// Hands the tap thread's run loop back to `start`; written before, read after the semaphore.
    private final class LoopBox: @unchecked Sendable {
        var loop: CFRunLoop?
    }

    private func handleListen(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = lock.withLock({ listenTap }) { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            Self.recordLastKey(event)
            guard !EventMarker.isOurs(event) else { return }
            recordKeyTiming(event, down: true)
            noteSecureInput(IsSecureEventInputEnabled())
            let chord = Self.chord(of: event)
            let replay = EventMarker.replayOrder(event) != nil
            let (arbiter, running, ghost, focus, holding, undoGate, catchUp, revert) = lock.withLock {
                (self.arbiter, acceptTapRunning, ghostVisible, editableFocus, holdQueue.isActive, self.undoGate,
                 catchUpWaiting, revertWaiting)
            }
            // A held press is reported when it is replayed.
            if holding, !replay { return }
            // A key the replies bubble takes is the consuming tap's (it emits the reply command).
            let (repliesOn, highlighted, arrows) = lock.withLock { (repliesShown, replyHighlighted, replyArrows) }
            if running, ReplyKeyRules.decide(chord, shown: repliesOn, highlighted: highlighted, arrows: arrows) != nil,
               !IsSecureEventInputEnabled() { return }
            // Backspace that undoes an automatic fix is the consuming tap's (it emits the undo).
            if Self.undoDecision(undoGate, event, chord) == .undo { return }
            // So is a Return while words wait to be settled (it is reported when replayed).
            if running {
                // The consuming tap owns keys it will swallow; don't report them as typing
                // (the accept/command event is emitted there instead).
                if let arbiter, Self.verdict(arbiter, chord, ghostVisible: ghost, editableFocus: focus,
                                             catchUpWaiting: catchUp, revertWaiting: revert).consumes { return }
            } else if let shortcut = Self.shortcut(arbiter, chord),
                      TapRules.shortcutConsumed(shortcut, editableFocus: focus, catchUpWaiting: catchUp,
                                                revertWaiting: revert) {
                // Defensive: no consuming tap (e.g. arbiter without bindings info). Report only.
                emit(.shortcut(shortcut))
            }
            emit(.keyDown(chord, isCharacter: Self.typedPrintable(event, modifiers: chord.modifiers)))
        case .keyUp:
            guard !EventMarker.isOurs(event) else { return }
            recordKeyTiming(event, down: false)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard !EventMarker.isOurs(event) else { return }
            lock.withLock { keyTiming.reset(keepingTokenTrigger: true) }  // may be a pick in a token picker
            emit(.mouseDown)
        case .flagsChanged:
            // Modifier presses aren't typing; use them only as a cheap Secure Input probe.
            noteSecureInput(IsSecureEventInputEnabled())
        default:
            break
        }
    }

    private func handleAccept(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let (tap, on) = lock.withLock { (acceptTap, acceptTapRunning) }
            if let tap, on { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            break
        default:
            return pass
        }
        guard !EventMarker.isOurs(event) else { return pass }
        let now = Self.uptimeNanoseconds()
        let replayOrder = EventMarker.replayOrder(event)
        // A quick further undo press while an undo is still typing (keys are held): judge it now, by
        // when it was pressed, rather than when it would be replayed. The coordinator queues it.
        let undoWhileHeld: Bool = lock.withLock {
            guard holdQueue.isActive, replayOrder == nil, undoGate.armed, !IsSecureEventInputEnabled() else {
                return false
            }
            let decision = Self.undoDecision(undoGate, event, Self.chord(of: event))
            guard decision == .undo else { return false }
            undoGate.apply(decision, now: event.timestamp)
            if !undoGate.armed { applyTapStateLocked() }
            return true
        }
        if undoWhileHeld {
            emit(.undoAutoFix)
            return nil
        }
        // Holding: keep the press (a copy; the tap consumes the original) to post again later.
        let (overdue, held): ([(order: Int, event: CGEvent)], Bool) = lock.withLock {
            let overdue = holdQueue.tick(now: now)
            guard holdQueue.isActive, let copy = event.copy() else { return (overdue, false) }
            if let replayOrder { return (overdue, holdQueue.replayArrived(order: replayOrder, event: copy)) }
            return (overdue, holdQueue.userKey(copy))
        }
        postReplays(overdue)
        if held { return nil }
        let result = handleAcceptKey(event, pass: pass)
        if let replayOrder {
            let next = lock.withLock {
                defer { applyTapStateLocked() }
                return holdQueue.replayPassed(order: replayOrder, now: now)
            }
            postReplays(next)
        }
        return result
    }

    private func handleAcceptKey(_ event: CGEvent, pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let (arbiter, on, ghost, focus, shortcutKeys, undo, catchUp, revert) = lock.withLock {
            let undo = Self.undoDecision(undoGate, event, Self.chord(of: event))
            if undoGate.armed {
                // Any key but the first of a double-tap ends the Backspace undo.
                undoGate.apply(undo, now: event.timestamp)
                if !undoGate.armed { applyTapStateLocked() }
            }
            return (self.arbiter, acceptTapRunning, ghostVisible, editableFocus, shortcutKeyCodes, undo,
                    catchUpWaiting, revertWaiting)
        }
        if undo == .undo, !IsSecureEventInputEnabled() {
            emit(.undoAutoFix)
            return nil
        }
        let (repliesOn, highlighted, arrows) = lock.withLock { (repliesShown, replyHighlighted, replyArrows) }
        if let key = ReplyKeyRules.decide(Self.chord(of: event), shown: repliesOn, highlighted: highlighted,
                                          arrows: arrows),
           !IsSecureEventInputEnabled() {
            switch key {
            case .insert, .dismiss:
                // Hand the keys back at once: a second Return or Escape is the app's again.
                lock.withLock {
                    repliesShown = false
                    replyHighlighted = false
                    replyArrows = []
                    applyTapStateLocked()
                }
            case .next where !highlighted:
                lock.withLock {
                    replyHighlighted = true
                    applyTapStateLocked()
                }
            case .next, .step: break
            }
            emit(.reply(key))
            return nil
        }
        guard on, let arbiter else { return pass }
        // Cheap exit while no ghost is visible: only bound shortcut keys with a modifier matter.
        if !ghost {
            guard shortcutKeys.contains(keyCode) else { return pass }
        }
        // Under Secure Input nothing is consumed (the ghost is about to be hidden anyway).
        let secure = IsSecureEventInputEnabled()
        noteSecureInput(secure)
        guard !secure else { return pass }

        switch Self.verdict(arbiter, Self.chord(of: event), ghostVisible: ghost, editableFocus: focus,
                            catchUpWaiting: catchUp, revertWaiting: revert) {
        case .accept(let action):
            emit(.accept(action))
            return nil
        case .dismiss:
            emit(.escapeDismissed)
            return nil
        case .shortcut(let shortcut):
            if shortcut == .catchUp || shortcut == .revertFix {
                // Keys typed from here on wait until the fix is in (the coordinator releases them).
                lock.withLock {
                    holdQueue.begin(now: Self.uptimeNanoseconds())
                    applyTapStateLocked()
                }
            }
            emit(.shortcut(shortcut))
            return nil
        case .cycleAlternative(let forward):
            emit(.cycleAlternative(forward: forward))
            return nil
        case .switchStyle(let forward):
            emit(.switchStyle(forward: forward))
            return nil
        case .passThrough:
            return pass
        }
    }

    private func pollSecureInput() {
        let (ghost, overdue): (Bool, [(order: Int, event: CGEvent)]) = lock.withLock {
            let overdue = holdQueue.tick(now: Self.uptimeNanoseconds())
            applyTapStateLocked()   // picks up binding changes
            return (ghostVisible, overdue)
        }
        postReplays(overdue)
        guard ghost else { return }
        noteSecureInput(IsSecureEventInputEnabled())
    }

    /// The user's own key presses only, at the time they were made (a held key replayed later is
    /// already recorded).
    private func recordKeyTiming(_ event: CGEvent, down: Bool) {
        guard EventMarker.replayOrder(event) == nil else { return }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let time = TimeInterval(event.timestamp) / 1_000_000_000
        lock.withLock {
            if down {
                let flags = event.flags
                if sampleKeys != nil, sampleKeys!.count < Self.sampleKeysCap {
                    let commandLike = !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])
                    let char = keyCode == 51 && !commandLike ? RecordedKey.backspace
                        : commandLike ? nil : KeyTimingLog.character(keyCode: keyCode, shift: flags.contains(.maskShift))
                    sampleKeys!.append(KeyStroke(keyCode: keyCode, char: char, down: time,
                                                 isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
                }
                keyTiming.keyDown(keyCode: keyCode, shift: flags.contains(.maskShift),
                                  commandLike: !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]),
                                  at: time, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            } else {
                keyTiming.keyUp(keyCode: keyCode, at: time)
                if let i = sampleKeys?.lastIndex(where: { $0.keyCode == keyCode && $0.up == nil }) { sampleKeys![i].up = time }
            }
        }
    }

    /// The recent key presses (autocorrect's key timing).
    public func keyTimingSnapshot() -> KeyTimingLog { lock.withLock { keyTiming } }

    /// "Save typing samples": keep every key press (with timing) until drained; off drops them.
    public func setRecordsSampleKeys(_ on: Bool) {
        lock.withLock {
            if !on { sampleKeys = nil } else if sampleKeys == nil { sampleKeys = [] }
        }
    }

    /// The key presses kept for typing samples since the last drain.
    public func drainSampleKeys() -> [KeyStroke] {
        lock.withLock {
            defer { if sampleKeys != nil { sampleKeys = [] } }
            return sampleKeys ?? []
        }
    }

    /// Forget the recent key presses (focus moved to another field). A pending "/", "@" or "#" stays
    /// (`KeyTimingLog.tokenTrigger`): hosts move focus to their picker, or rebuild the field when the
    /// token goes in. It still lapses on its own (idle, words typed, shortcuts).
    public func resetKeyTiming() { lock.withLock { keyTiming.reset(keepingTokenTrigger: true) } }

    private func noteSecureInput(_ on: Bool) {
        let changed: Bool = lock.withLock {
            if on { keyTiming.reset() }
            defer { lastSecureInput = on }
            return lastSecureInput != on
        }
        if changed { emit(.secureInputChanged(on)) }
    }

    private func emit(_ event: TypingEvent) {
        let sinks = lock.withLock { Array(eventSinks.values) }
        for sink in sinks { sink.yield(event) }
    }

    private func emit(_ command: InputCommand) {
        let sinks = lock.withLock { Array(commandSinks.values) }
        for sink in sinks { sink.yield(command) }
    }

    // MARK: Helpers

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    /// The last key press the listen tap saw, for diagnosing shortcuts that fire on their own: who
    /// posted it (`sourcePID` 0 and `fromHardware` for the real keyboard) and when (system uptime).
    public struct LastKey: Sendable, Equatable {
        public var chord: KeyChord
        public var sourcePID: Int32
        public var fromHardware: Bool
        public var ours: Bool
        public var at: TimeInterval
    }

    private static let lastKeyLock = NSLock()
    nonisolated(unsafe) private static var lastKeyValue: LastKey?

    public static var lastKey: LastKey? { lastKeyLock.withLock { lastKeyValue } }

    private static func recordLastKey(_ event: CGEvent) {
        let key = LastKey(chord: chord(of: event),
                          sourcePID: Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID)),
                          fromHardware: event.getIntegerValueField(.eventSourceStateID)
                              == Int64(CGEventSourceStateID.hidSystemState.rawValue),
                          ours: EventMarker.isOurs(event),
                          at: ProcessInfo.processInfo.systemUptime)
        lastKeyLock.withLock { lastKeyValue = key }
    }

    private static func chord(of event: CGEvent) -> KeyChord {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        return ChordMatcher.chord(keyCode: keyCode, rawFlags: event.flags.rawValue)
    }

    private static func verdict(_ arbiter: any AcceptanceArbitrating, _ chord: KeyChord, ghostVisible: Bool,
                                 editableFocus: Bool, catchUpWaiting: Bool, revertWaiting: Bool) -> InputVerdict {
        guard ghostVisible else {
            guard let found = shortcut(arbiter, chord),
                  TapRules.shortcutConsumed(found, editableFocus: editableFocus, catchUpWaiting: catchUpWaiting,
                                            revertWaiting: revertWaiting)
            else { return .passThrough }
            return .shortcut(found)
        }
        let now = mach_absolute_time()
        if let extended = arbiter as? any ExtendedAcceptanceArbitrating {
            return TapRules.gate(extended.inputVerdict(for: chord, now: now), catchUpWaiting: catchUpWaiting,
                                 revertWaiting: revertWaiting)
        }
        if case .consume(let action) = arbiter.verdict(for: chord, now: now) { return .accept(action) }
        return .passThrough
    }

    /// Posts held presses again, tagged with their order number so the taps can follow them.
    private func postReplays(_ events: [(order: Int, event: CGEvent)]) {
        for item in events {
            EventMarker.tagReplay(item.event, order: item.order)
            item.event.post(tap: .cgSessionEventTap)
        }
    }

    /// Both taps judge with the event's own timestamp, so they agree on the same press.
    private static func undoDecision(_ gate: BackspaceUndoGate, _ event: CGEvent,
                                     _ chord: KeyChord) -> BackspaceUndoGate.Decision {
        gate.decide(plainBackspace: ChordMatcher.isPlainBackspace(chord),
                    autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    now: event.timestamp)
    }

    private static func uptimeNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func shortcut(_ arbiter: (any AcceptanceArbitrating)?, _ chord: KeyChord) -> GlobalShortcut? {
        (arbiter as? any ExtendedAcceptanceArbitrating)?.shortcut(for: chord)
    }

    /// Reads the event's Unicode payload into a scratch buffer, classifies it, and wipes the buffer.
    private static func typedPrintable(_ event: CGEvent, modifiers: UInt64) -> Bool {
        let capacity = 8
        return withUnsafeTemporaryAllocation(of: UniChar.self, capacity: capacity) { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            buffer.initialize(repeating: 0)
            defer { buffer.update(repeating: 0) }
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: capacity, actualStringLength: &length, unicodeString: base)
            let count = min(max(length, 0), capacity)
            return PrintableDetector.isPrintable(utf16: UnsafeBufferPointer(start: base, count: count), modifiers: modifiers)
        }
    }

    // MARK: Diagnostics

    /// Every event tap in the session (`CGGetEventTapList`) for `EventTapDiagnostics`. Describes
    /// taps only, never events. Best-effort: empty when the call fails; it never blocks on input.
    public static func snapshotTaps() -> [TapInfo] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var raw = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var filled: UInt32 = 0
        guard CGGetEventTapList(count, &raw, &filled) == .success else { return [] }
        return raw.prefix(Int(min(filled, count))).map { tap in
            TapInfo(pid: tap.tappingProcess, targetPID: tap.processBeingTapped,
                    location: TapLocation(rawValue: tap.tapPoint.rawValue), options: tap.options.rawValue,
                    eventsMask: tap.eventsOfInterest, enabled: tap.enabled,
                    averageLatencyMicros: Double(tap.avgUsecLatency))
        }
    }
}
