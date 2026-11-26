import Foundation
import HunchCore

/// What the app observed. The service decides nothing about whether recording is allowed; the
/// caller must not send observations from secure fields or when learning is off.
public enum HistoryObservation: Sendable {
    /// `boosted` lists normalized (lowercased, trimmed) words the decoder was biased toward in
    /// this suggestion; their credit is discounted when the user confirms them.
    case suggestionShown(field: FieldID, before: String, suggestion: String, scores: [WordScore],
                         boosted: Set<String> = [])
    case accepted(field: FieldID, text: String)
    /// `appKey` (see `AppKey`) labels saved style snippets and credits learned words to an app.
    case textChanged(field: FieldID, before: String, appKey: String? = nil)
    case dismissed(field: FieldID)
    /// The user kept a flagged word instead of taking the spelling fix.
    case correctionSkipped(field: FieldID, word: String)
    /// The user cleanly rejected an automatic fix and kept the word.
    case fixRejected(field: FieldID, word: String)
    /// The user typed `word` and kept the automatic fix `fix` (personal slip list).
    case fixKept(field: FieldID, word: String, fix: String)
    /// An automatic fix to `fix` was cleanly rejected (personal slip list).
    case slipFixRejected(field: FieldID, fix: String)
    case correctionAccepted(field: FieldID, word: String)
    case focusLeft(field: FieldID)
    case tick
}

