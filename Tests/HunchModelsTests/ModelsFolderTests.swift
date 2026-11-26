import Foundation
import Testing
@testable import HunchModels
import HunchCore

private struct FakeInspector: GGUFInspecting {
    func inspect(_ url: URL) -> (GGUFValidity, GGUFSummary?) {
        let n = url.lastPathComponent.lowercased()
        if n.hasPrefix("mmproj") { return (.auxiliary("vision projector"), nil) }
        if let sp = SplitName(fileName: url.lastPathComponent) { return (.splitPart(index: sp.index, of: sp.total), GGUFSummary(version: 3, architecture: "llama")) }
        if n.contains("bad") { return (.notGGUF, nil) }
        return (.valid, GGUFSummary(version: 3, architecture: "llama"))
    }
}

private final class MemoryStore: BookmarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: FolderBookmark?
    func load() -> FolderBookmark? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ b: FolderBookmark?) throws { lock.lock(); value = b; lock.unlock() }
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("gt-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u.resolvingSymlinksInPath()
}

private func touch(_ dir: URL, _ rel: String, bytes: Int = 8) throws {
    let u = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: bytes).write(to: u)
}

private func manager(_ store: BookmarkStoring = MemoryStore(), watch: Bool = false,
                     debounce: TimeInterval = 0.5, poll: TimeInterval = 0) -> ModelsFolderManager {
    ModelsFolderManager(store: store, inspector: FakeInspector(), debounceInterval: debounce, watch: watch,
                        pollInterval: poll)
}

@Suite struct ClassifierTests {
    private func facts(uuid: String? = "A", mounted: Set<String> = ["A"], existence: PathExistence = .directory,
                       probe: ReadProbe = .ok, configured: Bool = true) -> FolderFacts {
        FolderFacts(configured: configured, url: URL(fileURLWithPath: "/Volumes/X/m"), lastPath: "/Volumes/X/m",
                    volumeName: "X", volumeUUID: uuid, mountedVolumeUUIDs: mounted, existence: existence, readProbe: probe)
    }

    @Test func states() {
        let url = URL(fileURLWithPath: "/Volumes/X/m")
        #expect(FolderStateClassifier.classify(facts(configured: false)) == .notConfigured)
        #expect(FolderStateClassifier.classify(facts()) == .available(url))
        #expect(FolderStateClassifier.classify(facts(mounted: ["B"], existence: .absent))
                == .volumeOffline(volumeName: "X", lastPath: "/Volumes/X/m"))
        #expect(FolderStateClassifier.classify(facts(existence: .absent)) == .missing(lastPath: "/Volumes/X/m"))
        #expect(FolderStateClassifier.classify(facts(existence: .file)) == .notADirectory(url))
        #expect(FolderStateClassifier.classify(facts(probe: .denied)) == .permissionDenied(url))
        #expect(FolderStateClassifier.classify(facts(uuid: nil, mounted: [])) == .available(url))
    }

    @Test func debounceTimeline() {
        var d = DebounceTimeline(interval: 0.5)
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(d.remaining(at: t0) == nil)
        #expect(!d.isDue(at: t0))
        d.record(at: t0)
        #expect(d.remaining(at: t0.addingTimeInterval(0.2)) == 0.3 as TimeInterval? || abs((d.remaining(at: t0.addingTimeInterval(0.2)) ?? 9) - 0.3) < 1e-6)
        d.record(at: t0.addingTimeInterval(0.4))  // burst extends the deadline
        #expect(!d.isDue(at: t0.addingTimeInterval(0.6)))
        #expect(d.isDue(at: t0.addingTimeInterval(0.9)))
        d.reset()
        #expect(d.remaining(at: t0) == nil)
    }
}

@Suite struct ScannerTests {
    @Test func depthHiddenAuxiliaryInvalid() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "a.gguf")
        try touch(d, "B.GGUF")
        try touch(d, "sub/c.gguf")
        try touch(d, "sub/sub2/d.gguf")
        try touch(d, "sub/sub2/sub3/e.gguf")        // depth 4: too deep
        try touch(d, ".hidden.gguf")
        try touch(d, ".hiddendir/f.gguf")
        try touch(d, "mmproj-a.gguf")
        try touch(d, "bad.gguf")
        try touch(d, "notes.txt")
        let entries = FolderScanner(inspector: FakeInspector()).scan(root: d)
        let names = entries.map(\.id.relativePath)
        #expect(Set(names) == ["a.gguf", "B.GGUF", "sub/c.gguf", "sub/sub2/d.gguf", "bad.gguf"])
        #expect(entries.first { $0.id.relativePath == "bad.gguf" }?.validity == .notGGUF)
        #expect(entries.filter { $0.validity == .valid }.count == 4)
    }

    @Test func symlinkOutsideFolderIgnored() throws {
        let d = try tempDir(), outside = try tempDir()
        defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: outside) }
        try touch(outside, "out.gguf")
        try touch(d, "in.gguf")
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link.gguf"),
                                                   withDestinationURL: outside.appendingPathComponent("out.gguf"))
        let names = FolderScanner(inspector: FakeInspector()).scan(root: d).map(\.id.relativePath)
        #expect(names == ["in.gguf"])
    }

    @Test func realInspectorMarksGarbageNotGGUF() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try Data("this is not a model, just text".utf8).write(to: d.appendingPathComponent("x.gguf"))
        let e = FolderScanner().scan(root: d)
        #expect(e.count == 1)
        #expect(e[0].validity == .notGGUF)
    }
}

