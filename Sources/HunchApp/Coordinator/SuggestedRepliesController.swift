import AppKit
import HunchCore
import HunchEndpoint
import HunchEngine
import HunchHistory
import HunchInput
import HunchModels
import HunchOverlay

/// Suggested replies (Settings → General → Suggestions). When a field is empty and stays idle for
/// `suggestedRepliesDelayMs`, reads the screen fresh, asks the writing model for up to three replies
/// to the message waiting there, and shows them in a bubble above the caret. Tab highlights one,
/// Return or a click inserts it (nothing is sent), Escape closes the bubble, any other key closes it
/// and types as usual.
///
/// Nothing shows without screen text to reply to, or when the only model is a base model. Replies
/// leave this Mac only for a loopback endpoint (screen text never goes to a remote one). perf.log
/// gets counts and times only; the diagnostic console (while open) gets the prompt, the replies and
/// what became of the bubble.
@MainActor
final class SuggestedRepliesController {
    private let coordinator: SuggestionCoordinator
    private let router: EngineRouter
    private let models: ModelController
    private let screen: ScreenContextController?
    private let inserter: any TextInserting
    private let settings: () -> HunchSettings
    private let setReplyKeys: (_ shown: Bool, _ highlighted: Bool, _ arrows: ReplyArrows) -> Void
    private let bubble = SuggestedRepliesBubble()
    /// Learned replies (the user's usual answers to recurring questions); set by the app.
    var learning: LearningController?

    /// The empty field being watched, as last read.
    private var target: (context: TextContext, geometry: CaretGeometry, policy: AppPolicy)?
    private var timer: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var writer: (any WriteGenerating)?
    private var picker: ReplyPicker?
    /// Closed with Escape or answered: no more replies for this field until it has had text.
    private var doneField: FieldID?
    private var generation: UInt64 = 0
    /// Re-reads the screen while the field stays empty (`watchScreen`).
    private var watch: Task<Void, Never>?
    /// The screen text the shown (or last asked-for) replies answer.
    private var usedScreen: String?
    /// The request whose replies are being written (for the console's "what happened").
    private var asking: RequestID?
    /// The bubble on screen: its request, when it showed, and Tabs pressed since.
    private var shown: (id: RequestID, at: ContinuousClock.Instant, tabs: Int)?
    /// The screen check after a click outside the bubble (`noteMouseDown`).
    private var clickCheck: Task<Void, Never>?
    /// The last "not offered" reason logged, per field, so perf.log gets it once.
    private var loggedWhyNot: (field: FieldID, why: String)?

    /// A fresher excerpt is fetched when the cached one is older than this.
    static let excerptMaxAge: Duration = .milliseconds(1500)
    static let excerptTimeout: Duration = .seconds(2)
    static let watchInterval: Duration = .seconds(4)
    static let watchLimit: Duration = .seconds(180)

    init(coordinator: SuggestionCoordinator, router: EngineRouter, models: ModelController,
         screen: ScreenContextController?, inserter: any TextInserting, settings: @escaping () -> HunchSettings,
         setReplyKeys: @escaping (Bool, Bool, ReplyArrows) -> Void) {
        self.coordinator = coordinator
        self.router = router
        self.models = models
        self.screen = screen
        self.inserter = inserter
        self.settings = settings
        self.setReplyKeys = setReplyKeys
        bubble.onClick = { [weak self] index in self?.clicked(index) }
    }

    var isShowing: Bool { picker != nil }

    // MARK: Inputs (from the suggestion coordinator)

