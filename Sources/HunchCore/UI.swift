import CoreGraphics
import Foundation

// MARK: Focus

public enum PauseReason: Hashable, Sendable { case ownPanelOpen, userToggle, permissionsMissing, writePanelOpen }

public enum FocusEvent: Sendable {
    case context(TextContext, CaretGeometry)
    case blocked(BlockReason, AppIdentity?)
    case focusLost
}

public struct ContextLimits: Sendable, Equatable {
    public var beforeChars: Int
    public var afterChars: Int
    public init(beforeChars: Int = 4000, afterChars: Int = 400) {
        self.beforeChars = beforeChars
        self.afterChars = afterChars
    }
}

// MARK: Input

public struct KeyChord: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    /// Masked CGEventFlags (command/option/control/shift only).
    public var modifiers: UInt64
    public init(keyCode: UInt16, modifiers: UInt64 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    // CGEventFlags masks: shift 0x20000, control 0x40000, option 0x80000, command 0x100000.
    public static let tab = KeyChord(keyCode: 48)
    public static let optionTab = KeyChord(keyCode: 48, modifiers: 0x80000)
    public static let controlTab = KeyChord(keyCode: 48, modifiers: 0x40000)
    public static let optionShiftTab = KeyChord(keyCode: 48, modifiers: 0x80000 | 0x20000)
    public static let escape = KeyChord(keyCode: 53)
    public static let optionDown = KeyChord(keyCode: 125, modifiers: 0x80000)
    public static let optionUp = KeyChord(keyCode: 126, modifiers: 0x80000)
    public static let optionShiftRight = KeyChord(keyCode: 124, modifiers: 0x80000 | 0x20000)
    public static let optionShiftLeft = KeyChord(keyCode: 123, modifiers: 0x80000 | 0x20000)
    public static let rightArrow = KeyChord(keyCode: 124)
    public static let optionRight = KeyChord(keyCode: 124, modifiers: 0x80000)
    public static let controlShiftZ = KeyChord(keyCode: 6, modifiers: 0x40000 | 0x20000)
}

/// Decision 4 (corrected 2026-10-11 from the user's competitor screenshots): Tab = next word,
/// Option+Tab = whole suggestion. Plus competitor-parity shortcuts (design §13).
///
/// Unset keys are saved as JSON null, so clearing one in Settings survives a reload (a missing key
/// takes the default instead).
///
/// Retired (2026-11-26): Suggest now, Pause in this app, Turn Hunch on/off, next/previous
/// alternative suggestion, Fix a missed word and Undo a fix (Backspace undoes fixes now). They are
/// unset by default, have no Settings row, and saved keys are ignored on load, so nothing reaches them.
public struct AcceptBindings: Codable, Sendable, Equatable {
    public var word: KeyChord?
    public var full: KeyChord?
    /// Manually request a suggestion when typing wasn't detected.
    public var forceActivate: KeyChord?
    /// Toggle completions in the frontmost app for a few minutes. Unset by default (Shift+Option+Tab
    /// went to write for me).
    public var toggleCurrentApp: KeyChord?
    /// Toggle completions everywhere until pressed again. Unset by default.
    public var toggleGlobal: KeyChord?
    /// Cycle through alternative suggestions while one is visible (M4). Consumed only then.
    public var nextAlternative: KeyChord?
    public var previousAlternative: KeyChord?
    /// Write for me: turn the instruction at the caret (or the selection) into a draft, or polish it.
    public var writeForMe: KeyChord?
    /// Autocorrect catch-up: apply the newest fix that was shown and typed past, in place, leaving
    /// the caret where it is. Unset by default; while unset the feature is off. Consumed only while
    /// such a fix is waiting, so otherwise the key reaches the app.
    public var catchUp: KeyChord?
    /// Autocorrect: put back what was typed for the newest fix still in the field; again, the one
    /// before. Control+Shift+Z by default; consumed only while such a fix is waiting (until focus
    /// leaves the field), so otherwise the key reaches the app.
    public var revertFix: KeyChord?
    /// Suggestion styles (Personalization → About me): redo the visible suggestion with the next
    /// (Option+Shift+Right) or previous (Option+Shift+Left) style in the ring. Consumed only while a ghost is visible and at least
    /// one style is on.
    public var styleNext: KeyChord?
    public var stylePrevious: KeyChord?
    public init(word: KeyChord? = .tab, full: KeyChord? = .optionTab, forceActivate: KeyChord? = nil,
                toggleCurrentApp: KeyChord? = nil, toggleGlobal: KeyChord? = nil,
                nextAlternative: KeyChord? = nil, previousAlternative: KeyChord? = nil,
                writeForMe: KeyChord? = .optionShiftTab, catchUp: KeyChord? = nil,
                revertFix: KeyChord? = nil,
                styleNext: KeyChord? = .optionShiftRight, stylePrevious: KeyChord? = .optionShiftLeft) {
        self.styleNext = styleNext
        self.stylePrevious = stylePrevious
        self.catchUp = catchUp
        self.revertFix = revertFix
        self.nextAlternative = nextAlternative
        self.previousAlternative = previousAlternative
        self.word = word
        self.full = full
        self.forceActivate = forceActivate
        self.toggleCurrentApp = toggleCurrentApp
        self.toggleGlobal = toggleGlobal
        self.writeForMe = writeForMe
    }

