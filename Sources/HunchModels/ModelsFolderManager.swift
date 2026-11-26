import Foundation
import HunchCore
import Synchronization

public enum ModelsFolderError: Error, Sendable, Equatable {
    case notADirectory
    case doesNotExist
    case notReadable
    case bookmarkFailed(String)
}

/// Owns the user-chosen models folder: resolution, state classification, scanning and watching.
/// Observe with `updates()` (yields the current snapshot first, then every change).
public actor ModelsFolderManager: ModelsFolderManaging {
    private let store: any BookmarkStoring
    private let scanner: FolderScanner
    private let watchEnabled: Bool
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var pollRoot: URL?
    private var lastSignature: Int?
    private var debounce: DebounceTimeline

    private var current = FolderSnapshot(state: .notConfigured, models: [], scannedAt: nil)
    private var started = false
    private var cache: FolderScanner.Cache = [:]
    /// Files added from outside the folder (absolute paths), listed after the folder's own.
    private var addedFiles: [String] = []
    private var addedCache: FolderScanner.Cache = [:]
    /// Subscribers. Guarded by a mutex (not actor state) so `updates()` registers synchronously
    /// and `onTermination` always finds, and removes, its entry.
    private let continuations = Mutex<[UUID: AsyncStream<FolderSnapshot>.Continuation]>([:])
    private var watcher: FSEventsWatcher?
    private var watchedPath: String?
    private var volumeObserver: WorkspaceVolumeObserver?
    private var debounceTask: Task<Void, Never>?
    /// Set on willUnmount so we report offline (and unload) before the volume actually goes.
    private var unmountingVolumePath: String?

    /// - Parameters:
    ///   - watch: enable FSEvents and NSWorkspace observers (disable in unit tests).
    ///   - pollInterval: seconds between cheap directory-listing comparisons, a fallback for volumes
    ///     where FSEvents misses changes (exFAT, external drives); 0 disables.
    public init(store: any BookmarkStoring = FileBookmarkStore(), inspector: any GGUFInspecting = GGUFInspector(),
                maxDepth: Int = 3, debounceInterval: TimeInterval = 0.5, watch: Bool = true,
                pollInterval: TimeInterval = 5) {
        self.pollInterval = pollInterval
        self.store = store
        self.scanner = FolderScanner(maxDepth: maxDepth, inspector: inspector)
        self.watchEnabled = watch
        self.debounce = DebounceTimeline(interval: debounceInterval)
        Task { await self.ensureStarted() }
    }

    // MARK: ModelsFolderManaging

    public func snapshot() async -> FolderSnapshot {
        await ensureStarted()
        return current
    }

    public nonisolated func updates() -> AsyncStream<FolderSnapshot> {
        let (stream, cont) = AsyncStream<FolderSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        continuations.withLock { $0[id] = cont }
        cont.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        Task { await self.sendInitial(id) }
        return stream
    }

    /// Number of live subscribers (tests).
    nonisolated var subscriberCount: Int { continuations.withLock { $0.count } }

    public func choose(folder: URL) async throws {
        await ensureStarted()
        let url = folder.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ModelsFolderError.doesNotExist }
        guard isDir.boolValue else { throw ModelsFolderError.notADirectory }
        guard Self.probeRead(url.path) == .ok else { throw ModelsFolderError.notReadable }
        let bookmark: FolderBookmark
        do { bookmark = try Self.makeBookmark(for: url) } catch {
            throw ModelsFolderError.bookmarkFailed(error.localizedDescription)
        }
        try store.save(bookmark)
        unmountingVolumePath = nil
        refresh(rescanFiles: true)
    }

    public func clear() async {
        await ensureStarted()
        try? store.save(nil)
        unmountingVolumePath = nil
        refresh(rescanFiles: true)
    }

    public func rescan() async {
        await ensureStarted()
        unmountingVolumePath = nil
        refresh(rescanFiles: true)
    }

    /// Sets the files added from outside the folder (absolute paths) and rescans them.
    public func setAddedFiles(_ paths: [String]) async {
        await ensureStarted()
        guard paths != addedFiles else { return }
        addedFiles = paths
        refresh(rescanFiles: true)
    }

    public func resolveForLoading(_ id: ModelEntryID) async -> Result<URL, ModelFolderUnavailable> {
        await ensureStarted()
        refresh(rescanFiles: false)
        guard case .available(let root) = current.state else { return .failure(.init(current.state)) }
        if id.isOutsideFolder {
            let file = URL(fileURLWithPath: id.relativePath)
            var isDir: ObjCBool = false
            guard addedFiles.contains(id.relativePath),
                  FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
                refresh(rescanFiles: true)
                return .failure(.init(.missing(lastPath: file.path)))
            }
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                return .failure(.init(.permissionDenied(file)))
            }
            return .success(file)
        }
        let file = root.appendingPathComponent(id.relativePath)
        let standardized = file.standardizedFileURL.path
        guard standardized.hasPrefix(root.standardizedFileURL.path + "/") else {
            return .failure(.init(.missing(lastPath: file.path)))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            refresh(rescanFiles: true)
            return .failure(.init(.missing(lastPath: file.path)))
        }
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            return .failure(.init(.permissionDenied(file)))
        }
        return .success(file)
    }

    // MARK: Lifecycle

    private func ensureStarted() async {
        guard !started else { return }
        started = true
        if watchEnabled {
            volumeObserver = WorkspaceVolumeObserver { [weak self] event in
                guard let self else { return }
                Task { await self.handle(event) }
            }
        }
        refresh(rescanFiles: true)
    }

    /// Yields the current snapshot to a new subscriber, unless it has already gone away. A change
    /// published before this runs is newer-or-equal, so the subscriber never sees a stale value
    /// after a fresh one (at worst it sees the same snapshot twice).
    private func sendInitial(_ id: UUID) async {
        await ensureStarted()
        let snapshot = current
        let cont = continuations.withLock { $0[id] }
        cont?.yield(snapshot)
    }

    private func handle(_ event: VolumeEvent) {
        switch event {
        case .willUnmount(let path):
            if let path, let root = currentRootPath, root == path || root.hasPrefix(path.hasSuffix("/") ? path : path + "/") {
                unmountingVolumePath = path
                stopWatching()
                refresh(rescanFiles: false)
            }
        case .didMount, .didUnmount, .didRename:
            unmountingVolumePath = nil
            refresh(rescanFiles: true)
        }
    }

    /// Called from the FSEvents callback path.
    private func fileSystemChanged() {
        debounce.record(at: Date())
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            while let self, let wait = await self.debounceRemaining(), wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
            }
            await self?.debounceFired()
        }
    }

    private func debounceRemaining() -> TimeInterval? { debounce.remaining(at: Date()) }

    private func debounceFired() {
        debounceTask = nil
        debounce.reset()
        refresh(rescanFiles: true)
    }

    // MARK: Resolution

    private var currentRootPath: String? {
        if case .available(let u) = current.state { return u.path }
        return nil
    }

    /// Re-resolves the bookmark, classifies, optionally rescans, and publishes if changed.
    private func refresh(rescanFiles: Bool) {
        var state: FolderState = .notConfigured
        var models = current.models
        var scanned = current.scannedAt

        if var stored = store.load() {
            let url = resolveURL(&stored)
            let facts = Self.gatherFacts(stored: stored, url: url)
            state = FolderStateClassifier.classify(facts)
            if let unmounting = unmountingVolumePath, case .available(let u) = state,
               u.path == unmounting || u.path.hasPrefix(unmounting.hasSuffix("/") ? unmounting : unmounting + "/") {
                state = .volumeOffline(volumeName: stored.volumeName, lastPath: stored.lastKnownPath)
            }
        }

        if case .available(let root) = state {
            if rescanFiles || current.state != state {
                lastSignature = scanner.signature(root: root)
                models = scanner.scan(root: root, cache: &cache)
                // An added path inside the folder is already listed by the scan.
                let rootPrefix = root.standardizedFileURL.path + "/"
                let outside = addedFiles.filter { !URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(rootPrefix) }
                models += scanner.entries(forFiles: outside, cache: &addedCache)
                scanned = Date()
            }
            startWatching(root.resolvingSymlinksInPath().path)
            startPolling(root)
        } else {
            stopPolling()
            models = []
            scanned = nil
            cache = [:]
            addedCache = [:]
            stopWatching()
        }

        let next = FolderSnapshot(state: state, models: models, scannedAt: scanned)
        // Compare without the timestamp so identical rescans don't make the UI flicker.
        if next.state != current.state || next.models != current.models {
            current = next
            for c in continuations.withLock({ Array($0.values) }) { c.yield(next) }
        } else {
            current.scannedAt = scanned
        }
    }

    /// Bookmark first (follows moves and renames on the same volume), then the last path.
    /// Refreshes stale bookmarks and a changed path in the store.
    private func resolveURL(_ stored: inout FolderBookmark) -> URL {
        var stale = false
        if let resolved = try? URL(resolvingBookmarkData: stored.bookmarkData,
                                   options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale) {
            let url = URL(fileURLWithPath: resolved.standardizedFileURL.path)
            if stale || url.path != stored.lastKnownPath {
                if var fresh = try? Self.makeBookmark(for: url) {
                    if !stale { fresh.bookmarkData = stored.bookmarkData }
                    try? store.save(fresh)
                    stored = fresh
                } else if url.path != stored.lastKnownPath {
                    stored.lastKnownPath = url.path
                    try? store.save(stored)
                }
            }
            return url
        }
        return URL(fileURLWithPath: stored.lastKnownPath)
    }

    private func startWatching(_ path: String) {
        guard watchEnabled else { return }
        if watcher != nil, watchedPath == path { return }
        stopWatching()
        watcher = FSEventsWatcher(path: path) { [weak self] in
            guard let self else { return }
            Task { await self.fileSystemChanged() }
        }
        watchedPath = watcher == nil ? nil : path
    }

    private func startPolling(_ root: URL) {
        guard pollInterval > 0 else { return }
        if pollTask != nil, pollRoot == root { return }
        stopPolling()
        pollRoot = root
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.pollTick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollRoot = nil
        lastSignature = nil
    }

    private func pollTick() {
        guard let root = pollRoot else { return }
        let sig = scanner.signature(root: root)
        if sig != lastSignature { refresh(rescanFiles: true) }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchedPath = nil
    }

    // MARK: Facts

    static func probeRead(_ path: String) -> ReadProbe {
        guard let dir = opendir(path) else {
            return (errno == EACCES || errno == EPERM) ? .denied : .failed
        }
        _ = readdir(dir)  // one entry is enough to prove it is listable
        closedir(dir)
        return .ok
    }

    static func mountedVolumeUUIDs() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey],
                                                         options: []) ?? []
        return Set(urls.compactMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
    }

    static func gatherFacts(stored: FolderBookmark, url: URL) -> FolderFacts {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let existence: PathExistence = !exists ? .absent : (isDir.boolValue ? .directory : .file)
        return FolderFacts(url: url, lastPath: stored.lastKnownPath, volumeName: stored.volumeName,
                           volumeUUID: stored.volumeUUID, mountedVolumeUUIDs: mountedVolumeUUIDs(),
                           existence: existence,
                           readProbe: existence == .directory ? probeRead(url.path) : .failed)
    }

    static func makeBookmark(for url: URL) throws -> FolderBookmark {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeIsRemovableKey,
                                                  .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey])
        let removable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false)
            || !(v?.volumeIsInternal ?? true) || !(v?.volumeIsLocal ?? true)
        return FolderBookmark(bookmarkData: data, lastKnownPath: url.path, volumeUUID: v?.volumeUUIDString,
                              volumeName: v?.volumeName, isOnRemovableVolume: removable)
    }
}
