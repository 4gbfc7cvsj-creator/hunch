import AppKit
import Foundation
import HunchCore
import HunchEndpoint
import HunchEngine
import HunchModels
import HunchOverlay
import HunchPolicy
import HunchText

/// Write for me: the shortcut's flow from capturing the range to replacing it with the draft.
///
/// 1. The shortcut reads the focused field (selection, else the caret's paragraph) and opens the
///    preview panel with Write or Polish preset by `WriteModeGuess`. Focus tracking pauses while the
///    panel is open, so no suggestion shows and no accept key reaches the host meanwhile.
/// 2. The draft streams in from the endpoint when one is configured, else the Language Model already
///    loaded for suggestions, or, with "Use a separate writing model" on, that writing model (shared
///    with suggestions when it is the same file; otherwise loaded on first use, released when idle).
///    A base Language Model asks first: set a separate writing model, or try the base model anyway.
/// 3. Insert gives focus back to the host, checks the field still holds the range, selects it (one
///    accessibility call; else deletes it with key presses) and pastes the draft over it. If the field changed meanwhile the draft goes on the clipboard instead.
@MainActor
final class WriteForMeController: WriteForMePanelDelegate {
    private let coordinator: SuggestionCoordinator
    private let router: EngineRouter
    private let models: ModelController
    private let policies: any AppPolicyResolving
    private let inserter: any TextInserting
    private let learning: LearningController?
    private let pauseFocus: () -> Void
    private let resumeFocus: () -> Void
    /// Starts the instruct model's download and shows it in Settings → Models.
    private let downloadModel: () -> Void
    /// Turns "Use a separate writing model" on and opens Settings → Models.
    private let setWritingModel: () -> Void
    /// Selects UTF-16 units (before, after) around the field's caret and checks the selection is the
    /// given text: nil when it is, else why not (then the range is deleted with key presses).
    private let selectAroundCaret: (FieldID, Int, Int, String) async -> String?
    /// Reads the field once with wider limits (nil when it can't): for a paragraph longer than the
    /// usual read window.
    private let readWider: (FieldID, ContextLimits) async -> TextContext?

    private let panel = WriteForMePanel()

    private struct Target {
        var context: TextContext
        var geometry: CaretGeometry
        var range: WriteRange
        var policy: AppPolicy
        /// Voice instructions: the spoken instruction for a `transform`, or the spoken description a
        /// `write` drafts from (then `range` is empty, at the caret).
        var instruction: String?
    }
    private var target: Target?
    /// Voice instructions: what the user said last, shown (editable) in the panel.
    private var spoken: SpokenInstruction?
    /// An accepted draft is going into the field.
    private var inserting = false
    private var mode: WriteMode = .write
    private var refinements: [String] = []
    private var previousDraft: String?
    private var useBaseModel = false
    private var generation: Task<Void, Never>?
    private var writer: (any WriteGenerating)?
    /// Bumped for every draft; partials from an older one are dropped.
    private var draftNumber = 0
    private var finishedDraft = 0
    private var starting = false

    /// How long to wait for a read of the field taken after the shortcut was pressed.
    static let freshReadWait: Duration = .milliseconds(250)
    /// How long the host gets to take focus back before inserting.
    static let refocusWait: Duration = .milliseconds(1500)
    static let forwardDeleteKeyCode: UInt16 = 117
    static let backspaceKeyCode: UInt16 = 51
    /// How long the deletes, then the paste, get to show in the field.
    static let landWait: Duration = .seconds(8)
    /// How long a changed field has to stay the same to count as done with the deletes.
    static let settleWait: Duration = .milliseconds(400)
    /// After a refused select: time for a host that applies selections late to settle.
    static let selectUndoWait: Duration = .milliseconds(200)

