import CoreText
import Foundation
import HunchCore
import HunchInput
import HunchEmoji
import HunchEngine
import HunchPrompt
import HunchHistory
import HunchOverlay
import HunchPolicy
import HunchScreen
import HunchSession
import HunchShell
import HunchText

/// MainActor shell around the pure `SuggestionSession` (design §3 request lifecycle): it feeds
/// focus/typing events in and executes the resulting commands (present/hide, arbiter snapshots,
/// serialized inserts, debounced engine requests). It owns the timers and tasks; all decisions
/// live in the session.
@MainActor
final class SuggestionCoordinator {
    private let engine: (AppPolicy) -> (any CompletionEngine)?
    private let keyboard: any KeyboardMonitoring
    private let arbiter: any AcceptanceArbitrating
    private let presenter: any GhostPresenting
    private let modeChooser: any GhostModeChoosing
    private let inserter: any TextInserting
    private let policies: any AppPolicyResolving
    private let settings: () -> HunchSettings
    private lazy var evalCapture = EvalCaptureRecorder(isEnabled: { [settings] in settings().debugLogging })
    /// Live acceptance log, on with debug logging.
    private lazy var outcomes: OutcomeLog = {
        let log = OutcomeLog(isEnabled: { [settings] in settings().debugLogging }, settings: settings)
        TypingSampleLog.fixReport = { [weak log] report, app, surface in log?.noteFixes(report, app: app, surface: surface) }
        return log
    }()
    private let noteTyping: () -> Void
    private let setEditableFocus: (Bool) -> Void
    private let screen: ScreenContextController?
    private let requestFreshContext: () -> Void
    private let learning: LearningController?
    private let clipboard: ClipboardContextController?
    private let inputMethodKind: () -> InputMethodKind

    /// Input-method composition guess (hosts that don't mark composing text). Only live while an
    /// input method is the current keyboard.
    private var composition = CompositionTracker()
    /// An Escape-cancel / retype / accept sequence is running; contexts don't reach the session
    /// meanwhile (the cancelled composition would look like the user deleting the ghost's anchor).
    private var compositionBusy = false
    private var queuedAccepts: [AcceptAction] = []
    private var publishedTabBlock = false
    private var insertVerifier: Task<Void, Never>?
    /// How long to wait for the field to show the composition gone after the Escape press. Zhuyin
    /// finalizes (rather than drops) the composition on Escape, so usually nothing changes and the
    /// accept goes ahead once this short wait is over.
    static let compositionCancelTimeout: Duration = .milliseconds(150)
    /// How a composition is finished before an accept: true = switch to the plain keyboard layout
    /// and back (silent, no key reaches the app); false = press Escape (Zhuyin finalizes on it, but
    /// the app then plays its alert sound). Switching is OFF: tried 2026-10-12, it left Zhuyin stuck
    /// typing English while its menu bar icon still showed Zhuyin (Caps Lock didn't recover it).
    static let commitCompositionBySwitchingInputSource = false
    /// How long to wait for an inserted suggestion to show up in the field.
    static let insertVerifyTimeout: Duration = .milliseconds(800)

    /// Replacement mode (emoji triggers and autocorrect): the text just before the caret should be
    /// replaced rather than continued. Shown and accepted outside the model session; Tab deletes
    /// `deleteCount` characters and types `replacement`.
    private struct ReplacementGhost {
        let field: FieldID
        let app: AppIdentity
        let urlHost: String?
        let before: String
        let deleteCount: Int
        let replacement: String
        /// What the ghost shows (the emoji, or the corrected word).
        let display: String
        /// Host text to strike through (autocorrect), nil for emoji.
        let struckText: String?
        var geometry: CaretGeometry
    }
    private var emojiGhost: ReplacementGhost?
    /// Autocorrect: a finder built with the current learned words (they change over time).
    private let corrections: (() -> CorrectionFinder)?
    private let learnedWords: (() -> Set<String>)?
    /// The spell check that knows the user's learned words (the Strong pass's guard), with or
    /// without screen context.
    var isMisspelled: (@Sendable (String) -> Bool)?
    /// Field whose prompt was last prewarmed (prefilled without decoding) on focus.
    private var prewarmedField: FieldID?
    /// Shell-command mode in terminals: the user's shell history and what their shell knows.
    private let shellHistory = ShellHistoryFile()
    /// Surface of the latest context: a shell prompt takes Right arrow instead of Tab.
    private var latestSurface: SurfaceKind = .unknown
    private let shellEnvironment = ShellEnvironment()
    private var emojiRepublisher: Task<Void, Never>?
    /// Escape on an emoji ghost: don't offer it again for the same text.
    private var dismissedEmojiBefore: (field: FieldID, before: String)?
    /// Tells when a shown fix was skipped (typed past or Escape), so the word can be learned.
    private var correctionSkips = CorrectionSkipTracker<FieldID>()
    /// Autocorrect catch-up and "Apply Corrections Automatically" (set by the app delegate).
    /// Suggested replies in empty fields (set by the app).
    var replies: SuggestedRepliesController?
    var autocorrect: AutocorrectFollowUp? {
        didSet {
            // After a fix behind the caret, the read it skipped is handled (a misspelled word right
            // after the fixed one is then checked too).
            autocorrect?.onFinished = { [weak self] expected in self?.replaySkippedRead(expectedBefore: expected) }
            autocorrect?.onEditStarted = { [weak self] in self?.send(.editBehindCaret) }
        }
    }
    /// The keyboard monitor's recent key presses with their timing ("Apply Corrections Automatically" weighs
    /// swaps and doubles with them), and how to forget them (set by the app delegate).
    var keyTimingSnapshot: (() -> KeyTimingLog)?
    /// Words the user often mistypes ("Apply Corrections Automatically"), set on each finder copy.
    var slipProfileSnapshot: (() -> SlipProfile?)?
    /// The learned words used in an app (its `AppKey`) or its category, offered as fixes first.
    var learnedHereSnapshot: ((String?) -> Set<String>?)?
    var resetKeyTiming: () -> Void = {}
    /// Dynamic Power Mode is on and currently in Efficiency (set by the app delegate). Autocorrect then
    /// acts like strength Light: spell checker only, no model.
    var isEfficiencyPower: () -> Bool = { false }

    /// Strong strength: the pause before the whole-field rewrite rereads the paragraph.
    private var rewriteTimer: Task<Void, Never>?
    /// A sentence end starts a pass after this short beat instead of the full pause.
    static let rewriteSentenceBeat: Duration = .milliseconds(150)

    /// What autocorrect does for this app now: its strength, capped to Light in Efficiency power mode.
    /// Every autocorrect use of the model goes through `usesModel` here.
    func correctionMode(_ policy: AppPolicy) -> CorrectionMode {
        CorrectionMode.resolve(chosen: policy.autocorrectStrength, efficiency: isEfficiencyPower())
    }
    /// Escape on a correction: don't offer a fix for that word again in this field.
    private var dismissedCorrections: (field: FieldID, words: Set<String>)?
    /// Latest before-caret text per field, to re-check before a replacement deletes anything.
    private var latestBefore: (field: FieldID, before: String)?
    /// A fetch for the ghost built from this text came back with no alternatives: Option+Up/Down
    /// then pass through to the app instead of being swallowed.
    private var noAlternativesFor: (field: FieldID, before: String)?
    /// When the last Tab/Option+Tab accept happened: a word just accepted is not "corrected".
    private var lastAcceptAt: ContinuousClock.Instant?
    /// Correction finder cached per learned-word set.
    private var finderCache: (words: Set<String>, finder: CorrectionFinder)?
    /// Selection and marked text in the latest context per field: a mirror needs neither.
    private var latestEditState: (field: FieldID, hasSelection: Bool, hasMarkedText: Bool)?
    /// The last draw asked for a mirror (it covers the host's line until hidden).
    private var mirrorShown = false

    private var session = SuggestionSession()
    private var inflight: Task<Void, Never>?
    /// The request `inflight` runs, once it has reached the model (past the typing pause).
    private var inflightAtModel: RequestID?
    /// Superseded requests left running at the model: the session may still show their result
    /// when the text typed since is the start of it.
    private var lateRequests: [UInt64: Task<Void, Never>] = [:]
    /// Streamed ghosts per request (perf.log only): when the model started on it, when the first
    /// words showed, and the last text shown before the final result.
    private var streams: [UInt64: (start: ContinuousClock.Instant, first: Duration?, last: String?)] = [:]
    private var republisher: Task<Void, Never>?
    private var holdReleaser: Task<Void, Never>?
    /// For the Tab-passed diagnostic: when the ghost was last drawn or hidden, and which event hid it.
    private var lastGhostShow: ContinuousClock.Instant?
    private var lastGhostHide: ContinuousClock.Instant?
    private var lastHideReason = "-"
    private var alternativesTask: Task<Void, Never>?
    /// The suggestion style picked with the style keys, for the rest of this field (nil = never
    /// pressed here; an id of nil = back on the app's own instructions, tag still shown).
    private var activeStyle: (field: FieldID, id: String?)?
    /// Shows the active style's name by the caret (nil hides it).
    private let styleTag: (StyleTagNames?, CGRect?) -> Void
    /// The field whose style tag a style key brought up. It stays up while the user steps through
    /// the styles (hiding the old suggestion doesn't take it down) and goes as soon as they type,
    /// accept, press Escape or leave the field.
    private var styleTagField: FieldID?

    /// Screen-measured baseline/x-height per line style (app + caret height + font size).
    /// One line style in one app: chat boxes get a new field identity per message, so keying by
    /// field would start every message unmeasured.
    private typealias CalibrationKey = CalibrationStore.Key
    private let calibrationProbe = TextCalibrationProbe()
    /// Measured in this session. Saved measurements (`calibrationStore`) are used until then.
    private var calibrations: [CalibrationKey: TextCalibration] = [:]
    private let calibrationStore: CalibrationStore
    private var calibrationAttempts: [CalibrationKey: CalibrationRetry] = [:]
    /// Line styles whose last measurement suggested a size correction not yet confirmed: measured
    /// once more this session.
    private var confirmingSize: Set<CalibrationKey> = []
    private var calibrating: Task<Void, Never>?

    /// Fields that report no text positions (Chrome's address bar): where the typed line was found
    /// on screen, so the caret can be placed after it (`TypedTextLocator`), per app and field height.
    private let textLocator = TypedTextLocator()
    private typealias AnchorKey = TypedAnchorStore.Key
    private var typedAnchors: TypedAnchorBook<AnchorKey>
    /// Anchors kept across launches; updated whenever the one in use changes.
    private let anchorStore: TypedAnchorStore
    private var locating: Task<Void, Never>?
    /// The last look per field, successful or not: re-checked at most this often while typing.
    private var lastLocate: (field: FieldID, at: ContinuousClock.Instant)?
    static let relocateInterval: Duration = .milliseconds(1500)
    /// The latest context's geometry as the reader gave it, before `placedGeometry`.
    private var latestRawGeometry: (field: FieldID, geometry: CaretGeometry)?
    /// The focused field's last read, until focus leaves or is blocked (write for me starts from it).
    private(set) var latestContext: (context: TextContext, geometry: CaretGeometry)?
    /// The latest read, only while suggestions are on for its app: a field read just for autocorrect
    /// (suggestions off) is not material for Write for me.
    var latestSuggestionContext: (context: TextContext, geometry: CaretGeometry)? {
        guard let latest = latestContext, settings().enabled,
              policy(bundleID: latest.context.app.bundleID, urlHost: latest.context.urlHost).enabled else { return nil }
        return latest
    }
    /// Why focus was last blocked, while it still is (for dictation's privacy check).
    private var latestBlock: (reason: BlockReason, app: AppIdentity?)?

