import AppKit
import ApplicationServices
import Foundation
import HunchCore
import HunchEndpoint
import HunchEngine
import HunchHistory
import HunchInput
import HunchModels
import HunchOverlay
import HunchPolicy
import HunchPrompt
import HunchText
import HunchWhisper

/// Dictation: the shortcut starts the microphone, the next tap (or letting go of a held press)
/// stops it; whisper.cpp transcribes, the language model Write for me uses cleans the transcript
/// up (unless that's off or fails), and the text goes in at the caret.
///
/// Every failure after recording keeps the words: a cleanup that fails or drifts falls back to the
/// raw transcript, and text that can't go into the field goes on the clipboard.
@MainActor
final class DictationController {
    private let coordinator: SuggestionCoordinator
    private let router: EngineRouter
    private let models: ModelController
    private let inserter: any TextInserting
    private let learning: LearningController?
    /// Fixes learned from the user correcting dictated text: replace rules and spelling ranks.
    let fixes: DictationFixStore
    private let settings: () -> HunchSettings
    /// Opens Settings → Model at Speech to Text (no speech model yet).
    private let openSettings: () -> Void
    /// Boost: Write for me polishes the paragraphs the dictated text went into.
    private let boost: (WriteForMeController.Dictated) -> Void

    private let recorder = MicRecorder()
    private let whisper = WhisperTranscriber()
    private let pill = DictationPill()
    /// The suggestions' pop-in, played on the dictated text at the caret before it is pasted.
    private let effects = TextEffectPlayer()
    /// A key or click arrived while the effect played: paste right away.
    private var effectInterrupted = false
    private var trigger = DictationTrigger()
    private var shortcut: DictationHotKey?
    private var escape: DictationHotKey?
    private var shortcutRefused = false
    /// EXPERIMENTAL voice instructions: a second shortcut that records the same way, but hands the
    /// raw transcript to Write for me instead of inserting it. One recorder and one pipeline serve
    /// both, so a dictation and a voice instruction can never overlap.
    private var voiceShortcut: DictationHotKey?
    private var voiceRefused: String?
    private let voice: VoiceHooks

    /// What dictation needs from Write for me for voice instructions.
    struct VoiceHooks {
        /// The panel is showing / Write for me is opening or inserting.
        var panelOpen: () -> Bool = { false }
        var writeBusy: () -> Bool = { false }
        /// The instruction is ready: route it (panel refine, or the field's selection / caret).
        var deliver: (String, VoiceInstructionTarget) async -> VoiceInstructionDelivery = { _, _ in .refuse(.off) }
    }

    /// What a recording is for.
    enum Purpose: Equatable {
        /// Dictation: the cleaned-up text goes in at the caret.
        case dictate
        /// A voice instruction for Write for me: never inserted.
        case instruction(VoiceInstructionTarget)
    }

    private struct Start {
        var context: TextContext?
        /// The app in front when dictation started (the field's app when it was read). With no
        /// readable field the text is pasted into it blind (`DictationBlindInsert`).
        var app: AppIdentity?
        var geometry: CaretGeometry?
        var at: ContinuousClock.Instant
        var model: URL
        var windowTitle: String?
        /// Hunch is off or doesn't learn where dictation started: no log, no learning, no context.
        var keepNothing: Bool
        /// This dictation's tag in `runs`.
        var run: Int
        var purpose: Purpose = .dictate
    }
    private var start: Start?
    /// Only the current dictation's work may clear `start`, `pipeline`, `writer` and Esc.
    private var runs = DictationRuns()
    private var pipeline: Task<Void, Never>?
    /// Stops the recording at the recorder's limit (it keeps no audio past it).
    private var limitTask: Task<Void, Never>?
    private var writer: (any WriteGenerating)?

    /// Dictated text being watched for the user's fixes, and the fixes seen so far.
    private struct Watch {
        var field: FieldID
        var inserted: String
        var chat: Bool
        var appKey: String?
        /// Also add fixed words to the learned words (only with "Learn from my writing" on).
        var learnWords: Bool
        var found: [DictationText.Correction] = []
    }
    private var watch: Watch?
    private var watchTask: Task<Void, Never>?
    /// How long dictated text is watched for fixes at most.
    static let watchLimit: Duration = .seconds(120)

    /// What the last insert put in the field, and Boost's offer for it while the pill shows it.
    private var lastInserted: WriteForMeController.Dictated?
    private var boostOffer: WriteForMeController.Dictated?
    /// How long the pill offers Boost.
    static let boostSeconds = 10.0

    /// The last dictation, for "Paste last dictation" (memory only).
    private(set) var lastText: String?
    private(set) var lastRaw: String?

    /// How long to wait for a fresh focus read before refusing dictation outside a text field.
    static let fieldRecheck: Duration = .milliseconds(200)
    /// Recordings shorter than this are an accidental press.
    static let minimumSeconds = 0.3
    /// How long the cleanup may take before the raw transcript goes in instead.
    static let cleanupTimeout: Duration = .seconds(20)