    private enum CodingKeys: String, CodingKey {
        case word, full, forceActivate, toggleCurrentApp, toggleGlobal, nextAlternative, previousAlternative, writeForMe, catchUp, revertFix,
             styleNext, stylePrevious
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AcceptBindings()
        func key(_ k: CodingKeys, _ fallback: KeyChord?) throws -> KeyChord? {
            guard c.contains(k) else { return fallback }
            return try c.decodeIfPresent(KeyChord.self, forKey: k)  // null = unset
        }
        // The retired shortcuts stay unset whatever was saved.
        self.init(word: try key(.word, d.word), full: try key(.full, d.full),
                  forceActivate: nil, toggleCurrentApp: nil, toggleGlobal: nil,
                  nextAlternative: nil, previousAlternative: nil,
                  writeForMe: try key(.writeForMe, d.writeForMe),
                  catchUp: nil, revertFix: nil,
                  styleNext: try key(.styleNext, d.styleNext),
                  stylePrevious: try key(.stylePrevious, d.stylePrevious))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(word, forKey: .word)
        try c.encode(full, forKey: .full)
        try c.encode(forceActivate, forKey: .forceActivate)
        try c.encode(toggleCurrentApp, forKey: .toggleCurrentApp)
        try c.encode(toggleGlobal, forKey: .toggleGlobal)
        try c.encode(nextAlternative, forKey: .nextAlternative)
        try c.encode(previousAlternative, forKey: .previousAlternative)
        try c.encode(writeForMe, forKey: .writeForMe)
        try c.encode(catchUp, forKey: .catchUp)
        try c.encode(revertFix, forKey: .revertFix)
        try c.encode(styleNext, forKey: .styleNext)
        try c.encode(stylePrevious, forKey: .stylePrevious)
    }
}

/// What Escape does while a suggestion is visible. The first press is consumed and clears the
/// suggestion; a second press goes to the app. With no suggestion visible, Escape is untouched.
public enum EscapeBehavior: String, Codable, Sendable, CaseIterable {
    case dismiss, dismissAndPauseBriefly
    /// Dismiss, and no suggestions in this app until another app comes to the front.
    case dismissUntilAppSwitch
}

/// How the suggested-replies bubble lays out its replies (Settings → Suggestions).
public enum SuggestedRepliesLayout: String, Codable, Sendable, CaseIterable {
    /// One panel above the caret, replies stacked top to bottom.
    case verticalStack
    /// Separate one-line chips side by side above the text box.
    case rowAboveField
    /// Outlined one-line chips starting at the caret, wrapping onto the next line inside the box.
    case inlineAtCaret
}

public enum AcceptAction: Sendable, Equatable { case word, full }
public enum TapVerdict: Sendable, Equatable { case consume(AcceptAction), passThrough }

public struct ArbiterSnapshot: Sendable, Equatable {
    public var field: FieldID
    public var hasGhost: Bool
    /// mach_absolute_time ticks at publish.
    public var publishedAt: UInt64
    public var tabAllowed: Bool
    /// No ghost on screen, but the user just accepted the last word and the next suggestion is on
    /// its way: accept chords are still owned (and queued by the session) for a short window
    /// instead of falling through to the app. Escape is not owned.
    public var holdOnly: Bool
    /// Option+Down/Up cycle alternatives only when true; otherwise those keys pass to the app
    /// (replacement ghosts, or an engine/fetch that has no alternatives for this suggestion).
    public var alternativesAvailable: Bool
    /// The style keys have something to do here (a style is on); otherwise they reach the app.
    public var styleNextAvailable: Bool = false
    public var stylePreviousAvailable: Bool = false
    /// At a shell prompt: Right arrow accepts the next word and Option+Right the whole suggestion
    /// (Option+Tab too); Tab stays with the shell.
    public var shellKeys: Bool
    /// This app's or site's accept keys (`AppPolicy.acceptWordKey`, `acceptFullKey`).
    public var wordKey: AcceptKey
    public var fullKey: AcceptKey
    public init(field: FieldID, hasGhost: Bool, publishedAt: UInt64, tabAllowed: Bool, holdOnly: Bool = false,
                alternativesAvailable: Bool = true, shellKeys: Bool = false,
                wordKey: AcceptKey = .shortcuts, fullKey: AcceptKey = .shortcuts) {
        self.wordKey = wordKey
        self.fullKey = fullKey
        self.shellKeys = shellKeys
        self.alternativesAvailable = alternativesAvailable
        self.field = field
        self.hasGhost = hasGhost
        self.publishedAt = publishedAt
        self.tabAllowed = tabAllowed
        self.holdOnly = holdOnly
    }
}