    /// Wait before asking the model: the typing pause from Settings (0...1000 ms; 0 = none).
    private var requestDelay: Duration {
        .milliseconds(min(max(settings().suggestionPauseMs, 0), 1000))
    }
    /// Well inside the arbiter's 1.5 s freshness window.
    static let republishInterval: Duration = .milliseconds(500)

    /// Lists the app (and site) of a field the user typed in (Settings → Apps).
    private let notePlaceUsed: (TextContext) -> Void
    /// Why focus is blocked, for the menu's problem line (names the Secure Input owner).
    private let onBlocked: (BlockReason, AppIdentity?) -> Void

    init(engine: @escaping (AppPolicy) -> (any CompletionEngine)?, keyboard: any KeyboardMonitoring,
         arbiter: any AcceptanceArbitrating, presenter: any GhostPresenting, modeChooser: any GhostModeChoosing,
         inserter: any TextInserting, policies: any AppPolicyResolving, settings: @escaping () -> HunchSettings,
         noteTyping: @escaping () -> Void, setEditableFocus: @escaping (Bool) -> Void = { _ in },
         screen: ScreenContextController? = nil, requestFreshContext: @escaping () -> Void = {},
         learning: LearningController? = nil, clipboard: ClipboardContextController? = nil,
         corrections: (() -> CorrectionFinder)? = nil, learnedWords: (() -> Set<String>)? = nil,
         inputMethodKind: @escaping () -> InputMethodKind = { .plainLayout },
         notePlaceUsed: @escaping (TextContext) -> Void = { _ in },
         calibrationStore: CalibrationStore = CalibrationStore(fileURL: nil),
         anchorStore: TypedAnchorStore = TypedAnchorStore(fileURL: nil),
         onBlocked: @escaping (BlockReason, AppIdentity?) -> Void = { _, _ in },
         styleTag: @escaping (StyleTagNames?, CGRect?) -> Void = { _, _ in }) {
        self.styleTag = styleTag
        self.onBlocked = onBlocked
        self.calibrationStore = calibrationStore
        self.anchorStore = anchorStore
        self.typedAnchors = TypedAnchorBook(anchors: anchorStore.anchors)
        self.notePlaceUsed = notePlaceUsed
        self.inputMethodKind = inputMethodKind
        self.learnedWords = learnedWords
        self.corrections = corrections
        self.clipboard = clipboard
        self.requestFreshContext = requestFreshContext
        self.learning = learning
        self.engine = engine
        self.keyboard = keyboard
        self.arbiter = arbiter
        self.presenter = presenter
        self.modeChooser = modeChooser
        self.inserter = inserter
        self.policies = policies
        self.settings = settings
        self.noteTyping = noteTyping
        self.setEditableFocus = setEditableFocus
        self.screen = screen
        clipboard?.focus = { [weak self] frontmost in self?.clipboardFocus(frontmost: frontmost) }
    }

    // MARK: Inputs

    func handle(_ event: FocusEvent) {
        switch event {
        case .context(let context, let rawGeometry):
            setEditableFocus(true)
            // Key presses typed in another field are not this field's words.
            if let previous = latestBefore?.field, previous != context.field { resetKeyTiming() }
            // A suggestion style lasts for the rest of its field.
            if let style = activeStyle, style.field != context.field {
                activeStyle = nil
                dismissStyleTag()
            }
            latestRawGeometry = (context.field, rawGeometry)
            latestContext = (context, rawGeometry)
            latestBlock = nil
            let geometry = placedGeometry(rawGeometry, context: context)
            let policy = policy(bundleID: context.app.bundleID, urlHost: context.urlHost)
            // Autocorrect works with suggestions off (globally or for this app); everything else that
            // reads the field (screen context, learning, suggestion requests) waits for suggestions.
            let suggestionsOn = settings().enabled && policy.enabled
            if suggestionsOn { learnEmptyFieldStart(context, geometry: rawGeometry) }
            // Typing in an app or site lists it in Settings → Apps.
            if !context.before.isEmpty { notePlaceUsed(context) }
            if suggestionsOn { screen?.noteContext(context, geometry: geometry, policy: policy) }
            autocorrect?.preContext(context)
            if suggestionsOn {
                learning?.noteContext(context)
                evalCapture.noteContext(context)
                outcomes.noteContext(context)
            } else {
                outcomes.focusEnded()
            }
            latestBefore = (context.field, context.before)
            latestSurface = context.metadata.surface
            latestEditState = (context.field, context.selectionLength > 0, context.hasMarkedText)
            composition.setInputMethod(inputMethodKind())
            composition.context(field: context.field, before: context.before)
            republishIfTabBlockChanged()
            replies?.noteContext(context, geometry: effectGeometry(rawGeometry, context: context), policy: policy,
                                 suggestionsOn: suggestionsOn)
            // While an autocorrect fix moves the caret around, its reads are not typing; while the model
            // chooses for ambiguous words, reads wait (no suggestion request may supersede the
            // scoring) and the newest is handled once it is done.
            if compositionBusy || autocorrect?.busy == true || autocorrect?.isChoosing == true { return }
            scheduleRewrite(context, policy: policy)
            // Chat boxes stay the same field across messages: an emptied box (message sent)
            // forgets corrections the user dismissed with Escape.
            if context.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               dismissedCorrections?.field == context.field {
                dismissedCorrections = nil
            }
            let skipped = correctionSkips.update(field: context.field, before: context.before)
            if let autocorrect {
                autocorrect.noteContext(context, skipped: skipped)
            } else if let skipped {
                learning?.noteCorrectionSkipped(skipped)
            }
            // A shell command gets neither emoji (`scp host:path`) nor spelling fixes, and its
            // suggestion starts with the first typed character.
            let shell = context.metadata.surface == .shell
            // Autocorrect alone (suggestions off) still needs the model for its choices: load it on a
            // new field the same way, with the field's own text only.
            if !suggestionsOn, !shell, correctionMode(policy).usesModel, autocorrect?.fixesAutomatically(policy) == true {
                prewarmIfNewField(context, policy: policy, autocorrectOnly: true)
            }
            if !shell, showEmojiIfTriggered(context, geometry: geometry, policy: policy) { return }
            if !shell, showCorrectionIfMisspelled(context, geometry: geometry, policy: policy) { return }
            guard suggestionsOn else {
                send(.blocked)
                return
            }
            prewarmIfNewField(context, policy: policy)
            locateTypedTextIfNeeded(context, geometry: rawGeometry, policy: policy)
            send(.context(context, geometry, midLineEnabled: policy.midLineEnabled,
                          minWords: shell ? 0 : policy.minWordsBeforeSuggesting ?? settings().minWordsBeforeSuggesting))
        case .blocked(let reason, let app):
            latestContext = nil
            latestBlock = (reason, app)
            onBlocked(reason, app)
            replies?.focusEnded()
            composition.focusLost()
            republishIfTabBlockChanged()
            correctionSkips.reset()
            rewriteTimer?.cancel()
            autocorrect?.focusEnded()
            clearEmoji()
            setEditableFocus(false)
            screen?.focusEnded()
            evalCapture.focusEnded()
            outcomes.focusEnded()
            learning?.noteFocusEnded()
            resetKeyTiming()
            dismissStyleTag()
            send(.blocked)
        case .focusLost:
            latestContext = nil
            latestBlock = nil
            replies?.focusEnded()
            composition.focusLost()
            republishIfTabBlockChanged()
            correctionSkips.reset()
            rewriteTimer?.cancel()
            autocorrect?.focusEnded()
            clearEmoji()
            setEditableFocus(false)
            screen?.focusEnded()
            evalCapture.focusEnded()
            outcomes.focusEnded()
            learning?.noteFocusEnded()
            resetKeyTiming()
            dismissStyleTag()
            send(.focusLost)
        }
    }

    func handle(_ event: TypingEvent) {
        switch event {
        case .keyDown(let chord, let isCharacter):
            Self.perf("key character=\(isCharacter)")
            composition.setInputMethod(inputMethodKind())
            composition.keyDown(chord, isCharacter: isCharacter)
            republishIfTabBlockChanged()
            // Any key the accept tap didn't swallow invalidates an emoji ghost (the trigger text may
            // have changed); the next context shows it again if the trigger is still there.
            clearEmoji()
            replies?.noteKeyDown(chord)
            // Typing (or any key but the style keys themselves) puts the style tag away.
            let bindings = settings().bindings
            if !ChordMatcher.matches(chord, bindings.styleNext), !ChordMatcher.matches(chord, bindings.stylePrevious) {
                dismissStyleTag()
            }
            noteTyping()
            screen?.noteTyping()
            learning?.noteTyping()
            outcomes.keyDown(isCharacter: isCharacter)
            autocorrect?.noteKeyDown()
            if ChordMatcher.isPlainTab(chord) { logTabPassed() }
            if isCharacter, session.isHoldingForEdit(now: .now) {
                // Typed on while autocorrect edits: Tab no longer belongs to the hidden suggestion.
                send(.characterTyped)
                if session.visibleGhost == nil, emojiGhost == nil {
                    holdReleaser?.cancel()
                    holdReleaser = nil
                    arbiter.publish(nil)
                    keyboard.setAcceptTapEnabled(false)
                }
            }
        case .mouseDown:
            composition.mouseDown()
            replies?.noteMouseDown()
            republishIfTabBlockChanged()
            // Clicks alone don't hide the ghost (that broke screenshots, whose region drag is a
            // click). A click that moves the caret, selects, or changes focus already clears it
            // through the next context; ask for that context right away.
            requestFreshContext()
        case .secureInputChanged(let on):
            if on {
                replies?.focusEnded()
                correctionSkips.reset()
                autocorrect?.focusEnded()
                clearEmoji()
                learning?.secureInputStarted()
                outcomes.focusEnded()
            }
            send(.secureInputChanged(on))
        case .accept(let action):
            tearDownMirror()
            dismissStyleTag()
            if let emoji = emojiGhost {
                acceptEmoji(emoji)
                return
            }
            composition.setInputMethod(inputMethodKind())
            if compositionBusy {
                if queuedAccepts.count < SuggestionSession.maxPendingAccepts { queuedAccepts.append(action) }
                return
            }
            if composition.needsFinishBeforeAccept, let ghost = session.visibleGhost {
                let text = composition.composedText
                if composition.hasPhoneticSymbols { return }   // belongs to the input method
                if !text.isEmpty {
                    acceptThroughComposition(action, ghost: ghost, startBefore: composition.startBefore,
                                             composed: text, field: composition.field)
                    return
                }
            }
            send(.accept(action, settings().wordUnits))
        }
    }

    // MARK: Composition

    private var tabBlockedByComposition: Bool { composition.composing && composition.hasPhoneticSymbols }

    private var tabAllowed: Bool { !tabBlockedByComposition }

    /// Republishes the arbiter snapshot when Tab starts or stops belonging to the input method.
    private func republishIfTabBlockChanged() {
        let blocked = tabBlockedByComposition
        guard blocked != publishedTabBlock else { return }
        publishedTabBlock = blocked
        if let ghost = session.visibleGhost {
            publish(ghost, policy: policy(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost))
        } else if let emoji = emojiGhost {
            publishEmoji(policy: policy(bundleID: emoji.app.bundleID, urlHost: emoji.urlHost))
        }
    }