    init(coordinator: SuggestionCoordinator, router: EngineRouter, models: ModelController,
         inserter: any TextInserting, learning: LearningController?, fixes: DictationFixStore,
         settings: @escaping () -> HunchSettings, openSettings: @escaping () -> Void,
         boost: @escaping (WriteForMeController.Dictated) -> Void, voice: VoiceHooks = VoiceHooks()) {
        self.boost = boost
        self.voice = voice
        self.coordinator = coordinator
        self.router = router
        self.models = models
        self.inserter = inserter
        self.learning = learning
        self.fixes = fixes
        self.settings = settings
        self.openSettings = openSettings
        shortcut = DictationHotKey(onPress: { [weak self] in self?.pressed() },
                                   onRelease: { [weak self] in self?.released() })
        escape = DictationHotKey(onPress: { [weak self] in self?.cancel() })
        voiceShortcut = DictationHotKey(onPress: { [weak self] in self?.voicePressed() },
                                        onRelease: { [weak self] in self?.voiceReleased() })
    }

    /// Why the voice instruction shortcut isn't registered (another Hunch shortcut has the keys,
    /// or the system refused it); nil when it is, or when the feature is off.
    var voiceShortcutProblem: String? { voiceRefused }

    /// The system refused the shortcut (another app holds it); Settings → Shortcuts says so.
    var isShortcutRefused: Bool { shortcutRefused }

    /// Settings changed: register the shortcut again.
    func apply(_ settings: HunchSettings) {
        let chord = settings.dictation.enabled ? settings.dictation.shortcut : nil
        shortcutRefused = !(shortcut?.register(chord) ?? true)
        if chord == nil, recorder.isRecording, start?.purpose == .dictate { cancel() }
        let voiceOn = settings.experimentalVoiceInstructions && settings.dictation.enabled
        let voiceChord = voiceOn ? settings.voiceInstruction.shortcut : nil
        if let clash = VoiceInstruction.conflict(voiceChord, dictation: chord, bindings: settings.bindings) {
            voiceShortcut?.register(nil)
            voiceRefused = "\(clash) already uses these keys. Pick another shortcut."
        } else {
            voiceRefused = voiceShortcut?.register(voiceChord) ?? true ? nil
                : "macOS or another app already uses these keys. Pick another shortcut."
        }
        if voiceChord == nil, recorder.isRecording, start?.purpose != .dictate { cancel() }
    }

    // MARK: Shortcut

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func pressed() {
        logShortcut("press")
        // A voice instruction is recording: only its own shortcut stops it.
        if recorder.isRecording, start?.purpose != .dictate { return }
        // Busy with the last one: a press doesn't start another.
        if pipeline != nil, !recorder.isRecording { return }
        switch trigger.keyDown(at: now()) {
        case .start: begin()
        case .stop: finish()
        case .none: break
        }
    }

