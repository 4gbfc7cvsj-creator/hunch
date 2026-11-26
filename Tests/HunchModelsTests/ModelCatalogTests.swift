import Foundation
import Testing
@testable import HunchModels
import HunchCore

private let gib: UInt64 = 1 << 30

@Suite struct ModelCatalogTests {
    @Test func entriesAreWellFormed() {
        #expect(ModelCatalog.updated == "2026-10-19")
        #expect((12...14).contains(ModelCatalog.entries.count))
        #expect(Set(ModelCatalog.entries.map(\.fileName)).count == ModelCatalog.entries.count)
        for e in ModelCatalog.entries {
            #expect(e.sha256.count == 64 && e.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(e.byteSize > 0)
            #expect(e.fileName.hasSuffix(e.use == .speechToText ? ".bin" : ".gguf"))
            #expect(DownloadPlan.url(for: e) != nil)
        }
        // One pick per tier within each language-model use.
        for use in [ModelUse.autocomplete, .writing] {
            for tier in MemoryTier.allCases {
                #expect(ModelCatalog.entries(for: use).filter { $0.recommendedTier == tier }.count == 1)
            }
            let small = ModelCatalog.entries(for: use).first { $0.recommendedTier == .small }!
            #expect(small.parameterBillions <= 2 && small.quantization.hasPrefix("Q4"))
        }
        // Speech: the six whisper.cpp models, Turbo the only pick (every tier falls back to it).
        let speech = ModelCatalog.entries(for: .speechToText)
        #expect(speech.count == 6 && speech.allSatisfy { $0.use == .speechToText && !$0.isInstruct })
        #expect(speech.filter { $0.recommendedTier != nil }.map(\.fileName) == ["ggml-large-v3-turbo.bin"])
        for ram: UInt64 in [8 * gib, 16 * gib, 64 * gib] {
            #expect(ModelRecommender.recommend(ramBytes: ram, chipBrand: "Apple M1", freeDiskBytes: nil,
                                               catalog: speech)?.model.fileName == "ggml-large-v3-turbo.bin")
        }
        #expect(ModelCatalog.entry(forFileName: "ggml-large-v3-turbo.bin")?.use == .speechToText)
        #expect(ModelCatalog.entries(for: .writing).allSatisfy { $0.isInstruct })
        #expect(ModelCatalog.entries(for: .autocomplete) == ModelCatalog.entries(for: .writing))
        // The development model is in the catalog.
        #expect(ModelCatalog.entry(forFileName: "gemma-4-E4B.i1-Q5_K_M.gguf")?.recommendedTier == .standard)
    }

    @Test func fileNameMatching() {
        #expect(ModelCatalog.entry(forFileName: "gemma-4-E4B.i1-Q5_K_M.gguf")?.displayName == "Gemma 4 E4B")
        #expect(ModelCatalog.entry(forFileName: "sub/GEMMA-4-E4B.I1-Q5_K_M.GGUF")?.displayName == "Gemma 4 E4B")
        #expect(ModelCatalog.entry(forFileName: "gemma-4-E4B.i1-Q5_K_M.gguf.part") == nil)
        #expect(ModelCatalog.entry(forFileName: "gemma-4-E4B.i1-Q4_K_M.gguf") == nil)
        let present = ModelCatalog.downloaded(relativePaths: ["a.gguf", "x/Qwen3-8B-Base.i1-Q4_K_M.gguf"])
        #expect(present == ["Qwen3-8B-Base.i1-Q4_K_M.gguf"])
    }

    @Test func parameterQuantLine() {
        let it = ModelCatalog.entry(forFileName: "gemma-4-E4B-it.i1-Q5_K_M.gguf")!
        #expect(it.parameterQuantLine == "E4B · Q5_K_M · instruct")
        #expect(ModelCatalog.entry(forFileName: "Qwen3-1.7B-Base.i1-Q4_K_M.gguf")!.parameterQuantLine == "1.7B · Q4_K_M")
    }
}