@Suite struct StoreTests {
    @Test func jsonRoundTripAndClear() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let s = FileBookmarkStore(fileURL: d.appendingPathComponent("nested/folder.json"))
        #expect(s.load() == nil)
        let b = FolderBookmark(bookmarkData: Data([1, 2, 3]), lastKnownPath: "/x", volumeUUID: "U",
                               volumeName: "V", isOnRemovableVolume: true)
        try s.save(b)
        #expect(s.load() == b)
        try s.save(nil)
        #expect(s.load() == nil)
    }
}

@Suite struct ManagerTests {
    @Test func notConfigured() async {
        let m = manager()
        #expect(await m.snapshot().state == .notConfigured)
    }

    @Test func chooseScansAndStoresBookmark() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "a.gguf"); try touch(d, "bad.gguf"); try touch(d, "mmproj-x.gguf")
        let store = MemoryStore()
        let m = manager(store)
        try await m.choose(folder: d)
        let snap = await m.snapshot()
        #expect(snap.state == .available(d))
        #expect(snap.models.count == 2)
        let b = try #require(store.load())
        #expect(b.lastKnownPath == d.path)
        #expect(!b.bookmarkData.isEmpty)
        #expect(b.volumeUUID != nil)

        // A fresh manager on the same store comes back configured.
        let m2 = manager(store)
        #expect(await m2.snapshot().state == .available(d))
        #expect(await m2.snapshot().models.count == 2)
    }

    @Test func chooseValidates() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "f.txt")
        let m = manager()
        await #expect(throws: ModelsFolderError.doesNotExist) { try await m.choose(folder: d.appendingPathComponent("nope")) }
        await #expect(throws: ModelsFolderError.notADirectory) { try await m.choose(folder: d.appendingPathComponent("f.txt")) }
        let locked = d.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        chmod(locked.path, 0o000); defer { chmod(locked.path, 0o755) }
        await #expect(throws: ModelsFolderError.notReadable) { try await m.choose(folder: locked) }
        #expect(await m.snapshot().state == .notConfigured)
    }

    @Test func rescanSeesChanges() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "a.gguf")
        let m = manager()
        try await m.choose(folder: d)
        try touch(d, "b.gguf")
        await m.rescan()
        #expect(await m.snapshot().models.count == 2)
        try FileManager.default.removeItem(at: d.appendingPathComponent("a.gguf"))
        await m.rescan()
        #expect(await m.snapshot().models.map(\.id.relativePath) == ["b.gguf"])
    }

    @Test func splitPartsCollapseToOneEntry() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        for i in 1...3 { try touch(d, "big-0000\(i)-of-00003.gguf", bytes: 10) }
        try touch(d, "other-00001-of-00002.gguf", bytes: 5)
        try touch(d, "plain.gguf", bytes: 1)
        let m = manager()
        try await m.choose(folder: d)
        let models = await m.snapshot().models
        #expect(models.map(\.id.relativePath) == ["big-00001-of-00003.gguf", "other-00001-of-00002.gguf", "plain.gguf"])
        #expect(models[0].validity == .valid)
        #expect(models[0].byteSize == 30)
        #expect(models[1].validity == .splitPart(index: 1, of: 2))
    }

    @Test func pollingSeesChangesWithoutEvents() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "a.gguf")
        let m = manager(poll: 0.1)
        try await m.choose(folder: d)
        try touch(d, "b.gguf")
        for _ in 0..<40 {
            if await m.snapshot().models.count == 2 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("poll did not pick up the new file")
    }

    @Test func folderDeletedThenRestored() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("models")
        try touch(f, "a.gguf")
        let m = manager()
        try await m.choose(folder: f)
        try FileManager.default.removeItem(at: f)
        await m.rescan()
        let s = await m.snapshot()
        #expect(s.state == .missing(lastPath: f.path))
        #expect(s.models.isEmpty)
        try touch(f, "a.gguf")
        await m.rescan()
        #expect(await m.snapshot().models.count == 1)
    }

    @Test func renamedFolderFollowedByBookmark() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("models"), g = d.appendingPathComponent("renamed")
        try touch(f, "a.gguf")
        let store = MemoryStore()
        let m = manager(store)
        try await m.choose(folder: f)
        try FileManager.default.moveItem(at: f, to: g)
        await m.rescan()
        let s = await m.snapshot()
        guard case .available(let u) = s.state else { Issue.record("state \(s.state)"); return }
        #expect(u.path == g.path)
        #expect(s.models.count == 1)
        #expect(store.load()?.lastKnownPath == g.path)  // stored path refreshed
    }

    @Test func staleBookmarkFallsBackToLastPath() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let store = MemoryStore()
        try store.save(FolderBookmark(bookmarkData: Data([0xde, 0xad]), lastKnownPath: d.path,
                                      volumeUUID: nil, volumeName: nil, isOnRemovableVolume: false))
        try touch(d, "a.gguf")
        let m = manager(store)
        #expect(await m.snapshot().state == .available(d))
    }

    @Test func volumeOfflineWhenUUIDNotMounted() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let store = MemoryStore()
        try store.save(FolderBookmark(bookmarkData: Data(), lastKnownPath: d.path,
                                      volumeUUID: "NOT-A-MOUNTED-UUID", volumeName: "Ghost", isOnRemovableVolume: true))
        let m = manager(store)
        #expect(await m.snapshot().state == .volumeOffline(volumeName: "Ghost", lastPath: d.path))
    }

    @Test func permissionDenied() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("m")
        try touch(f, "a.gguf")
        let m = manager()
        try await m.choose(folder: f)
        chmod(f.path, 0o000); defer { chmod(f.path, 0o755) }
        await m.rescan()
        let st = await m.snapshot().state
        guard case .permissionDenied(let u) = st else { Issue.record("state \(st)"); return }
        #expect(u.path == f.path)
    }

    @Test func clearForgets() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let store = MemoryStore()
        let m = manager(store)
        try await m.choose(folder: d)
        await m.clear()
        #expect(await m.snapshot().state == .notConfigured)
        #expect(store.load() == nil)
    }

    @Test func resolveForLoading() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "sub/a.gguf")
        let m = manager()
        let id = ModelEntryID(relativePath: "sub/a.gguf")
        if case .failure(let e) = await m.resolveForLoading(id) { #expect(e.state == .notConfigured) } else { Issue.record("expected failure") }
        try await m.choose(folder: d)
        #expect(try await m.resolveForLoading(id).get() == d.appendingPathComponent("sub/a.gguf"))
        // Path traversal is refused.
        if case .success = await m.resolveForLoading(ModelEntryID(relativePath: "../x.gguf")) { Issue.record("traversal allowed") }
        try FileManager.default.removeItem(at: d.appendingPathComponent("sub/a.gguf"))
        if case .failure(let e) = await m.resolveForLoading(id) {
            #expect(e.state == .missing(lastPath: d.appendingPathComponent("sub/a.gguf").path))
        } else { Issue.record("expected failure") }
        #expect(await m.snapshot().models.isEmpty)  // failure triggered a rescan
    }

    @Test func addedFilesListAfterTheFolderAndLoad() async throws {
        let d = try tempDir(), other = try tempDir()
        defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: other) }
        try touch(d, "a.gguf")
        try touch(other, "outside.gguf", bytes: 16)
        let outside = other.appendingPathComponent("outside.gguf").path
        let gone = other.appendingPathComponent("gone.gguf").path
        let m = manager()
        try await m.choose(folder: d)
        // A path inside the folder is already listed by the scan and isn't repeated.
        await m.setAddedFiles([outside, gone, d.appendingPathComponent("a.gguf").path])
        let models = await m.snapshot().models
        #expect(models.map(\.id.relativePath) == ["a.gguf", outside, gone])
        #expect(models[1].id.isOutsideFolder && models[1].validity == .valid && models[1].byteSize == 16)
        #expect(models[2].validity == .unreadable("file not found"))
        #expect(try await m.resolveForLoading(ModelEntryID(relativePath: outside)).get().path == outside)
        if case .success = await m.resolveForLoading(ModelEntryID(relativePath: gone)) { Issue.record("missing file loaded") }
        // Only listed absolute paths load.
        let stray = other.appendingPathComponent("stray.gguf")
        try touch(other, "stray.gguf")
        if case .success = await m.resolveForLoading(ModelEntryID(relativePath: stray.path)) { Issue.record("unlisted file loaded") }
        await m.setAddedFiles([])
        #expect(await m.snapshot().models.map(\.id.relativePath) == ["a.gguf"])
    }

    @Test func updatesYieldsCurrentThenChanges() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "a.gguf")
        let m = manager()
        var it = m.updates().makeAsyncIterator()
        #expect(await it.next()?.state == .notConfigured)
        try await m.choose(folder: d)
        let s = await it.next()
        #expect(s?.state == .available(d))
        #expect(s?.models.count == 1)
        // An unchanged rescan publishes nothing; the next event is the following real change.
        await m.rescan()
        try touch(d, "b.gguf")
        await m.rescan()
        #expect(await it.next()?.models.count == 2)
    }

    @Test func repeatedSubscribeCancelLeaksNothing() async throws {
        let m = manager()
        for i in 0..<200 {
            if i.isMultiple(of: 2) {
                // Dropped before the actor ever ran: termination precedes the initial yield.
                _ = m.updates()
            } else {
                let stream = m.updates()
                let task = Task { for await _ in stream {} }
                task.cancel()
                await task.value
            }
        }
        // Let the pending initial-yield tasks drain; they must not resurrect anything.
        for _ in 0..<50 where m.subscriberCount > 0 {
            _ = await m.snapshot()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.subscriberCount == 0)
        // A live subscriber still gets the current snapshot.
        var it = m.updates().makeAsyncIterator()
        #expect(await it.next()?.state == .notConfigured)
        #expect(m.subscriberCount == 1)
    }

    @Test func fsEventsTriggersDebouncedRescan() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "a.gguf")
        let m = manager(watch: true, debounce: 0.2)
        try await m.choose(folder: d)
        try await Task.sleep(for: .milliseconds(500))
        try touch(d, "b.gguf")
        var seen = 0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            seen = await m.snapshot().models.count
            if seen == 2 { break }
        }
        #expect(seen == 2)
    }
}