/// Lock-protected; callable synchronously from the event-tap thread.
public protocol AcceptanceArbitrating: Sendable {
    func publish(_ snapshot: ArbiterSnapshot?)
    func verdict(for chord: KeyChord, now: UInt64) -> TapVerdict
}

public enum TypingEvent: Sendable, Equatable {
    case keyDown(KeyChord, isCharacter: Bool)
    case mouseDown
    case accept(AcceptAction)
    case secureInputChanged(Bool)
}

public protocol KeyboardMonitoring: AnyObject {
    func start(arbiter: any AcceptanceArbitrating) throws
    func stop()
    func setAcceptTapEnabled(_ on: Bool)
    func events() -> AsyncStream<TypingEvent>
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted
    case fellBack(InsertionMode)
    case failed(String)
}

@MainActor
public protocol TextInserting {
    func insert(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int) async -> InsertionOutcome
    /// Deletes `count` characters before the caret (Backspace presses), then inserts `text`. Used
    /// to replace a typed trigger such as ":smile" with its emoji.
    func replace(deletingBackward count: Int, with text: String, into app: AppIdentity, mode: InsertionMode,
                 chunkSize: Int) async -> InsertionOutcome
    /// Presses and releases one key (no characters), e.g. Escape to cancel an input-method
    /// composition. False when it could not be posted (secure input, app no longer frontmost).
    func pressKey(_ keyCode: UInt16, into app: AppIdentity) -> Bool
    /// `insert` with the app's insertion quirks applied (see `InsertionWorkarounds`).
    func insert(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                workarounds: InsertionWorkarounds) async -> InsertionOutcome
    /// `replace` with the app's insertion quirks applied to the inserted text.
    func replace(deletingBackward count: Int, with text: String, into app: AppIdentity, mode: InsertionMode,
                 chunkSize: Int, workarounds: InsertionWorkarounds) async -> InsertionOutcome
    /// `insert` for a draft whose arrival the caller checks: a paste leaves `text` on the clipboard
    /// until `releaseClipboard(restore:)`, instead of restoring the user's contents after a fixed delay
    /// that a slow host can outlast (it would then paste the old contents, or nothing).
    func insertHoldingClipboard(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                                workarounds: InsertionWorkarounds) async -> InsertionOutcome
    /// Ends `insertHoldingClipboard`: puts the user's contents back (if the clipboard still holds the
    /// text), or with `restore` false leaves the text there for the user to paste.
    func releaseClipboard(restore: Bool)
}

public extension TextInserting {
    /// Unsupported by default.
    func pressKey(_ keyCode: UInt16, into app: AppIdentity) -> Bool { false }

    func insertHoldingClipboard(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                                workarounds: InsertionWorkarounds) async -> InsertionOutcome {
        await insert(text, into: app, mode: mode, chunkSize: chunkSize, workarounds: workarounds)
    }

    func releaseClipboard(restore: Bool) {}

    func replace(deletingBackward count: Int, with text: String, into app: AppIdentity, mode: InsertionMode,
                 chunkSize: Int) async -> InsertionOutcome {
        .failed("replacing text is not supported")
    }

    /// Ignores the workarounds by default, so inserters that don't support them insert as before.
    func insert(_ text: String, into app: AppIdentity, mode: InsertionMode, chunkSize: Int,
                workarounds: InsertionWorkarounds) async -> InsertionOutcome {
        await insert(text, into: app, mode: mode, chunkSize: chunkSize)
    }

    func replace(deletingBackward count: Int, with text: String, into app: AppIdentity, mode: InsertionMode,
                 chunkSize: Int, workarounds: InsertionWorkarounds) async -> InsertionOutcome {
        await replace(deletingBackward: count, with: text, into: app, mode: mode, chunkSize: chunkSize)
    }
}

// MARK: Overlay

/// `mirror`: an opaque panel covers the caret's line and redraws its typed text with the ghost.
public enum GhostMode: Sendable, Equatable { case inline, card, mirror }

