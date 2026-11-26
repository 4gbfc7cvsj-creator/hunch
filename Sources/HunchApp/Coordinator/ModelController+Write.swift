import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import Synchronization

/// Write for me on the local side: the Language Model already loaded for suggestions (the default,
/// and whenever the writing model is that same file), or a separate writing model in its own host,
/// loaded the first time it is needed and released after a few idle minutes (the host reloads it on
/// the next draft).
extension ModelController {
    /// The catalog's writing model recommended for this Mac, offered for download when the folder
    /// has no instruct model.
    static var writeCatalogFileName: String {
        ModelRecommender.recommend(ramBytes: MachineFacts.physicalMemory, chipBrand: MachineFacts.chipBrand,
                                   freeDiskBytes: nil, catalog: ModelCatalog.entries(for: .writing))?.model.fileName
            ?? "gemma-4-E4B-it.i1-Q5_K_M.gguf"
    }
    /// Room for the screen, the field and the instructions, plus the draft.
    static let writeContextTokens = 8192
    static let writeDraftTokens = 900
    /// A few idle minutes, then the instruct model's memory goes back to the system.
    static let writeIdleReleaseSeconds: Double = 180

    /// The instruct model Write for me uses: the one chosen in Settings while Writing's source is
    /// local; otherwise (the endpoint is the choice, and this is its fallback) by `fallbackEntry`.
    func instructEntry() -> ModelEntry? {
        let valid = snapshot.models.filter { $0.validity == .valid && $0.summary != nil }
        let instruct = valid.filter(isInstruct)
        if settings.writeEngine == .local, let chosen = instruct.first(where: { $0.id == settings.writeModel }) {
            return chosen
        }
        return Self.fallbackEntry(instruct, use: .writing, recommended: Self.writeCatalogFileName)
    }

    /// An instruct model: added under Writing Model (Settings → Models), else what the profile
    /// detector reads from it. A file added under Language Model can be either kind.
    func isInstruct(_ entry: ModelEntry) -> Bool {
        if let added = settings.addedModels.first(where: { $0.path == entry.id.relativePath }),
           ModelUse(rawValue: added.use) == .writing {
            return true
        }
        guard let summary = entry.summary else { return false }
        return detector.detect(summary, fileName: entry.id.relativePath).isInstruct
    }

    var hasInstructModel: Bool { instructEntry() != nil }

    /// The writing model is the Language Model's file, already loaded for suggestions: drafts run
    /// on that host instead of loading a second copy.
    var writingModelIsLanguageModel: Bool {
        guard engine != nil, let active = activeEntry else { return false }
        return instructEntry()?.id == active.id
    }

    /// A writer on the instruct model, loading it (in the background) if needed. Nil when the folder
    /// has no instruct model.
    func instructWriter() -> LocalWriter? {
        guard let entry = instructEntry(), let summary = entry.summary else { return nil }
        let host = writeHost ?? LlamaModelHost(profileDetector: detector)
        writeHost = host
        let counter = WriteRequestCounter()
        var options = RuntimeOptions(contextTokens: Self.writeContextTokens, maxSequences: 1,
                                     idleReleaseAfterSeconds: Self.writeIdleReleaseSeconds)
        options.contextTokens = summary.contextLength.map { min(Self.writeContextTokens, max($0, 2048)) }
            ?? Self.writeContextTokens
        if writeEntry?.id != entry.id {
            writeEntry = entry
            let folder = self.folder
            writeLoading = Task {
                guard case .success(let url) = await folder.resolveForLoading(entry.id) else { return }
                var resolved = entry
                resolved.url = url
                await host.load(resolved, options: options)
            }
        }
        let loading = writeLoading
        return LocalWriter(host: WaitingHost(host: host, loading: loading),
                           promptTokenBudget: options.contextTokens - Self.writeDraftTokens - 64,
                           maxTokens: Self.writeDraftTokens, nextID: { counter.next() })
    }

    /// The Language Model as a writer, on the host suggestions already use (an instruct model writes
    /// with the chat prompt; a base one, by the user's choice, with a rougher document prompt).
    /// `currentID` keeps the shared executor's latest-wins order: the draft runs as the newest
    /// request until the user types again.
    func languageModelWriter(currentID: @escaping @Sendable () -> RequestID) -> LocalWriter? {
        guard engine != nil, let options = loadedOptions else { return nil }
        return LocalWriter(host: host, promptTokenBudget: max(512, options.contextTokens - Self.writeDraftTokens - 64),
                           maxTokens: min(Self.writeDraftTokens, options.contextTokens / 3), nextID: currentID)
    }

    /// The instruct model is loaded and ready to write (false while it loads or after an idle release).
    func writeModelReady() async -> Bool {
        guard let host = writeHost else { return false }
        if case .ready = await host.state() { return true }
        return false
    }

    /// Folder offline or the instruct model gone: free it.
    func writeFolderChanged() {
        guard let host = writeHost else { return }
        let stillThere: Bool
        if case .available = snapshot.state, let entry = writeEntry {
            stillThere = snapshot.models.contains { $0.id == entry.id && $0.validity == .valid }
        } else {
            stillThere = false
        }
        guard !stillThere else { return }
        writeEntry = nil
        writeLoading = nil
        Task { await host.unload() }
    }
}

/// Monotonic ids for the write host's executor (only write jobs run there).
final class WriteRequestCounter: Sendable {
    private let value = Atomic<UInt64>(0)
    func next() -> RequestID { RequestID(value.add(1, ordering: .relaxed).newValue) }
}

/// A host whose first use waits for the background load to finish (instead of failing with
/// "not loaded" while the file is still being read).
final class WaitingHost: ModelHosting {
    private let host: any ModelHosting
    private let loading: Task<Void, Never>?

    init(host: any ModelHosting, loading: Task<Void, Never>?) {
        self.host = host
        self.loading = loading
    }

    func state() async -> ModelLoadState {
        await loading?.value
        return await host.state()
    }

    func states() -> AsyncStream<ModelLoadState> { host.states() }
    func load(_ entry: ModelEntry, options: RuntimeOptions) async { await host.load(entry, options: options) }
    func unload() async { await host.unload() }

    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        await loading?.value
        return try await host.withSession(id, body)
    }

    func cancel(olderThan id: RequestID) { host.cancel(olderThan: id) }
}