    /// Debug log: what the shortcut press looked like (which key the keyboard tap saw last, who
    /// posted it, how long ago, the front app, a text field or not), to find presses nobody made.
    private func logShortcut(_ what: String) {
        guard PromptDebugLog.isEnabled else { return }
        var line = "dictation \(what) phase=\(trigger.phase) recording=\(recorder.isRecording)"
        if let key = KeyboardMonitor.lastKey {
            let ago = Int((now() - key.at) * 1000)
            let app = NSRunningApplication(processIdentifier: key.sourcePID)?.bundleIdentifier ?? "-"
            line += " lastKey=\(key.chord.keyCode)/0x\(String(key.chord.modifiers, radix: 16)) agoMs=\(ago)"
                + " hardware=\(key.fromHardware) ours=\(key.ours) sourcePID=\(key.sourcePID) sourceApp=\(app)"
        } else {
            line += " lastKey=none"
        }
        line += " front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")"
        line += " field=\(coordinator.latestContext != nil)"
        PromptDebugLog.note(line, file: "perf.log")
    }

    private func released() {
        logShortcut("release")
        if recorder.isRecording, start?.purpose != .dictate { return }
        if trigger.keyUp(at: now()) == .stop { finish() }
    }

    // MARK: Voice instructions (experimental)

    private func voicePressed() {
        logShortcut("voice press")
        if recorder.isRecording {
            // Dictating: the voice shortcut doesn't touch it.
            guard start?.purpose != .dictate else { return }
            _ = trigger.keyDown(at: now())  // the stopping press of a tap
            return
        }
        guard trigger.keyDown(at: now()) == .start else { return }
        beginVoice(retried: false)
    }

    private func voiceReleased() {
        logShortcut("voice release")
        guard recorder.isRecording, start?.purpose != .dictate else {
            // A refused or late start: the press counted as a tap.
            if !recorder.isRecording, start == nil, pipeline == nil { trigger.reset() }
            return
        }
        if trigger.keyUp(at: now()) == .stop { finish() }
    }

    /// Checks where the instruction would go, then records like dictation. A field the focus read
    /// hasn't caught up with yet gets one more look, like dictation's.
    private func beginVoice(retried: Bool) {
        let settings = settings()
        coordinator.requestContextNow()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let state = VoiceInstructionRoute.PressState(
            featureOn: settings.experimentalVoiceInstructions, dictationEnabled: settings.dictation.enabled,
            panelOpen: voice.panelOpen(), writeBusy: voice.writeBusy(),
            speechBusy: pipeline != nil || recorder.isRecording,
            secureInput: SecureInputProbe.isSecureEventInputEnabled() != false
                || coordinator.dictationPrivacy(frontmostBundleID: front) == .refuse,
            readableField: coordinator.latestContext != nil)
        switch VoiceInstructionRoute.atPress(state) {
        case .success(let target):
            begin(purpose: .instruction(target))
        case .failure(.noField) where !retried:
            Task { [weak self] in
                try? await Task.sleep(for: Self.fieldRecheck)
                guard let self, self.start == nil, !self.recorder.isRecording else { return }
                let held = self.trigger.phase != .idle
                self.beginVoice(retried: true)
                // Let go meanwhile: it was a tap, so the next press stops it.
                if self.recorder.isRecording, !held {
                    _ = self.trigger.keyDown(at: self.now())
                    _ = self.trigger.keyUp(at: self.now())
                }
            }
        case .failure(let why):
            trigger.reset()
            logShortcut("voice refused: \(why.rawValue)")
            NSSound.beep()
            pill.show(.message(VoiceInstruction.message(why), isProblem: true),
                      near: coordinator.latestContext?.geometry.caretRect ?? .zero)
            pill.hide(after: 2.5)
        }
    }

    /// The transcript of a voice instruction: lightly trimmed (no cleanup pass), shown in the pill,
    /// and handed to Write for me. Never inserted, never kept for "Paste last dictation".
    private func deliverInstruction(_ raw: String, target: VoiceInstructionTarget) async {
        guard let text = VoiceInstruction.clean(raw) else {
            pill.show(.message("Didn't catch that", isProblem: false))
            pill.hide(after: 2)
            return
        }
        pill.show(.message(VoiceInstruction.heard(text), isProblem: false))
        guard !Task.isCancelled else { return }
        let delivery = await voice.deliver(text, target)
        if case .refuse(let why) = delivery {
            NSSound.beep()
            pill.show(.message(VoiceInstruction.message(why), isProblem: true))
            pill.hide(after: 3)
        } else {
            pill.hide(after: 1.5)
        }
    }

    // MARK: Recording

    private func begin(purpose: Purpose = .dictate) {
        // A new dictation ends the watch on the last one.
        endWatch()
        boostOffer = nil
        guard SecureInputProbe.isSecureEventInputEnabled() == false else {
            trigger.reset()
            NSSound.beep()
            pill.show(.message("Dictation is off in password fields", isProblem: true))
            pill.hide(after: 2.5)
            return
        }
        guard let model = speechModelURL() else {
            trigger.reset()
            pill.show(.message("Download a speech model in Settings → Performance & Models", isProblem: true))
            pill.hide(after: 4)
            openSettings()
            return
        }
        switch MicRecorder.permission {
        case .authorized: break
        case .notDetermined:
            trigger.reset()
            Task {
                if await MicRecorder.requestPermission() {
                    pill.show(.message("Microphone allowed. Press the shortcut again to dictate.", isProblem: false))
                    pill.hide(after: 3)
                }
            }
            return
        default:
            trigger.reset()
            pill.show(.message("Allow Hunch to use the microphone in System Settings", isProblem: true))
            pill.hide(after: 4)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        coordinator.requestContextNow()
        // A voice instruction checked where it goes already (`VoiceInstructionRoute.atPress`).
        if purpose == .dictate, !coordinator.focusIsOnTextField {
            // The focus read may lag a just-clicked field: look again shortly before refusing.
            trigger.reset()
            Task { [weak self] in
                try? await Task.sleep(for: Self.fieldRecheck)
                guard let self, self.start == nil, !self.recorder.isRecording else { return }
                guard self.coordinator.focusIsOnTextField else {
                    self.logShortcut("refused: no text field")
                    NSSound.beep()
                    self.pill.show(.message("Click into a text box to dictate", isProblem: true), near: .zero)
                    self.pill.hide(after: 2.5)
                    return
                }
                self.begin()
                // A press that started it late counts as a tap: the next press stops it.
                guard self.recorder.isRecording else { return }
                _ = self.trigger.keyDown(at: self.now())
                _ = self.trigger.keyUp(at: self.now())
            }
            return
        }
        let privacy = coordinator.dictationPrivacy(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard purpose != .dictate || privacy != .refuse else {
            trigger.reset()
            NSSound.beep()
            pill.show(.message("Dictation is off in this app", isProblem: true))
            pill.hide(after: 2.5)
            return
        }
        let keepNothing = privacy == .keepNothing
        let latest = coordinator.latestContext
        let front = NSWorkspace.shared.frontmostApplication
        let app = latest?.context.app ?? front.flatMap { front in
            front.bundleIdentifier.map {
                AppIdentity(bundleID: $0, pid: front.processIdentifier, localizedName: front.localizedName)
            }
        }
        start = Start(context: latest?.context, app: app, geometry: latest?.geometry, at: .now, model: model,
                      windowTitle: keepNothing ? nil : latest.flatMap { Self.windowTitle(pid: $0.context.app.pid) },
                      keepNothing: keepNothing, run: runs.next(), purpose: purpose)
        do {
            try recorder.start { _ in }
        } catch {
            trigger.reset()
            start = nil
            pill.show(.message("Couldn't start the microphone", isProblem: true))
            pill.hide(after: 3)
            return
        }
        // The model loads while the user speaks.
        whisper.preload(model)
        escape?.register(KeyChord(keyCode: 53))
        limitTask?.cancel()
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MicRecorder.maxSeconds))
            guard !Task.isCancelled, let self, self.recorder.isRecording else { return }
            self.logShortcut("limit")
            self.finish()
        }
        pill.show(.recording, near: latest?.geometry.caretRect ?? .zero)
    }

    /// Esc: drop the recording, or stop the work on it.
    private func cancel() {
        limitTask?.cancel()
        trigger.reset()
        _ = recorder.stop()
        // The cancelled work winds down on its own; it must not touch the next dictation.
        runs.next()
        pipeline?.cancel()
        pipeline = nil
        whisper.cancel()
        writer?.cancelWrites()
        writer = nil
        let wasInstruction = start.map { $0.purpose != .dictate } ?? false
        start = nil
        escape?.unregister()
        pill.show(.message(wasInstruction ? "Voice instruction cancelled" : "Dictation cancelled", isProblem: false))
        pill.hide(after: 1.2)
    }

    private func finish() {
        limitTask?.cancel()
        trigger.reset()
        let samples = recorder.stop()
        guard let start else { return }
        let seconds = Double(samples.count) / WhisperTranscriber.sampleRate
        guard seconds >= Self.minimumSeconds else {
            self.start = nil
            escape?.unregister()
            pill.hide()
            return
        }
        pill.show(.working("Transcribing…"))
        pipeline = Task { [weak self] in
            await self?.process(samples, seconds: seconds, start: start)
            guard let self, self.runs.isCurrent(start.run) else { return }
            self.pipeline = nil
            self.start = nil
            self.escape?.unregister()
        }
    }

    // MARK: Pipeline

    private func process(_ samples: [Float], seconds: Double, start: Start) async {
        let settings = settings()
        let dictation = settings.dictation
        var log = DictationLog(seconds: seconds, model: start.model.lastPathComponent, toggles: dictation.context,
                               preset: dictation.cleanupEnabled ? dictation.preset.rawValue : "off")
        // Dictation log: with debug logging on, and never where Hunch keeps nothing.
        let keepLog = settings.debugLogging && !start.keepNothing
        let reference = start.context.map { coordinator.dictationReference(context: $0) }
        // No readable field: the app's own settings still apply (local engine only, its shape).
        let policy = reference?.policy ?? start.app.map { coordinator.dictationPolicy(bundleID: $0.bundleID) } ?? .default
        let shape = start.context.map {
            WriteShapeResolver.resolve(policy.writeShape, surface: $0.metadata.surface, urlHost: $0.urlHost,
                                       bundleID: $0.app.bundleID, isAIChatInput: $0.metadata.isAIChatInput)
        } ?? start.app.map {
            WriteShapeResolver.resolve(policy.writeShape, surface: .unknown, urlHost: nil, bundleID: $0.bundleID)
        } ?? .paragraph
        let traditional = dictation.context.languages && Self.prefersTraditional()
        let spellings = dictation.context.learnedWords
            ? await learnedSpellings(for: start.context, learned: settings.learning.enabled) : []

        // Speech to text.
        let sttStart = ContinuousClock.now
        let transcript: Transcript
        do {
            transcript = try await whisper.transcribe(samples, model: start.model,
                                                      prompt: DictationFramer.whisperPrompt(spellings: spellings,
                                                                                            traditionalChinese: traditional))
        } catch {
            guard !Task.isCancelled else { return }
            pill.show(.message("Couldn't transcribe: \(Self.describe(error))", isProblem: true))
            pill.hide(after: 4)
            return
        }
        guard !Task.isCancelled else { return }
        log.whisperMs = Self.ms(since: sttStart)
        log.language = transcript.language
        var raw = DictationText.scrubTranscript(transcript.text)
        if traditional { raw = HanScript.traditional(raw) }
        raw = DictationText.applyFixes(fixes.fixes, to: raw).text
        if case .instruction(let target) = start.purpose {
            await deliverInstruction(raw, target: target)
            return
        }
        log.raw = raw
        guard !raw.isEmpty, !DictationText.isEmptySpeech(raw) else {
            pill.show(.message("Didn't catch that", isProblem: false))
            pill.hide(after: 2)
            log.outcome = "nothing heard"
            if keepLog { log.write() }
            return
        }
        lastRaw = raw

        // Cleanup.
        var text = raw
        if dictation.cleanupEnabled {
            pill.show(.working("Cleaning up…"))
            let context = buildContext(start: start, reference: start.keepNothing ? nil : reference?.screen,
                                       spellings: spellings, traditional: traditional,
                                       toggles: start.keepNothing ? Self.keepNothingToggles(dictation.context)
                                                                  : dictation.context,
                                       settings: settings, policy: policy)
            log.contextTokens = Self.contextTokens(context)
            let cleanupStart = ContinuousClock.now
            let result = await cleanUp(raw, preset: dictation.preset, shape: shape, context: context,
                                       policy: policy, settings: settings, run: start.run)
            guard !Task.isCancelled else { return }
            log.cleanupMs = Self.ms(since: cleanupStart)
            switch result {
            case .cleaned(let cleaned, let via):
                text = traditional ? HanScript.traditional(cleaned) : cleaned
                log.outcome = "cleaned (\(via))"
            case .fellBack(let why):
                log.outcome = "raw: \(why)"
            }
        } else {
            log.outcome = "raw: cleanup off"
        }
        // The cleanup may have "fixed" a learned word back, or kept chat-style capitals.
        text = DictationText.applyFixes(fixes.fixes, to: text).text
        if shape == .message { text = DictationText.chatStyle(text, transcript: raw) }
        log.shape = shape.rawValue
        log.cleaned = text
        lastText = text

        // Insert.
        lastInserted = nil
        let learn = DictationLearning.decide(
            learnFromFixes: dictation.learnFromFixes, learnFromWriting: settings.learning.enabled,
            appAllowsLearning: policy.learningAllowed, surface: start.context?.metadata.surface,
            keepNothing: start.keepNothing)
        let inserted = await insert(text, start: start, chat: shape == .message, learn: learn)
        log.inserted = inserted
        if keepLog { log.write() }
        guard !Task.isCancelled else { return }
        if !inserted {
            pill.show(.message("The text box changed: the text is on the clipboard", isProblem: true))
            pill.hide(after: 4)
        } else if dictation.boostAfterDictation, let offer = lastInserted {
            offerBoost(offer)
        } else if dictation.showTimings {
            // TESTING (remove later, see TODO.md): timings for comparing models and context.
            pill.show(.message(log.summary, isProblem: false))
            pill.hide(after: 4)
        } else {
            pill.hide()
        }
    }

    private enum CleanupResult {
        case cleaned(String, via: String)
        case fellBack(String)
    }

    private func cleanUp(_ raw: String, preset: DictationPreset, shape: WriteShape, context: DictationContext,
                         policy: AppPolicy, settings: HunchSettings, run: Int) async -> CleanupResult {
        // A cancelled run's writer is no longer `self.writer`: leave the next run's alone.
        func setWriter(_ new: (any WriteGenerating)?) {
            if runs.isCurrent(run) { self.writer = new }
        }
        let request = DictationCleanup(transcript: raw, preset: preset, context: context, shape: shape)
        var useEndpoint = policy.engineOverride != .local
        for _ in 0..<2 {
            guard let (writer, use, viaEndpoint) = pickWriter(useEndpoint: useEndpoint, settings: settings) else {
                return .fellBack("no instruct model")
            }
            setWriter(writer)
            let write = WriteRequest(id: RequestID(1), mode: .polish, source: raw, shape: .paragraph,
                                     context: PromptInput(before: "", after: "", surface: context.surface ?? .unknown,
                                                          preferredLanguages: []),
                                     dictation: request)
            do {
                let reply = try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask { try await writer.write(write) { _ in } }
                    group.addTask {
                        try await Task.sleep(for: Self.cleanupTimeout)
                        return nil
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? nil
                }
                setWriter(nil)
                guard let reply else {
                    writer.cancelWrites()
                    return .fellBack("timed out")
                }
                if viaEndpoint { router.noteSuccess(use) }
                switch DictationText.check(reply, transcript: raw, textBefore: context.textBefore) {
                case .accept(let text): return .cleaned(text, via: viaEndpoint ? "endpoint" : "local")
                case .reject(let why): return .fellBack("rejected \(why.rawValue)")
                }
            } catch {
                setWriter(nil)
                if Task.isCancelled { return .fellBack("cancelled") }
                // The endpoint failed: skip it for a while and try the local model once.
                if viaEndpoint {
                    router.noteFailure(use)
                    useEndpoint = false
                    continue
                }
                return .fellBack("error")
            }
        }
        return .fellBack("error")
    }

    /// Write for me's source: its endpoint when chosen and answering, else the Language Model (or the
    /// separate writing model). A base Language Model doesn't follow the rules well enough: none.
    private func pickWriter(useEndpoint: Bool, settings: HunchSettings)
        -> (any WriteGenerating, ModelUse, Bool)? {
        let use: ModelUse = settings.useWritingModel ? .writing : .autocomplete
        if useEndpoint, let endpoint = router.slot(use).available { return (endpoint, use, true) }
        if !settings.useWritingModel || models.writingModelIsLanguageModel {
            guard !models.languageModelIsBase else { return nil }
            let id = coordinator.currentRequestID
            return models.languageModelWriter(currentID: { id }).map { ($0, use, false) }
        }
        return models.instructWriter().map { ($0, use, false) }
    }

    // MARK: Context

    private func buildContext(start: Start, reference screen: String?, spellings: [String], traditional: Bool,
                              toggles: DictationContextToggles, settings: HunchSettings,
                              policy: AppPolicy) -> DictationContext {
        var context = DictationContext(spellings: spellings, traditionalChinese: traditional)
        let field = start.context
        if toggles.titleNames, let title = start.windowTitle {
            context.titleNames = DictationText.names(in: title, limit: 10)
        }
        if toggles.screenNames, let screen {
            context.screenNames = DictationText.names(in: screen, limit: 30)
        }
        if toggles.textBefore, let field {
            let before = String(field.before.suffix(400))
            context.textBefore = SecretSanitizer.redact(before, surface: field.metadata.surface)
        }
        if toggles.appType, let field, !policy.omitSurfaceContext {
            context.surface = field.metadata.surface
            context.appName = field.app.localizedName
        }
        if toggles.languages {
            context.languages = Array(Locale.preferredLanguages.prefix(4))
        }
        if toggles.aboutMe, settings.usePersonalInfo, policy.personalInfoAllowed {
            let about = settings.aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
            context.aboutMe = about.isEmpty ? nil : String(about.prefix(300))
        }
        return context
    }

    /// Where Hunch keeps nothing, the cleanup gets no field, screen, title, app or About me
    /// context: only learned spellings and the user's languages.
    static func keepNothingToggles(_ toggles: DictationContextToggles) -> DictationContextToggles {
        var t = toggles
        t.titleNames = false
        t.screenNames = false
        t.textBefore = false
        t.appType = false
        t.aboutMe = false
        return t
    }

    /// Learned words and words added by hand that aren't blocked: words added by hand first, then
    /// those used in this app, then by strength. At most 60. With "Learn from my writing" off
    /// (`learned` false), only words added by hand.
    private func learnedSpellings(for context: TextContext?, learned: Bool) async -> [String] {
        guard let learning else { return [] }
        let appKey = context.flatMap { AppKey.make(bundleID: $0.app.bundleID, urlHost: $0.urlHost) }
        let entries = await learning.entries().filter {
            $0.status != .blocked && $0.text.count >= 2 && (learned || $0.origin == .manual)
        }
        // Words fixed in dictation rank by how often, how lately and where they were fixed.
        func score(_ e: LearnedWordInfo) -> Float {
            var s = e.strength + fixes.score(word: e.text, appKey: appKey)
            if e.origin == .manual { s += 10 }
            if e.origin == .dictation { s += 4 }
            if let appKey, e.apps.contains(where: { $0.key == appKey }) { s += 1 }
            return s
        }
        return entries.sorted { score($0) > score($1) }.prefix(60).map(\.text)
    }

    /// The user types Traditional Chinese: their keyboard or language list says so.
    static func prefersTraditional() -> Bool {
        if InputSourceScripts.shared.preferredHan == .traditional { return true }
        return Locale.preferredLanguages.contains {
            let l = $0.lowercased()
            return l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo")
        }
    }

    /// The focused window's title, read directly (the suggestion setting for titles is separate).
    static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        let text = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    // MARK: Insertion

    /// Pastes `text` at the caret of the field dictation started in. False (and the text on the
    /// clipboard) when focus moved to another field or the paste failed.
    private func insert(_ text: String, start: Start, chat: Bool, learn: DictationLearning) async -> Bool {
        guard let origin = start.context else {
            return await insertBlind(text, start: start)
        }
        coordinator.requestContextNow()
        try? await Task.sleep(for: .milliseconds(60))
        guard let latest = coordinator.latestContext,
              latest.context.field.pid == origin.field.pid,
              latest.context.field.elementHash == origin.field.elementHash else {
            putOnClipboard(text)
            return false
        }
        let now = latest.context
        let reference = coordinator.dictationReference(context: now)
        let policy = reference.policy
        let fitted = DictationText.fitted(text, after: now.before)
        await playEffect(fitted, context: now, geometry: latest.geometry)
        // The effect player is shared: a run that was cancelled or replaced by a newer dictation
        // leaves it to the newer one.
        let isCurrent = { [weak self] in self?.runs.isCurrent(start.run) ?? false }
        guard !Task.isCancelled else {
            if isCurrent() { effects.hideAll() }
            return false
        }
        let mode: InsertionMode = policy.insertion == .pasteMatchStyle ? .pasteMatchStyle : .paste
        let outcome = await inserter.insertHoldingClipboard(fitted, into: now.app, mode: mode,
                                                            chunkSize: policy.injectionChunkSize ?? 16,
                                                            workarounds: policy.insertionWorkarounds)
        if case .failed = outcome {
            if isCurrent() { effects.hideAll() }
            inserter.releaseClipboard(restore: true)
            putOnClipboard(text)
            return false
        }
        lastInserted = WriteForMeController.Dictated(text: fitted, field: now.field)
        // The ghost goes as the pasted text shows below; a host slow to report it gets a moment.
        if isCurrent() { effects.hideAll(after: Self.effectAfterPaste) }
        // Hold the clipboard until the field shows the text (a slow host pastes late). Esc or a new
        // dictation ends the wait: a cancelled sleep returns at once, so the loop would otherwise
        // spin on the main thread for the rest of the 3 s.
        let pasted = ContinuousClock.now
        while ContinuousClock.now - pasted < .seconds(3), !Task.isCancelled, isCurrent() {
            if let latest = coordinator.latestContext?.context, latest.capturedAt >= pasted,
               WriteRange.showsDraft(fitted, before: latest.before) {
                // The pasted text is in the field under the settled effect: take the effect down.
                effects.hideAll()
                inserter.releaseClipboard(restore: true)
                learning?.noteDraftInserted(field: latest.field, draft: fitted)
                if learn.rules {
                    beginWatch(Watch(field: latest.field, inserted: fitted, chat: chat,
                                     appKey: AppKey.make(bundleID: latest.app.bundleID, urlHost: latest.urlHost),
                                     learnWords: learn.words))
                }
                return true
            }
            coordinator.requestContextNow()
            try? await Task.sleep(for: .milliseconds(40))
        }
        // Not seen (or no longer waited for): it may have gone in anyway; keep it on the clipboard to be safe.
        if isCurrent() { effects.hideAll() }
        inserter.releaseClipboard(restore: false)
        return true
    }

    /// Plays the pop-in on `text` at the caret, wrapped like the field, and waits until it settles
    /// (or a key or click cuts it short). Nothing plays with the effect off for dictation, None, or
    /// no trustworthy caret.
    private func playEffect(_ text: String, context: TextContext, geometry: CaretGeometry) async {
        let settings = settings()
        guard settings.effectsForDictation else { return }
        // A guessed caret is moved after the typed line when it was found on screen, as for
        // suggestions, or in an empty field to where the app's text was seen to start.
        let geometry = coordinator.effectGeometry(geometry, context: context)
        guard geometry.quality >= .derived else {
            SuggestionCoordinator.perf("dictation effect skipped: caret quality=\(geometry.quality) "
                + "field=\(geometry.fieldFrame != nil) before=\(context.before.count) after=\(context.after.count) "
                + "app=\(context.app.bundleID)")
            return
        }
        effects.appearance = settings.appearance
        let base = coordinator.effectPresentation(text, context: context, geometry: geometry)
        // Ends in the field's own text color, so the paste replaces it without a change.
        let color = geometry.font?.textColor.map {
            NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        } ?? NSColor.labelColor
        let (settle, _) = effects.playWrapped(text, base: base, color: color)
        SuggestionCoordinator.perf("dictation effect quality=\(geometry.quality) settleMs=\(Int(settle * 1000)) "
            + "app=\(context.app.bundleID)")
        guard settle > 0 else { return }
        effectInterrupted = false
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.effectInterrupted = true }
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        let end = ContinuousClock.now + .milliseconds(Int(settle * 1000))
        while ContinuousClock.now < end, !effectInterrupted, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(15))
        }
        if effectInterrupted {
            SuggestionCoordinator.perf("dictation effect cut short by a key or click")
            effects.hideAll()
        }
    }

    /// Longest the dictation ghost stays after the paste when the field is slow to show the text.
    static let effectAfterPaste: TimeInterval = 0.3

    /// Dictation started where the field can't be read (Hunch is off there, a terminal that
    /// shows no text, a selection): pastes into the same app without reading the field, so nothing
    /// is read, watched or learned. The user's clipboard comes back after the paste.
    private func insertBlind(_ text: String, start: Start) async -> Bool {
        guard let app = start.app else {
            putOnClipboard(text)
            return false
        }
        coordinator.requestContextNow()
        try? await Task.sleep(for: .milliseconds(60))
        let front = NSWorkspace.shared.frontmostApplication
        let allowed = DictationBlindInsert.allowed(
            startPID: app.pid, frontPID: front?.processIdentifier,
            secureInput: SecureInputProbe.isSecureEventInputEnabled(),
            privacy: coordinator.dictationPrivacy(frontmostBundleID: front?.bundleIdentifier),
            onTextField: coordinator.focusIsOnTextField)
        guard allowed else {
            putOnClipboard(text)
            return false
        }
        let policy = coordinator.dictationPolicy(bundleID: app.bundleID)
        let mode: InsertionMode = policy.insertion == .pasteMatchStyle ? .pasteMatchStyle : .paste
        let outcome = await inserter.insert(text, into: app, mode: mode, chunkSize: policy.injectionChunkSize ?? 16,
                                            workarounds: policy.insertionWorkarounds)
        if case .failed = outcome {
            putOnClipboard(text)
            return false
        }
        return true
    }

    // MARK: Boost

    private func offerBoost(_ offer: WriteForMeController.Dictated) {
        boostOffer = offer
        // Next to the caret where the dictated text ends (the insert waited for a read showing it).
        let caret = coordinator.latestContext.flatMap { latest in
            latest.context.field.pid == offer.field.pid && latest.context.field.elementHash == offer.field.elementHash
                ? latest.geometry.caretRect : nil
        }
        pill.showBoost(near: caret, for: Self.boostSeconds) { [weak self] in
            guard let self, let offer = self.takeBoostOffer(hidePill: false) else { return }
            self.boost(offer)
        }
    }

    /// The Boost offer while the pill shows it, ending it. The Write for me shortcut uses it to
    /// polish what was just dictated.
    func takeBoostOffer(hidePill: Bool = true) -> WriteForMeController.Dictated? {
        defer { boostOffer = nil }
        guard let offer = boostOffer else { return nil }
        if hidePill {
            guard pill.isOfferingBoost else { return nil }
            pill.hide()
        }
        return offer
    }

    /// Typing, or a click anywhere but the pill, ends the Boost offer.
    func noteTyping(_ event: TypingEvent) {
        guard boostOffer != nil else { return }
        switch event {
        case .keyDown:
            endBoostOffer()
        case .mouseDown:
            if !pill.contains(NSEvent.mouseLocation) { endBoostOffer() }
        default:
            break
        }
    }

    /// Leaving the field ends the Boost offer.
    func noteFocus(_ event: FocusEvent) {
        guard let offer = boostOffer else { return }
        switch event {
        case .context(let context, _):
            if context.field.pid != offer.field.pid || context.field.elementHash != offer.field.elementHash {
                endBoostOffer()
            }
        case .focusLost:
            endBoostOffer()
        case .blocked:
            break
        }
    }

    private func endBoostOffer() {
        boostOffer = nil
        if pill.isOfferingBoost { pill.hide() }
    }

    private func putOnClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// "Paste last dictation" / "Paste last raw transcript" from the menu bar.
    func pasteLast(raw: Bool) {
        guard let text = raw ? lastRaw : lastText else { NSSound.beep(); return }
        Task {
            // The menu closes first and the app the user was in gets its focus back.
            try? await Task.sleep(for: .milliseconds(250))
            coordinator.requestContextNow()
            try? await Task.sleep(for: .milliseconds(60))
            guard let context = coordinator.latestContext?.context else {
                putOnClipboard(text)
                NSSound.beep()
                return
            }
            let outcome = await inserter.insert(DictationText.fitted(text, after: context.before), into: context.app,
                                                mode: .paste, chunkSize: 16)
            if case .failed = outcome { putOnClipboard(text) }
        }
    }

    // MARK: Learning from fixes

    /// Watches the field the text went into until the user leaves it, the text is gone (sent,
    /// deleted) or the time is up; then learns the fixes made inside it.
    private func beginWatch(_ new: Watch) {
        endWatch()
        watch = new
        watchTask = Task { [weak self] in
            let started = ContinuousClock.now
            while ContinuousClock.now - started < Self.watchLimit {
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, !Task.isCancelled, let current = self.watch else { return }
                self.coordinator.requestContextNow()
                guard let now = self.coordinator.latestContext?.context, now.field.pid == current.field.pid,
                      now.field.elementHash == current.field.elementHash else { break }
                let text = now.before + now.selectedText + now.after
                guard case .present(let found) = DictationText.corrections(
                    inserted: current.inserted, field: text, chat: current.chat, isKnownWord: Self.isKnownWord)
                else { break }
                self.watch?.found = found
            }
            self?.endWatch()
        }
    }

    /// Stops watching and learns what was found.
    private func endWatch() {
        watchTask?.cancel()
        watchTask = nil
        guard let ended = watch else { return }
        watch = nil
        guard !ended.found.isEmpty else { return }
        Task { await learn(ended.found, appKey: ended.appKey, words: ended.learnWords) }
    }

    /// Keeps the fix rules; adds the words to the learned words only when `words` is true.
    private func learn(_ found: [DictationText.Correction], appKey: String?, words: Bool) async {
        // Without learned words, a fix with no rule keeps nothing, so it isn't shown as learned.
        let found = words ? found : found.filter { $0.rule != nil }
        guard !found.isEmpty else { return }
        var undo: [(wordID: String?, heard: String?)] = []
        let existing = words ? Set(await learning?.entries().map(\.id) ?? []) : []
        for correction in found {
            var wordID: String?
            if words, let id = try? await learning?.addFromDictation(correction.word), !existing.contains(id) {
                wordID = id
            }
            if let rule = correction.rule { fixes.record(heard: rule.heard, written: rule.written, appKey: appKey) }
            undo.append((wordID, correction.rule?.heard))
        }
        let learned = found.map(\.word).joined(separator: ", ")
        pill.show("Learned: \(learned)", button: "Undo", for: 6) { [weak self] in
            guard let self else { return }
            for item in undo {
                if let heard = item.heard { self.fixes.undo(heard: heard) }
                if let id = item.wordID { Task { try? await self.learning?.delete(id: id) } }
            }
        }
    }

    /// A correctly spelled word: a fix of it needs a neighbouring word for its rule, so the word
    /// itself is never replaced everywhere.
    static func isKnownWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    // MARK: Helpers

    /// The chosen whisper model in the models folder, else the best one downloaded there.
    func speechModelURL() -> URL? {
        guard case .available(let folder) = models.snapshot.state else { return nil }
        let files = FileManager.default
        func url(_ name: String) -> URL? {
            let candidate = folder.appendingPathComponent(name)
            return files.fileExists(atPath: candidate.path) ? candidate : nil
        }
        if let chosen = settings().dictation.speechModel, let found = url(chosen) { return found }
        let preference = ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin",
                          "ggml-base.bin", "ggml-tiny.bin"]
        return preference.lazy.compactMap(url).first
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Rough token count of the context blocks (about 4 characters a token), for the test readout.
    private static func contextTokens(_ c: DictationContext) -> Int {
        let parts = c.spellings + c.titleNames + c.screenNames + c.languages
            + [c.textBefore, c.aboutMe, c.appName].compactMap { $0 }
        return parts.reduce(0) { $0 + ($1.utf8.count + 3) / 4 }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case TranscriptionError.modelMissing: "the speech model is missing"
        case TranscriptionError.loadFailed(let name): "couldn't load \(name)"
        case TranscriptionError.failed(let code): "whisper error \(code)"
        default: error.localizedDescription
        }
    }
}