public struct GhostPresentation: Sendable, Equatable {
    public var text: String
    public var geometry: CaretGeometry
    public var mode: GhostMode
    /// Measured from the host's painted text (screen calibration): baseline above the caret rect's
    /// bottom, and the host's x-height, both in points. Nil until measured.
    public var measuredBaseline: CGFloat?
    /// The host's x-height read from its ink (points), nil until measured.
    public var measuredXHeight: CGFloat?
    /// x-height of the host's text drawn in each face the ghost could use, measured the same way,
    /// at `measuredAtSize` (`TextCalibration.faceXHeights`); for the alignment check.
    public var drawnXHeights: [String: CGFloat] = [:]
    public var measuredAtSize: CGFloat?
    /// Bundle ID of the host, for the alignment check's log.
    public var appID: String?
    /// Autocorrect: the host's text just before the caret to draw struck through (the misspelled
    /// word, plus anything typed after it). Nil for ordinary suggestions.
    public var struckText: String?
    /// Per-app manual rendering adjustments; the identity unless the app or site has some.
    public var tweaks: GhostTweaks
    /// Mirror mode only: the line to redraw under the ghost. Nil in the other modes.
    public var mirror: MirrorContent?
    public init(text: String, geometry: CaretGeometry, mode: GhostMode, measuredBaseline: CGFloat? = nil,
                measuredXHeight: CGFloat? = nil, struckText: String? = nil, tweaks: GhostTweaks = GhostTweaks(),
                mirror: MirrorContent? = nil) {
        self.tweaks = tweaks
        self.mirror = mirror
        self.struckText = struckText
        self.text = text
        self.geometry = geometry
        self.mode = mode
        self.measuredBaseline = measuredBaseline
        self.measuredXHeight = measuredXHeight
    }
}

/// Per-app manual nudges for the ghost, a fallback for hosts whose reported font size or baseline
/// stays wrong after automatic calibration. The default value changes nothing.
public struct GhostTweaks: Sendable, Equatable {
    /// Point size multiplier, applied after the learned width scale.
    public var fontSizeFactor: CGFloat
    /// Baseline shift in points, positive = up (AppKit coordinates). Inline mode only.
    public var verticalOffset: CGFloat
    /// Draw in the default grey, ignoring the host's text color.
    public var greyForced: Bool
    /// The app's or category's own look; nil uses Settings → Appearance.
    public var appearance: AppearanceSettings?

    /// Accepted size multipliers; values outside are clamped.
    public static let factorRange: ClosedRange<CGFloat> = 0.5...2.0

    public init(fontSizeFactor: CGFloat = 1, verticalOffset: CGFloat = 0, greyForced: Bool = false,
                appearance: AppearanceSettings? = nil) {
        self.fontSizeFactor = fontSizeFactor
        self.verticalOffset = verticalOffset
        self.greyForced = greyForced
        self.appearance = appearance
    }

    /// From a resolved policy: the factor is clamped to `factorRange`; non-finite values (a
    /// hand-edited file) fall back to the identity.
    public init(_ policy: AppPolicy) {
        let factor = CGFloat(policy.fontSizeAdjustmentFactor)
        let offset = CGFloat(policy.verticalAlignmentOffset)
        self.init(fontSizeFactor: factor.isFinite ? min(max(factor, Self.factorRange.lowerBound), Self.factorRange.upperBound) : 1,
                  verticalOffset: offset.isFinite ? offset : 0,
                  greyForced: policy.greySuggestionColorEnabled, appearance: policy.appearance)
    }
}

/// What mirror mode redraws: the typed text of the caret's line, where it starts, and the field's
/// background behind it. Holds field text: never logged.
public struct MirrorContent: Sendable, Equatable {
    /// Text from the start of the caret's line to the caret.
    public var lineBefore: String
    /// AppKit global x of the line's first character.
    public var lineStartX: CGFloat
    /// The field's background behind the line, when known; otherwise the presenter derives one from
    /// the text color.
    public var backgroundColor: RGBAColor?
    public init(lineBefore: String, lineStartX: CGFloat, backgroundColor: RGBAColor? = nil) {
        self.lineBefore = lineBefore
        self.lineStartX = lineStartX
        self.backgroundColor = backgroundColor
    }
}

@MainActor
public protocol GhostPresenting {
    func present(_ presentation: GhostPresentation)
    func hide()
}

public protocol GhostModeChoosing: Sendable {
    func mode(for geometry: CaretGeometry, caretAtLineEnd: Bool, preference: OverlayPreference) -> GhostMode
    /// Mirror mode also needs the field's selection and marked-text state: a mirrored line would hide
    /// the host's selection highlight or composition underline.
    func mode(for geometry: CaretGeometry, caretAtLineEnd: Bool, preference: OverlayPreference,
              hasSelection: Bool, hasMarkedText: Bool) -> GhostMode
}