@Suite struct RealFolderTests {
    @Test func devFolderIfPresent() async throws {
        let path = "/Volumes/Samsung 1TB/LLM/GhostType"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let m = ModelsFolderManager(store: MemoryStore(), watch: false)
        try await m.choose(folder: URL(fileURLWithPath: path))
        let s = await m.snapshot()
        // The folder's contents change as models are added or removed; the base model must be there and valid.
        #expect(s.models.contains { $0.id.relativePath == "gemma-4-E4B-it.i1-Q5_K_M.gguf" && $0.validity == .valid })
    }
}


@Suite struct SplitGroupingTests {
    private func entry(_ rel: String, size: Int64 = 10, validity: GGUFValidity? = nil, dir: String = "/m") -> ModelEntry {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(rel)
        let v = validity ?? (SplitName(fileName: url.lastPathComponent).map { .splitPart(index: $0.index, of: $0.total) } ?? .valid)
        return ModelEntry(id: ModelEntryID(relativePath: rel), url: url, byteSize: size, modified: Date(timeIntervalSince1970: 1),
                          validity: v, summary: nil)
    }

    @Test func parsesNames() {
        let n = SplitName(fileName: "Qwen3-Q4_K_M-00002-of-00005.gguf")
        #expect(n == SplitName(fileName: "qwen3-q4_k_m-00002-of-00005.GGUF").map { _ in n! })
        #expect(n?.base == "Qwen3-Q4_K_M")
        #expect(n?.index == 2)
        #expect(n?.total == 5)
        #expect(SplitName(fileName: "plain.gguf") == nil)
        #expect(SplitName(fileName: "x-of-3.gguf") == nil)
        #expect(SplitName(fileName: "m-1-of-x.gguf") == nil)
        #expect(SplitName(fileName: "m-00001-of-00002.bin") == nil)
    }

