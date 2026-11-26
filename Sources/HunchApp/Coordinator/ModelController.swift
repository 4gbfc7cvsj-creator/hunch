import AppKit
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPolicy
import HunchPrompt
import HunchText

/// Local-model management on top of HunchModels' folder manager (design §6): follows the folder
/// state, resolves the selected entry right before every load, unloads when the folder becomes
/// unavailable, and reloads the selection automatically when it comes back.
@MainActor
final class ModelController {
    enum Status: Equatable {
        case noFolder
        case volumeOffline(volumeName: String?)
        case folderMissing(path: String)
        case permissionDenied(path: String)
        case notADirectory(path: String)
        case noUsableModel(folder: String)
        case unloaded
        case loading(String)
        case ready(String)
        case idle(String)
        case failed(String)
    }

    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    /// Shared with `LearningController`, which keeps its learned-word set current.
    let spellChecker = LearnedWordsSpellChecker(base: SystemSpellChecker.cached())
    let folder: ModelsFolderManager
    private(set) var engine: (any CompletionEngine)?
    private(set) var status: Status = .noFolder
    private(set) var snapshot = FolderSnapshot(state: .notConfigured, models: [], scannedAt: nil)
    private(set) var activeEntry: ModelEntry?
    /// Called on any change of `status`, `snapshot`, or `activeEntry`.
    var onChange: (() -> Void)?

    let detector = DefaultModelProfileDetector()
    private(set) var settings = HunchSettings()
    private(set) var loadedOptions: RuntimeOptions?
    /// "Unload Model Now": stay unloaded until the user picks a model or the settings change.
    private var userUnloaded = false
    /// False while the endpoint serves everything: the model isn't loaded up front then.
    private var localWanted = true
    /// A local request came in while loading was deferred; load from now on.
    private var demanded = false
    /// True when the app has an app/site engine override of `.local` (set by the app delegate).
    var hasLocalOverride: () -> Bool = { false }
    private var loading = false
    /// Load generations: lets a finished load notice it was superseded by an unload or folder change.
    private var loadState = ModelLoadCoordinatorState()
    private var reloadPending = false
    private var unmountObserver: NSObjectProtocol?
    private var tasks: [Task<Void, Never>] = []
    /// Write for me's instruct model, loaded on first use (see ModelController+Write).
    var writeHost: LlamaModelHost?
    var writeEntry: ModelEntry?
    var writeLoading: Task<Void, Never>?
    /// Dynamic Power Mode's mode and the chosen Efficiency model (nil: the smallest); nil while off.
    private(set) var dynamic: (mode: PowerMode, efficiency: String?)?
    /// The next load comes from Dynamic Power Mode: it waits for a suggestion in progress instead of
    /// cancelling it, and a released (idle) model is only retargeted, not loaded.
    private var swapGently = false