    /// Tab on a ghost while the typed characters are an uncommitted composition: the input method
    /// would swallow our inserted text. Cancel the composition with Escape, wait for the field to
    /// drop it, type the characters back as ordinary text, then accept as usual.
    private func acceptThroughComposition(_ action: AcceptAction, ghost: GhostState, startBefore: String,
                                          composed: String, field: FieldID?) {
        compositionBusy = true
        queuedAccepts = []
        let policy = policy(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost)
        let inserter = self.inserter
        Task { [weak self] in
            var reverted = false
            let fired = Self.commitCompositionBySwitchingInputSource
                ? await InputMethodState.shared.commitCompositionBySwitching()
                : inserter.pressKey(53, into: ghost.app)
            if fired {
                let deadline = ContinuousClock.now + Self.compositionCancelTimeout
                while ContinuousClock.now < deadline {
                    self?.requestFreshContext()
                    try? await Task.sleep(for: .milliseconds(25))
                    guard let self else { return }
                    if self.latestBefore?.field == field, self.latestBefore?.before == startBefore {
                        reverted = true
                        break
                    }
                }
            }
            var proceed = true
            DrawDebugLog.note("ime tab: escape reverted=\(reverted) composedLen=\(composed.count)")
            if reverted {
                let outcome = await inserter.insert(composed, into: ghost.app, mode: policy.insertion,
                                                    chunkSize: policy.injectionChunkSize ?? 16,
                                                    workarounds: policy.insertionWorkarounds)
                DrawDebugLog.note("ime tab: retype outcome=\(outcome)")
                if case .failed = outcome { proceed = false }
            }
            guard let self else { return }
            self.composition.end()
            self.compositionBusy = false
            self.republishIfTabBlockChanged()
            let options = self.settings().wordUnits
            let queued = self.queuedAccepts
            self.queuedAccepts = []
            DrawDebugLog.note("ime tab: proceed=\(proceed) ghostVisible=\(self.session.visibleGhost != nil) remainingLen=\(self.session.visibleGhost?.remaining.count ?? -1)")
            if proceed { self.send(.accept(action, options)) }
            for next in queued { self.send(.accept(next, options)) }
        }
    }

    /// After an accept insert: the field should show the inserted text before the caret. When it
    /// still shows exactly what it showed before the insert, the host dropped the text; give the
    /// ghost back. Anything unclear (the user typed on, a different field) restores nothing.
    private func verifyInsert(_ text: String, field: FieldID?, preBefore: String?) {
        insertVerifier?.cancel()
        guard let field, let preBefore else { return }
        insertVerifier = Task { [weak self] in
            let deadline = ContinuousClock.now + Self.insertVerifyTimeout
            while ContinuousClock.now < deadline {
                self?.requestFreshContext()
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                guard let latest = self.latestBefore, latest.field == field else { return }
                if latest.before.suffix(text.count + 40).contains(text) { return }
            }
            guard !Task.isCancelled, let self, let latest = self.latestBefore,
                  latest.field == field, latest.before == preBefore else { return }
            DrawDebugLog.note("insert lost len=\(text.count): field unchanged after verify window")
            self.send(.insertLost(text))
        }
    }