    @Test func completeSetCollapses() {
        let out = SplitModelGrouping.collapse([entry("a-00002-of-00002.gguf"), entry("a-00001-of-00002.gguf"), entry("z.gguf")])
        #expect(out.count == 2)
        let a = out.first { $0.id.relativePath.hasPrefix("a-") }
        #expect(a?.id.relativePath == "a-00001-of-00002.gguf")
        #expect(a?.byteSize == 20)
        #expect(a?.validity == .valid)
    }

    @Test func missingPartIsUnusable() {
        let out = SplitModelGrouping.collapse([entry("a-00001-of-00003.gguf"), entry("a-00003-of-00003.gguf")])
        #expect(out.count == 1)
        #expect(out[0].validity == .splitPart(index: 1, of: 3))
        let noFirst = SplitModelGrouping.collapse([entry("a-00002-of-00003.gguf"), entry("a-00003-of-00003.gguf")])
        #expect(noFirst.count == 1)
        #expect(noFirst[0].validity != .valid)
    }

    @Test func differentFoldersAndTotalsStaySeparate() {
        let out = SplitModelGrouping.collapse([
            entry("x/a-00001-of-00001.gguf", dir: "/m"), entry("y/a-00001-of-00001.gguf", dir: "/m/y"),
        ])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.validity == .valid })
    }
}