    init(folder: ModelsFolderManager = ModelsFolderManager()) {
        self.folder = folder
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.volumeWillUnmount(volume) }
        }
        // Follow the runtime's real state (idle release, reload, failure) for the menu.
        let states = host.states()
        tasks.append(Task { [weak self] in
            for await state in states { self?.runtimeStateChanged(state) }
        })
    }

    /// Starts observing the folder. With no folder chosen yet, adopts `settings.modelsFolderPath`.
    func start(settings: HunchSettings) {
        self.settings = settings
        refreshLocalWanted()
        let folder = self.folder
        let updates = folder.updates()
        tasks.append(Task { [weak self] in
            for await snapshot in updates { self?.folderChanged(snapshot) }
        })
        adoptSettingsFolderIfNeeded()
        pushAddedFiles()
    }

    /// Hands the files added from outside the folder to the folder manager.
    private func pushAddedFiles() {
        let paths = settings.addedModels.filter(\.isOutsideFolder).map(\.path)
        let folder = self.folder
        Task { await folder.setAddedFiles(paths) }
    }

    /// No folder chosen in the manager yet (first launch, or the drive wasn't mounted then):
    /// adopt the path from the settings once it exists.
    private func adoptSettingsFolderIfNeeded() {
        guard let path = settings.modelsFolderPath else { return }
        let folder = self.folder
        Task {
            if case .notConfigured = await folder.snapshot().state, FileManager.default.fileExists(atPath: path) {
                try? await folder.choose(folder: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    }

    /// The root folder the manager currently resolves to (nil unless available).
    var availableFolderPath: String? {
        if case .available(let url) = snapshot.state { return url.path }
        return nil
    }

    // MARK: Settings and user actions

    /// Applies new settings: reloads when the selection or runtime options changed.
    func apply(settings new: HunchSettings) {
        let old = settings
        settings = new
        if old.activeModel != new.activeModel || old.runtime != new.runtime { swapGently = false }
        let wantedBefore = localWanted
        refreshLocalWanted()
        if old.addedModels != new.addedModels { pushAddedFiles() }
        if old.activeModel != new.activeModel || old.runtime != new.runtime {
            userUnloaded = false
            requestLoad()
        } else if localWanted && !wantedBefore {
            // Engine switched back to local: load now (an explicit "Unload Model Now" still holds).
            requestLoad()
        }
    }

    private func refreshLocalWanted() {
        localWanted = EngineSelection.localModelWanted(
            globalEngine: settings.engine, endpointConfigured: settings.endpoint != nil,
            anyLocalOverride: hasLocalOverride())
    }

    /// A request needs the local engine but loading was deferred: load it now.
    func loadOnDemand() {
        guard !localWanted, !demanded, !userUnloaded else { return }
        demanded = true
        requestLoad()
    }

    func choose(folder url: URL) async throws {
        try await folder.choose(folder: url)
    }

    func rescan() {
        adoptSettingsFolderIfNeeded()
        let folder = self.folder
        Task { await folder.rescan() }
    }

    /// The user picked a model (possibly the current one after "Unload Model Now").
    func userSelectedModel() {
        userUnloaded = false
        requestLoad()
    }

    func unloadNow() async {
        userUnloaded = true
        loadState.noteUnload()
        await unloadModel()
        setStatus(.unloaded)
    }

    // MARK: Folder state

    private func folderChanged(_ next: FolderSnapshot) {
        snapshot = next
        if case .available(let root) = next.state {
            loadState.folderChanged(availableRoot: root.path)
        } else {
            loadState.folderChanged(availableRoot: nil)
        }
        switch next.state {
        case .available:
            // Also covers a selection that vanished from the folder: the load picks another entry
            // (unloading the old one) or reports that nothing is usable.
            requestLoad()
        default:
            if engine != nil || activeEntry != nil { Task { await unloadModel() } }
            setStatus(Self.status(for: next.state))
        }
        writeFolderChanged()
        onChange?()
    }

    static func status(for state: FolderState) -> Status {
        switch state {
        case .notConfigured: .noFolder
        case .volumeOffline(let name, _): .volumeOffline(volumeName: name)
        case .missing(let path): .folderMissing(path: path)
        case .permissionDenied(let url): .permissionDenied(path: url.path)
        case .notADirectory(let url): .notADirectory(path: url.path)
        case .available(let url): .noUsableModel(folder: url.path)
        }
    }

    // MARK: Loading

    /// Serializes loads: a request during a load re-runs the selection once that load finishes.
    private func requestLoad() {
        guard !loading else {
            reloadPending = true
            return
        }
        loading = true
        Task {
            repeat {
                reloadPending = false
                await loadSelected()
            } while reloadPending
            loading = false
        }
    }

    /// The Language Model: the chosen one while autocomplete's source is local; otherwise (the
    /// endpoint is the choice, and this is its fallback) or with no choice, an instruct model by
    /// `fallbackEntry` (instruct + chat-prefill-v5 matched base + document in the 2026-10-19 eval, and
    /// Write for me can share it), else a base one, else the first valid model.
    func preferredEntry() -> ModelEntry? {
        guard let top = handPickedEntry() else { return nil }
        guard let dynamic, settings.engine == .local else { return top }
        let options = dynamicCandidates()
        let id = DynamicPower.pick(mode: dynamic.mode, performance: top.id,
                                   efficiencyChoice: dynamic.efficiency.map(ModelEntryID.init(relativePath:)),
                                   available: options.map { ($0.id, $0.byteSize) })
        return options.first { $0.id == id } ?? top
    }

    /// Models Dynamic Power Mode can use: the ones listed under Language Model in Settings
    /// (instruct models, and base models the user added there) plus the hand-picked one.
    func dynamicCandidates() -> [ModelEntry] {
        let top = handPickedEntry()?.id
        let added = Set(settings.addedModels.map(\.path))
        return snapshot.models.filter { entry in
            entry.validity == .valid && entry.summary != nil
                && (isInstruct(entry) || entry.id == top || added.contains(entry.id.relativePath))
        }
    }

    /// Dynamic Power Mode changed mode or Efficiency model (or turned off: nil). Reloads only when
    /// the pick changes; the swap waits for a suggestion in progress, and a released model just
    /// reloads as the new pick later.
    func setDynamic(mode: PowerMode, efficiency: String?) {
        setDynamic((mode, efficiency))
    }

    func clearDynamic() { setDynamic(nil) }

    private func setDynamic(_ next: (mode: PowerMode, efficiency: String?)?) {
        let before = preferredEntry()?.id
        dynamic = next
        guard preferredEntry()?.id != before else {
            onChange?()
            return
        }
        swapGently = true
        requestLoad()
    }

    /// The Language Model chosen by hand (or by fallback), before Dynamic Power Mode.
    func handPickedEntry() -> ModelEntry? {
        let valid = snapshot.models.filter { $0.validity == .valid && $0.summary != nil }
        if settings.engine == .local, let chosen = valid.first(where: { $0.id == settings.activeModel }) {
            return chosen
        }
        return Self.fallbackEntry(valid.filter(isInstruct), use: .autocomplete)
            ?? Self.fallbackEntry(valid.filter { !isInstruct($0) }, use: .autocomplete) ?? valid.first
    }

    /// The Language Model is a local base model (not trained to follow instructions). False while
    /// autocomplete uses its endpoint or nothing is chosen yet.
    var languageModelIsBase: Bool {
        guard settings.engine == .local, let entry = activeEntry ?? preferredEntry() else { return false }
        return !isInstruct(entry)
    }

    /// The instruct model a pending one-time switch (`instructSwitchPending`) should select: nil when
    /// the Language Model is already instruct or the folder has none.
    func instructSwitchTarget() -> ModelEntryID? {
        guard case .available = snapshot.state, let current = preferredEntry(), !isInstruct(current) else { return nil }
        let instruct = snapshot.models.filter { $0.validity == .valid && $0.summary != nil && isInstruct($0) }
        return Self.fallbackEntry(instruct, use: .autocomplete)?.id
    }

    /// A use's local model when none is chosen (or the endpoint is): the only one there is; with
    /// several, the catalog's recommendation for this Mac if it is among them, else the first.
    static func fallbackEntry(_ candidates: [ModelEntry], use: ModelUse,
                              recommended: String? = nil) -> ModelEntry? {
        guard candidates.count > 1 else { return candidates.first }
        let pick = (recommended ?? recommendedFileName(use))?.lowercased()
        return candidates.first { ($0.id.relativePath as NSString).lastPathComponent.lowercased() == pick }
            ?? candidates.first
    }

    /// The catalog's pick for this Mac among a use's entries.
    static func recommendedFileName(_ use: ModelUse) -> String? {
        ModelRecommender.recommend(ramBytes: MachineFacts.physicalMemory, chipBrand: MachineFacts.chipBrand,
                                   freeDiskBytes: nil, catalog: ModelCatalog.entries(for: use))?.model.fileName
    }

    private func loadSelected() async {
        guard !userUnloaded else { return setStatus(.unloaded) }
        // Endpoint-only setups skip the load (an already loaded model is left to idle release).
        guard localWanted || demanded || engine != nil else { return setStatus(.unloaded) }
        guard case .available(let root) = snapshot.state else { return }
        guard var entry = preferredEntry(), let summary = entry.summary else {
            await unloadModel()
            return setStatus(.noUsableModel(folder: root.path))
        }
        if activeEntry?.id == entry.id, engine != nil,
           loadedOptions == Self.loadOptions(settings.runtime, trainedContext: summary.contextLength) { return }
        let gentle = swapGently
        swapGently = false
        let token = loadState.beginLoad()

        // Re-check the folder and the file right before loading (the drive may have gone).
        switch await folder.resolveForLoading(entry.id) {
        case .failure(let unavailable):
            await unloadModel()
            // A newer unload or folder change already published its own status.
            if loadState.isLatest(token) { setStatus(Self.status(for: unavailable.state)) }
            return
        case .success(let url):
            entry.url = url
        }

        let options = Self.loadOptions(settings.runtime, trainedContext: summary.contextLength)
        // Dynamic Power Mode on a released model: point the reload at the new pick and load nothing
        // (it loads with the next suggestion, like any idle reload).
        if gentle, case .idle = status, engine != nil,
           await host.retargetIfReleased(entry, options: options), loadState.isCurrent(token) {
            activeEntry = entry
            installEngine(options: options)
            return setStatus(.idle(entry.id.relativePath))
        }
        // A gentle swap queues behind a suggestion in progress on the host's executor; any other
        // load ejects first (cancelling it).
        if !gentle { await unloadModel() }
        guard loadState.isCurrent(token) else { return }
        activeEntry = entry
        setStatus(.loading(entry.id.relativePath))
        await host.load(entry, options: options)
        let failure: String? = if case .failed(_, let message) = await host.state() { message } else { nil }
        // An unload, a folder change, or the folder going away while we were loading supersedes
        // this load: drop whatever got loaded and keep the status published meanwhile.
        switch loadState.finishLoad(token, failure: failure) {
        case .discard:
            engine = nil
            activeEntry = nil
            loadedOptions = nil
            await host.unload()
            onChange?()
            return
        case .reportFailure(let message):
            activeEntry = nil
            return setStatus(.failed(message))
        case .commit:
            break
        }
        installEngine(options: options)
        setStatus(.ready(entry.id.relativePath))
    }

    /// A fresh engine over the host (its result cache belongs to the model it was made for).
    private func installEngine(options: RuntimeOptions) {
        // Typo check: hide suggestions after a misspelled word (English and other spaced scripts;
        // CJK is skipped); preface echoes of the framer's own header are suppressed.
        let post = DefaultPostProcessor(spellChecker: spellChecker,
                                        spellLanguages: Locale.preferredLanguages,
                                        prefaceTexts: DocumentFramer.prefacePhrases)
        engine = LocalCompletionEngine(host: host, postProcessor: post,
                                       promptTokenBudget: Self.promptBudget(contextTokens: options.contextTokens),
                                       resultCacheCapacity: 32,
                                       costObserver: { cost in
                                           SuggestionCoordinator.perf(
                                               "cost id=\(cost.id.raw) decoded=\(cost.decodedTokens) "
                                               + String(format: "decodeMs=%.1f", cost.decodeMilliseconds)
                                               + " finished=\(cost.finished) prewarm=\(cost.prewarm)")
                                       })
        loadedOptions = options
    }

    /// Runtime options for a load: at least `RuntimeOptions.defaultContextTokens` of context (older
    /// settings files saved 2048), but never more than the model was trained on.
    static func loadOptions(_ saved: RuntimeOptions, trainedContext: Int?) -> RuntimeOptions {
        var options = saved
        let wanted = max(saved.contextTokens, RuntimeOptions.defaultContextTokens)
        options.contextTokens = trainedContext.map { min(wanted, max($0, 512)) } ?? wanted
        return options
    }

    /// The framer's token budget: the context minus room for the suggestion and its branches.
    static func promptBudget(contextTokens: Int) -> Int {
        max(256, contextTokens - RuntimeOptions.decodeHeadroom)
    }

    private func unloadModel() async {
        let hadModel = engine != nil || activeEntry != nil
        engine = nil
        activeEntry = nil
        loadedOptions = nil
        if hadModel { await host.unload() }
        onChange?()
    }

    private func runtimeStateChanged(_ state: ModelLoadState) {
        guard let active = activeEntry, loadState.folderAvailable else { return }
        let name = active.id.relativePath
        switch state {
        case .ready(let id, _) where id == active.id && engine != nil: setStatus(.ready(name))
        case .releasedIdle(let id) where id == active.id: setStatus(.idle(name))
        case .loading(let id, _) where id == active.id: setStatus(.loading(name))
        case .failed(let id, let message) where id == active.id: setStatus(.failed(message))
        default: break
        }
    }

    private func volumeWillUnmount(_ volume: URL) {
        // Free a mapped model before the volume goes (design decision 8). The folder manager
        // reports the volume offline separately; the model reloads when it's back.
        if let writeHost, writeHost.unloadIfModel(onVolume: volume) { writeEntry = nil }
        if host.unloadIfModel(onVolume: volume) {
            loadState.noteUnload()
            engine = nil
            activeEntry = nil
            loadedOptions = nil
            setStatus(.volumeOffline(volumeName: volume.lastPathComponent))
        }
    }

    private func setStatus(_ status: Status) {
        self.status = status
        onChange?()
    }

    // MARK: Downloads

    /// A catalog download finished and its file is in the folder. Rescans now rather than after
    /// the FSEvents debounce, and returns true when the new model should become the selection:
    /// only when nothing usable was there to load, so a download never replaces the user's pick.
    func downloadCompleted(_ id: ModelEntryID) -> Bool {
        rescan()
        if case .noUsableModel = status { return true }
        return false
    }
}