    /// A read of the focused field. `geometry` is where the caret is drawn (`effectGeometry`).
    func noteContext(_ context: TextContext, geometry: CaretGeometry, policy: AppPolicy, suggestionsOn: Bool) {
        if let current = target?.context.field, current != context.field {
            if current.pid == context.field.pid, current.elementHash == context.field.elementHash {
                Self.log("replies: same box, new field generation \(current.generation) → \(context.field.generation)")
            }
            doneField = nil
            end("focus moved", "closed: focus moved to another field")
            reset()
        }
        let s = settings()
        guard SuggestedRepliesGate.mayOffer(featureOn: s.suggestedRepliesEnabled, suggestionsOn: suggestionsOn,
                                            context: context, policy: policy) else {
            let why = SuggestedRepliesGate.whyNot(featureOn: s.suggestedRepliesEnabled, suggestionsOn: suggestionsOn,
                                                  context: context, policy: policy)
            // "Field has text" only on the box's first read (it changes with every key).
            let typed = why.hasPrefix("field has text")
            if loggedWhyNot?.field != context.field || (!typed && loggedWhyNot?.why != why) {
                loggedWhyNot = (context.field, why)
                Self.log("replies: not offered in \(context.app.bundleID) (\(why))")
            }
            // Text in the field: once it is empty again, replies may come back.
            if !SuggestedRepliesGate.isEmpty(context) {
                doneField = nil
                end("field got text", "closed: the field got text (typed, pasted or filled by the app)")
            } else {
                end("not allowed", "closed: replies are off or not allowed in this field now")
            }
            reset()
            target = nil
            return
        }
        target = (context, geometry, policy)
        guard doneField != context.field, picker == nil, job == nil, timer == nil, watch == nil else { return }
        scheduleAsk(trigger: "first ask")
    }