/// Owns the vocabulary: runs the outcome tracker, applies events, answers bias queries, and
/// saves (debounced) and consolidates it.
public actor HistoryService {
    private let store: EncryptedHistoryStore
    private let saveDelay: Duration
    private let scorer = VocabularyScorer()
    private var model = VocabularyModel()
    private var tracker: OutcomeTracker
    private var loaded = false
    /// How the store load went; `isReadOnly` means saving is refused for this session.
    public private(set) var loadState: HistoryLoadState = .noFile
    private var dirty = false
    private var changedSinceConsolidation = false
    private var saveTask: Task<Void, Never>?
    private var builder: BiasBuilder?
    /// Learned phrases indexes, one per category (or per app key for places in no category),
    /// each with the IDs of the sentences it was built from.
    private var phraseModels: [String: (ids: [String], model: PhraseModel)] = [:]
    /// Rebuilds of a group's index started after a sentence was saved, by group.
    private var phraseWarmTasks: [String: Task<Void, Never>] = [:]
    private let phraseWarmDelay: Duration
    private var builtAt = Date.distantPast
    private var styleCaptureEnabled = false
    private var styleFields: [FieldID: StyleFieldState] = [:]
    private var styleAccepts: [FieldID: (text: String, at: Date)] = [:]
    private var stylePins: [FieldID: [String]] = [:]
    /// The app key last seen for each field, used to credit learned words to where they were typed.
    private var fieldApps: [FieldID: String] = [:]
    /// Last text seen per field, to notice a sent message (the field empties after typing).
    /// Messages the user sent recently, per app key; memory only.
    /// "Is this word a typo of a real word?" (true/false, nil = unknown). When set, ordinary typing
    /// never teaches typos ("dont"); names and terms the dictionary lacks ("hunch") answer
    /// false and stay learnable. May block briefly (bounded) on the caller's thread, so it must
    /// never wait on this actor.
    private var spelling: (@Sendable (String) -> Bool?)?
    /// The user's app categories, read on each query (cheap; the source is lock-guarded).
    private var categories: @Sendable () -> AppCategories = { AppCategories() }

    public init(store: EncryptedHistoryStore, saveDelay: Duration = .seconds(20),
                settleInterval: TimeInterval = 10, phraseWarmDelay: Duration = .seconds(1)) {
        self.store = store
        self.saveDelay = saveDelay
        self.phraseWarmDelay = phraseWarmDelay
        tracker = OutcomeTracker(settleInterval: settleInterval)
    }

    public func setSpelling(_ check: (@Sendable (String) -> Bool?)?) { spelling = check }

    /// "Is this word most likely the user's own typo?" (true/false, nil = unknown). A word kept over
    /// fixes that would become active is blocked as a likely typo instead
    /// (`VocabularyModel.blockIfLikelyTypo`); consolidation checks the active words. Same threading
    /// rules as `spelling`.
    private var likelyTypo: (@Sendable (String) -> Bool?)?

    public func setLikelyTypo(_ check: (@Sendable (String) -> Bool?)?) { likelyTypo = check }

    /// Where app categories come from. Apps in one category share saved sentences and
    /// learned-word strength.
    public func setAppCategories(_ provider: @escaping @Sendable () -> AppCategories) {
        categories = provider
        stylePins = [:]
    }

    /// Reads the store (once). Called lazily; call it at launch to avoid first-use latency.
    public func load() {
        guard !loaded else { return }
        loaded = true
        let r = store.loadResult()
        model = r.model
        loadState = r.state
        if r.state == .loadedLegacyFormat { dirty = true; scheduleSave() }   // rewrite with AAD
    }

    public var entryCount: Int {
        load()
        return model.entries.count
    }

    public func record(_ observation: HistoryObservation, at now: Date = Date()) {
        load()
        var events: [LearningEvent]
        switch observation {
        case let .suggestionShown(field, before, suggestion, scores, boosted):
            events = tracker.suggestionShown(field: field, before: before, suggestion: suggestion,
                                             scores: scores, boosted: boosted, at: now)
        case let .accepted(field, text):
            if styleCaptureEnabled { styleAccepts[field] = (text, now) }
            events = tracker.accepted(field: field, text: text, at: now)
        case let .textChanged(field, before, appKey):
            if let appKey { fieldApps[field] = appKey }
            observeStyle(field: field, text: before, appKey: appKey, at: now)
            events = tracker.textChanged(field: field, before: before, at: now)
        case let .dismissed(field): events = tracker.dismissed(field: field, at: now)
        case let .focusLeft(field):
            leaveStyleField(field, at: now)
            events = tracker.focusLeft(field: field, at: now)
        case .tick: events = tracker.tick(at: now)
        case let .correctionSkipped(field, word): events = [LearningEvent(field: field, kind: .correctionSkipped(word: word))]
        case let .fixRejected(field, word): events = [LearningEvent(field: field, kind: .fixRejected(word: word))]
        case let .fixKept(field, word, fix): events = [LearningEvent(field: field, kind: .fixKept(word: word, fix: fix))]
        case let .slipFixRejected(field, fix): events = [LearningEvent(field: field, kind: .slipFixRejected(fix: fix))]
        case let .correctionAccepted(field, word): events = [LearningEvent(field: field, kind: .correctionAccepted(word: word))]
        }
        defer { if case let .focusLeft(field) = observation { fieldApps[field] = nil } }
        guard !events.isEmpty else { return }
        for e in events { model.apply(e, now: now, scorer: scorer, appKey: fieldApps[e.field],
                                    spelling: spelling, likelyTypo: likelyTypo) }
        markChanged()
    }

    /// Bias for the next suggestion. Rebuilds the lookup index only after the model changed
    /// (or hourly, so decay is reflected).
    public func bias(for before: String, strength: Float, appKey: String? = nil, now: Date = Date(),
                     midWordOnly: Bool = false) -> LearnedBias {
        // Blocked words are returned even when strength is 0: blocking is an explicit choice.
        currentBuilder(now: now)?.bias(for: before, strength: strength, appKey: appKey, categories: categories(),
                                       midWordOnly: midWordOnly)
            ?? LearnedBias(entries: [], strength: strength)
    }

    /// The writer's strongest active learned words for `appKey` (or its category), up to `limit`, in a
    /// stable alphabetical order: the vocabulary notes a framer can list in the prompt.
    public func vocabularyNotes(appKey: String?, limit: Int = 30, now: Date = Date()) -> [String] {
        currentBuilder(now: now)?.topWords(appKey: appKey, limit: limit, categories: categories()) ?? []
    }

    /// Learned words gated by relevance (`VocabularyGate`): at most `limit` active words for `appKey`'s
    /// app or category whose learned lead-in matches the words before the caret, or whose sentences in
    /// this app or category share at least `minOverlap` content words with the screen or the sentence
    /// being typed. Nil `appKey` gives none.
    public func gatedVocabulary(before: String, screen: String?, appKey: String?, limit: Int = 4,
                                minOverlap: Int = 2, now: Date = Date()) -> [VocabularyGate.Pick] {
        load()
        guard let appKey else { return [] }
        let cats = categories()
        let candidates = model.entries.values.filter { $0.active && !$0.blocked }.compactMap { e -> VocabularyGate.Candidate? in
            let w = e.weight(at: now) * BiasBuilder.appFactor(apps: e.apps, appKey: appKey, categories: cats)
            return w > 0 ? VocabularyGate.Candidate(text: e.text, weight: w, contexts: e.contexts) : nil
        }
        let sentences = model.style.snippets.filter { $0.appKey.map { cats.sameCategory($0, appKey) } ?? false }.map(\.text)
        return VocabularyGate.select(candidates, sentences: sentences, before: before, screen: screen,
                                     limit: limit, minOverlap: minOverlap)
    }

    /// Every active learned word usable in `appKey`'s app or category (diagnostic console only).
    public func learnedWordsHere(appKey: String?, now: Date = Date()) -> [String] {
        load()
        guard let appKey else { return [] }
        let cats = categories()
        return model.entries.values.filter { $0.active && !$0.blocked && $0.weight(at: now) > 0
            && BiasBuilder.appFactor(apps: $0.apps, appKey: appKey, categories: cats) > 0 }.map(\.text).sorted()
    }

    /// The lookup index, rebuilt only after the model changed (or hourly, so decay is reflected).
    private func currentBuilder(now: Date) -> BiasBuilder? {
        load()
        if builder == nil || now.timeIntervalSince(builtAt) > 3600 {
            builder = BiasBuilder(model: model, now: now)
            builtAt = now
        }
        return builder
    }

    /// Consolidates when the Mac is idle and something changed since the last run, or when the
    /// last run was 24 h or more ago. Returns whether it ran.
    @discardableResult
    public func consolidateIfDue(idle: Bool, now: Date = Date()) -> Bool {
        load()
        let sinceLast = model.lastConsolidated.map { now.timeIntervalSince($0) } ?? .infinity
        let due = (idle && (changedSinceConsolidation || model.lastConsolidated == nil)) || sinceLast >= 86_400
        guard due, !model.entries.isEmpty || model.lastConsolidated != nil else { return false }
        model.consolidate(now: now, spelling: spelling, likelyTypo: likelyTypo)
        changedSinceConsolidation = false
        builder = nil
        scheduleSave()
        dirty = true
        return true
    }

    /// Total positive mass recorded for a normalized word (test and diagnostics helper).
    func appsForTesting(of key: String) -> [String: Float] { model.entries[key]?.apps ?? [:] }

    func totalMass(of key: String) -> Float { model.entries[key]?.posMass ?? 0 }

    /// Drops all pending observation state (unconfirmed accepts, on-screen suggestion, retained
    /// text). Learned data is kept. Call when learning is turned off or Secure Input starts.
    public func reset() {
        tracker.reset()
        fieldApps = [:]
        styleFields = [:]
        styleAccepts = [:]
        stylePins = [:]
    }

    /// Wipes the learned data, the file (and stray temp files), and the key. In-memory state is
    /// cleared first; a failure deleting from disk is rethrown so the UI can say so.
    /// Single words the user has confirmed (active entries), lowercased. Used to exempt them from
    /// the typo check, so a name or term the user writes often never hides suggestions.
    public func activeWords() -> Set<String> {
        if !loaded { load() }
        return Set(model.entries.values.filter { $0.active && !$0.blocked && !$0.text.contains(" ") }
            .map { $0.text.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    /// The active learned words (as `activeWords`) with the apps each was used in, for autocorrect's
    /// app-aware fix offers. Two entries with the same lowercased text pool their apps.
    public func activeWordPlaces() -> LearnedWordPlaces {
        if !loaded { load() }
        return Self.places(of: model)
    }

    /// `activeWordPlaces` from a model (also for the eval, which reads the history file itself).
    public static func places(of model: VocabularyModel) -> LearnedWordPlaces {
        var apps: [String: [String: Float]] = [:]
        for e in model.entries.values where e.active && !e.blocked && !e.text.contains(" ") {
            let key = e.text.trimmingCharacters(in: .whitespaces).lowercased()
            apps[key, default: [:]].merge(e.apps, uniquingKeysWith: +)
        }
        return LearnedWordPlaces(apps: apps)
    }

    /// Words the user often mistypes (kept automatic fixes), for autocorrect's slip profile.
    public func troubleWords(now: Date = Date()) -> [TroubleWord] {
        if !loaded { load() }
        return model.troubleWords(now: now)
    }

    // MARK: Learned words editor

    /// Every entry (in-memory one-offs included), active first, then learning, then blocked.
    public func entries(now: Date = Date()) -> [LearnedWordInfo] {
        load()
        return model.infos(now: now)
    }

    /// Re-spells a word; merges into an existing entry with the same text. Returns the new id.
    @discardableResult
    public func rename(id: String, to newText: String, now: Date = Date()) throws -> String {
        try beginEdit()
        let k = try model.rename(id: id, to: newText, now: now)
        markChanged()
        return k
    }

    public func delete(id: String) throws {
        try beginEdit()
        try model.delete(id: id)
        markChanged()
    }

    /// Adds a word by hand (or from a dictation fix): active at once, never auto-pruned. Returns its id.
    @discardableResult
    public func add(text: String, origin: VocabEntry.Origin = .manual, now: Date = Date()) throws -> String {
        try beginEdit()
        let k = try model.addManual(text, origin: origin, now: now)
        markChanged()
        return k
    }

    public func setBlocked(id: String, _ blocked: Bool, now: Date = Date()) throws {
        try beginEdit()
        try model.setBlocked(id: id, blocked, now: now)
        markChanged()
    }

    /// Blocks a word that may not be in the list yet. Returns its id.
    @discardableResult
    public func block(text: String, now: Date = Date()) throws -> String {
        try beginEdit()
        let k = try model.block(text, now: now)
        markChanged()
        return k
    }

    // MARK: Style snippets

    /// Turns sentence capture on or off. Off by default; turning it off forgets in-progress text.
    public func setStyleCaptureEnabled(_ on: Bool) {
        styleCaptureEnabled = on
        if !on { styleFields = [:]; styleAccepts = [:] }
    }

    /// Up to `k` earlier sentences of the user's that share content words with `before`. The first
    /// non-empty pick per field is kept until focus leaves it or it is cleared.
    /// Only sentences written in the same app (`appKey`) or an app in its category are
    /// candidates; a nil key gives none.
    public func styleExamples(for before: String, field: FieldID, appKey: String?, k: Int = 2) -> [String] {
        load()
        guard let appKey else { return [] }
        if let pinned = stylePins[field], !pinned.isEmpty { return pinned }
        let cats = categories()
        let sameApp = model.style.snippets.suffix(StyleLibrary.promptPoolSize)
            .filter { $0.appKey.map { cats.sameCategory($0, appKey) } ?? false }
        let picked = StyleText.pick(from: sameApp, before: before, k: k)
        if !picked.isEmpty { stylePins[field] = picked }
        return picked
    }

    /// Learned phrases: continuations of `before` drawn from the sentences saved in the same app
    /// (`appKey`) or an app in its category, the same rule as `styleExamples`. A place in no
    /// category uses only its own sentences; a nil key gives none. Each group's index is rebuilt
    /// when its sentences change, including when apps move between categories.
    public func phrases(for before: String, appKey: String?) -> [PhraseContinuation] {
        load()
        guard let appKey else { return [] }
        let g = phraseGroup(appKey)
        if let cached = phraseModels[g.key], cached.ids == g.ids {
            return cached.model.continuations(after: before)
        }
        let built = PhraseModel(sentences: g.texts)
        phraseModels[g.key] = (g.ids, built)
        return built.continuations(after: before)
    }

    /// The saved sentences learned phrases may use for `appKey`, and the cache key of their group.
    private func phraseGroup(_ appKey: String) -> (key: String, ids: [String], texts: [String]) {
        let cats = categories()
        let key = cats.category(of: appKey).map { "category:" + StyleLibrary.bucket($0) } ?? "app:" + appKey
        var match: [String: Bool] = [:]   // per app key, so each is looked up once
        let snippets = model.style.snippets.filter { s in
            guard let k = s.appKey else { return false }
            if let m = match[k] { return m }
            let m = cats.sameCategory(k, appKey)
            match[k] = m
            return m
        }
        return (key, snippets.map(\.id), snippets.map(\.text))
    }

    /// After a sentence is saved in `appKey`, rebuilds its group's index off this actor (after a
    /// short pause so a burst of saves builds once), so the next suggestion doesn't pay for it.
    private func warmPhrases(for appKey: String) {
        let key = phraseGroup(appKey).key
        phraseWarmTasks[key]?.cancel()
        let delay = phraseWarmDelay
        phraseWarmTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let g = await self?.phraseGroup(appKey) else { return }
            if await self?.phraseCacheHolds(g.key, g.ids) ?? true { return }
            let texts = g.texts
            let built = await Task.detached(priority: .utility) { PhraseModel(sentences: texts) }.value
            guard !Task.isCancelled else { return }
            await self?.storeWarmPhrases(built, appKey: appKey, ids: g.ids)
        }
    }

    private func phraseCacheHolds(_ key: String, _ ids: [String]) -> Bool { phraseModels[key]?.ids == ids }

    /// Keeps a background-built index only if its group's sentences haven't changed meanwhile.
    private func storeWarmPhrases(_ built: PhraseModel, appKey: String, ids: [String]) {
        let g = phraseGroup(appKey)
        guard g.ids == ids else { return }
        phraseModels[g.key] = (ids, built)
        phraseWarmTasks[g.key] = nil
    }

    /// Whether the index for `appKey`'s group is built and current (tests).
    func phrasesReady(for appKey: String) -> Bool {
        let g = phraseGroup(appKey)
        return phraseCacheHolds(g.key, g.ids)
    }

    private func dropPhraseIndexes() {
        for t in phraseWarmTasks.values { t.cancel() }
        phraseWarmTasks = [:]
        phraseModels = [:]
    }

    public func styleSnippets() -> [StyleSnippet] {
        load()
        return model.style.snippets
    }

    public func deleteSnippet(id: String) {
        load()
        guard model.style.remove(id: id) else { return }
        stylePins = [:]
        dropPhraseIndexes()
        markStyleChanged()
    }

    public func deleteAllSnippets() {
        load()
        guard !model.style.isEmpty else { return }
        model.style.removeAll()
        stylePins = [:]
        dropPhraseIndexes()
        markStyleChanged()
    }

    private static let acceptWindow: TimeInterval = 5

    private func observeStyle(field: FieldID, text: String, appKey: String?, at now: Date) {
        guard styleCaptureEnabled else { return }
        guard var st = styleFields[field] else {
            styleFields[field] = StyleFieldState(baseline: text, latest: text, appKey: appKey)
            return
        }
        let prev = st.latest
        let replaced = !prev.isEmpty && !text.hasPrefix(String(prev.prefix(20))) && text.count * 2 < prev.count
        if replaced {
            harvestStyle(st, cleared: true, at: now)
            stylePins[field] = nil
            st = StyleFieldState(baseline: text, latest: text, appKey: appKey ?? st.appKey)
        } else {
            var acc: String? = nil
            if let a = styleAccepts[field], now.timeIntervalSince(a.at) <= Self.acceptWindow { acc = a.text }
            let rest = st.observe(text, accepted: acc)
            styleAccepts[field] = rest.flatMap { $0.isEmpty ? nil : ($0, styleAccepts[field]?.at ?? now) }
            if let b = appKey { st.appKey = b }
        }
        styleFields[field] = st
    }

    private func leaveStyleField(_ field: FieldID, at now: Date) {
        stylePins[field] = nil
        styleAccepts[field] = nil
        guard var st = styleFields.removeValue(forKey: field) else { return }
        st.closeRun()
        harvestStyle(st, cleared: false, at: now)
    }

    private func harvestStyle(_ st: StyleFieldState, cleared: Bool, at now: Date) {
        guard styleCaptureEnabled else { return }
        var added = false
        let cats = categories()
        // A sentence holding anything secret-looking is never saved.
        for s in st.harvest(cleared: cleared) where !SecretSanitizer.containsSecret(s) {
            if model.style.add(text: s, at: now, appKey: st.appKey, categoryOf: { cats.category(of: $0) }) {
                added = true
            }
        }
        if added {
            markStyleChanged()
            if let k = st.appKey { warmPhrases(for: k) }
        }
    }

    // MARK: Learned replies

    /// The user sent `answer` in reply to the message whose question sentences are `keys`, in `appKey`.
    public func recordReply(keys: [String], answer: String, appKey: String, now: Date = Date()) {
        load()
        if model.replies.record(keys: keys, answer: answer, appKey: appKey, now: now) { markStyleChanged() }
    }

    /// Learned replies for the message whose question sentences are `keys`, in `appKey`.
    public func learnedReplies(keys: [String], appKey: String, now: Date = Date()) -> LearnedSuggestion? {
        load()
        return model.replies.suggestion(keys: keys, appKey: appKey, now: now)
    }

    /// Every learned question, most recently seen first (Settings).
    public func learnedReplyQuestions(now: Date = Date()) -> [LearnedQuestion] {
        load()
        model.replies.prune(now: now)
        return model.replies.questions.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Applies a Settings edit to the learned replies.
    public func editLearnedReplies(_ edit: @Sendable (inout LearnedReplies) throws -> Void) throws {
        load()
        if loadState.isReadOnly { throw LearnedReplyError.readOnlyStore }
        try edit(&model.replies)
        markStyleChanged()
    }

    private func markStyleChanged() {
        dirty = true
        scheduleSave()
    }

    private func beginEdit() throws {
        load()
        if loadState.isReadOnly { throw LearnedWordError.readOnlyStore }
    }

    public func deleteAll() throws {
        saveTask?.cancel()
        saveTask = nil
        model = VocabularyModel()
        styleFields = [:]
        styleAccepts = [:]
        stylePins = [:]
        dropPhraseIndexes()
        fieldApps = [:]
        tracker = OutcomeTracker(settleInterval: tracker.settleInterval)
        loaded = true
        dirty = false
        builder = nil
        changedSinceConsolidation = false
        try store.deleteAll()
        loadState = .noFile   // nothing left on disk to protect
    }

    /// Writes pending changes now (also call on quit). Does nothing in a read-only session.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, !loadState.isReadOnly else { return }
        dirty = false
        do { try store.save(model) } catch { dirty = true }
    }

    private func markChanged() {
        dirty = true
        changedSinceConsolidation = true
        builder = nil
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}
