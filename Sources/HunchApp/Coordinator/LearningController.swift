import Foundation
import HunchCore
import HunchHistory
import HunchPolicy

/// App-side glue for "learn from my writing" (design decision 7): forwards what happens in a field
/// (suggestion shown, accepted, text changed, dismissed, focus left) to the history service in
/// order, hands learned vocabulary to requests, and consolidates while the Mac is idle.
/// Records nothing unless learning is on globally and allowed for the app; blocked/secure fields
/// never produce contexts, so they never reach this type.
@MainActor
final class LearningController {
    private let service: HistoryService
    private let settings: () -> HunchSettings
    private let policies: any AppPolicyResolving
    private let feed: AsyncStream<(HistoryObservation, Date)>.Continuation
    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var field: FieldID?
    private var fieldAllowed = false
    private var lastTyping = ContinuousClock.now
    /// Words the latest request's learned bias could push, to discount their credit when kept.
    private var lastBiasWords: Set<String> = []
    private var wasEnabled = false

    static let tickInterval: Duration = .seconds(5)
    static let strengthScale: Float = 2
    /// No typing for this long counts as idle (consolidation may run).
    static let idleAfter: Duration = .seconds(120)

    private let spellChecker: LearnedWordsSpellChecker?
    private var ticks = 0

    init(service: HistoryService, settings: @escaping () -> HunchSettings, policies: any AppPolicyResolving,
         spellChecker: LearnedWordsSpellChecker? = nil) {
        self.service = service
        self.spellChecker = spellChecker
        self.settings = settings
        self.policies = policies
        let (stream, continuation) = AsyncStream<(HistoryObservation, Date)>.makeStream()
        feed = continuation
        wasEnabled = settings().learning.enabled
        // Sentences are saved whenever learning is on: learned phrases need them even with
        // "Learn writing style" off.
        let captureOn = settings().learning.enabled
        Task { await service.setStyleCaptureEnabled(captureOn) }
        // One consumer keeps observations in the order they happened; anything still queued when
        // learning is switched off is dropped.
        consumer = Task {
            for await (observation, at) in stream {
                guard settings().learning.enabled else { continue }
                await service.record(observation, at: at)
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private var enabled: Bool { settings().learning.enabled }

    private func send(_ observation: HistoryObservation) {
        guard enabled else { return }
        feed.yield((observation, Date()))
    }

    // MARK: Observations

    func noteContext(_ context: TextContext) {
        checkPendingReply(context)
        if let previous = field, previous != context.field { send(.focusLeft(field: previous)) }
        field = context.field
        if draftInField(context) {
            fieldAllowed = false
            return
        }
        let policy = policies.resolve(bundleID: context.app.bundleID, urlHost: context.urlHost).policy
        // Shell commands are not writing: never learned as words or saved as sentences.
        fieldAllowed = CodeSurfaceRules.learningAllowed(policy: policy, surface: context.metadata.surface)
            && policy.enabled && !policy.secureExcluded && context.metadata.surface != .shell
        guard fieldAllowed else { return }
        send(.textChanged(field: context.field, before: context.before,
                           appKey: AppKey.make(bundleID: context.app.bundleID, urlHost: context.urlHost)))
    }

    /// A write-for-me draft went into this field: it is model-written, so nothing in the field is
    /// learned while the draft is still there (what was typed before it was already recorded).
    func noteDraftInserted(field: FieldID, draft: String) {
        send(.focusLeft(field: field))
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftGuard = DraftGuard(pid: field.pid, element: field.elementHash,
                                head: String(text.prefix(Self.draftMarkerLength)),
                                tail: String(text.suffix(Self.draftMarkerLength)))
        if self.field?.pid == field.pid, self.field?.elementHash == field.elementHash { fieldAllowed = false }
    }

    private struct DraftGuard {
        var pid: pid_t
        var element: Int
        var head: String
        var tail: String
    }
    private var draftGuard: DraftGuard?
    static let draftMarkerLength = 48

    /// True while the context's element still holds the inserted draft; the guard ends once the
    /// draft is gone from that element (sent, deleted).
    private func draftInField(_ context: TextContext) -> Bool {
        guard let g = draftGuard, context.field.pid == g.pid, context.field.elementHash == g.element else { return false }
        let text = context.before + context.selectedText + context.after
        if text.contains(g.head) || text.contains(g.tail) { return true }
        draftGuard = nil
        return false
    }

    func noteFocusEnded() {
        if let previous = field { send(.focusLeft(field: previous)) }
        field = nil
        fieldAllowed = false
    }

    func noteShown(context: TextContext, text: String, scores: [WordScore]) {
        guard fieldAllowed, context.field == field else { return }
        let words = Set(text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { $0.lowercased() })
        send(.suggestionShown(field: context.field, before: context.before, suggestion: text, scores: scores,
                              boosted: words.intersection(lastBiasWords)))
    }

    /// Learning switched off (or Secure Input started): forget everything pending in memory.
    func settingsChanged(_ settings: HunchSettings) {
        let on = settings.learning.enabled
        defer { wasEnabled = on }
        let service = self.service
        // Learned phrases need saved sentences, so capture follows learning, not writing style.
        Task { await service.setStyleCaptureEnabled(on) }
        guard wasEnabled, !on else { return }
        noteFocusEnded()
        Task { await service.reset() }
    }

    func secureInputStarted() {
        noteFocusEnded()
        let service = self.service
        Task { await service.reset() }
    }

    func noteAccepted(_ text: String) {
        guard fieldAllowed, let field else { return }
        send(.accepted(field: field, text: text))
    }

    /// The user kept a flagged word instead of the fix. A third skip can make the word active, so
    /// the typo exemption is refreshed once the observation has been applied.
    func noteCorrectionSkipped(_ word: String) {
        guard fieldAllowed, let field, enabled else { return }
        send(.correctionSkipped(field: field, word: word))
        // The service is an actor and the feed consumer awaits each record in order, so a fire-and-forget
        // refresh could run before the skip lands; the once-a-minute refresh in tick() covers that.
        // Hop through the service once more (it processes calls in arrival order) after a short pause.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.refreshWords()
        }
    }

    /// The user cleanly rejected an automatic fix of `word` (`FixRejectionWatch`): counts as a skip,
    /// and two make the word active, so the typo exemption is refreshed like after a skip.
    func noteFixRejected(_ word: String, fix: String? = nil) {
        guard fieldAllowed, let field, enabled else { return }
        send(.fixRejected(field: field, word: word))
        if let fix { send(.slipFixRejected(field: field, fix: fix)) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.refreshWords()
        }
    }

    /// The user typed on past an automatic fix of `word` to `fix`: teaches the personal slip list
    /// (three make `fix` a word they often mistype), so the slip profile is refreshed after it lands.
    func noteFixKept(word: String, fix: String) {
        guard fieldAllowed, let field, enabled else { return }
        send(.fixKept(field: field, word: word, fix: fix))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.refreshWords()
        }
    }

    func noteCorrectionAccepted(_ word: String) {
        guard fieldAllowed, let field else { return }
        send(.correctionAccepted(field: field, word: word))
    }

    func noteDismissed() {
        guard fieldAllowed, let field else { return }
        send(.dismissed(field: field))
    }

    func noteTyping() { lastTyping = .now }

    // MARK: Using what was learned

    /// Learned vocabulary for a request; empty when learning or the strength is off.
    /// Learned vocabulary for a request. Blocked words (`avoid`) always apply — blocking is an
    /// explicit choice — while learned words only boost where learning is on and allowed.
    func bias(for before: String, appKey: String?, learningAllowed: Bool) async -> LearnedBias {
        let learning = settings().learning
        // The slider runs 0–3; the decoder's measured safe range is up to ~6 (M3 eval: no first-word
        // loss or intrusions at 6, intrusions start near 10), so Max maps to 6.
        let boost = learning.enabled && learningAllowed ? learning.strength * Self.strengthScale : 0
        var bias = await service.bias(for: before, strength: boost, appKey: appKey)
        if boost <= 0 { bias.entries = [] }
        // Learned phrases: same gates as learned words, from this app's or category's sentences.
        if learning.enabled, learningAllowed {
            let strength = LearnedBias.phraseStrength(personalize: learning.strength)
            if strength > 0 {
                bias.phrases = await service.phrases(for: before, appKey: appKey).map { .init(text: $0.text, weight: $0.weight) }
                bias.phraseStrength = bias.phrases.isEmpty ? 0 : strength
            }
        }
        lastBiasWords = Set(bias.entries.flatMap {
            $0.text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map { $0.lowercased() }
        })
        return bias
    }

    /// The few learned words worth naming to an instruct model for this text (`VocabularyGate`: a
    /// learned lead-in just typed, or the screen or sentence on the topic of the word's own sentences).
    /// Same gates as learned words in `bias`; only framers that list vocabulary (instruct) show them.
    /// With the diagnostic console open, also what the console shows: each word's reason, and every
    /// learned word usable here (to label one a suggestion brings in without the notes).
    func vocabulary(for before: String, screen: String?, appKey: String?,
                    learningAllowed: Bool) async -> (words: [String], diagnostics: LearnedNoteDiagnostics?) {
        let learning = settings().learning
        guard learning.enabled, learningAllowed, learning.strength > 0 else { return ([], nil) }
        let picks = await service.gatedVocabulary(before: before, screen: screen, appKey: appKey)
        guard DiagnosticRecorder.shared.isEnabled else { return (picks.map(\.text), nil) }
        let here = await service.learnedWordsHere(appKey: appKey)
        return (picks.map(\.text), LearnedNoteDiagnostics(picks: picks.map { .init(word: $0.text, reason: $0.reason) },
                                                          learnedHere: here))
    }

    /// Up to two of the user's earlier sentences relevant to `before`; empty when learning or the
    /// style option is off, or learning isn't allowed for this app.
    func styleExamples(for before: String, field: FieldID, appKey: String?, learningAllowed: Bool) async -> [String] {
        let learning = settings().learning
        guard learning.enabled, learning.styleExamplesEnabled, learningAllowed else { return [] }
        return await service.styleExamples(for: before, field: field, appKey: appKey, k: 2)
    }

    /// The user's handles in this app and their recently sent messages; empty where learning is
    /// off or not allowed.
    // MARK: Learned replies

    /// Learned replies work only while both "Learn words and phrases" and Suggested replies are on.
    private var repliesLearningOn: Bool {
        let s = settings()
        return s.learning.enabled && s.suggestedRepliesEnabled
    }

    /// The question sentences of their newest message on `screen` (`ReplyQuestion`); nil when my own
    /// message is the newest, or the screen says nothing about who wrote what.
    static func replyKeys(screen: String?) -> [String]? {
        guard let run = ReplyQuestion.theirNewest(screen: screen) else { return nil }
        let keys = ReplyQuestion.keySentences(run)
        return keys.isEmpty ? nil : keys
    }

    /// The reply the user last picked from the bubble (`ReplyPick`), until it is sent.
    private var pick: ReplyPick?
    /// A picked reply that was just sent, learned once the box stays empty for `sendSettle`.
    private var pendingReply: (task: Task<Void, Never>, field: FieldID, pick: ReplyPick)?
    /// A box that empties and fills up again within this long was edited (text selected and
    /// replaced), not sent.
    static let sendSettle: Duration = .seconds(3)

    /// The user picked `text` from the suggested replies bubble in `field`.
    func notePicked(_ text: String, field: FieldID) {
        pick = ReplyPick(text: text, field: field)
    }

    /// A message was sent from `context`'s box with `screen` showing what it answered: when it is the
    /// reply the user picked (or starts with it), learns it as an answer to their newest message
    /// there, once the box stays empty. Typed messages are never learned. Same gates as other
    /// learning (the app allows it, never a shell, never with a write-for-me draft in the box).
    func noteSent(_ text: String, context: TextContext, screen: String?) {
        guard let pick, pick.isAnswered(by: text, field: context.field) else { return }
        self.pick = nil
        guard repliesLearningOn, fieldAllowed, field == context.field,
              let keys = Self.replyKeys(screen: screen),
              let appKey = AppKey.make(bundleID: context.app.bundleID, urlHost: context.urlHost) else { return }
        let service = self.service
        pendingReply?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.sendSettle)
            guard !Task.isCancelled else { return }
            self?.pendingReply = nil
            await service.recordReply(keys: keys, answer: text, appKey: appKey)
        }
        pendingReply = (task, context.field, pick)
    }

    /// The box a picked reply was just "sent" from has text again: it was replaced, not sent. The
    /// pick still stands for a real send later.
    private func checkPendingReply(_ context: TextContext) {
        guard let pending = pendingReply, pending.field == context.field, !context.looksEmpty else { return }
        pending.task.cancel()
        pendingReply = nil
        pick = pending.pick
    }

    /// Learned replies for the message waiting on `screen` in `context`'s app, with its question
    /// sentences; nil when off, not allowed here, or nothing is learned for it.
    func learnedReplies(context: TextContext, screen: String?) async -> (keys: [String], suggestion: LearnedSuggestion?)? {
        guard repliesLearningOn, fieldAllowed, field == context.field, let keys = Self.replyKeys(screen: screen),
              let appKey = AppKey.make(bundleID: context.app.bundleID, urlHost: context.urlHost) else { return nil }
        return (keys, await service.learnedReplies(keys: keys, appKey: appKey))
    }

    func learnedReplyQuestions() async -> [LearnedQuestion] { await service.learnedReplyQuestions() }
    func editLearnedReplies(_ edit: @escaping @Sendable (inout LearnedReplies) throws -> Void) async throws {
        try await service.editLearnedReplies(edit)
    }

    func styleSnippets() async -> [StyleSnippet] { await service.styleSnippets() }
    func deleteSnippet(id: String) async { await service.deleteSnippet(id: id) }
    func deleteAllSnippets() async { await service.deleteAllSnippets() }

    var entryCount: Int { get async { await service.entryCount } }

    // MARK: Editing (Settings → Writing → Learned words)

    func entries() async -> [LearnedWordInfo] { await service.entries() }
    func rename(id: String, to text: String) async throws { _ = try await service.rename(id: id, to: text) ; await refreshWords() }
    func delete(id: String) async throws { try await service.delete(id: id); await refreshWords() }
    func add(_ text: String) async throws { _ = try await service.add(text: text); await refreshWords() }
    /// A word the user fixed in dictated text. Returns its id.
    @discardableResult
    func addFromDictation(_ text: String) async throws -> String {
        let id = try await service.add(text: text, origin: .dictation)
        await refreshWords()
        return id
    }
    func setBlocked(id: String, _ blocked: Bool) async throws {
        try await service.setBlocked(id: id, blocked)
        await refreshWords()
    }

    /// Keeps the typo exemption in step with edits right away.
    private func refreshWords() async {
        guard let spellChecker else { return }
        spellChecker.setLearnedWords(await service.activeWordPlaces())
        spellChecker.setTroubleWords(await service.troubleWords())
    }

    func deleteAll() async throws {
        try await service.deleteAll()
        spellChecker?.setLearnedWords(.empty)
        spellChecker?.setTroubleWords([])
    }

    /// True when the saved history couldn't be read this session (e.g. the Keychain key was
    /// unavailable); learning then stays in memory and never overwrites the file.
    var isReadOnly: Bool { get async { await service.loadState.isReadOnly } }

    /// Saves pending changes (app quit).
    func flush() async { await service.flush() }

    private func tick() {
        guard enabled else { return }
        send(.tick)
        let idle = ContinuousClock.now - lastTyping > Self.idleAfter
        let service = self.service
        let checker = spellChecker
        ticks += 1
        let refreshWords = ticks % 12 == 1   // about once a minute
        Task {
            _ = await service.consolidateIfDue(idle: idle)
            if refreshWords, let checker {
                checker.setLearnedWords(await service.activeWordPlaces())
                checker.setTroubleWords(await service.troubleWords())
            }
        }
    }
}