    /// Asks after the idle delay (`suggestedRepliesDelayMs`) in the empty field.
    private func scheduleAsk(trigger: String) {
        let delayMs = HunchSettings.suggestedRepliesDelayMs
        let delay = Duration.milliseconds(max(0, delayMs))
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.start(trigger: "\(trigger), after \(delayMs) ms idle in the empty field")
        }
    }

    /// How long after a click outside the bubble the screen is read again.
    static let clickCheckDelay: Duration = .milliseconds(500)

    /// A click anywhere (where the pointer is now). Outside the bubble it may have
    /// switched the conversation while the same box keeps focus (another chat in the sidebar): the
    /// screen is read again shortly after, and when it changed, the old replies close and new ones
    /// are asked for. When it didn't (a screenshot's drag, a click on nothing), they stay.
    func noteMouseDown() {
        guard picker != nil || job != nil, !bubble.contains(NSEvent.mouseLocation), let target, let screen else { return }
        let field = target.context.field, policy = target.policy
        clickCheck?.cancel()
        clickCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.clickCheckDelay)
            guard !Task.isCancelled, let self, self.target?.context.field == field,
                  let text = await screen.freshExcerptText(for: field, policy: policy, maxAge: .zero,
                                                           timeout: Self.excerptTimeout),
                  !Task.isCancelled, self.target?.context.field == field, self.picker != nil || self.job != nil,
                  !SuggestedReplies.sameScreen(text, self.usedScreen) else { return }
            Self.log("replies: screen changed after a click, asking again")
            self.end("screen changed", "closed: you clicked elsewhere and the conversation on screen changed")
            self.reset()
            self.scheduleAsk(trigger: "re-ask: a click changed the conversation on screen")
        }
    }

    /// A key the bubble didn't take: it closes, the key reaches the app. A ⌘ shortcut leaves it open
    /// (a screenshot, switching tabs); one that changes the field (⌘V) closes it through the next read.
    func noteKeyDown(_ chord: KeyChord) {
        if chord.modifiers & ChordMatcher.command != 0 { return }
        end("closed by typing", "closed: you pressed a key the bubble doesn't take, so it went to the app")
        reset()
    }

    /// Focus moved away, was blocked, or Secure Input started.
    func focusEnded() {
        end("focus left", "closed: focus left the field (or it was blocked, or Secure Input started)")
        reset()
        target = nil
        doneField = nil
    }

    /// A key the bubble took (from the keyboard monitor).
    func handle(_ key: ReplyKey) {
        guard var picker else { return setReplyKeys(false, false, []) }
        switch key {
        case .next, .step:
            if case .step(let forward) = key { picker.step(forward: forward) } else { picker.next() }
            shown?.tabs += 1
            self.picker = picker
            bubble.setHighlight(picker.highlighted)
            // The highlighted chip grows, so the chips may wrap differently: the arrows follow.
            let a = bubble.arrangement
            setReplyKeys(true, picker.highlighted != nil,
                         ReplyArrows(rawValue: (a.stacked ? ReplyArrows.vertical.rawValue : 0)
                                     | (a.sideBySide ? ReplyArrows.horizontal.rawValue : 0)))
        case .insert:
            guard let text = picker.chosen, let index = picker.highlighted else { return }
            insert(text, index: index, how: "Return")
        case .dismiss:
            end("closed with Esc", "closed with Escape")
            doneField = target?.context.field
            reset()
        }
    }

    // MARK: Replies

    /// Asks for replies to the screen as it is now (`screenText`: a read just taken by the watch).
    /// A bubble already showing stays until the new replies replace it.
    /// `trigger` says why it asks, for the console.
    private func start(screenText: String? = nil, trigger: String) {
        guard let target else { return }
        let field = target.context.field
        guard let writer = pickWriter(target.policy) else {
            Self.log("replies: no instruct model")
            return
        }
        self.writer = writer
        generation &+= 1
        let number = generation
        let id = RequestID(UInt64(number))
        asking = id
        let s = settings()
        let length = target.policy.length ?? s.length
        let screenTokens = HunchSettings.suggestedRepliesScreenTokens
        let started = ContinuousClock.now
        job = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == number {
                    self.job = nil
                    self.watchScreen()
                }
            }
            let read: ScreenContextController.FreshRead?
            if let screenText {
                read = .init(text: screenText, fetched: true, age: .zero, waited: .zero)
            } else {
                read = await self.screen?.freshExcerpt(for: field, policy: target.policy,
                                                       maxAge: Self.excerptMaxAge, timeout: Self.excerptTimeout)
            }
            guard let read, !read.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Self.log("replies: no screen text")
                if self.asking == id { self.asking = nil }
                return
            }
            let text = read.text
            guard !Task.isCancelled, self.generation == number, self.target?.context.field == field else { return }
            self.usedScreen = text
            let learned = await self.learning?.learnedReplies(context: target.context, screen: text)
            guard !Task.isCancelled, self.generation == number, self.target?.context.field == field else { return }
            let learnedLine = Self.describeLearned(learned)
            // A clear habit: the user's usual answers, without asking the model.
            if let suggestion = learned?.suggestion, suggestion.skipModel, let now = self.target {
                self.asking = nil
                let total = SuggestionCoordinator.ms(since: started)
                Self.log("replies: \(suggestion.replies.count) learned in \(total) ms, model not asked")
                Self.noteLearnedOnly(id, context: target.context, items: [
                    .init("Why it asked", trigger),
                    .init("Learned replies", learnedLine),
                    .init("To the bubble", "\(total) ms from asking"),
                ])
                self.end("replaced", "replaced: the screen changed and new replies took its place")
                self.show(suggestion.replies, at: now.geometry, id: id)
                return
            }
            let learnedReplies = learned?.suggestion?.replies ?? []
            var input = await self.coordinator.writeInput(context: target.context, textBefore: "", textAfter: "")
            input.screenContext = text
            input.screenTokenLimit = screenTokens
            var request = WriteRequest(id: id, mode: .write, source: "", shape: .message, context: input)
            request.replies = ReplyRequest(length: length)
            request.replies?.learned = learnedReplies
            let modelStarted = ContinuousClock.now
            do {
                let raw = try await writer.write(request) { _ in }
                guard !Task.isCancelled, self.generation == number, let now = self.target,
                      now.context.field == field else { return }
                self.asking = nil
                let parsed = SuggestedReplies.parse(raw)
                // A weak last reply (the model nearly stopped before it, or was much less sure of it).
                let (modelReplies, dropped) = ReplyScoring.keep(parsed, scores: (writer as? LocalWriter)?.lastReplyScores ?? [])
                let replies = SuggestedReplies.merge(learned: learnedReplies, model: modelReplies)
                let total = SuggestionCoordinator.ms(since: started)
                let model = SuggestionCoordinator.ms(since: modelStarted)
                let screenMs = Int(read.waited / .milliseconds(1)), age = Int(read.age / .milliseconds(1))
                Self.log("replies: \(replies.count)\(dropped == nil ? "" : " (1 dropped)") in \(total) ms (screen \(screenMs) ms "
                         + "\(read.fetched ? "fresh" : "cached"), age \(age) ms, \(text.count) chars; model \(model) ms)"
                         + (screenText == nil ? "" : " re-ask"))
                Self.noteBubble(id, [
                    .init("Why it asked", trigger),
                    .init("Screen read", "\(read.fetched ? "read now" : "recent read reused"), \(age) ms old, "
                          + "\(screenMs) ms waited, \(text.count) characters before the token limit"),
                    .init("Your sent messages", read.sent.map { s in
                        "\(s.remembered) remembered for this app; \(s.confirmed) matched on screen (labeled Me), "
                            + "\(s.vetoed) Me label\(s.vetoed == 1 ? "" : "s") taken off below them"
                    } ?? "not checked (re-ask with the screen already read)"),
                    .init("Learned replies", learnedLine),
                    .init("Model", "\(model) ms (waiting for the model, reading the prompt and writing)"),
                    .init("To the bubble", "\(total) ms from asking"
                          + (screenText == nil ? " (plus the \(HunchSettings.suggestedRepliesDelayMs) ms idle wait)" : "")),
                    .init("Dropped", dropped.map { "reply \(parsed.count), \"\($0.reply)\" (\(ReplyScoring.describe($0))): "
                        + "the model nearly stopped before it or was much less sure of it" } ?? "nothing"),
                ])
                if replies.isEmpty {
                    self.end("replaced", "closed: the screen changed and nothing new awaited a reply")
                    self.hideBubble()
                    Self.noteFate(id, .replies(summary: "no bubble",
                                               detail: "no bubble: the model found nothing waiting for a reply"))
                } else {
                    self.end("replaced", "replaced: the screen changed and new replies took its place")
                    self.show(replies, at: now.geometry, id: id)
                }
            } catch {
                // Cancelled by a key, a focus change or a re-ask: `end` already noted why.
                guard !Task.isCancelled, self.generation == number else { return }
                if self.asking == id { self.asking = nil }
                Self.log("replies: failed (\(type(of: error)))")
                Self.noteFate(id, .replies(summary: "failed", detail: "failed: \(type(of: error))"))
            }
        }
    }

    /// While the field stays empty, re-reads the screen every `watchInterval` (for `watchLimit`) and
    /// asks again once the conversation changed and then held still for one more read (a reply that
    /// is still streaming in is waited out). Text recognition varies a little from read to read, so
    /// "changed" means the newest words differ, not any character (`SuggestedReplies.sameScreen`).
    private func watchScreen() {
        guard watch == nil, let target, doneField != target.context.field, let screen else { return }
        let field = target.context.field, policy = target.policy
        watch = Task { [weak self] in
            var pending: String?
            let until = ContinuousClock.now + Self.watchLimit
            while ContinuousClock.now < until {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled, let self, self.target?.context.field == field else { return }
                guard let text = await screen.freshExcerptText(for: field, policy: policy, maxAge: .zero,
                                                               timeout: Self.excerptTimeout),
                      !Task.isCancelled else { continue }
                if SuggestedReplies.sameScreen(text, self.usedScreen) {
                    pending = nil
                    continue
                }
                let similarity = self.usedScreen.map { SuggestedReplies.screenSimilarity(text, $0) } ?? 0
                guard let earlier = pending, SuggestedReplies.sameScreen(text, earlier) else {
                    pending = text
                    continue
                }
                // Don't swap the replies under a highlight the user is moving.
                if self.picker?.highlighted != nil { continue }
                let score = String(format: "%.2f", similarity)
                Self.log("replies: screen changed (similarity \(score)), asking again")
                self.watch = nil
                self.start(screenText: text, trigger: "re-ask: the screen changed (newest words \(score) alike, "
                           + "below 0.75) and held still for one more read")
                return
            }
            self?.watch = nil
        }
    }

    private func show(_ replies: [String], at geometry: CaretGeometry, id: RequestID) {
        let picker = ReplyPicker(replies: replies)
        self.picker = picker
        shown = (id, ContinuousClock.now, 0)
        Self.noteFate(id, .replies(summary: "shown \(replies.count)", detail: "\(replies.count) shown, still open"))
        // The replies pop in like suggestions: this app's own look, else Appearance.
        let s = settings()
        bubble.effectLook = s.effectsForQuickReplies
            ? target.flatMap { GhostTweaks($0.policy).appearance } ?? s.appearance : nil
        bubble.show(replies, highlighted: nil, geometry: geometry, layout: s.suggestedRepliesLayout)
        setReplyKeys(true, false, [])
    }

    private func clicked(_ index: Int) {
        guard let picker, picker.replies.indices.contains(index) else { return }
        insert(picker.replies[index], index: index, how: "a click")
    }

    private func insert(_ text: String, index: Int, how: String) {
        if let shown {
            let tabs = shown.tabs == 1 ? "1 Tab" : "\(shown.tabs) Tabs"
            end("inserted #\(index + 1)", "inserted reply \(index + 1) of \(picker?.replies.count ?? 0) with \(how) "
                + "after \(tabs)")
        }
        guard let target else { return reset() }
        doneField = target.context.field
        learning?.notePicked(text, field: target.context.field)
        reset()
        let policy = target.policy, app = target.context.app
        let inserter = self.inserter
        Self.log("replies: inserting #\(index + 1) len=\(text.count)")
        Task {
            let outcome = await inserter.insert(text, into: app, mode: policy.insertion,
                                                chunkSize: policy.injectionChunkSize ?? 16,
                                                workarounds: policy.insertionWorkarounds)
            if case .failed = outcome { Self.log("replies: insert failed") }
        }
    }

    /// Notes what became of the bubble on screen (or the replies being written), once: perf.log
    /// gets `summary` and how long it was up, the console's record the full `detail`.
    private func end(_ summary: String, _ detail: String) {
        if let shown {
            self.shown = nil
            let up = String(format: "%.1f s", Double((ContinuousClock.now - shown.at) / .milliseconds(100)) / 10)
            let tabs = summary.hasPrefix("inserted") ? "" : ", \(shown.tabs) Tab\(shown.tabs == 1 ? "" : "s")"
            Self.log("replies: \(summary) after \(up)\(tabs)")
            Self.noteFate(shown.id, .replies(summary: summary, detail: "\(detail), \(up) after it showed\(tabs)"))
        }
        if let asking, summary != "replaced" {
            self.asking = nil
            Self.log("replies: cancelled before ready (\(summary))")
            Self.noteFate(asking, .replies(summary: "cancelled", detail: "cancelled before the replies were ready: \(detail)"))
        }
    }

    /// Hides the bubble and stops any timer or generation.
    private func reset() {
        end("closed", "closed")
        clickCheck?.cancel()
        timer?.cancel()
        timer = nil
        if job != nil {
            job?.cancel()
            job = nil
            writer?.cancelWrites()
        }
        watch?.cancel()
        watch = nil
        usedScreen = nil
        generation &+= 1
        hideBubble()
    }

    private func hideBubble() {
        if picker != nil {
            picker = nil
            bubble.hide()
        }
        setReplyKeys(false, false, [])
    }

    // MARK: Model

    /// The model that writes replies: the writing source's loopback endpoint when chosen and
    /// answering, else its local model. Nil when that model is a base model or missing.
    private func pickWriter(_ policy: AppPolicy) -> (any WriteGenerating)? {
        let s = models.settings
        let use: ModelUse = s.useWritingModel ? .writing : .autocomplete
        let config = s.useWritingModel ? s.writeEndpoint : s.endpoint
        if policy.engineOverride != .local, let endpoint = router.slot(use).available,
           let config, EndpointURLPolicy.isLoopback(config.baseURL) {
            return endpoint
        }
        if !s.useWritingModel || models.writingModelIsLanguageModel {
            guard !models.languageModelIsBase else { return nil }
            let coordinator = self.coordinator
            let id = coordinator.currentRequestID
            return models.languageModelWriter(currentID: { id })
        }
        return models.instructWriter()
    }

    /// Why replies can't show with these settings, for Settings; nil when they can.
    func blockedReason(_ s: HunchSettings) -> String? {
        if !s.screenContextEnabled { return "Needs screen context (Settings → Screen) to see the message you're replying to." }
        if s.useWritingModel {
            return models.instructEntry() == nil ? "Needs an instruct writing model (Settings → Models)." : nil
        }
        return models.languageModelIsBase
            ? "Needs an instruct model: the Language Model is a base model. Turn on a separate writing model in Settings → Models."
            : nil
    }

    private static func log(_ line: String) { SuggestionCoordinator.perf(line) }

    /// The console's "what happened" for request `id` (no-op while the console is closed).
    private static func noteFate(_ id: RequestID, _ fate: DiagnosticFate) {
        guard DiagnosticRecorder.shared.isEnabled else { return }
        DiagnosticRecorder.shared.update(requestKey: id.raw, kind: .suggestedReplies) { $0.fate = fate }
    }

    /// What learned replies found for the message, for the console.
    static func describeLearned(_ learned: (keys: [String], suggestion: LearnedSuggestion?)?) -> String {
        guard let learned else {
            return "not used: off (needs Learn words and phrases), not allowed in this app, or no message of theirs "
                + "is the newest on screen"
        }
        let asked = learned.keys.map { "\"\(String($0.prefix(80)))\"" }.joined(separator: " / ")
        guard let s = learned.suggestion else { return "nothing learned yet for their question \(asked)" }
        let list = s.replies.map { "\"\($0)\"" }.joined(separator: ", ")
        let how = s.skipModel ? "a clear habit, so the model was not asked"
            : "not a clear habit yet (needs \(LearnedReplies.casesToSkip)+ sends, \(Int(LearnedReplies.coverageToSkip * 100))% "
                + "covered), so they go first and the model was told about them"
        return "\(list) for \(asked) (\(String(format: "%.2f", s.similarity)) alike; \(s.cases) send\(s.cases == 1 ? "" : "s"), "
            + "\(Int((s.coverage * 100).rounded()))% covered): \(how)"
    }

    /// Starts a console record for replies shown without the model (there is no prompt to record).
    private static func noteLearnedOnly(_ id: RequestID, context: TextContext, items: [DiagnosticSection.Item]) {
        guard DiagnosticRecorder.shared.isEnabled else { return }
        _ = DiagnosticRecorder.shared.record(DiagnosticRecord(
            requestKey: id.raw, kind: .suggestedReplies, appName: context.app.localizedName, domain: context.urlHost,
            model: "learned replies (no model)", sections: [DiagnosticSection("Bubble", items)]))
    }

    /// Adds the "Bubble" section (why it asked, the screen read, timings) to request `id`'s record.
    private static func noteBubble(_ id: RequestID, _ items: [DiagnosticSection.Item]) {
        guard DiagnosticRecorder.shared.isEnabled else { return }
        DiagnosticRecorder.shared.update(requestKey: id.raw, kind: .suggestedReplies) { record in
            record.sections.insert(DiagnosticSection("Bubble", items), at: 0)
        }
    }
}

/// What the General pane shows under "Quick replies" when they can't work (set by the app).
@MainActor @Observable
final class SuggestedRepliesStatus {
    static let shared = SuggestedRepliesStatus()
    var blockedReason: String?
}