    /// Who the writer is: "Name: …" from the macOS account's full name (skipped when it is empty or
    /// just the short login name), then the "About me" text. Nil when both are empty.
    static func aboutWriter(aboutMe: String) -> String? {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !full.isEmpty && full != NSUserName() ? "Name: \(full)." : nil
        let about = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [name, about.isEmpty ? nil : about].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The app's or site's instructions replace "How I write": switched on and actually present.
    static func replacesGlobal(_ policy: AppPolicy) -> Bool {
        policy.instructionsReplaceGlobal
            && !(policy.customInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A completion suggestion (not an emoji or spelling fix) is showing.
    var showsSuggestion: Bool { emojiGhost == nil && session.visibleGhost != nil }

    /// Escape with a visible ghost: clear it and, depending on settings, pause briefly.
    func dismissFromEscape() {
        tearDownMirror()
        dismissStyleTag()
        if let emoji = emojiGhost {
            dismissedEmojiBefore = (emoji.field, emoji.before)
            if emoji.struckText != nil {
                if let word = correctionSkips.escaped() { learning?.noteCorrectionSkipped(word) }
                autocorrect?.noteEscaped()
                // Remember the misspelled word itself (struck text minus trailing space/punctuation).
                let word = (emoji.struckText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
                var words = dismissedCorrections?.field == emoji.field ? (dismissedCorrections?.words ?? []) : []
                words.insert(word)
                dismissedCorrections = (emoji.field, words)
            }
            clearEmoji()
            return
        }
        if session.visibleGhost != nil {
            learning?.noteDismissed()
            outcomes.noteDismissed()
        }
        send(.escape(pauseBriefly: settings().escapeBehavior == .dismissAndPauseBriefly))
    }

    /// The catch-up shortcut was consumed: fix the newest missed word in place.
    func catchUpMissedFix() {
        let context = latestContext?.context
        autocorrect?.catchUp(field: context?.field, app: context?.app,
                             policy: context.map { policy(bundleID: $0.app.bundleID, urlHost: $0.urlHost) })
    }

    /// The revert shortcut was consumed: put back what was typed for the newest fix in the field.
    func revertNewestFix() {
        let context = latestContext?.context
        autocorrect?.revertNewest(field: context?.field, app: context?.app,
                                  policy: context.map { policy(bundleID: $0.app.bundleID, urlHost: $0.urlHost) })
    }

    /// A word was picked in the menu under a fixed word (the typed word reverts it).
    func changeMarkedFix(id: Int, to word: String, settle: Bool) {
        let context = latestContext?.context
        autocorrect?.changeMarked(id: id, to: word, settle: settle, field: context?.field, app: context?.app,
                                  policy: context.map { policy(bundleID: $0.app.bundleID, urlHost: $0.urlHost) })
    }

    /// What the menu under a fixed word offers: the other words the finder sees for the typed word
    /// in this field's context.
    func fixChoices(id: Int) -> FixChoices? {
        guard let autocorrect, let context = latestContext?.context else { return nil }
        let policy = policy(bundleID: context.app.bundleID, urlHost: context.urlHost)
        let finder = corrections.map { cachedFinder($0, policy: policy, field: context.field,
                                                    bundleID: context.app.bundleID, urlHost: context.urlHost) }
        return autocorrect.choices(id: id) { typed, head, current in
            finder?.alternatives(for: typed, head: head, current: current) ?? []
        }
    }

    /// Backspace straight after an automatic fix was consumed: restore the original word.
    func undoAutoFix() {
        let context = latestContext?.context
        autocorrect?.undoAutoFix(field: context?.field, app: context?.app,
                                 policy: context.map { policy(bundleID: $0.app.bundleID, urlHost: $0.urlHost) })
    }

    /// Option+Down / Option+Up on a visible suggestion.
    func cycleAlternative(forward: Bool) {
        guard emojiGhost == nil else { return }
        send(.cycleAlternative(forward: forward))
    }

    /// The style keys on a visible suggestion: step around the ring (forward = next style, back = the
    /// one before; the app's own instructions sit between the last and the first) and ask again.
    func switchStyle(forward: Bool) {
        guard emojiGhost == nil, let ghost = session.visibleGhost else { return }
        let styles = settings().suggestionStyles
        guard !SuggestionStyleRing.usable(styles).isEmpty else { return }
        let next = SuggestionStyleRing.step(from: style(for: ghost.field)?.id, forward: forward, styles: styles)
        activeStyle = (ghost.field, next)
        styleTagField = ghost.field
        noAlternativesFor = nil
        send(.forceActivate)
        // The tag shows at once, before the new suggestion arrives (dropping the old one hid it),
        // and slides the way the ring moved.
        var names = styleTagNames(for: ghost)
        names?.step = forward ? .forward : .back
        styleTag(names, ghost.geometry.caretRect)
    }

    /// Takes the style tag down until the next style key press.
    private func dismissStyleTag() {
        styleTagField = nil
        styleTag(nil, nil)
    }

    /// The style tag for `ghost`'s field while a style key brought it up; nil otherwise. The
    /// app's own chip is named after where its instructions come from (the app, site or category).
    private func styleTagNames(for ghost: GhostState) -> StyleTagNames? {
        guard styleTagField == ghost.field, let active = activeStyle, active.field == ghost.field else { return nil }
        let source = policies.resolve(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost).instructionsSource
        let own = StyleTagNames.ownName(source: source, appName: ghost.app.localizedName)
        return SuggestionStyleRing.tag(for: active.id, styles: settings().suggestionStyles, ownName: own)
    }

    /// The style in use for `field`, if one is on and still enabled.
    private func style(for field: FieldID) -> SuggestionStyle? {
        guard let active = activeStyle, active.field == field else { return nil }
        return SuggestionStyleRing.style(active.id, in: settings().suggestionStyles)
    }

    /// Alternatives for the visible suggestion: the same request with first-token fan-out 3 (the
    /// engine returns the other branches' suggestions). Independent of the main request lineage.
    private func fetchAlternatives(id: RequestID, context: TextContext) {
        alternativesTask?.cancel()
        let policy = policy(bundleID: context.app.bundleID, urlHost: context.urlHost)
        guard settings().enabled, let engine = engine(policy) else { return }
        var request = makeRequest(id: id, context: context, policy: policy)
        request.decode.firstTokenFanout = max(3, request.decode.firstTokenFanout)
        let learning = self.learning
        alternativesTask = Task { [weak self] in
            if let learning {
                    let appKey = AppKey.make(bundleID: context.app.bundleID, urlHost: context.urlHost)
                    let learningAllowed = CodeSurfaceRules.learningAllowed(policy: policy, surface: context.metadata.surface)
                    async let bias = learning.bias(for: context.before, appKey: appKey,
                                                  learningAllowed: learningAllowed)
                    async let style = learning.styleExamples(for: context.before, field: context.field,
                                                             appKey: appKey, learningAllowed: learningAllowed)
                    // Gated learned-word notes, from the same screen text the prompt gets (instruct
                    // framers name them; the document framer for base models ignores them).
                    let screen = request.input.screenContext
                    async let vocabulary = learning.vocabulary(for: context.before, screen: screen,
                                                               appKey: appKey, learningAllowed: learningAllowed)
                    request.bias = await bias
                    request.input.styleExamples = await style
                    let notes = await vocabulary
                    request.input.vocabulary = notes.words
                    request.learnedNotes = notes.diagnostics
                }
            guard let result = try? await engine.complete(request, partial: { _ in }), !Task.isCancelled,
                  let self else { return }
            DiagnosticNotes.judge(id, .notApplicable, note: "Alternatives for the suggestion on screen (Option+Up/Down).")
            let shown = self.session.visibleGhost?.remaining
            let useful = result.alternatives.contains { alt in
                alt.contains(where: { !$0.isWhitespace }) && alt != shown
            }
            if !useful {
                self.noAlternativesFor = (context.field, context.before)
                if let ghost = self.session.visibleGhost {
                    self.publish(ghost, policy: self.policy(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost))
                }
            }
            self.send(.alternatives(id: id, list: result.alternatives, requestContext: context))
        }
    }

    /// ⌃Tab: request a suggestion now for the current field, even inside an Escape pause.
    func forceActivate() {
        clearEmoji()
        send(.forceActivate)
    }

    // MARK: Prewarm

    /// On focusing a new field, prefill its prompt in the background (no decoding), so the first
    /// suggestion, which often waits for the minimum word count, starts from a warm cache and a
    /// model released while idle reloads early. Uses the current request id, so the session's
    /// next real request (a higher id) supersedes it.
    /// `autocorrectOnly`: suggestions are off and autocorrect needs the model (its choices score on
    /// it, `scoreContinuations`); the prompt then holds only the field's own text, like a scoring
    /// request, and no suggestion follows.
    private func prewarmIfNewField(_ context: TextContext, policy: AppPolicy, autocorrectOnly: Bool = false) {
        let policy = Self.requestPolicy(policy, context: context)
        guard prewarmedField != context.field, autocorrectOnly || settings().enabled, !context.hasMarkedText,
              let engine = engine(policy) else { return }
        prewarmedField = context.field
        var request = makeRequest(id: session.latestRequestID, context: context, policy: policy)
        request.prewarmOnly = true
        if autocorrectOnly {
            request.input.screenContext = nil
            request.input.clipboard = nil
        }
        Task { await engine.prewarm(request) }
    }

    // MARK: Emoji

    private func emojiPreferences(_ s: EmojiSettings) -> EmojiPreferences {
        EmojiPreferences(skinTone: EmojiSkinTone(rawValue: s.skinTone) ?? .none, includeNeutral: s.includeNeutral,
                         gender: EmojiGender(rawValue: s.gender) ?? .neutral)
    }

    /// Shows an emoji ghost when the caret follows a trigger; true when emoji mode took the context.
    /// Emoticons and ":" search follow the app's or site's policy (base: the general emoji setting).
    private func showEmojiIfTriggered(_ context: TextContext, geometry: CaretGeometry, policy: AppPolicy) -> Bool {
        let emojiSettings = settings().emoji
        guard policy.emoticonEmojiEnabled || policy.emojiSearchEnabled, settings().enabled, policy.enabled,
              !context.hasMarkedText, CodeSurfaceRules.replacementsAllowed(surface: context.metadata.surface),
              context.selectionLength == 0, geometry.quality >= .derived,
              !(dismissedEmojiBefore?.field == context.field && dismissedEmojiBefore?.before == context.before),
              let trigger = EmojiTrigger.detect(before: context.before, preferences: emojiPreferences(emojiSettings)),
              trigger.kind.isAllowed(emoticons: policy.emoticonEmojiEnabled, search: policy.emojiSearchEnabled),
              let first = trigger.candidates.first
        else {
            clearEmoji()
            return false
        }
        // The model's ghost (and any request in flight) gives way to the emoji; an accept hold from
        // the previous suggestion must not switch the accept tap off under it.
        send(.escape(pauseBriefly: false))
        holdReleaser?.cancel()
        holdReleaser = nil
        showReplacement(ReplacementGhost(field: context.field, app: context.app, urlHost: context.urlHost,
                                         before: context.before, deleteCount: trigger.triggerText.count,
                                         replacement: first.emoji, display: first.emoji, struckText: nil,
                                         geometry: geometry),
                        context: context, policy: policy)
        return true
    }

    /// Autocorrect: the last word before the caret is misspelled → show the fix (word struck through,
    /// correction after it); Tab replaces it. True when correction mode took the context. Follows the
    /// app's or site's policy (base: the general autocorrect setting).
    private func showCorrectionIfMisspelled(_ context: TextContext, geometry: CaretGeometry, policy: AppPolicy) -> Bool {
        guard policy.autocorrectEnabled, let makeFinder = corrections,
              CodeSurfaceRules.replacementsAllowed(surface: context.metadata.surface),
              !context.hasMarkedText, context.selectionLength == 0 else { return false }
        let finder = cachedFinder(makeFinder, policy: policy, field: context.field,
                                  bundleID: context.app.bundleID, urlHost: context.urlHost)
        autocorrect?.fixConfidence = { finder.confidence(typed: $0, fixed: $1) }
        func dismissed(_ word: String) -> Bool {
            dismissedCorrections?.field == context.field
                && dismissedCorrections?.words.contains(word.lowercased()) == true
        }
        // A fast-Tab hold is active (the session knows; the releaser task outlives it).
        let holdingAccept = session.isHoldingAccept(now: .now)
        // Right after a suggestion was taken its words are the model's, not typed: no fixes.
        let wordsTyped = geometry.quality >= .derived
            && context.caretAtLineEnd
            && !(dismissedEmojiBefore?.field == context.field && dismissedEmojiBefore?.before == context.before)
            && !(lastAcceptAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false)
            && !holdingAccept
        // Fix automatically on fields read like a document: every word typed is looked at once, also
        // when no read came right after it (fast typing), and fixed behind the caret if need be. An
        // ambiguous word waits for the next one; then the model chooses (it replaces behind the
        // caret, so no caret geometry needed).
        if let autocorrect, autocorrect.fixesAutomatically(policy),
           AutocorrectFollowUp.catchUpSurface(context.metadata.surface) {
            guard !holdingAccept else { return false }
            let took = autocorrect.step(context, policy: policy, checkWords: wordsTyped,
                                        finding: autoFixFinding(finder, field: context.field),
                                        score: { [weak self] head, continuations in
                await self?.scoreContinuations(context, head: head, continuations: continuations, policy: policy)
            })
            if took { send(.editBehindCaret) }
            return took
        }
        guard wordsTyped else { return false }
        guard let proposal = finder.proposal(before: context.before) else { return false }
        guard proposal.deleteCount <= context.before.count,
              !dismissed(proposal.misspelled),
              autocorrect?.wasRestored(field: context.field, word: proposal.misspelled) != true
        else { return false }
        if let autocorrect, autocorrect.autoFix(context, proposal: proposal, policy: policy) {
            send(.editBehindCaret)
            return true
        }
        correctionSkips.shown(field: context.field, before: context.before, word: proposal.misspelled,
                             trailingCount: proposal.trailing.count)
        send(.escape(pauseBriefly: false))
        holdReleaser?.cancel()
        holdReleaser = nil
        showReplacement(ReplacementGhost(field: context.field, app: context.app, urlHost: context.urlHost,
                                         before: context.before, deleteCount: proposal.deleteCount,
                                         replacement: proposal.replacement + proposal.trailing,
                                         display: proposal.replacement,
                                         struckText: String(context.before.suffix(proposal.deleteCount)),
                                         geometry: geometry),
                        context: context, policy: policy)
        autocorrect?.noteShown(context, proposal: proposal)
        return true
    }

    /// "Apply Corrections Automatically": what the finder makes of a word, leaving out words dismissed in the field.
    private func autoFixFinding(_ finder: CorrectionFinder, field: FieldID) -> (String) -> CorrectionFinding? {
        let dismissed = dismissedCorrections?.field == field ? (dismissedCorrections?.words ?? []) : []
        return { stem in
            switch finder.finding(before: stem, deferAmbiguous: true) {
            case .fix(let p)? where dismissed.contains(p.misspelled.lowercased()): nil
            case .ambiguous(let t)? where dismissed.contains(t.misspelled.lowercased()): nil
            case let found: found
            }
        }
    }

    /// Scores continuations of `head` on the suggestion model, framed like a suggestion for the same
    /// field. nil when the engine isn't the local model or the model isn't loaded right now.
    private func scoreContinuations(_ context: TextContext, head: String, continuations: [String],
                                    policy: AppPolicy) async -> [Float]? {
        // Strength Light and Efficiency power mode never use the model: no scoring, no load.
        guard correctionMode(policy).usesModel,
              let scorer = engine(policy) as? any ContinuationScoring else { return nil }
        var headContext = context
        headContext.before = head
        // The newest id: the scorer's job queues behind work already sent, and nothing newer is sent
        // while autocorrect is busy.
        var request = makeRequest(id: session.newestRequestID, context: headContext, policy: policy)
        // Only the field's own text: the screen and the clipboard often hold the same typo (a chat
        // about it, the line being copied), and the model would copy it from there.
        request.input.screenContext = nil
        request.input.clipboard = nil
        let scores = try? await scorer.scoreContinuations(request, continuations: continuations)
        // No model loaded (released while idle) and no suggestion request to reload it: autocorrect
        // reloads it itself, so the next choice in this field has the model again.
        if scores == nil, correctionMode(policy).usesModel, !(settings().enabled && policy.enabled) {
            prewarmedField = nil
            prewarmIfNewField(context, policy: policy, autocorrectOnly: true)
        }
        return scores
    }

    // MARK: Whole-field rewrite (Strong)

    /// Every read restarts the pause: once the user stops typing for the set time (or right after a
    /// sentence end), the rewrite rereads the paragraph. Strong only: Light and Efficiency power mode
    /// never get here (`rewritesAtPauses`), and only with the local model.
    private func scheduleRewrite(_ context: TextContext, policy: AppPolicy) {
        rewriteTimer?.cancel()
        rewriteTimer = nil
        guard let autocorrect, correctionMode(policy).rewritesAtPauses, autocorrect.fixesAutomatically(policy),
              AutocorrectFollowUp.catchUpSurface(context.metadata.surface), context.selectionLength == 0,
              engine(policy) is any FieldRewriting,
              context.before.contains(where: \.isLetter) else { return }
        let last = context.before.last, previous = context.before.dropLast().last
        let sentenceEnd = last.map(\.isWhitespace) == true && previous.map { ".!?".contains($0) } == true
        let pause = min(max(settings().autocorrectRewritePause, HunchSettings.rewritePauseRange.lowerBound),
                        HunchSettings.rewritePauseRange.upperBound)
        let wait: Duration = sentenceEnd ? Self.rewriteSentenceBeat : .milliseconds(Int(pause * 1000))
        let lastKey = ContinuousClock.now
        rewriteTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let latest = self.latestContext?.context,
                  latest.field == context.field, latest.before == context.before else { return }
            self.startRewrite(latest, policy: policy, lastKey: lastKey)
        }
    }

    /// `lastKey`: when the read that started the pause came in (about the user's last key), for the
    /// "strong pass:" lines in perf.log (outcome and how long after the last key the fix landed).
    private func startRewrite(_ context: TextContext, policy: AppPolicy, lastKey: ContinuousClock.Instant) {
        guard let autocorrect, correctionMode(policy).rewritesAtPauses else { return }
        var options = RewriteOptions()
        options.fixesCapitals = policy.autoCapitalizationAllowed && settings().autocorrectCapitalization
        options.fixesPunctuation = settings().fixPunctuation && policy.fixesPunctuation
        options.leavesShorthand = settings().autocorrectLeaveChatShorthand && policy.leavesChatShorthand
        // Names and terms on screen are never changed (the finder leaves them alone too).
        options.keptWords = screen?.screenWords(for: context.field, policy: policy).words ?? []
        options.isKnownWord = (isMisspelled ?? screen?.isMisspelled).map { misspelled in { @Sendable word in !misspelled(word) } }
        let opts = options
        func request(_ target: RewriteTarget) -> RewriteRequest {
            RewriteRequest(target: target.text, before: target.before, after: context.after,
                           surface: context.metadata.surface, appName: context.app.localizedName,
                           fixesCapitals: opts.fixesCapitals, fixesPunctuation: opts.fixesPunctuation,
                           keepsShorthand: opts.leavesShorthand)
        }
        autocorrect.rewriteAtPause(context, policy: policy, options: options, lastKey: lastKey, generate: { [weak self] target in
            guard let self, self.correctionMode(policy).rewritesAtPauses,
                  let rewriter = self.engine(policy) as? any FieldRewriting else { return nil }
            let request = request(target)
            // The newest id: a suggestion request sent after this (the user typed again) cancels it.
            let started = ContinuousClock.now
            let pass: LocalRewriter.Pass
            do {
                pass = try await rewriter.rewrite(request, id: self.session.newestRequestID)
            } catch LocalRewriter.RewriteError.notLoaded {
                // Released while idle, and no suggestion request will reload it (suggestions off):
                // the pass reloads it itself, so the next pause in this field has the model again.
                if !(self.settings().enabled && policy.enabled) {
                    self.prewarmedField = nil
                    self.prewarmIfNewField(context, policy: policy, autocorrectOnly: true)
                }
                return nil
            } catch {
                // A newer request (the user typed again) took the model: the pass's work is lost.
                Self.perf("strong pass: cancelled after \(Self.ms(since: started)) ms, "
                          + "\(Self.ms(since: lastKey)) ms after the last key")
                return nil
            }
            Self.perf("rewrite pass \(Int((ContinuousClock.now - started) / .milliseconds(1))) ms, "
                      + "prompt \(pass.promptTokens) (reused \(pass.reusedTokens)), generated \(pass.generatedTokens)")
            return pass.revised
        }, score: { [weak self] target, head, continuations in
            // Right after the pass, on its own prompt cache; a newer request (the user typed) cancels it.
            guard let self, self.correctionMode(policy).rewritesAtPauses,
                  let rewriter = self.engine(policy) as? any FieldRewriting else { return nil }
            return try? await rewriter.score(request(target), head: head, continuations: continuations,
                                             id: self.session.newestRequestID)
        })
    }

    /// Handles again the newest read, skipped while autocorrect was changing the field, when it shows
    /// the text expected after the change.
    private func replaySkippedRead(expectedBefore: String?) {
        guard let (context, geometry) = latestContext, autocorrect?.busy != true,
              autocorrect?.isChoosing != true else { return }
        if let expectedBefore, !CatchUpPlan.unchanged(before: context.before, originalBefore: expectedBefore) { return }
        handle(.context(context, geometry))
    }

    /// The finder rebuilt only when the learned-word set changes (it indexes those words).
    /// The shorthand switch is per app (and gated globally), so it is set on a copy for each call (the cache is shared).
    private func cachedFinder(_ make: () -> CorrectionFinder, policy: AppPolicy, field: FieldID,
                              bundleID: String, urlHost: String?) -> CorrectionFinder {
        let words = learningWordsSnapshot()
        var finder: CorrectionFinder
        if let cache = finderCache, cache.words == words {
            finder = cache.finder
        } else {
            finder = make()
            finderCache = (words, finder)
        }
        finder.modelFree = !correctionMode(policy).usesModel
        finder.leavesShorthand = settings().autocorrectLeaveChatShorthand && policy.leavesChatShorthand
        finder.fixesCapitals = policy.autoCapitalizationAllowed && settings().autocorrectCapitalization
        finder.fixesConfusedWords = settings().autocorrectFixConfusedWords && policy.fixConfusedWordsAllowed
        finder.textReplacements = TextReplacements.system()
        finder.appliesReplacements = policy.appliesTextReplacements && !finder.textReplacements.isEmpty
            && !HostTextReplacements.appliesItself(bundleID: bundleID)
        finder.fixesPunctuation = settings().fixPunctuation && policy.fixesPunctuation
        finder.doubleSpace = Self.doubleSpaceMode(bundleID: bundleID)
        finder.keyTiming = keyTimingSnapshot?()
        finder.slipProfile = slipProfileSnapshot?()
        finder.learnedHere = learnedHereSnapshot?(AppKey.make(bundleID: bundleID, urlHost: urlHost))
        finder.screenWords = screen?.screenWords(for: field, policy: policy) ?? .empty
        return finder
    }

    /// Two spaces: native text views apply macOS's "Add period with double-space" themselves (when it
    /// is on), so Hunch leaves them alone; elsewhere it makes the period when the system setting
    /// is on (default on) and otherwise just removes the extra space.
    static func doubleSpaceMode(bundleID: String) -> PunctuationFixer.DoubleSpace {
        if HostTextReplacements.appliesItself(bundleID: bundleID) { return .off }
        let enabled = UserDefaults.standard.object(forKey: "NSAutomaticPeriodSubstitutionEnabled") as? Bool ?? true
        return enabled ? .period : .collapse
    }

    private func learningWordsSnapshot() -> Set<String> { learnedWords?() ?? [] }

    private func showReplacement(_ ghost: ReplacementGhost, context: TextContext, policy: AppPolicy) {
        emojiGhost = ghost
        dismissStyleTag()
        // Corrections draw over the host's word, so they need the inline position.
        var mode: GhostMode = ghost.struckText != nil ? .inline
            : chooseMode(ghost.geometry, field: ghost.field, caretAtLineEnd: context.caretAtLineEnd, policy: policy)
        let measured = mode == .mirror
            ? calibrationKey(bundleID: ghost.app.bundleID, geometry: ghost.geometry).flatMap(calibration(for:)) : nil
        let mirror = mode == .mirror ? mirrorContent(field: ghost.field, geometry: ghost.geometry, measured: measured) : nil
        if mode == .mirror, mirror == nil { mode = .card }
        mirrorShown = mode == .mirror
        presenter.present(GhostPresentation(text: ghost.display, geometry: ghost.geometry, mode: mode,
                                            measuredBaseline: measured?.baselineAboveCaretBottom,
                                            struckText: ghost.struckText, tweaks: GhostTweaks(policy), mirror: mirror))
        publishEmoji(policy: policy)
        keyboard.setAcceptTapEnabled(true)
        if emojiRepublisher == nil {
            emojiRepublisher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.republishInterval)
                    guard !Task.isCancelled, let self, let emoji = self.emojiGhost else { return }
                    self.publishEmoji(policy: self.policy(bundleID: emoji.app.bundleID, urlHost: emoji.urlHost))
                }
            }
        }
    }

