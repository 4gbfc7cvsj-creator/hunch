import Foundation

// Dictation: hold or tap a shortcut, speak, and the transcript (cleaned up by the language model
// Write for me uses) goes in at the caret. Speech to text is whisper.cpp (HunchWhisper).

/// How much the cleanup changes. Every preset drops filler, keeps only the corrected words of a
/// self-correction and turns spoken punctuation into marks; the presets differ above that.
public enum DictationPreset: String, Codable, Sendable, CaseIterable {
    /// Punctuation, capitals, filler and stutters only; the wording stays as spoken.
    case light
    /// Light, plus grammar and run-on sentences.
    case standard
    /// Standard, plus clearer phrasing where it is awkward (same meaning, voice and facts).
    case polished
}

/// TESTING (remove when the Dictation settings get their real design, see TODO.md): one switch per
/// context source the cleanup prompt can get, to compare quality and speed.
public struct DictationContextToggles: Codable, Sendable, Equatable {
    /// Learned words (and words added by hand) as preferred spellings, for whisper and the cleanup.
    public var learnedWords: Bool
    /// Names and terms taken from the window title (an email subject, a document name).
    public var titleNames: Bool
    /// Names and terms taken from the text on screen (needs screen awareness on).
    public var screenNames: Bool
    /// The text right before the caret, so the cleanup fits where the words go.
    public var textBefore: Bool
    /// The kind of field (chat, email, code…) and the app's name.
    public var appType: Bool
    /// The languages the user writes in, and Traditional Chinese when that's what they type.
    public var languages: Bool
    /// A trimmed "About me" (respects "Use my personal information").
    public var aboutMe: Bool

    public init(learnedWords: Bool = true, titleNames: Bool = true, screenNames: Bool = true, textBefore: Bool = true,
                appType: Bool = true, languages: Bool = true, aboutMe: Bool = false) {
        self.learnedWords = learnedWords
        self.titleNames = titleNames
        self.screenNames = screenNames
        self.textBefore = textBefore
        self.appType = appType
        self.languages = languages
        self.aboutMe = aboutMe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DictationContextToggles()
        learnedWords = try c.decodeIfPresent(Bool.self, forKey: .learnedWords) ?? d.learnedWords
        titleNames = try c.decodeIfPresent(Bool.self, forKey: .titleNames) ?? d.titleNames
        screenNames = try c.decodeIfPresent(Bool.self, forKey: .screenNames) ?? d.screenNames
        textBefore = try c.decodeIfPresent(Bool.self, forKey: .textBefore) ?? d.textBefore
        appType = try c.decodeIfPresent(Bool.self, forKey: .appType) ?? d.appType
        languages = try c.decodeIfPresent(Bool.self, forKey: .languages) ?? d.languages
        aboutMe = try c.decodeIfPresent(Bool.self, forKey: .aboutMe) ?? d.aboutMe
    }
}