public extension GhostModeChoosing {
    /// Choosers that never mirror don't need the extra state.
    func mode(for geometry: CaretGeometry, caretAtLineEnd: Bool, preference: OverlayPreference,
              hasSelection: Bool, hasMarkedText: Bool) -> GhostMode {
        mode(for: geometry, caretAtLineEnd: caretAtLineEnd, preference: preference)
    }
}

// MARK: Settings

/// Completion length in words. Ranges match competitors' presets (design §13); `maxWords` is the
/// upper bound and `minWords` the point before which a sentence end doesn't stop generation.
public enum LengthPreset: String, Codable, Sendable, CaseIterable {
    case short, medium, long, veryLong, ultra
    public var minWords: Int {
        switch self {
        case .short: return 1
        case .medium: return 2
        case .long: return 4
        case .veryLong: return 7
        case .ultra: return 10
        }
    }
    public var maxWords: Int {
        switch self {
        case .short: return 2
        case .medium: return 4
        case .long: return 7
        case .veryLong: return 10
        case .ultra: return 15
        }
    }
    /// Whether the end of the model's turn is held until `minWords` (`DecodeConfig.holdEndBelowMinWords`).
    /// Only the two longest settings: shorter ones already end near their minimum.
    public var holdsEnd: Bool { self == .veryLong || self == .ultra }

    /// Token cap for the suggestion. The longer settings need more than the default 24: 15 words
    /// plus punctuation, or 45 CJK characters (3 per word), don't fit in 24 tokens.
    public var maxTokens: Int {
        switch self {
        case .short, .medium, .long: return 24
        case .veryLong: return 32
        case .ultra: return 48
        }
    }
}

/// Emoji suggestions (":" search and emoticons). Tones and genders are HunchEmoji raw values.
public struct EmojiSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var skinTone: String
    public var includeNeutral: Bool
    public var gender: String
    public init(enabled: Bool = true, skinTone: String = "none", includeNeutral: Bool = false, gender: String = "neutral") {
        self.enabled = enabled
        self.skinTone = skinTone
        self.includeNeutral = includeNeutral
        self.gender = gender
    }
}

/// "Learn from my writing" (design decision 7): opt-in, local-only, encrypted.
public struct LearningSettings: Codable, Sendable, Equatable {
    /// Record outcomes (accepted, kept, corrected, typed over) and learn vocabulary.
    public var enabled: Bool
    /// "Personalize word choice" strength: 0 = off … 3 = max (logit units at full weight).
    public var strength: Float
    /// Keep a few of the user's sentences and show the most relevant two to the model. Only has
    /// an effect while `enabled` is true.
    public var styleExamplesEnabled: Bool
    public init(enabled: Bool = false, strength: Float = 1.5, styleExamplesEnabled: Bool = true) {
        self.enabled = enabled
        self.strength = strength
        self.styleExamplesEnabled = styleExamplesEnabled
    }

    private enum CodingKeys: String, CodingKey { case enabled, strength, styleExamplesEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? 1.5
        styleExamplesEnabled = try c.decodeIfPresent(Bool.self, forKey: .styleExamplesEnabled) ?? true
    }
}

/// A model file added in Settings → Models ("Add a model file…" or Hugging Face search), listed under
/// the category it was added from whatever the detector reads from it.
public struct AddedModel: Codable, Sendable, Equatable {
    /// An absolute path for a file kept where it is, outside the models folder; otherwise the path
    /// relative to the folder (its `ModelEntryID`).
    public var path: String
    /// The `ModelUse` raw value ("autocomplete", "writing", "speechToText").
    public var use: String
    public init(path: String, use: String) {
        self.path = path
        self.use = use
    }

    /// Kept outside the models folder (the folder scan doesn't find it).
    public var isOutsideFolder: Bool { path.hasPrefix("/") }
}