@Suite struct ModelRecommenderTests {
    @Test func tiers() {
        #expect(ModelRecommender.tier(ramBytes: 8 * gib) == .small)
        #expect(ModelRecommender.tier(ramBytes: 16 * gib) == .standard)
        #expect(ModelRecommender.tier(ramBytes: 24 * gib) == .standard)
        #expect(ModelRecommender.tier(ramBytes: 32 * gib) == .large)
        #expect(ModelRecommender.tier(ramBytes: 128 * gib) == .large)
    }

    @Test func recommendsPerTier() {
        let lots: Int64 = 1 << 40
        let r8 = ModelRecommender.recommend(ramBytes: 8 * gib, chipBrand: "Apple M1", freeDiskBytes: lots)!
        #expect(r8.model.parameterBillions <= 2)
        #expect(r8.warnings.isEmpty)
        #expect(r8.reason == "Fits comfortably in 8 GB")

        let r16 = ModelRecommender.recommend(ramBytes: 16 * gib, chipBrand: "Apple M2 Pro", freeDiskBytes: lots)!
        #expect(r16.model.fileName == "gemma-4-E4B-it.i1-Q5_K_M.gguf")
        #expect(r16.reason == "Fits comfortably in 16 GB")
        #expect(r16.warnings.isEmpty)

        let r32 = ModelRecommender.recommend(ramBytes: 32 * gib, chipBrand: "Apple M3 Max", freeDiskBytes: lots)!
        #expect(r32.model.parameterLabel == "8B" && r32.model.quantization == "Q4_K_M")
        // The Language Model is an instruct model.
        #expect(r32.model.isInstruct)
    }

    @Test func recommendsWritingModelsPerTier() {
        let writing = ModelCatalog.entries(for: .writing)
        func pick(_ ram: UInt64) -> String? {
            ModelRecommender.recommend(ramBytes: ram, chipBrand: "Apple M4", freeDiskBytes: nil, catalog: writing)?
                .model.fileName
        }
        #expect(pick(8 * gib) == "Qwen3-1.7B.i1-Q4_K_M.gguf")
        #expect(pick(16 * gib) == "gemma-4-E4B-it.i1-Q5_K_M.gguf")
        #expect(pick(64 * gib) == "Qwen3-8B.i1-Q4_K_M.gguf")
    }

    @Test func diskWarningBelowSizePlusTenPercent() {
        let model = ModelCatalog.entry(forFileName: "gemma-4-E4B-it.i1-Q5_K_M.gguf")!
        let required = ModelRecommender.requiredDiskBytes(for: model)
        #expect(required == model.byteSize + model.byteSize / 10)
        let short = ModelRecommender.recommend(ramBytes: 16 * gib, chipBrand: "Apple M4", freeDiskBytes: required - 1)!
        #expect(short.warnings == [.disk(requiredBytes: required, freeBytes: required - 1)])
        #expect(short.warnings[0].message.hasPrefix("Needs 6.3 GB of free disk space"))
        let enough = ModelRecommender.recommend(ramBytes: 16 * gib, chipBrand: "Apple M4", freeDiskBytes: required)!
        #expect(enough.warnings.isEmpty)
        let unknown = ModelRecommender.recommend(ramBytes: 16 * gib, chipBrand: "Apple M4", freeDiskBytes: nil)!
        #expect(unknown.warnings.isEmpty)
    }