    init(coordinator: SuggestionCoordinator, router: EngineRouter, models: ModelController,
         policies: any AppPolicyResolving, inserter: any TextInserting, learning: LearningController?,
         pauseFocus: @escaping () -> Void, resumeFocus: @escaping () -> Void, downloadModel: @escaping () -> Void,
         setWritingModel: @escaping () -> Void,
         selectAroundCaret: @escaping (FieldID, Int, Int, String) async -> String? = { _, _, _, _ in "unsupported" },
         readWider: @escaping (FieldID, ContextLimits) async -> TextContext? = { _, _ in nil }) {
        self.coordinator = coordinator
        self.router = router
        self.models = models
        self.policies = policies
        self.inserter = inserter
        self.learning = learning
        self.pauseFocus = pauseFocus
        self.resumeFocus = resumeFocus
        self.downloadModel = downloadModel
        self.setWritingModel = setWritingModel
        self.selectAroundCaret = selectAroundCaret
        self.readWider = readWider
        panel.delegate = self
        panel.highlights = { [weak self] text in
            guard let original = self?.target?.range.source else { return [] }
            return WordDiff.changedRanges(original: original, revised: text)
        }
    }

    var isOpen: Bool { panel.isVisible }

    /// Opening (reading the field) or inserting an accepted draft: a voice instruction must wait.
    var isBusy: Bool { starting || inserting }

    // MARK: Shortcut

    /// What dictation just put in a field, for Boost.
    struct Dictated {
        var text: String
        var field: FieldID
    }

    /// Opens the panel. With `boosting`, it polishes the paragraphs that dictation touched (Boost)
    /// instead of guessing the mode for the caret's paragraph.
    func start(boosting: Dictated? = nil) {
        guard !panel.isVisible, !starting else { return }
        starting = true
        let pressedAt = ContinuousClock.now
        coordinator.requestContextNow()
        Task {
            defer { starting = false }
            guard let latest = await freshRead(since: pressedAt), !latest.context.hasMarkedText else {
                NSSound.beep()
                return
            }
            var context = latest.context
            let dictated: String? = if let boosting, context.field.pid == boosting.field.pid,
                                       context.field.elementHash == boosting.field.elementHash {
                boosting.text
            } else {
                nil
            }
            var lookup = WriteRange.lookup(context, dictated: dictated)
            // The paragraph runs past the read window: read the field wider rather than replace
            // only the part of it that was read.
            if lookup == .needsWiderRead {
                if let wide = await readWider(context.field, WriteRange.widerReadLimits), !wide.hasMarkedText {
                    context = wide
                    lookup = WriteRange.lookup(wide, dictated: dictated)
                }
            }
            guard let range = lookup.range else {
                NSSound.beep()
                return
            }
            let policy = policies.resolve(bundleID: context.app.bundleID, urlHost: context.urlHost).policy
            target = Target(context: context, geometry: latest.geometry, range: range, policy: policy)
            spoken = nil
            open(mode: boosting != nil ? .polish : WriteModeGuess.guess(range.source), caret: latest.geometry.caretRect)
        }
    }