public struct DictationSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Tap to start and again to stop, or hold to talk. ⌘⇧` by default.
    public var shortcut: KeyChord?
    /// The whisper model's file name in the models folder; nil uses the best one downloaded.
    public var speechModel: String?
    /// Run the transcript through the language model before inserting it.
    public var cleanupEnabled: Bool
    public var preset: DictationPreset
    public var context: DictationContextToggles
    /// TESTING (remove later, see TODO.md): show the timings in the pill after inserting.
    public var showTimings: Bool
    /// Watch dictated text for the user's fixes and learn them (the word, and a replace rule).
    public var learnFromFixes: Bool
    /// After dictated text goes in, the pill offers Boost for a few seconds: Write for me polishes
    /// the paragraphs the dictation touched.
    public var boostAfterDictation: Bool

    public static let defaultShortcut = KeyChord(keyCode: 50, modifiers: 0x100000 | 0x20000)

    public init(enabled: Bool = true, shortcut: KeyChord? = DictationSettings.defaultShortcut,
                speechModel: String? = nil, cleanupEnabled: Bool = true, preset: DictationPreset = .standard,
                context: DictationContextToggles = DictationContextToggles(), showTimings: Bool = true,
                learnFromFixes: Bool = true, boostAfterDictation: Bool = true) {
        self.enabled = enabled
        self.shortcut = shortcut
        self.speechModel = speechModel
        self.cleanupEnabled = cleanupEnabled
        self.preset = preset
        self.context = context
        self.showTimings = showTimings
        self.learnFromFixes = learnFromFixes
        self.boostAfterDictation = boostAfterDictation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DictationSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        // Saved as null when cleared, so a cleared shortcut stays cleared.
        shortcut = c.contains(.shortcut) ? try c.decodeIfPresent(KeyChord.self, forKey: .shortcut) : d.shortcut
        speechModel = try c.decodeIfPresent(String.self, forKey: .speechModel)
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? d.cleanupEnabled
        preset = (try? c.decodeIfPresent(DictationPreset.self, forKey: .preset)) ?? d.preset
        context = (try? c.decodeIfPresent(DictationContextToggles.self, forKey: .context)) ?? d.context
        showTimings = try c.decodeIfPresent(Bool.self, forKey: .showTimings) ?? d.showTimings
        learnFromFixes = try c.decodeIfPresent(Bool.self, forKey: .learnFromFixes) ?? d.learnFromFixes
        boostAfterDictation = try c.decodeIfPresent(Bool.self, forKey: .boostAfterDictation) ?? d.boostAfterDictation
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(shortcut, forKey: .shortcut)
        try c.encodeIfPresent(speechModel, forKey: .speechModel)
        try c.encode(cleanupEnabled, forKey: .cleanupEnabled)
        try c.encode(preset, forKey: .preset)
        try c.encode(context, forKey: .context)
        try c.encode(showTimings, forKey: .showTimings)
        try c.encode(learnFromFixes, forKey: .learnFromFixes)
        try c.encode(boostAfterDictation, forKey: .boostAfterDictation)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, shortcut, speechModel, cleanupEnabled, preset, context, showTimings, learnFromFixes,
             boostAfterDictation
    }
}

/// What the cleanup prompt gets besides the transcript. Everything is reference: it helps spell
/// names and fit the text to where it goes, and none of it may end up in the output.
public struct DictationContext: Sendable, Equatable {
    /// Learned words and words added by hand, most useful first.
    public var spellings: [String]
    /// Names and terms from the window title.
    public var titleNames: [String]
    /// Names and terms from the text on screen.
    public var screenNames: [String]
    /// The field's text right before the caret (its end only).
    public var textBefore: String?
    public var surface: SurfaceKind?
    public var appName: String?
    /// Display names of the languages the user writes in ("English", "Chinese (Taiwan)").
    public var languages: [String]
    /// Write Chinese in Traditional characters.
    public var traditionalChinese: Bool
    public var aboutMe: String?

    public init(spellings: [String] = [], titleNames: [String] = [], screenNames: [String] = [],
                textBefore: String? = nil, surface: SurfaceKind? = nil, appName: String? = nil,
                languages: [String] = [], traditionalChinese: Bool = false, aboutMe: String? = nil) {
        self.spellings = spellings
        self.titleNames = titleNames
        self.screenNames = screenNames
        self.textBefore = textBefore
        self.surface = surface
        self.appName = appName
        self.languages = languages
        self.traditionalChinese = traditionalChinese
        self.aboutMe = aboutMe
    }
}

/// A dictation cleanup, carried in a `WriteRequest` so it runs on Write for me's writers.
public struct DictationCleanup: Sendable, Equatable {
    /// What speech to text heard.
    public var transcript: String
    public var preset: DictationPreset
    public var context: DictationContext
    /// Where the words go (resolved like Write for me's, never `adaptive`): it sets the layout,
    /// capitals and punctuation, never the content.
    public var shape: WriteShape

    public init(transcript: String, preset: DictationPreset, context: DictationContext,
                shape: WriteShape = .paragraph) {
        self.transcript = transcript
        self.preset = preset
        self.context = context
        self.shape = shape
    }
}

/// A fix learned from the user correcting dictated text in the field: speech to text heard
/// `heard`, the user wrote `written`. `written` also goes in the learned-words list; the rule
/// replaces `heard` in later transcripts before the cleanup.
public struct DictationFix: Codable, Sendable, Equatable, Identifiable {
    public var heard: String
    public var written: String
    /// Off: kept in the list but not applied.
    public var enabled: Bool
    /// How many times the user made this fix.
    public var count: Int
    public var lastFixed: Date
    /// App keys (bundle IDs or site hosts) the fix was made in, most recent first.
    public var apps: [String]

    /// The heard side, case-folded: one rule per mishearing.
    public var id: String { Self.key(heard) }

    public init(heard: String, written: String, enabled: Bool = true, count: Int = 1, lastFixed: Date = Date(),
                apps: [String] = []) {
        self.heard = heard
        self.written = written
        self.enabled = enabled
        self.count = count
        self.lastFixed = lastFixed
        self.apps = apps
    }

    public static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Tap-or-hold for the dictation shortcut. A press that is let go quickly is a tap: the first tap
/// starts recording and the next stops it. A press held past `holdThreshold` is push-to-talk:
/// recording stops when it is let go.
public struct DictationTrigger: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Pressed to start; tap or hold not known yet.
        case pressed(at: TimeInterval)
        /// Started by a tap; the next press stops it.
        case latched
        /// The stopping press is down (the stop happens on its release).
        case stopping
    }

    public enum Action: Sendable, Equatable { case none, start, stop }

    public static let holdThreshold: TimeInterval = 0.3
    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func keyDown(at time: TimeInterval) -> Action {
        switch phase {
        case .idle:
            phase = .pressed(at: time)
            return .start
        case .latched:
            phase = .stopping
            return .none
        case .pressed, .stopping:
            return .none  // key repeat
        }
    }

    public mutating func keyUp(at time: TimeInterval) -> Action {
        switch phase {
        case .pressed(let start):
            if time - start < Self.holdThreshold {
                phase = .latched
                return .none
            }
            phase = .idle
            return .stop
        case .stopping:
            phase = .idle
            return .stop
        case .idle, .latched:
            return .none
        }
    }

    /// Recording ended some other way (Esc, an error, the pipeline finished).
    public mutating func reset() { phase = .idle }
}

/// What dictation learns when the user fixes a word it dictated.
public struct DictationLearning: Sendable, Equatable {
    /// Keep the heard→written fix for later dictations (dictation's own store).
    public var rules: Bool
    /// Also add the word to the learned words that suggestions use.
    public var words: Bool

    /// `learnFromFixes` is dictation's switch, `learnFromWriting` the global "Learn from my writing"
    /// one (learned words belong to it). Code buffers and apps where learning is off learn nothing.
    public static func decide(learnFromFixes: Bool, learnFromWriting: Bool, appAllowsLearning: Bool,
                              surface: SurfaceKind?, keepNothing: Bool) -> DictationLearning {
        let allowed = learnFromFixes && appAllowsLearning && surface != .code && !keepNothing
        return DictationLearning(rules: allowed, words: allowed && learnFromWriting)
    }
}

/// What dictation may do where it starts, from the app's policy and why focus was blocked there.
public enum DictationPrivacy: Sendable, Equatable {
    /// Password and secure fields, secure-excluded apps: no recording at all.
    case refuse
    /// Hunch is off or doesn't learn here: dictate, but log, learn and read nothing.
    case keepNothing
    case normal

    public static func decide(policy: AppPolicy, blockReason: BlockReason?) -> DictationPrivacy {
        switch blockReason {
        case .secureEventInput, .secureExcludedApp, .secureRole, .sensitiveMarker, .protectedContent:
            return .refuse
        default:
            break
        }
        if policy.secureExcluded { return .refuse }
        switch blockReason {
        case .globallyDisabled, .appDisabled, .trackingPaused:
            return .keepNothing
        default:
            break
        }
        if !policy.enabled || !policy.learningAllowed { return .keepNothing }
        return .normal
    }
}

/// Dictation that started without a readable field: Hunch is off in the app, a terminal that
/// shows no text, a selection. The text is pasted into the app in front without reading the field,
/// but only if, when the text is ready, nothing changed that makes that unsafe.
public enum DictationBlindInsert {
    /// - startPID: the app in front when dictation started; `frontPID`: the one in front now.
    /// - privacy: `DictationPrivacy` for where focus is now (a password field refuses).
    /// - onTextField: focus is still on something dictation can type into.
    public static func allowed(startPID: pid_t?, frontPID: pid_t?, secureInput: Bool,
                               privacy: DictationPrivacy, onTextField: Bool) -> Bool {
        guard let startPID, frontPID == startPID else { return false }
        return !secureInput && privacy != .refuse && onTextField
    }
}

/// Tags each dictation so work left from an earlier one (a cancelled transcription or cleanup that
/// is still winding down) can't clear the state of the one after it.
public struct DictationRuns: Sendable, Equatable {
    public private(set) var current = 0

    public init() {}

    /// A new dictation starts, or the current one is cancelled: earlier tags stop being current.
    @discardableResult
    public mutating func next() -> Int {
        current += 1
        return current
    }

    public func isCurrent(_ run: Int) -> Bool { run == current }
}