public struct HunchSettings: Codable, Sendable, Equatable {
    /// Global kill switch (the toggle-globally shortcut flips it).
    public var enabled: Bool
    /// Default for apps without a user override; per-app settings can enable or disable either way.
    public var completionsEnabledByDefault: Bool
    public var escapeBehavior: EscapeBehavior
    /// Autocomplete's source: the local model or `endpoint`.
    public var engine: EngineKind
    public var modelsFolderPath: String?
    public var activeModel: ModelEntryID?
    /// The instruct model Write for me uses (Settings → Models → Writing Model); nil picks one.
    public var writeModel: ModelEntryID?
    /// "Use a separate writing model for Write for Me". Off (the default), Write for me uses the
    /// Language Model (`activeModel` / `endpoint`), which is already loaded for suggestions.
    public var useWritingModel: Bool
    /// Set once on files from before the Language Model (autocomplete on instruct models): the next
    /// time the folder is available, a base `activeModel` switches to an instruct model if the
    /// folder has one, then this clears. Never set for new installs.
    public var instructSwitchPending: Bool
    /// Write for me's source when `useWritingModel` is on: the writing model or `writeEndpoint`.
    public var writeEngine: EngineKind
    public var writeEndpoint: EndpointConfig?
    /// Speech to text's source and endpoint (unused: dictation runs whisper.cpp on this Mac).
    public var speechEngine: EngineKind
    public var speechEndpoint: EndpointConfig?
    /// Model files added by hand or from Hugging Face search, with their category.
    public var addedModels: [AddedModel]
    public var length: LengthPreset
    public var bindings: AcceptBindings
    public var wordUnits: WordUnitOptions
    /// Decision 7 (revised 2026-10-11): ONE user-editable "Custom instructions" box, like competitors':
    /// who the writer is, languages, preferred style. Sent as `PromptInput.globalInstructions`.
    public var customInstructions: String
    /// Model file name → framer id.
    public var framerOverrides: [String: String]
    public var runtime: RuntimeOptions
    public var decode: DecodeConfig
    /// Autocomplete's endpoint.
    public var endpoint: EndpointConfig?
    /// Every diagnostic log at once (Privacy & Data → Diagnostics): perf and prompt logs, the
    /// alignment check (`AlignmentCheckLog`), eval captures (`EvalCaptureRecorder`), typing samples
    /// (`TypingSampleLog`) and suggestion outcomes (`OutcomeLog`), and the dictation log. Off by default.
    public var debugLogging: Bool
    /// Opt-in screen-aware suggestions (needs Screen Recording permission). Off by default.
    public var screenContextEnabled: Bool
    /// Most prompt tokens screen text may take (Settings slider, `screenContextTokenRange`).
    public var screenContextTokenLimit: Int
    public static let screenContextTokenRange: ClosedRange<Int> = 300...3500
    /// Global default for completing inside existing text (mid-line); per-app patches override it.
    /// Off by default (design §13).
    public var midLineByDefault: Bool
    /// Hunch completes what you're writing; it doesn't propose what to say. No suggestion
    /// until the current line has at least this many words (0 = suggest on empty lines too).
    public var minWordsBeforeSuggesting: Int
    /// How long typing must pause before the model is asked for a new suggestion, in ms (0 = ask
    /// right away). Keys typed within this time of each other start no generation (a suggestion
    /// that still matches what's typed is kept without one): short waits save GPU while typing
    /// quickly; long ones (500, 1000) suggest only when the user stops to think.
    public var suggestionPauseMs: Int
    /// The Settings slider's stops, in ms.
    public static let suggestionPauseStops: [Int] = [0, 5, 10, 50, 100, 500, 1000]
    /// Settings → General → Suggestions: "Quick replies". In an empty field, as soon as it is
    /// idle (`suggestedRepliesDelayMs`), a bubble above the caret offers up to three ways to
    /// answer the message on screen (Tab picks, Return or a click inserts). Needs suggestions on, screen
    /// context and an instruct model. Off by default.
    public var suggestedRepliesEnabled: Bool = false
    /// How long an empty field must stay idle before suggested replies are asked for, in ms: no wait
    /// (tuned with a slider, which is gone).
    public static let suggestedRepliesDelayMs = 0
    /// How the replies are laid out (the user's choice).
    public var suggestedRepliesLayout: SuggestedRepliesLayout = .verticalStack
    /// Most prompt tokens the screen text may take in a suggested-replies prompt (newest kept). Less
    /// than suggestions get: a reply needs the newest message, and less old text keeps it on topic.
    public static let suggestedRepliesScreenTokens = 1000
    public var learning: LearningSettings
    /// Opt-in clipboard awareness: recently copied text informs suggestions. Off by default.
    public var clipboardContextEnabled: Bool
    public var emoji: EmojiSettings
    /// Include the window title (e.g. a chat or email subject) in the prompt. Off by default; the
    /// app name and website domain are always included.
    public var windowTitleContextEnabled: Bool
    /// Show a fix for a misspelled last word (struck through + correction); Tab applies it.
    public var autocorrectEnabled: Bool
    /// Autocorrect: fix a misspelled word as soon as it is finished instead of showing the fix and
    /// waiting for Tab. Backspace straight after restores the word. Off by default.
    public var autocorrectFixAutomatically: Bool = false
    /// "Fix punctuation": missing apostrophes, spaces around punctuation, doubled spaces. Needs
    /// autocorrect; apps can turn it off (off in Chats). On by default.
    public var fixPunctuation: Bool = true
    /// Autocorrect also fixes capitals (THe → The, tHIS → This, i → I, monday → Monday, iphone →
    /// iPhone). On by default; apps and categories can turn it off (off in Chats).
    public var autocorrectCapitalization: Bool = true
    /// "Fix commonly confused words" (with Fix automatically): the model checks their/there/they're,
    /// your/you're, its/it's, then/than and a few more pairs, and fixes one only when the sentence
    /// clearly calls for the other. Apps can turn it off (off in Chats). On by default.
    public var autocorrectFixConfusedWords: Bool = true
    /// Autocorrect Strength: Light (spell checker only, never the model), Balanced (default), Strong
    /// (Balanced plus the whole-field rewrite at pauses). Apps, sites and categories can override it.
    public var autocorrectStrength: AutocorrectStrength = .balanced
    /// Strong: seconds without typing before the rewrite rereads the paragraph (0.5–3; a sentence end
    /// starts one at once).
    public var autocorrectRewritePause: Double = 1.0
    public static let rewritePauseRange: ClosedRange<Double> = 0.5...3
    /// Test setting: after an automatic fix, the first Backspace deletes as usual and a second one
    /// within this many ms undoes the fix (keeping the first deletion). 0: the first Backspace undoes.
    public var autocorrectUndoDoubleTapMs: Int = 300
    public static let undoDoubleTapRange: ClosedRange<Int> = 0...800
    /// "Allow chat shorthand" (u, thx, gonna stay as typed): the global gate for the per-app switch,
    /// which is on in Chats. Off: shorthand is corrected everywhere. On by default.
    public var autocorrectLeaveChatShorthand: Bool = true
    /// "Use my personal information": tell the model who the user is: their macOS account name and
    /// the "About me" text. On by default; apps and sites can turn it off. Stays on the Mac with the
    /// local model.
    public var usePersonalInfo: Bool
    /// "About me": who the user is (role, background), in their words. "How I write" is
    /// `customInstructions`.
    public var aboutMe: String
    /// Suggestion styles (Personalization → About me), in ring order: the style keys step through
    /// the enabled ones, starting from and returning to the app's own instructions.
    public var suggestionStyles: [SuggestionStyle] = SuggestionStyle.builtIns
    /// Show the first words of a suggestion while the rest is still written (they pass
    /// the same checks); the finished suggestion then appears whole and replaces, shortens or hides them.
    public var showWhileWriting: Bool
    /// The `OnboardingFlow.currentVersion` of the welcome tour the user finished; nil = never
    /// finished, so the tour opens at launch.
    public var onboardingCompletedVersion: Int?
    /// Dictation: shortcut, speech model and cleanup (General, Shortcuts, Personalization, Model).
    public var dictation: DictationSettings
    /// "Write for me": saved custom shapes and edits to the presets' wording (Settings → Apps).
    public var writeShapes: WriteShapeLibrary
    /// Dynamic Power Mode (Settings → Performance & Models): picks smaller Language and speech
    /// models on low battery or under load. See `DynamicPower`.
    public var dynamicPower: DynamicPowerSettings
    /// Settings → Appearance: suggestion pop-in animation, color and strength.
    public var appearance: AppearanceSettings
    /// Settings → Appearance → Icons: the menu bar glyph.
    public var menuBarIcon: MenuBarIconChoice = .cat
    /// Settings → Appearance → Icons: the app icon, shown in Hunch's windows and set on the app in
    /// Finder (re-applied at launch, since an update replaces the bundle).
    public var appIcon: AppIconChoice = .standard
    /// Settings → Appearance: dictated text pops in with the suggestions' effect before it is pasted.
    public var effectsForDictation: Bool = true
    /// Settings → General: the word-start confidence floor (`SuggestionConfidence`). Files from
    /// before it get the default, so the earlier saved -1.0 moves to -1.5.
    public var suggestionConfidence: SuggestionConfidence = .standard
    /// Settings → Appearance: Write for me's draft pops in with the suggestions' effect as it streams.
    public var effectsForWriteForMe: Bool = true
    /// Settings → Appearance: quick replies pop in with the suggestions' effect.
    public var effectsForQuickReplies: Bool = true
    /// EXPERIMENTAL (Settings → General → Experimental): speak a Write for me instruction with
    /// `voiceInstructionShortcut`. Off by default.
    public var experimentalVoiceInstructions: Bool = false
    /// The voice instruction shortcut (Settings → Shortcuts); only registered while
    /// `experimentalVoiceInstructions` is on.
    public var voiceInstruction = VoiceInstructionSettings()