    /// Waits up to `freshReadWait` for a read of the field taken after `since` (it has what was typed
    /// right before the press), else takes the latest one.
    private func freshRead(since: ContinuousClock.Instant) async -> (context: TextContext, geometry: CaretGeometry)? {
        let deadline = since + Self.freshReadWait
        while ContinuousClock.now < deadline,
              coordinator.latestSuggestionContext.map({ $0.context.capturedAt < since }) ?? true {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return coordinator.latestSuggestionContext.map { ($0.context, $0.geometry) }
    }

    /// Shows the panel for `target` and starts the first draft.
    private func open(mode: WriteMode, caret: CGRect) {
        guard let target else { return }
        self.mode = mode
        refinements = []
        previousDraft = nil
        useBaseModel = false
        pauseFocus()
        // The draft plays the suggestions' pop-in: this app's own look, else Appearance.
        let settings = models.settings
        panel.effectLook = settings.effectsForWriteForMe
            ? GhostTweaks(target.policy).appearance ?? settings.appearance : nil
        panel.show(near: caret, mode: mode, original: target.range.source, spoken: spoken?.text)
        generate()
    }

    // MARK: Voice instructions (experimental)

    /// A spoken instruction for the focused field: applied to the selection (`transform`), or with
    /// nothing selected, a description of what to write at the caret (`write`). The transcript is
    /// never inserted; the draft shows in the panel as usual. Returns what happened, for the pill.
    func startVoice(instruction: String) async -> VoiceInstructionDelivery {
        let early = VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: panel.isVisible,
                                                     writeBusyNow: isBusy, selectedText: nil)
        if case .refuse = early { return early }
        starting = true
        defer { starting = false }
        coordinator.requestContextNow()
        guard let latest = await freshRead(since: .now), !latest.context.hasMarkedText else {
            return .refuse(.noField)
        }
        let context = latest.context
        let delivery = VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: panel.isVisible,
                                                        writeBusyNow: inserting, selectedText: context.selectedText)
        let range: WriteRange
        let mode: WriteMode
        switch delivery {
        case .transformSelection:
            mode = .transform
            range = WriteRange(source: context.selectedText, deleteBackward: 0, deleteForward: 0,
                               replacesSelection: true, textBefore: context.before, textAfter: context.after)
        case .writeAtCaret:
            mode = .write
            range = .atCaret(before: context.before, after: context.after)
        case .refine, .refuse:
            return delivery
        }
        let policy = policies.resolve(bundleID: context.app.bundleID, urlHost: context.urlHost).policy
        target = Target(context: context, geometry: latest.geometry, range: range, policy: policy,
                        instruction: instruction)
        spoken = SpokenInstruction(text: instruction, kind: .initial)
        Self.log("voice \(mode.rawValue) instruction=\(instruction.count) selection=\(context.selectedText.count)")
        open(mode: mode, caret: latest.geometry.caretRect)
        return delivery
    }

    /// A spoken refinement for the open panel: run at once, or left in the refine box while a draft
    /// is still coming (Return runs it).
    func refineByVoice(_ text: String) -> VoiceInstructionDelivery {
        let delivery = VoiceInstructionRoute.atDelivery(target: .panel, panelOpenNow: panel.isVisible,
                                                        writeBusyNow: false, selectedText: nil)
        guard delivery == .refine else { return delivery }
        if panel.isGenerating {
            panel.fillRefine(text)
            return delivery
        }
        let draft = panel.currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        spoken = SpokenInstruction(text: text, kind: .refinement(baseRefinements: refinements,
                                                                 baseDraft: draft.isEmpty ? nil : draft))
        panel.showSpoken(text)
        writePanel(didRefine: text, currentDraft: draft)
        return delivery
    }

    func writePanel(didEditSpoken instruction: String) {
        guard let spoken, let rerun = spoken.rerun(with: instruction) else { return }
        self.spoken?.text = instruction
        if let new = rerun.instruction { target?.instruction = new }
        refinements = rerun.refinements
        previousDraft = rerun.previousDraft
        generate()
    }

    // MARK: Drafts

    /// "Use a separate writing model" is off in Settings → Models: drafts come from the Language Model.
    private var writingModelOff: Bool { !models.settings.useWritingModel }

    /// The use whose source drafts come from: the Language Model's unless a separate writing model is on.
    private var sourceUse: ModelUse { writingModelOff || useBaseModel ? .autocomplete : .writing }

    /// The draft's writer: the source use's endpoint when it is chosen and answering, else its local
    /// model. The Language Model's host serves drafts whenever it holds the model to write with, so
    /// nothing loads twice.
    private func pickWriter() -> (any WriteGenerating)? {
        guard let target else { return nil }
        // Shell prompts never reach here (no prose range there); an app forced to local stays local.
        if !useBaseModel, target.policy.engineOverride != .local,
           let endpoint = router.slot(sourceUse).available {
            return endpoint
        }
        if useBaseModel || writingModelOff || models.writingModelIsLanguageModel {
            let coordinator = self.coordinator
            let id = coordinator.currentRequestID
            return models.languageModelWriter(currentID: { id })
        }
        return models.instructWriter()
    }

    /// Drafts would come from a local base Language Model, which isn't trained to follow
    /// instructions: ask before using it.
    private func needsBaseWarning(_ target: Target) -> Bool {
        guard writingModelOff, !useBaseModel, models.languageModelIsBase else { return false }
        let endpointServes = target.policy.engineOverride != .local && router.slot(.autocomplete).available != nil
        return !endpointServes
    }

    private func generate() {
        guard let target else { return }
        generation?.cancel()
        writer?.cancelWrites()
        if needsBaseWarning(target) {
            panel.showBaseLanguageModel()
            return
        }
        guard let writer = pickWriter() else {
            let endpointDown = router.slot(sourceUse).unavailable
            // With writing models off, don't offer one: the autocomplete model is what's missing.
            if writingModelOff && !useBaseModel {
                panel.showNoAutocompleteModel(endpointDown: endpointDown)
            } else {
                panel.showNoModel(canTryBase: models.engine != nil, endpointDown: endpointDown)
            }
            return
        }
        self.writer = writer
        draftNumber += 1
        let number = draftNumber
        // Only a separate writing model's own host may still need loading.
        let local = writer is LocalWriter && !useBaseModel && !writingModelOff && !models.writingModelIsLanguageModel
        let working = Self.workingLabel(mode)
        panel.showWorking(working)
        let request = (mode: mode, refinements: refinements, previous: previousDraft)
        let (shape, shapeText) = WriteShapeChoice.resolve(
            policy: target.policy, library: models.settings.writeShapes, mode: mode,
            surface: target.context.metadata.surface, urlHost: target.context.urlHost,
            bundleID: target.context.app.bundleID, isAIChatInput: target.context.metadata.isAIChatInput)
        // Only a prompt-aware polish ends with a gap note; it never goes into the draft.
        let splitsGaps = mode == .polish && shape == .aiPrompt
        // Voice drafts: in the script the user writes Chinese in (the spoken words and the selection
        // say which; models often answer in Simplified).
        let scriptSource = target.instruction.map { target.range.source + $0 }
        let traditional = scriptSource != nil && DictationController.prefersTraditional()
        let fitScript: @Sendable (String) -> String = { text in
            guard let scriptSource else { return text }
            return VoiceInstruction.matchScript(text, source: scriptSource, prefersTraditional: traditional)
        }
        let viaEndpoint = writer is EndpointCompletionEngine
        let use = sourceUse
        generation = Task { [weak self] in
            guard let self else { return }
            if local, await !self.models.writeModelReady() {
                self.panel.showWorking("Loading the writing model (the first draft takes a little longer)…")
            }
            let input = await coordinator.writeInput(context: target.context, textBefore: target.range.textBefore,
                                                     textAfter: target.range.textAfter)
            // A spoken description is the write's source; a transform keeps the selection as source.
            let source = request.mode == .write ? target.instruction ?? target.range.source : target.range.source
            let write = WriteRequest(id: RequestID(UInt64(number)), mode: request.mode, source: source,
                                     shape: shape, refinements: request.refinements,
                                     previousDraft: request.previous, context: input, shapeText: shapeText,
                                     instruction: request.mode == .transform ? target.instruction : nil)
            do {
                let raw = try await writer.write(write) { [weak self] partial in
                    Task { @MainActor in
                        guard let self, self.draftNumber == number, self.finishedDraft != number else { return }
                        self.panel.showWorking(working)
                        self.panel.showDraft(fitScript(splitsGaps ? DraftGaps.split(partial).draft : partial),
                                             finished: false)
                    }
                }
                guard !Task.isCancelled, draftNumber == number else { return }
                if viaEndpoint { router.noteSuccess(use) }
                finishedDraft = number
                let (split, gaps) = splitsGaps ? DraftGaps.split(raw) : (raw, nil)
                let text = fitScript(split)
                if text.isEmpty {
                    panel.showError("The model returned nothing. Try again or refine the request.")
                } else {
                    panel.showDraft(text, finished: true, gaps: gaps)
                }
            } catch is CancellationError {
                // Cancelled by something other than a newer draft or closing the panel: say so
                // rather than keep showing "Writing…".
                guard !Task.isCancelled, draftNumber == number else { return }
                finishedDraft = number
                panel.showError("The draft was interrupted. Try again.")
            } catch {
                guard draftNumber == number else { return }
                // The endpoint failed: skip it for a while and write this draft locally instead.
                if viaEndpoint, !Task.isCancelled {
                    router.noteFailure(use)
                    generate()
                    return
                }
                finishedDraft = number
                panel.showError("Couldn't write a draft: \(Self.describe(error))")
            }
        }
    }

    private static func workingLabel(_ mode: WriteMode) -> String {
        switch mode {
        case .write: "Writing…"
        case .polish: "Polishing…"
        case .transform: "Rewriting…"
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case WriteError.failed(let message): message
        case WriteError.noInstructModel: "no instruct model"
        default: String(describing: error)
        }
    }

    // MARK: Panel

    func writePanel(didChooseMode mode: WriteMode) {
        self.mode = mode
        refinements = []
        previousDraft = nil
        generate()
    }

    func writePanel(didRefine request: String, currentDraft: String) {
        refinements.append(request)
        let draft = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        previousDraft = draft.isEmpty ? nil : draft
        generate()
    }

    func writePanelDidCancel() {
        close()
        if let target { reactivate(target.context.app) }
        target = nil
        spoken = nil
    }

    func writePanelDownloadModel() {
        downloadModel()
        writePanelDidCancel()
    }

    func writePanelSetWritingModel() {
        writePanelDidCancel()
        setWritingModel()
    }

    func writePanelTryBaseModel() {
        useBaseModel = true
        generate()
    }

    func writePanel(didAccept draft: String) {
        guard let target else { return }
        // Before focus tracking resumes: its first read of the field arrives right after this, and
        // with nothing changed in the field it is the only one (repeats are not emitted).
        let closedAt = ContinuousClock.now
        close()
        self.target = nil
        spoken = nil
        let text = target.range.insertion(for: draft)
        reactivate(target.context.app)
        inserting = true
        Task {
            await insert(text, into: target, since: closedAt)
            inserting = false
        }
    }

    private func close() {
        generation?.cancel()
        generation = nil
        writer?.cancelWrites()
        writer = nil
        panel.hide()
        resumeFocus()
    }

    private func reactivate(_ app: AppIdentity) {
        NSRunningApplication(processIdentifier: app.pid)?.activate()
    }

    // MARK: Insertion

    /// What `awaitRead` saw of the field, for the log (lengths only, never the text).
    private struct ReadTrace {
        var reads = 0
        var lastBefore = 0
        var lastAfter = 0
        var line: String { "reads=\(reads) before=\(lastBefore) after=\(lastAfter)" }
    }

    /// Waits for a read of `field` taken after `since` that satisfies `done` (asking for reads every
    /// 30 ms); nil after `timeout`. With `settle`, a read also counts once the field has differed from
    /// `changedFrom` and then stayed the same for `settle`, if `settled` accepts it.
    private func awaitRead(of field: FieldID, since: ContinuousClock.Instant, timeout: Duration,
                           trace: inout ReadTrace, until done: (TextContext) -> Bool,
                           changedFrom start: TextContext? = nil, settle: Duration? = nil,
                           settled: (TextContext) -> Bool = { _ in false }) async -> TextContext? {
        let deadline = ContinuousClock.now + timeout
        var stable: (text: String, since: ContinuousClock.Instant)?
        while ContinuousClock.now < deadline {
            if let latest = coordinator.latestSuggestionContext?.context, latest.capturedAt >= since,
               latest.field.pid == field.pid, latest.field.elementHash == field.elementHash {
                trace.reads += 1
                trace.lastBefore = latest.before.count
                trace.lastAfter = latest.after.count
                if done(latest) { return latest }
                if let settle, let start {
                    let text = latest.before + "\u{0}" + latest.after
                    if text != start.before + "\u{0}" + start.after {
                        if stable?.text != text { stable = (text, ContinuousClock.now) }
                        if let stable, ContinuousClock.now - stable.since >= settle, settled(latest) { return latest }
                    }
                }
            }
            coordinator.requestContextNow()
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }

    /// Selects the range so the paste replaces it in one step. Where the host won't take the selection,
    /// deletes it with key presses instead and waits until the field shows it gone. Then pastes the draft, and keeps the draft
    /// on the clipboard until the field shows it too. A slow host (a cold start, a long range: every
    /// character is one key press) can take longer than any fixed delay to get to the paste, and a
    /// clipboard restored before then would paste the old contents, or nothing, after the deletes.
    private func insert(_ draft: String, into target: Target, since: ContinuousClock.Instant) async {
        let field = target.context.field
        let range = target.range
        // The host takes focus back; wait for a read of the same element (its generation is new).
        var trace = ReadTrace()
        guard let fresh = await awaitRead(of: field, since: since, timeout: Self.refocusWait, trace: &trace,
                                          until: { _ in true }) else {
            Self.log("no read of the same field after refocus (latest pid match: "
                     + "\(coordinator.latestSuggestionContext?.context.field.pid == field.pid))")
            fallBackToClipboard(draft)
            return
        }
        guard Self.stillHolds(range, fresh) else {
            Self.log("field changed: selection=\(fresh.selectionLength) marked=\(fresh.hasMarkedText) "
                     + "replacesSelection=\(range.replacesSelection)")
            fallBackToClipboard(draft)
            return
        }
        let policy = target.policy
        let mode: InsertionMode = policy.insertion == .pasteMatchStyle ? .pasteMatchStyle : .paste
        var deleteForward = range.deleteForward, deleteBackward = range.deleteBackward
        if deleteForward + deleteBackward > 0 {
            let backward = range.source.prefix(range.deleteBackward).utf16.count
            let forward = range.source.suffix(range.deleteForward).utf16.count
            if let reason = await selectAroundCaret(fresh.field, backward, forward, range.source) {
                Self.log("select failed (\(reason)), deleting with keys")
                // Make sure no selection was left behind before pressing keys: a Backspace would
                // delete it and then more. Hosts that apply the range late (Electron apps) get a
                // moment to apply it and the caret's restore. A field that ends up as it was sends
                // no new read (repeats are not emitted), so the read from before still counts.
                try? await Task.sleep(for: Self.selectUndoWait)
                trace = ReadTrace()
                guard await awaitRead(of: field, since: fresh.capturedAt, timeout: Self.refocusWait, trace: &trace,
                                      until: { Self.stillHolds(range, $0) }) != nil else {
                    Self.log("field changed after select attempt: \(trace.line)")
                    fallBackToClipboard(draft)
                    return
                }
            } else {
                deleteForward = 0
                deleteBackward = 0
            }
        }
        for _ in 0..<deleteForward {
            guard inserter.pressKey(Self.forwardDeleteKeyCode, into: fresh.app) else {
                Self.log("forward delete could not be posted")
                fallBackToClipboard(draft)
                return
            }
        }
        for _ in 0..<deleteBackward {
            guard inserter.pressKey(Self.backspaceKeyCode, into: fresh.app) else {
                Self.log("backspace could not be posted")
                fallBackToClipboard(draft)
                return
            }
        }
        // No read of the field at all after the deletes (some editors swap the element when it
        // empties): paste anyway, keeping the draft on the clipboard, rather than stop after deleting.
        var unconfirmed = false
        if deleteForward + deleteBackward > 0 {
            let posted = ContinuousClock.now
            trace = ReadTrace()
            // Done when the text around the range meets at the caret, or (a host that reports the
            // emptied spot differently) once the field changed, stopped changing, and the range's text
            // is gone from the caret.
            let cleared = await awaitRead(of: field, since: posted, timeout: Self.landWait, trace: &trace,
                                          until: { range.isCleared(before: $0.before, after: $0.after) },
                                          changedFrom: fresh, settle: Self.settleWait,
                                          settled: { range.isGoneFromCaret(before: $0.before, after: $0.after) })
            if cleared == nil {
                Self.log("deletes not seen in the field: \(trace.line) expected before=\(range.textBefore.count) "
                         + "after=\(range.textAfter.count) deleted=\(range.deleteBackward)+\(range.deleteForward) "
                         + "start before=\(fresh.before.count) after=\(fresh.after.count)")
                guard trace.reads == 0 else {
                    fallBackToClipboard(draft, maybeInserted: false)
                    return
                }
                unconfirmed = true
            }
        }
        let outcome = await inserter.insertHoldingClipboard(draft, into: fresh.app, mode: mode,
                                                            chunkSize: policy.injectionChunkSize ?? 16,
                                                            workarounds: policy.insertionWorkarounds)
        if case .failed(let reason) = outcome {
            Self.log("insert failed: \(reason)")
            inserter.releaseClipboard(restore: true)
            fallBackToClipboard(draft)
            return
        }
        if unconfirmed {
            inserter.releaseClipboard(restore: false)
            // The alert takes focus: give the host time to get to the paste first.
            try? await Task.sleep(for: Self.refocusWait)
            fallBackToClipboard(draft, maybeInserted: true)
            return
        }
        let pasted = ContinuousClock.now
        trace = ReadTrace()
        guard await awaitRead(of: field, since: pasted, timeout: Self.landWait, trace: &trace,
                              until: { WriteRange.showsDraft(draft, before: $0.before) }) != nil else {
            // Maybe it went in and the field reads differently: the draft stays on the clipboard.
            Self.log("draft not seen in the field: \(trace.line) draft=\(draft.count)")
            inserter.releaseClipboard(restore: false)
            fallBackToClipboard(draft, maybeInserted: true)
            return
        }
        inserter.releaseClipboard(restore: true)
        learning?.noteDraftInserted(field: fresh.field, draft: draft)
    }

    static func stillHolds(_ range: WriteRange, _ context: TextContext) -> Bool {
        range.stillHolds(before: context.before, after: context.after, selected: context.selectedText,
                         selectionLength: context.selectionLength, markedText: context.hasMarkedText,
                         beforeIsCut: context.beforeIsCut, afterIsCut: context.afterIsCut)
    }

    /// Why an insert fell back, in perf.log while debug logging is on. Never the text.
    private static func log(_ line: String) {
        SuggestionCoordinator.perf("write-for-me " + line)
    }

    /// The field changed (or focus went elsewhere) before the draft could go in: keep the draft.
    /// `maybeInserted`: it was pasted but never showed in the field. `false` with deletes posted:
    /// the original text may be partly gone.
    private func fallBackToClipboard(_ draft: String, maybeInserted: Bool? = nil) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(draft, forType: .string)
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "The draft is on the clipboard"
        alert.informativeText = switch maybeInserted {
        case true?: "Hunch couldn't confirm the draft went in. If it isn't in the text box, paste it there."
        case false?: "The text box was slow to update, so Hunch stopped before pasting. Check the text box, "
            + "then paste the draft where you want it (Undo may bring back the original)."
        case nil: "The text box changed before Hunch could put the draft in. Paste it where you want it."
        }
        alert.addButton(withTitle: "OK")
        // A modal run while focus tracking is live can deadlock (see `SettingsWindowController`).
        pauseFocus()
        NSApp.activate()
        alert.runModal()
        resumeFocus()
    }
}