    private func publishEmoji(policy: AppPolicy) {
        guard let emoji = emojiGhost else { return }
        arbiter.publish(ArbiterSnapshot(field: emoji.field, hasGhost: true, publishedAt: mach_absolute_time(),
                                        tabAllowed: tabAllowed, alternativesAvailable: false,
                                        wordKey: policy.acceptWordKey, fullKey: policy.acceptFullKey))
    }

    private func clearEmoji() {
        guard emojiGhost != nil else { return }
        emojiGhost = nil
        emojiRepublisher?.cancel()
        emojiRepublisher = nil
        presenter.hide()
        arbiter.publish(nil)
        keyboard.setAcceptTapEnabled(false)
    }

    private func acceptEmoji(_ ghost: ReplacementGhost) {
        clearEmoji()
        // A fix (not an emoji) was taken: a small signal against learning that word.
        if ghost.struckText != nil, let word = correctionSkips.accepted() { learning?.noteCorrectionAccepted(word) }
        if ghost.struckText != nil { autocorrect?.noteAccepted() }
        // The field must still hold exactly what the ghost was built from; a lagging read would
        // otherwise make the Backspaces delete the wrong characters.
        guard latestBefore?.field == ghost.field, latestBefore?.before == ghost.before else { return }
        let policy = policy(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost)
        let inserter = self.inserter
        // A fix taken with Tab can be put back later (not an emoji). Recorded before it goes in, so
        // the reads showing it already find it (a lagging read still showing the word is ignored).
        if ghost.struckText != nil {
            autocorrect?.noteTabFix(field: ghost.field, before: ghost.before, deleteCount: ghost.deleteCount,
                                    replacement: ghost.replacement)
        }
        Task {
            _ = await inserter.replace(deletingBackward: ghost.deleteCount, with: ghost.replacement, into: ghost.app,
                                       mode: policy.insertion, chunkSize: policy.injectionChunkSize ?? 16,
                                       workarounds: policy.insertionWorkarounds)
        }
    }

    // MARK: Session plumbing

    private func send(_ event: SessionEvent) {
        let commands = session.handle(event, now: .now)
        if DrawDebugLog.isEnabled, case .accept = event {
            DrawDebugLog.note("session accept -> \(commands.map { String(describing: $0).prefix(24) })")
        }
        if commands.contains(where: { if case .present = $0 { true } else { false } }) { lastGhostShow = .now }
        if commands.contains(.hide) {
            lastGhostHide = .now
            lastHideReason = Self.eventName(event)
        }
        commands.forEach(execute)
        updateRepublisher()
    }

    /// The event's case name only (never its text).
    private static func eventName(_ event: SessionEvent) -> String {
        switch event {
        case .context: "context"
        case .blocked: "blocked"
        case .focusLost: "focusLost"
        case .result: "result"
        case .partial: "partial"
        case .accept: "accept"
        case .insertFinished: "insertFinished"
        case .insertLost: "insertLost"
        case .escape: "escape"
        case .editBehindCaret: "editBehindCaret"
        case .characterTyped: "characterTyped"
        case .forceActivate: "forceActivate"
        case .mouseDown: "mouseDown"
        case .secureInputChanged: "secureInput"
        case .republishTick: "republishTick"
        case .cycleAlternative: "cycleAlternative"
        case .alternatives: "alternatives"
        }
    }

    private func execute(_ command: SessionCommand) {
        switch command {
        case .present(let ghost):
            let policy = policy(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost)
            draw(ghost, policy: policy)
            publish(ghost, policy: policy)
            keyboard.setAcceptTapEnabled(true)
        case .republish(let ghost):
            publish(ghost, policy: policy(bundleID: ghost.app.bundleID, urlHost: ghost.urlHost))
        case .hide:
            presenter.hide()
            if styleTagField == nil { styleTag(nil, nil) }  // kept up while stepping through styles
            arbiter.publish(nil)
            keyboard.setAcceptTapEnabled(false)
        case let .holdAccept(field, app, urlHost):
            let publishHold = { [weak self] in
                guard let self else { return }
                let policy = self.policy(bundleID: app.bundleID, urlHost: urlHost)
                let shell = self.latestSurface == .shell
                self.arbiter.publish(ArbiterSnapshot(field: field, hasGhost: true, publishedAt: mach_absolute_time(),
                                                     tabAllowed: self.tabAllowed && !shell, holdOnly: true,
                                                     shellKeys: shell, wordKey: policy.acceptWordKey,
                                                     fullKey: policy.acceptFullKey))
            }
            publishHold()
            keyboard.setAcceptTapEnabled(true)
            holdReleaser?.cancel()
            holdReleaser = Task { [weak self] in
                // An autocorrect edit still running: keep owning the accept keys until it is read back.
                // The pass after it was read back publishes once more, covering the wait for its suggestion.
                while let self, self.session.isHoldingForEdit(now: .now) {
                    try? await Task.sleep(for: Self.republishInterval)
                    guard !Task.isCancelled else { return }
                    guard self.session.visibleGhost == nil, self.emojiGhost == nil else { return }
                    publishHold()
                }
                try? await Task.sleep(for: SuggestionSession.acceptHold + .milliseconds(100))
                guard !Task.isCancelled, let self, self.session.visibleGhost == nil, self.emojiGhost == nil
                else { return }
                // The hold expired with nothing shown: stop consuming keys.
                self.keyboard.setAcceptTapEnabled(false)
            }
        case let .requestAlternatives(id, context):
            fetchAlternatives(id: id, context: context)
        case .cancelRequest:
            inflight?.cancel()
            inflight = nil
            for task in lateRequests.values { task.cancel() }
            lateRequests = [:]
        case let .request(id, context, _):
            startRequest(id: id, context: context)
        case let .insert(text, app, urlHost):
            lastAcceptAt = .now
            learning?.noteAccepted(text)
            outcomes.noteAccepted(text)
            let preBefore = latestBefore
            insertVerifier?.cancel()
            let policy = policy(bundleID: app.bundleID, urlHost: urlHost)
            let inserter = self.inserter
            Task { [weak self] in
                let outcome = await inserter.insert(text, into: app, mode: policy.insertion,
                                                    chunkSize: policy.injectionChunkSize ?? 16,
                                                    workarounds: policy.insertionWorkarounds)
                DrawDebugLog.note("insert len=\(text.count) outcome=\(outcome)")
                if case .failed = outcome {
                    self?.send(.insertFinished(success: false))
                } else {
                    self?.send(.insertFinished(success: true))
                    self?.verifyInsert(text, field: preBefore?.field, preBefore: preBefore?.before)
                }
            }
        }
    }