/// TESTING (remove later, see TODO.md): one line per dictation in dictation-test.log, with the raw
/// and cleaned text, timings and which context switches were on, to compare runs.
struct DictationLog {
    var seconds: Double
    var model: String
    var toggles: DictationContextToggles
    var preset: String
    var whisperMs: Int?
    var cleanupMs: Int?
    var contextTokens: Int?
    var language: String?
    var raw: String?
    var cleaned: String?
    var outcome = ""
    var inserted = false
    var shape: String?

    /// "Whisper 0.8 s · cleanup 0.6 s · 312 context tokens".
    var summary: String {
        var parts: [String] = []
        if let whisperMs { parts.append(String(format: "Whisper %.1f s", Double(whisperMs) / 1000)) }
        if let cleanupMs { parts.append(String(format: "cleanup %.1f s", Double(cleanupMs) / 1000)) }
        if let contextTokens { parts.append("\(contextTokens) context tokens") }
        if outcome.hasPrefix("raw:") { parts.append(outcome) }
        return parts.joined(separator: " · ")
    }

    static var fileURL: URL { SavedLogKind.dictations.fileURL }

    func write() {
        let t = toggles
        let on = [("learnedWords", t.learnedWords), ("titleNames", t.titleNames), ("screenNames", t.screenNames),
                  ("textBefore", t.textBefore), ("appType", t.appType), ("languages", t.languages),
                  ("aboutMe", t.aboutMe)].filter(\.1).map(\.0)
        func value(_ x: Any?) -> Any { x ?? NSNull() }
        let object: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "audioSeconds": (seconds * 10).rounded() / 10,
            "model": model, "preset": preset, "context": on, "whisperMs": value(whisperMs),
            "cleanupMs": value(cleanupMs), "contextTokens": value(contextTokens), "language": value(language),
            "raw": value(raw), "cleaned": value(cleaned), "outcome": outcome, "inserted": inserted,
            "shape": value(shape),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        let url = Self.fileURL
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Owner only: it holds what the user said. An older log made with default permissions is tightened.
        if files.fileExists(atPath: url.path) {
            try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