    public init(enabled: Bool = true, completionsEnabledByDefault: Bool = true,
                escapeBehavior: EscapeBehavior = .dismissAndPauseBriefly, engine: EngineKind = .local, modelsFolderPath: String? = nil,
                activeModel: ModelEntryID? = nil, length: LengthPreset = .medium, bindings: AcceptBindings = AcceptBindings(),
                wordUnits: WordUnitOptions = WordUnitOptions(), customInstructions: String = "",
                framerOverrides: [String: String] = [:], runtime: RuntimeOptions = RuntimeOptions(),
                decode: DecodeConfig = DecodeConfig(), endpoint: EndpointConfig? = nil, debugLogging: Bool = false,
                screenContextEnabled: Bool = false, screenContextTokenLimit: Int = 3500, midLineByDefault: Bool = false,
                minWordsBeforeSuggesting: Int = 2, suggestionPauseMs: Int = 0,
                learning: LearningSettings = LearningSettings(),
                clipboardContextEnabled: Bool = false, emoji: EmojiSettings = EmojiSettings(),
                windowTitleContextEnabled: Bool = false, autocorrectEnabled: Bool = true,
                usePersonalInfo: Bool = true, aboutMe: String = "", showWhileWriting: Bool = true,
                writeModel: ModelEntryID? = nil, useWritingModel: Bool = false, instructSwitchPending: Bool = false, writeEngine: EngineKind = .local,
                writeEndpoint: EndpointConfig? = nil, speechEngine: EngineKind = .local,
                speechEndpoint: EndpointConfig? = nil, addedModels: [AddedModel] = [],
                onboardingCompletedVersion: Int? = nil, dictation: DictationSettings = DictationSettings(),
                writeShapes: WriteShapeLibrary = WriteShapeLibrary(),
                dynamicPower: DynamicPowerSettings = DynamicPowerSettings(),
                appearance: AppearanceSettings = AppearanceSettings()) {
        self.appearance = appearance
        self.writeShapes = writeShapes
        self.dynamicPower = dynamicPower
        self.dictation = dictation
        self.addedModels = addedModels
        self.writeEngine = writeEngine
        self.writeEndpoint = writeEndpoint
        self.speechEngine = speechEngine
        self.speechEndpoint = speechEndpoint
        self.writeModel = writeModel
        self.useWritingModel = useWritingModel
        self.instructSwitchPending = instructSwitchPending
        self.showWhileWriting = showWhileWriting
        self.usePersonalInfo = usePersonalInfo
        self.aboutMe = aboutMe
        self.enabled = enabled
        self.completionsEnabledByDefault = completionsEnabledByDefault
        self.escapeBehavior = escapeBehavior
        self.engine = engine
        self.modelsFolderPath = modelsFolderPath
        self.activeModel = activeModel
        self.length = length
        self.bindings = bindings
        self.wordUnits = wordUnits
        self.customInstructions = customInstructions
        self.framerOverrides = framerOverrides
        self.runtime = runtime
        self.decode = decode
        self.endpoint = endpoint
        self.debugLogging = debugLogging
        self.screenContextEnabled = screenContextEnabled
        self.screenContextTokenLimit = screenContextTokenLimit
        self.midLineByDefault = midLineByDefault
        self.minWordsBeforeSuggesting = minWordsBeforeSuggesting
        self.suggestionPauseMs = suggestionPauseMs
        self.learning = learning
        self.clipboardContextEnabled = clipboardContextEnabled
        self.emoji = emoji
        self.windowTitleContextEnabled = windowTitleContextEnabled
        self.autocorrectEnabled = autocorrectEnabled
        self.onboardingCompletedVersion = onboardingCompletedVersion
    }
}

/// EXPERIMENTAL: the voice instruction shortcut. Hold or tap it like dictation's: speak an
/// instruction for the selection, a description of what to write, or a refinement in the open
/// Write for me panel.
public struct VoiceInstructionSettings: Codable, Sendable, Equatable {
    /// ⌥⌘` by default (dictation has ⌘⇧`). Saved as null when cleared, so it stays cleared.
    public var shortcut: KeyChord?

    public static let defaultShortcut = KeyChord(keyCode: 50, modifiers: 0x100000 | 0x80000)

    public init(shortcut: KeyChord? = VoiceInstructionSettings.defaultShortcut) {
        self.shortcut = shortcut
    }

    private enum CodingKeys: String, CodingKey { case shortcut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = c.contains(.shortcut) ? try c.decodeIfPresent(KeyChord.self, forKey: .shortcut)
                                         : Self.defaultShortcut
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shortcut, forKey: .shortcut)
    }
}

public protocol SettingsStoring: Sendable {
    func current() -> HunchSettings
    func update(_ mutate: @Sendable (inout HunchSettings) -> Void) throws
    func changes() -> AsyncStream<HunchSettings>
}