    private func draw(_ ghost: GhostState, policy: AppPolicy) {
        var mode = chooseMode(ghost.geometry, field: ghost.field, caretAtLineEnd: ghost.caretAtLineEnd,
                              policy: policy)
        if mode == .mirror, session.acceptedTextLanding {
            // Accepted text the field hasn't shown yet: a mirror would redraw the line without it.
            // The host's own line shows until the text lands and the next context redraws.
            mirrorShown = false
            presenter.hide()
            if styleTagField == nil { styleTag(nil, nil) }  // kept up while stepping through styles
            return
        }
        let key = calibrationKey(for: ghost)
        let measured = key.flatMap { calibrations[$0] ?? calibrationStore.calibration(for: $0) }
        let mirror = mode == .mirror ? mirrorContent(field: ghost.field, geometry: ghost.geometry, measured: measured) : nil
        if mode == .mirror, mirror == nil { mode = .card }
        mirrorShown = mode == .mirror
        if DrawDebugLog.isEnabled {
            DrawDebugLog.note("ghost field=\(ghost.field.pid)/\(ghost.field.elementHash)/\(ghost.field.generation) app=\(ghost.app.bundleID) "
                + "key=\(key.map { "h\($0.caretHeight) s\($0.fontSize)" } ?? "nil") calibrated=\(measured != nil) "
                + "thisSession=\(key.map { calibrations[$0] != nil } ?? false)")
        }
        let onLine = mode == .inline || mode == .mirror
        // The face and size decided from the measurement, shared with the reader (next reads carry
        // it) and applied to this draw right away.
        var geometry = ghost.geometry
        if let measured {
            FaceChoiceBook.shared.set(measured.faceChoice,
                                      for: .init(bundleID: ghost.app.bundleID, pointSize: geometry.font?.pointSize,
                                                 fontTag: FaceChoiceBook.fontTag(geometry.font)))
            geometry.font = FaceChoiceBook.shared.apply(to: geometry.font, bundleID: ghost.app.bundleID)
        }
        var presentation = GhostPresentation(text: ghost.remaining, geometry: geometry, mode: mode,
                                             measuredBaseline: onLine ? measured?.baselineAboveCaretBottom : nil,
                                             measuredXHeight: measured?.hostXHeight, tweaks: GhostTweaks(policy),
                                             mirror: mirror)
        presentation.drawnXHeights = measured?.faceXHeights ?? [:]
        presentation.measuredAtSize = measured?.measuredAtSize
        presentation.appID = ghost.app.bundleID
        presenter.present(presentation)
        styleTag(styleTagNames(for: ghost), geometry.caretRect)
        // A saved measurement is drawn with right away and still re-measured once per session (twice
        // when a size correction needs confirming).
        if let key, calibrations[key] == nil || confirmingSize.contains(key), onLine, policy.screenContextAllowed {
            calibrate(ghost, key: key)
        }
    }

    /// An inline presentation of `text` at `geometry`'s caret, drawn the way a suggestion there would
    /// be (measured face and baseline, the app's tweaks and own look), for dictation's effect.
    func effectPresentation(_ text: String, context: TextContext, geometry: CaretGeometry) -> GhostPresentation {
        let policy = policy(bundleID: context.app.bundleID, urlHost: context.urlHost)
        let measured = calibrationKey(bundleID: context.app.bundleID, geometry: geometry).flatMap(calibration(for:))
        var geometry = geometry
        if measured != nil {
            geometry.font = FaceChoiceBook.shared.apply(to: geometry.font, bundleID: context.app.bundleID)
        }
        var p = GhostPresentation(text: text, geometry: geometry, mode: .inline,
                                  measuredBaseline: measured?.baselineAboveCaretBottom,
                                  measuredXHeight: measured?.hostXHeight, tweaks: GhostTweaks(policy))
        p.appID = context.app.bundleID
        return p
    }

    /// The chooser with the latest context's selection and marked text for this field (an input
    /// method's composition counts as marked text even where the host doesn't mark it).
    private func chooseMode(_ geometry: CaretGeometry, field: FieldID, caretAtLineEnd: Bool,
                            policy: AppPolicy) -> GhostMode {
        let state = latestEditState?.field == field ? latestEditState : nil
        return modeChooser.mode(for: geometry, caretAtLineEnd: caretAtLineEnd, preference: policy.overlay,
                                hasSelection: state?.hasSelection ?? true,
                                hasMarkedText: (state?.hasMarkedText ?? true) || composition.composing)
    }

    /// Mirror mode's line: the caret's line in the field's latest text, where it starts, and its
    /// background (the host's report, else the calibration strip's sample; else the presenter
    /// derives one). Nil when the latest text is another field's or the line start is unknown.
    private func mirrorContent(field: FieldID, geometry: CaretGeometry, measured: TextCalibration?) -> MirrorContent? {
        guard let latest = latestBefore, latest.field == field, let startX = geometry.lineStartX else { return nil }
        return MirrorContent(lineBefore: MirrorLayout.lastLine(of: latest.before), lineStartX: startX,
                             backgroundColor: geometry.font?.backgroundColor ?? measured?.backgroundColor)
    }

    /// Takes the mirror down at once, before anything is typed into the host: the host's line then
    /// shows exactly as the host drew it.
    private func tearDownMirror() {
        guard mirrorShown else { return }
        mirrorShown = false
        presenter.hide()
    }

    private func calibrationKey(for ghost: GhostState) -> CalibrationKey? {
        calibrationKey(bundleID: ghost.app.bundleID, geometry: ghost.geometry)
    }

    private func calibrationKey(bundleID: String, geometry: CaretGeometry) -> CalibrationKey? {
        guard geometry.quality >= .derived else { return nil }
        let size = geometry.font?.pointSize ?? 0
        return CalibrationKey(bundleID: bundleID, caretHeight: Int(geometry.caretRect.height.rounded()),
                              fontSize: Int((size * 2).rounded()), fontTag: FaceChoiceBook.fontTag(geometry.font))
    }

    /// This session's measurement for `key`, else the saved one.
    private func calibration(for key: CalibrationKey) -> TextCalibration? {
        calibrations[key] ?? calibrationStore.calibration(for: key)
    }