    @Test func diskWarningCountsBytesAlreadyDownloaded() {
        let model = ModelCatalog.entry(forFileName: "gemma-4-E4B.i1-Q5_K_M.gguf")!
        let required = ModelRecommender.requiredDiskBytes(for: model)
        let part: Int64 = 3_000_000_000
        // Mid-download: the part's bytes are already used, so less free space is enough.
        #expect(ModelRecommender.warnings(for: model, ramBytes: 16 * gib, chipBrand: "Apple M4",
                                          freeDiskBytes: required - part, downloadedBytes: part).isEmpty)
        #expect(ModelRecommender.warnings(for: model, ramBytes: 16 * gib, chipBrand: "Apple M4",
                                          freeDiskBytes: required - part - 1, downloadedBytes: part)
                == [.disk(requiredBytes: required - part, freeBytes: required - part - 1)])
        // Downloaded: no disk warning at all.
        #expect(ModelRecommender.warnings(for: model, ramBytes: 16 * gib, chipBrand: "Apple M4",
                                          freeDiskBytes: 0, downloadedBytes: model.byteSize).isEmpty)
    }

    @Test func memoryWarningWhenMinimumExceedsRAM() {
        let gemma = ModelCatalog.entry(forFileName: "gemma-4-E4B.i1-Q5_K_M.gguf")!
        let w = ModelRecommender.warnings(for: gemma, ramBytes: 8 * gib, chipBrand: "Apple M1", freeDiskBytes: nil)
        #expect(w == [.memory(requiredBytes: 16 * gib, physicalBytes: 8 * gib)])
        #expect(w[0].message == "Needs 16 GB of memory; this Mac has 8 GB.")
        // A catalog whose only entry is too big still yields it, with the warning and another reason.
        let r = ModelRecommender.recommend(ramBytes: 8 * gib, chipBrand: "Apple M1", freeDiskBytes: nil,
                                           catalog: [gemma])!
        #expect(r.model == gemma)
        #expect(r.warnings.count == 1)
        #expect(r.reason == "The smallest model in the catalog")
    }

    @Test func chipWarning() {
        let m = ModelCatalog.entries[0]
        #expect(ModelRecommender.warnings(for: m, ramBytes: 64 * gib, chipBrand: "Intel(R) Core(TM) i9",
                                          freeDiskBytes: nil) == [.notAppleSilicon])
        #expect(ModelRecommender.warnings(for: m, ramBytes: 64 * gib, chipBrand: "", freeDiskBytes: nil).isEmpty)
    }

    @Test func emptyCatalog() {
        #expect(ModelRecommender.recommend(ramBytes: 16 * gib, chipBrand: "Apple M1", freeDiskBytes: nil,
                                           catalog: []) == nil)
    }

    @Test func machineFactsReadLocally() {
        #expect(MachineFacts.physicalMemory > 0)
        #expect(MachineFacts.freeDiskBytes(at: FileManager.default.temporaryDirectory) != nil)
        _ = MachineFacts.chipBrand
    }
}