    /// Measures the host's painted text once per line style per session (bursts of 3 tries 2 s
    /// apart, a new burst 30 s after a failed one; `CalibrationRetry`), saves it, then redraws.
    private func calibrate(_ ghost: GhostState, key: CalibrationKey) {
        guard calibrating == nil else { DrawDebugLog.note("calibrate waiting: previous still running"); return }
        // Not enough typed text inside the field yet: wait without spending an attempt.
        guard TextCalibrationProbe.hasRoom(caretRect: ghost.geometry.caretRect, fieldFrame: ghost.geometry.fieldFrame)
        else { return }
        // The typed text on the caret's line: what the capture should show (match and verify).
        guard let before = latestBefore, before.field == ghost.field else { return }
        let lineText = String(before.before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        guard lineText.contains(where: { !$0.isWhitespace }) else { return }
        var retry = calibrationAttempts[key] ?? CalibrationRetry()
        guard retry.begin(at: .now) else { return }
        if calibrationAttempts.count > 256 { calibrationAttempts.removeAll() }
        calibrationAttempts[key] = retry
        let probe = calibrationProbe
        let caret = ghost.geometry.caretRect
        let fieldFrame = ghost.geometry.fieldFrame
        let pid = ghost.app.pid
        let font = ghost.geometry.font
        calibrating = Task { [weak self] in
            let measured = await probe.measure(pid: pid, caretRect: caret, fieldFrame: fieldFrame,
                                             lineText: lineText, font: font,
                                             ownPid: ProcessInfo.processInfo.processIdentifier)
            guard let self else { return }
            self.calibrating = nil
            guard let measured else { return }
            let previous = self.calibration(for: key)
            let result = measured.decided(previous: previous)
            self.noteFaceChange(app: ghost.app.bundleID, key: key, from: previous?.faceChoice ?? .none, to: result)
            if result.needsConfirmation { self.confirmingSize.insert(key) } else { self.confirmingSize.remove(key) }
            if self.calibrations.count > 256 { self.calibrations.removeAll() }
            self.calibrations[key] = result
            self.calibrationStore.save(result, for: key)
            if let visible = self.session.visibleGhost, self.calibrationKey(for: visible) == key {
                self.draw(visible, policy: self.policy(bundleID: visible.app.bundleID, urlHost: visible.urlHost))
            }
        }
    }

    /// Alignment check log: a face pick or size correction applied or cleared for a line style.
    private func noteFaceChange(app: String, key: CalibrationKey, from old: FaceChoice, to new: TextCalibration) {
        let choice = new.faceChoice
        let size = String(format: "%.1f", Double(key.fontSize) / 2)
        let host = new.hostXHeight.map { String(format: "%.2f", $0) } ?? "nil"
        let logKey = "change|\(app)|\(key.fontSize)"
        if old != choice {
            AlignmentCheckLog.note("correction app=\(app) size=\(size) face=\(old.family ?? "default")→\(choice.family ?? "default") "
                + String(format: "sizeFactor=%.3f→%.3f", old.sizeFactor, choice.sizeFactor) + " x(host)=\(host)", key: logKey)
        } else if new.needsConfirmation, let s = new.sizeSuggestion {
            AlignmentCheckLog.note("pending app=\(app) size=\(size) suggests sizeFactor=" + String(format: "%.3f", s)
                + " x(host)=\(host), measuring again to confirm", key: logKey)
        }
    }

    // MARK: Fields with no text positions

    /// True when the caret can be placed after the field's typed line: the reader only estimated it,
    /// and the caret ends the field's single line with nothing selected or composing.
    private static func canPlace(_ geometry: CaretGeometry, context: TextContext) -> Bool {
        geometry.quality == .estimated && geometry.fieldFrame != nil && context.after.isEmpty
            && context.selectionLength == 0 && !context.hasMarkedText
            && TypedTextAnchor.isPlaceable(before: context.before)
    }

    private static func anchorKey(_ app: AppIdentity, frame: CGRect) -> AnchorKey {
        AnchorKey(bundleID: app.bundleID, height: Int(frame.height.rounded()))
    }

    // MARK: Empty fields

    /// Where text starts in each app's fields (keyed by app and site), learned while typing a first
    /// line, for placing dictation's effect in an empty field that reports no caret position.
    private lazy var emptyFieldStarts: [String: EmptyFieldStart] = {
        guard let data = UserDefaults.standard.data(forKey: Self.emptyFieldStartsKey),
              let saved = try? JSONDecoder().decode([String: EmptyFieldStart].self, from: data) else { return [:] }
        return saved
    }()
    private static let emptyFieldStartsKey = "emptyFieldTextStarts"

    private static func emptyFieldKey(_ context: TextContext) -> String {
        context.app.bundleID + "|" + (context.urlHost ?? "")
    }

    private func learnEmptyFieldStart(_ context: TextContext, geometry: CaretGeometry) {
        guard geometry.quality == .exact, let field = geometry.fieldFrame,
              !context.before.isEmpty, !context.before.contains(where: \.isNewline),
              context.selectionLength == 0, !context.hasMarkedText else { return }
        // The host's own position for the line's first character; else, with only a character or two
        // typed, their measured width (a font that differs from the host's is then off by a point at
        // most, where a longer line would be off by many).
        let width: CGFloat
        if let startX = geometry.lineStartX {
            width = geometry.caretRect.minX - startX
        } else if context.before.count <= 2, let size = geometry.font?.pointSize, size > 0 {
            let font = TextCalibrationProbe.font(for: geometry.font, size: size)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: context.before, attributes: [.init(kCTFontAttributeName as String): font]))
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        } else {
            return
        }
        guard var start = EmptyFieldStart.learn(caret: geometry.caretRect, field: field, lineWidth: width) else { return }
        start.fromHost = geometry.lineStartX != nil
        let key = Self.emptyFieldKey(context)
        let old = emptyFieldStarts[key]
        // A measured start never replaces one the host gave.
        if old?.fromHost == true, start.fromHost != true { return }
        // Only a move of a point or more is worth saving.
        if let old, abs(old.left - start.left) < 1, abs(old.top - start.top) < 1,
           abs(old.caretHeight - start.caretHeight) < 1 { return }
        if emptyFieldStarts.count > 256 { emptyFieldStarts.removeAll() }
        emptyFieldStarts[key] = start
        Self.perf("empty field start learned: left=\(Int(start.left)) top=\(Int(start.top)) "
            + "from=\(geometry.lineStartX == nil ? "measure" : "host") app=\(context.app.bundleID)")
        if let data = try? JSONEncoder().encode(emptyFieldStarts) {
            UserDefaults.standard.set(data, forKey: Self.emptyFieldStartsKey)
        }
    }

    /// The caret for drawing dictation's effect: the suggestion geometry, or in an empty field that
    /// only has an estimate, where this app's text was seen to start.
    func effectGeometry(_ geometry: CaretGeometry, context: TextContext) -> CaretGeometry {
        let placed = placedGeometry(geometry, context: context)
        guard placed.quality < .derived, let field = placed.fieldFrame,
              context.before.isEmpty, context.after.allSatisfy(\.isNewline),
              let start = emptyFieldStarts[Self.emptyFieldKey(context)] else { return placed }
        var out = placed
        out.caretRect = start.caret(in: field)
        out.lineStartX = out.caretRect.minX
        out.quality = .derived
        return out
    }

    /// The reader's geometry, or, for a field with no text positions whose typed line was found on
    /// screen, a caret after that line ("derived", so Automatic draws inline).
    private func placedGeometry(_ geometry: CaretGeometry, context: TextContext) -> CaretGeometry {
        guard Self.canPlace(geometry, context: context), let frame = geometry.fieldFrame,
              let anchor = typedAnchors.anchor(for: Self.anchorKey(context.app, frame: frame)) else { return geometry }
        let font = TextCalibrationProbe.font(for: geometry.font, size: anchor.pointSize)
        guard let caret = anchor.caret(after: context.before, fieldFrame: frame, font: font) else { return geometry }
        var placed = geometry
        placed.caretRect = caret
        placed.quality = .derived
        var hint = geometry.font ?? FontHint()
        hint.pointSize = anchor.pointSize
        placed.font = hint
        return placed
    }

    /// Looks for the typed line on screen when the reader could only estimate the caret, while
    /// typing at most every `relocateInterval` (`TypedAnchorBook` decides what a look changes).
    private func locateTypedTextIfNeeded(_ context: TextContext, geometry: CaretGeometry, policy: AppPolicy) {
        guard locating == nil, policy.screenContextAllowed, Self.canPlace(geometry, context: context),
              TypedTextAnchor.isEligible(before: context.before), let frame = geometry.fieldFrame else { return }
        if let last = lastLocate, last.field == context.field, ContinuousClock.now - last.at < Self.relocateInterval {
            return
        }
        lastLocate = (context.field, .now)
        let locator = textLocator
        let field = context.field
        let text = context.before
        let font = geometry.font
        let key = Self.anchorKey(context.app, frame: frame)
        locating = Task { [weak self] in
            let anchor = await locator.locate(pid: field.pid, fieldFrame: frame, text: text, font: font,
                                              ownPid: ProcessInfo.processInfo.processIdentifier)
            guard let self else { return }
            self.locating = nil
            // Typing moved on while looking: the capture may show older text, so only a fit of the
            // text still in the field counts.
            guard self.latestBefore?.field == field, self.latestBefore?.before == text else { return }
            let changed = anchor.map { self.typedAnchors.noteFound($0, for: key) }
                ?? self.typedAnchors.noteMissed(for: key)
            if changed {
                self.anchorStore.set(self.typedAnchors.anchor(for: key), for: key)
                self.redrawPlaced(field: field)
            }
        }
    }

    /// Redraws a visible ghost in `field` with the caret from the current anchor (or without one).
    private func redrawPlaced(field: FieldID) {
        guard var visible = session.visibleGhost, visible.field == field,
              let raw = latestRawGeometry, raw.field == field,
              let before = latestBefore, before.field == field else { return }
        let context = TextContext(app: visible.app, field: field, before: before.before, after: "",
                                  caretAtLineEnd: visible.caretAtLineEnd, contentSignature: 0)
        visible.geometry = placedGeometry(raw.geometry, context: context)
        draw(visible, policy: policy(bundleID: visible.app.bundleID, urlHost: visible.urlHost))
    }

    private func publish(_ ghost: GhostState, policy: AppPolicy) {
        // The local engine can always produce alternatives (fetched on demand); other engines may not.
        let supported = engine(policy)?.kind == .local
        let exhausted = noAlternativesFor?.field == ghost.field && noAlternativesFor?.before == latestBefore?.before
        let shell = latestSurface == .shell
        var snapshot = ArbiterSnapshot(field: ghost.field, hasGhost: true, publishedAt: mach_absolute_time(),
                                       tabAllowed: tabAllowed && !shell,
                                       alternativesAvailable: supported && !exhausted && !shell,
                                       shellKeys: shell, wordKey: policy.acceptWordKey, fullKey: policy.acceptFullKey)
        if !shell {
            let usable = !SuggestionStyleRing.usable(settings().suggestionStyles).isEmpty
            snapshot.styleNextAvailable = usable
            snapshot.stylePreviousAvailable = usable
        }
        arbiter.publish(snapshot)
    }

    /// Keeps the arbiter snapshot fresh while a ghost is visible; stops once it hides.
    private func updateRepublisher() {
        if session.visibleGhost == nil {
            republisher?.cancel()
            republisher = nil
        } else if republisher == nil {
            republisher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.republishInterval)
                    guard !Task.isCancelled, let self else { return }
                    self.send(.republishTick)
                }
            }
        }
    }

    /// A plain Tab reached the app: why Hunch didn't take it (flags and times only, never text).
    private func logTabPassed() {
        guard PromptDebugLog.isEnabled else { return }
        let now = ContinuousClock.now
        let sinceHide = lastGhostHide.map { "\(Self.ms(since: $0))" } ?? "-"
        let sinceShow = lastGhostShow.map { "\(Self.ms(since: $0))" } ?? "-"
        Self.perf("tab passed to app: ghost=\(session.visibleGhost != nil) emoji=\(emojiGhost != nil) "
                  + "hold=\(session.isHoldingAccept(now: now)) editHold=\(session.isHoldingForEdit(now: now)) "
                  + "autocorrectBusy=\(autocorrect?.busy == true) choosing=\(autocorrect?.isChoosing == true) "
                  + "tabAllowed=\(tabAllowed) msSinceShow=\(sinceShow) msSinceHide=\(sinceHide) "
                  + "lastHide=\(lastHideReason)")
    }

    private func policy(bundleID: String, urlHost: String?) -> AppPolicy {
        policies.resolve(bundleID: bundleID, urlHost: urlHost).policy
    }

    // MARK: Requests

    /// Shell commands always use the on-device model: shell history and terminal text never go to
    /// an endpoint, whatever the app or global engine choice.
    static func requestPolicy(_ policy: AppPolicy, context: TextContext) -> AppPolicy {
        guard context.metadata.surface == .shell else { return policy }
        var local = policy
        local.engineOverride = .local
        return local
    }

    /// Whole milliseconds from `start` to now.
    nonisolated static func ms(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    /// One counts-only line in perf.log while debug logging is on.
    nonisolated static func perf(_ line: String) {
        guard PromptDebugLog.isEnabled else { return }
        PromptDebugLog.note(line, file: "perf.log")
    }

    nonisolated static func perfResult(_ result: CompletionResult, displayed: Bool, late: Bool = false) {
        guard PromptDebugLog.isEnabled else { return }
        let fate: String = switch result.outcome {
        case .show: displayed ? "shown" : "not-displayed"
        case .suppress(let reason): "suppressed:\(reason.rawValue)"
        }
        func ms(_ d: Duration?) -> String {
            d.map { String(format: "%.1f", Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15) } ?? "-"
        }
        perf("result id=\(result.id.raw) fate=\(fate)\(late ? " late=1" : "") path=\(result.path.rawValue) firstMs=\(ms(result.timings.firstVisible)) "
             + "totalMs=\(ms(result.timings.total)) syncMs=\(ms(result.timings.promptSync)) "
             + "decodedPrompt=\(result.timings.decodedPromptTokens)")
    }

    private func startRequest(id: RequestID, context: TextContext) {
        Self.perf("request id=\(id.raw)")
        // One still waiting out the pause is cancelled before any GPU work; one already at the model
        // keeps running (the engine aborts it at its next decode step if it can) for a late result.
        if let task = inflight, let atModel = inflightAtModel {
            lateRequests[atModel.raw] = task
        } else {
            inflight?.cancel()
        }
        inflight = nil
        inflightAtModel = nil
        let policy = Self.requestPolicy(policy(bundleID: context.app.bundleID, urlHost: context.urlHost), context: context)
        guard settings().enabled, let engine = engine(policy) else { return }
        engine.cancel(olderThan: id)
        if context.metadata.surface == .shell {
            startShellRequest(id: id, context: context, policy: policy, engine: engine)
            return
        }
        var request = makeRequest(id: id, context: context, policy: policy)
        request.streamsCheckedPartials = settings().showWhileWriting
        let learning = self.learning
        let delay = requestDelay
        inflight = Task { [weak self] in
            do {
                // A new keystroke within the pause cancels this task before any GPU work starts.
                if delay > .zero { try await Task.sleep(for: delay) }
                // Learned words only where learning is allowed, so a private name learned in one
                // app doesn't surface in another the user has excluded.
                if let learning {
                    let appKey = AppKey.make(bundleID: context.app.bundleID, urlHost: context.urlHost)
                    let learningAllowed = CodeSurfaceRules.learningAllowed(policy: policy, surface: context.metadata.surface)
                    async let bias = learning.bias(for: context.before, appKey: appKey,
                                                  learningAllowed: learningAllowed)
                    async let style = learning.styleExamples(for: context.before, field: context.field,
                                                             appKey: appKey, learningAllowed: learningAllowed)
                    // Gated learned-word notes, from the same screen text the prompt gets (instruct
                    // framers name them; the document framer for base models ignores them).
                    let screen = request.input.screenContext
                    async let vocabulary = learning.vocabulary(for: context.before, screen: screen,
                                                               appKey: appKey, learningAllowed: learningAllowed)
                    request.bias = await bias
                    request.input.styleExamples = await style
                    let notes = await vocabulary
                    request.input.vocabulary = notes.words
                    request.learnedNotes = notes.diagnostics
                }
                try Task.checkCancellation()
                self?.inflightAtModel = id
                defer { self?.requestEnded(id) }
                self?.streams[id.raw] = (.now, nil, nil)
                // With streaming off the engine still reports the raw text as it is decoded; showing
                // it would flash suggestions the finished result then changes or hides (e.g. one
                // below the confidence floor), so only checked partials reach the session.
                let streamsPartials = request.streamsCheckedPartials
                let result = try await engine.complete(request) { [weak self] text in
                    guard streamsPartials else { return }
                    Task { @MainActor in self?.streamed(id: id, text: text, context: context) }
                }
                guard !Task.isCancelled, let self else {
                    Self.perf("superseded id=\(id.raw)")
                    DiagnosticNotes.judge(id, .notDisplayed("the result came back after you had typed on, so it was dropped"))
                    return
                }
                let text: String? = if case .show(let text) = result.outcome { text } else { nil }
                let late = id != self.session.latestRequestID
                self.send(.result(id: result.id, text: text, requestContext: context))
                // A late result shows only the part not typed yet, so compare the ghost's end.
                let displayed = text.map { text in
                    self.session.visibleGhost.map { !$0.remaining.isEmpty && text.hasSuffix($0.remaining) } ?? false
                } ?? false
                Self.perfResult(result, displayed: displayed, late: late)
                DiagnosticNotes.judge(id, text: text, displayed: displayed, late: late,
                                      shown: self.session.visibleGhost?.remaining)
                self.perfStream(id: id, final: text)
                if let text, displayed {
                    learning?.noteShown(context: context, text: text, scores: result.wordScores)
                    self.outcomes.noteShown(context: context, text: text, result: result, late: late)
                }
            } catch {
                // Cancellation and engine errors simply produce no suggestion.
                Self.perf("ended id=\(id.raw) without a result (\(error is CancellationError ? "cancelled" : "error"))")
            }
        }
    }

    /// Checked words of a suggestion still being written.
    private func streamed(id: RequestID, text: String, context: TextContext) {
        send(.partial(id: id, text: text, requestContext: context))
        guard session.visibleGhost?.remaining == text, var stream = streams[id.raw] else { return }
        if stream.first == nil { stream.first = .now - stream.start }
        stream.last = text
        streams[id.raw] = stream
    }

    /// One counts-only line per request whose stream was shown: what the final result did to it.
    private func perfStream(id: RequestID, final: String?) {
        guard let stream = streams.removeValue(forKey: id.raw), let last = stream.last, let first = stream.first
        else { return }
        let outcome = switch final {
        case nil: "vanished"
        case last?: "kept"
        case let text? where text.hasPrefix(last): "grew"
        case let text? where last.hasPrefix(text): "shortened"
        default: "changed"
        }
        let ms = Double(first.components.seconds) * 1000 + Double(first.components.attoseconds) / 1e15
        Self.perf("stream id=\(id.raw) outcome=\(outcome) firstMs=\(String(format: "%.1f", ms))")
    }

    private func requestEnded(_ id: RequestID) {
        streams[id.raw] = nil
        lateRequests[id.raw] = nil
        if inflightAtModel == id { inflightAtModel = nil }
    }

    /// At a shell prompt: the newest matching command from the user's history, shown at once; else
    /// the local model writes the rest of the line, shown only when it names real commands, parses,
    /// and is not risky (`ShellEnvironment.isValidSuggestion`). Nothing is learned here.
    private func startShellRequest(id: RequestID, context: TextContext, policy: AppPolicy,
                                   engine: any CompletionEngine) {
        let typed = context.metadata.typedCommand ?? ""
        let historyFile = shellHistory
        let environment = shellEnvironment
        let delay = requestDelay
        let request = makeRequest(id: id, context: context, policy: policy)
        inflight = Task { [weak self] in
            do {
                let history = await Task.detached { historyFile.current() }.value
                if let fromHistory = history.completion(for: typed) {
                    guard !Task.isCancelled, let self else { return }
                    self.send(.result(id: id, text: fromHistory, requestContext: context))
                    return
                }
                if delay > .zero { try await Task.sleep(for: delay) }
                let result = try await engine.complete(request) { _ in }
                guard !Task.isCancelled else { return }
                var text: String? = if case .show(let text) = result.outcome { text } else { nil }
                if let candidate = text {
                    let valid = await Task.detached { environment.isValidSuggestion(typed + candidate) }.value
                    if !valid {
                        text = nil
                        DiagnosticNotes.judge(id, .blockedByShellCheck)
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.send(.result(id: result.id, text: text, requestContext: context))
            } catch {
                // Cancellation and engine errors simply produce no suggestion.
            }
        }
    }

    /// How many recent history commands the model sees.
    static let shellRecentCommands = 8

    /// The note the model gets at a shell prompt: one command line, and the user's recent commands.
    static func shellInstructions(recent: [String]) -> String {
        var note = "Complete the command line typed at this shell prompt with one valid shell command. "
            + "Write only the command, never prose or an explanation."
        if !recent.isEmpty {
            note += "\nCommands I ran recently:\n" + recent.map { "  " + $0 }.joined(separator: "\n")
        }
        return note
    }

    private func makeRequest(id: RequestID, context: TextContext, policy: AppPolicy) -> CompletionRequest {
        if context.metadata.surface == .shell { return makeShellRequest(id: id, context: context) }
        // A suggestion style replaces the app's instructions and "How I write" and may set the length.
        let style = style(for: context.field)
        var policy = policy
        if let style {
            policy.customInstructions = nil
            if let length = style.length { policy.length = length }
        }
        let settings = settings()
        let preset = policy.length ?? settings.length
        var decode = settings.decode
        // The older word limit only applies where no length is chosen here.
        decode.maxWords = policy.length == nil ? (policy.maxWordsOverride ?? preset.maxWords) : preset.maxWords
        decode.minWords = min(preset.minWords, decode.maxWords)
        decode.maxTokens = max(decode.maxTokens, preset.maxTokens)
        decode.holdEndBelowMinWords = preset.holdsEnd
        decode.allowNewline = false
        decode.wordStartMinFirstLogProb = settings.suggestionConfidence.wordStartMinFirstLogProb
        let instructions = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var input = PromptInput(
            before: context.before, after: context.after,
            surface: policy.omitSurfaceContext ? .unknown : context.metadata.surface,
            // "How I write" is left out where this app's or site's own instructions replace it.
            globalInstructions: instructions.isEmpty || Self.replacesGlobal(policy) ? nil : instructions,
            appInstructions: policy.customInstructions,
            aboutWriter: settings.usePersonalInfo && policy.personalInfoAllowed
                ? Self.aboutWriter(aboutMe: settings.aboutMe) : nil,
            preferredLanguages: InputMethodState.shared.promptLanguages,
            maxWords: decode.maxWords, allowNewlines: false,
            // Latest cached excerpt for this field only; a request never waits for OCR.
            screenContext: screen?.excerptText(for: context.field, policy: policy),
            clipboard: clipboard?.excerpt(for: context, policy: policy),
            // Where the user is writing: app name and site always (metadata), the window title only
            // when opted in (it can carry chat names or email subjects).
            appName: context.app.localizedName,
            domain: context.urlHost,
            windowTitle: settings.windowTitleContextEnabled ? context.windowTitle : nil,
            allowedScripts: InputSourceScripts.shared.allowed,
            preferredHanScript: InputSourceScripts.shared.preferredHan,
            // The field's label, else its placeholder: what belongs in this box. A code buffer's
            // label is the editor's accessibility hint, not a description of the text.
            fieldLabel: context.metadata.surface == .code ? nil : context.metadata.label ?? context.metadata.placeholder,
            quoteStyle: policy.smartQuotesEnabled ? .matchField : .straight)
        if let style {
            input.globalInstructions = nil
            input.styleInstructions = style.instructions
        }
        let screenRange = HunchSettings.screenContextTokenRange
        input.screenTokenLimit = min(max(settings.screenContextTokenLimit, screenRange.lowerBound), screenRange.upperBound)
        input.screenInterfaceDropped = screen?.excerptInterfaceDropped(for: context.field, policy: policy) ?? 0
        evalCapture.noteRequest(context, screen: input.screenContext)
        return CompletionRequest(id: id, context: context, input: input, decode: decode)
    }

    // MARK: Write for me

    /// Asks the focus tracker for a read now (the next context arrives through `handle`).
    func requestContextNow() { requestFreshContext() }

    /// The newest suggestion request id: a write on the shared model runs as this id, so it is the
    /// newest job there until the user types again.
    var currentRequestID: RequestID { session.newestRequestID }

    /// The writer, the place and the reference text for a write-for-me draft, built like a
    /// suggestion's prompt input. `before`/`after` are the field's text around the range.
    func writeInput(context: TextContext, textBefore: String, textAfter: String) async -> PromptInput {
        let policy = policy(bundleID: context.app.bundleID, urlHost: context.urlHost)
        let settings = settings()
        let instructions = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var input = PromptInput(
            before: textBefore, after: textAfter,
            surface: policy.omitSurfaceContext ? .unknown : context.metadata.surface,
            globalInstructions: instructions.isEmpty || Self.replacesGlobal(policy) ? nil : instructions,
            appInstructions: policy.customInstructions,
            aboutWriter: settings.usePersonalInfo && policy.personalInfoAllowed
                ? Self.aboutWriter(aboutMe: settings.aboutMe) : nil,
            preferredLanguages: InputMethodState.shared.promptLanguages,
            maxWords: 0, allowNewlines: true,
            screenContext: screen?.excerptText(for: context.field, policy: policy),
            clipboard: clipboard?.excerpt(for: context, policy: policy),
            appName: context.app.localizedName,
            domain: context.urlHost,
            windowTitle: settings.windowTitleContextEnabled ? context.windowTitle : nil,
            allowedScripts: InputSourceScripts.shared.allowed,
            preferredHanScript: InputSourceScripts.shared.preferredHan,
            fieldLabel: context.metadata.label ?? context.metadata.placeholder,
            quoteStyle: policy.smartQuotesEnabled ? .matchField : .straight)
        if let learning {
            let appKey = AppKey.make(bundleID: context.app.bundleID, urlHost: context.urlHost)
            let allowed = CodeSurfaceRules.learningAllowed(policy: policy, surface: context.metadata.surface)
            input.styleExamples = await learning.styleExamples(for: textBefore, field: context.field, appKey: appKey,
                                                               learningAllowed: allowed)
        }
        return input
    }

    /// Dictation's view of the field it starts in: the app's settings, and the screen text near it
    /// (nil unless screen awareness is on and allowed there).
    /// What dictation may do in the app in front: from the field's policy, or with no readable field,
    /// from why focus was blocked and the frontmost app's policy.
    /// The focus engine's latest word on the app in front, for the clipboard's source check.
    func clipboardFocus(frontmost: String?) -> ClipboardSource.Focus? {
        if let context = latestContext?.context {
            // A read with suggestions off (autocorrect only) is not a read for the clipboard's sake.
            if !settings().enabled { return ClipboardSource.Focus(bundleID: context.app.bundleID, blockReason: .globallyDisabled) }
            return ClipboardSource.Focus(bundleID: context.app.bundleID, urlHost: context.urlHost)
        }
        // Secure Input can block before the app is known: it's the one in front.
        guard let block = latestBlock, let bundleID = block.app?.bundleID ?? frontmost else { return nil }
        return ClipboardSource.Focus(bundleID: bundleID, blockReason: block.reason)
    }

    /// Focus is on something dictation can type into: a read field, or one blocked for another
    /// reason than not being editable (an app Hunch is off in, a selection, marked text…).
    var focusIsOnTextField: Bool {
        if latestContext != nil { return true }
        guard let block = latestBlock else { return false }
        return block.reason != .notEditable
    }

    func dictationPrivacy(frontmostBundleID: String?) -> DictationPrivacy {
        if let context = latestContext?.context {
            return DictationPrivacy.decide(policy: policy(bundleID: context.app.bundleID, urlHost: context.urlHost),
                                           blockReason: settings().enabled ? nil : .globallyDisabled)
        }
        let bundleID = latestBlock?.app?.bundleID ?? frontmostBundleID
        let appPolicy = bundleID.map { policy(bundleID: $0, urlHost: nil) } ?? .default
        return DictationPrivacy.decide(policy: appPolicy, blockReason: latestBlock?.reason)
    }

    /// The app's settings for dictation that started with no readable field (by bundle ID only).
    func dictationPolicy(bundleID: String) -> AppPolicy {
        policy(bundleID: bundleID, urlHost: nil)
    }

    func dictationReference(context: TextContext) -> (policy: AppPolicy, screen: String?) {
        let policy = policy(bundleID: context.app.bundleID, urlHost: context.urlHost)
        return (policy, screen?.excerptText(for: context.field, policy: policy))
    }

    /// A shell prompt's request: the screen lines and the prompt line as the text, one line out,
    /// none of the writer's prose settings (instructions, About me, screen OCR, clipboard).
    private func makeShellRequest(id: RequestID, context: TextContext) -> CompletionRequest {
        var decode = settings().decode
        decode.wordStartMinFirstLogProb = settings().suggestionConfidence.wordStartMinFirstLogProb
        decode.maxWords = 24
        decode.minWords = 1
        decode.allowNewline = false
        let input = PromptInput(
            before: context.before, after: "", surface: .shell,
            // The history file is cached until it changes, so this rarely touches the disk.
            appInstructions: Self.shellInstructions(recent: shellHistory.current().recent(Self.shellRecentCommands)),
            preferredLanguages: Locale.preferredLanguages,
            maxWords: decode.maxWords, allowNewlines: false,
            appName: context.app.localizedName,
            quoteStyle: .straight)
        return CompletionRequest(id: id, context: context, input: input, decode: decode)
    }
}