@Suite struct DownloadPlanTests {
    @Test func urlBuilding() {
        let url = DownloadPlan.url(repo: "mradermacher/gemma-4-E4B-i1-GGUF", fileName: "gemma-4-E4B.i1-Q5_K_M.gguf")
        #expect(url?.absoluteString
                == "https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF/resolve/main/gemma-4-E4B.i1-Q5_K_M.gguf?download=true")
        #expect(DownloadPlan.url(repo: "a/b", fileName: "x y.gguf")?.absoluteString
                == "https://huggingface.co/a/b/resolve/main/x%20y.gguf?download=true")
        #expect(DownloadPlan.url(repo: "a", fileName: "x.gguf") == nil)
        #expect(DownloadPlan.url(repo: "a/b/c", fileName: "x.gguf") == nil)
        #expect(DownloadPlan.url(repo: "../b", fileName: "x.gguf") == nil)
        #expect(DownloadPlan.url(repo: "a/b", fileName: "../x.gguf") == nil)
        #expect(DownloadPlan.url(repo: "a/b", fileName: ".hidden.gguf") == nil)
    }

    @Test func partAndFinalPaths() {
        let folder = URL(fileURLWithPath: "/m")
        #expect(DownloadPlan.partURL(for: "a.gguf", in: folder).path == "/m/a.gguf.part")
        #expect(DownloadPlan.finalURL(for: "a.gguf", in: folder).path == "/m/a.gguf")
    }

    @Test func resumeOffsets() {
        #expect(DownloadPlan.resumeOffset(partBytes: 0, expectedBytes: 100) == 0)
        #expect(DownloadPlan.resumeOffset(partBytes: 40, expectedBytes: 100) == 40)
        #expect(DownloadPlan.resumeOffset(partBytes: 100, expectedBytes: 100) == 100)
        #expect(DownloadPlan.resumeOffset(partBytes: 101, expectedBytes: 100) == 0)
        #expect(DownloadPlan.rangeHeader(offset: 0) == nil)
        #expect(DownloadPlan.rangeHeader(offset: 40) == "bytes=40-")
    }

    @Test func responseActions() {
        typealias P = DownloadPlan
        #expect(P.action(status: 200, contentRange: nil, retryAfter: nil, requestedOffset: 0, mayRetry: true) == .write(from: 0))
        // Range ignored: whole file again.
        #expect(P.action(status: 200, contentRange: nil, retryAfter: nil, requestedOffset: 40, mayRetry: true) == .write(from: 0))
        #expect(P.action(status: 206, contentRange: "bytes 40-99/100", retryAfter: nil, requestedOffset: 40,
                         mayRetry: true) == .write(from: 40))
        #expect(P.action(status: 206, contentRange: "bytes 0-99/100", retryAfter: nil, requestedOffset: 40,
                         mayRetry: true) == .fail(status: 206))
        #expect(P.action(status: 206, contentRange: nil, retryAfter: nil, requestedOffset: 40, mayRetry: true) == .fail(status: 206))
        #expect(P.action(status: 404, contentRange: nil, retryAfter: nil, requestedOffset: 0, mayRetry: true) == .fail(status: 404))
        #expect(P.action(status: 429, contentRange: nil, retryAfter: "5", requestedOffset: 0, mayRetry: true) == .retry(after: 5))
        #expect(P.action(status: 503, contentRange: nil, retryAfter: nil, requestedOffset: 0, mayRetry: true)
                == .retry(after: P.defaultRetryDelay))
        #expect(P.action(status: 429, contentRange: nil, retryAfter: "5", requestedOffset: 0, mayRetry: false) == .fail(status: 429))
        #expect(P.action(status: 429, contentRange: nil, retryAfter: "3600", requestedOffset: 0, mayRetry: true) == .fail(status: 429))
    }

    @Test func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)  // Sun, 09 Sep 2001 01:46:40 GMT
        #expect(DownloadPlan.retryDelay("0", now: now) == 0)
        #expect(DownloadPlan.retryDelay(" 12 ", now: now) == 12)
        #expect(DownloadPlan.retryDelay("Sun, 09 Sep 2001 01:47:00 GMT", now: now) == 20)
        #expect(DownloadPlan.retryDelay("Sun, 09 Sep 2001 01:00:00 GMT", now: now) == 0)
        #expect(DownloadPlan.retryDelay("garbage", now: now) == DownloadPlan.defaultRetryDelay)
        #expect(DownloadPlan.retryDelay("61", now: now) == nil)
    }

    @Test func contentRange() {
        #expect(DownloadPlan.contentRangeStart("bytes 40-99/100") == 40)
        #expect(DownloadPlan.contentRangeStart("bytes 0-0/*") == 0)
        #expect(DownloadPlan.contentRangeStart("items 1-2/3") == nil)
        #expect(DownloadPlan.contentRangeStart("bytes */100") == nil)
    }

    @Test func progressSummaryAndThroughput() {
        let p = DownloadProgress(receivedBytes: 1_200_000_000, totalBytes: 5_762_896_640, bytesPerSecond: 35_200_000)
        #expect(p.summary == "1.2 of 5.8 GB · 35 MB/s")
        #expect(abs(p.fraction - 0.2082) < 0.001)
        var m = ThroughputMeter(window: 3)
        #expect(m.bytesPerSecond == 0)
        m.record(totalBytes: 0, at: 0)
        m.record(totalBytes: 10_000_000, at: 1)
        #expect(m.bytesPerSecond == 10_000_000)
        m.record(totalBytes: 20_000_000, at: 2)
        m.record(totalBytes: 50_000_000, at: 5)  // the t=0 and t=1 samples drop out
        #expect(m.bytesPerSecond == 10_000_000)
    }

    @Test func scannerIgnoresPartFiles() throws {
        struct Valid: GGUFInspecting {
            func inspect(_ url: URL) -> (GGUFValidity, GGUFSummary?) { (.valid, GGUFSummary(version: 3)) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 8).write(to: dir.appendingPathComponent("a.gguf"))
        try Data(count: 8).write(to: DownloadPlan.partURL(for: "b.gguf", in: dir))
        let names = FolderScanner(inspector: Valid()).scan(root: dir).map(\.id.relativePath)
        #expect(names == ["a.gguf"])
    }
}
