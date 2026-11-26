// Model discovery and loading shared by the subcommands.
import Foundation
import HunchCore
import HunchLlama
import HunchModels
import HunchPrompt

let evalRuntimeOptions = RuntimeOptions(contextTokens: RuntimeOptions.defaultContextTokens, batchTokens: 512, gpuLayers: -1, loadMode: .mmap,
                                        fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)

func makeEntry(path: String) -> ModelEntry {
    let url = URL(fileURLWithPath: path)
    let (validity, summary) = GGUFInspector().inspect(url)
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return ModelEntry(id: ModelEntryID(relativePath: url.lastPathComponent), url: url,
                      byteSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                      modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                      validity: validity, summary: summary)
}

/// Wraps a host so the engine sees a different `addsBOS` (the engine trusts the host's
/// `.ready` profile). Used by configs that force `addBOS`.
final class BOSOverridingHost: ModelHosting {
    private let inner: any ModelHosting
    private let addsBOS: Bool
    init(_ inner: any ModelHosting, addsBOS: Bool) {
        self.inner = inner
        self.addsBOS = addsBOS
    }

    func state() async -> ModelLoadState {
        let s = await inner.state()
        if case .ready(let id, var profile) = s {
            profile.addsBOS = addsBOS
            return .ready(id, profile)
        }
        return s
    }

    func states() -> AsyncStream<ModelLoadState> { inner.states() }
    func load(_ entry: ModelEntry, options: RuntimeOptions) async { await inner.load(entry, options: options) }
    func unload() async { await inner.unload() }
    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        try await inner.withSession(id, body)
    }

    func cancel(olderThan id: RequestID) { inner.cancel(olderThan: id) }
}

/// Hands out strictly increasing request ids across engines (the executor rejects stale ids).
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> RequestID { lock.withLock { value += 1; return RequestID(value) } }
}

func describe(_ validity: GGUFValidity) -> String {
    switch validity {
    case .valid: return "valid"
    case .notGGUF: return "not-gguf"
    case .unsupportedVersion(let v): return "unsupported-version(\(v))"
    case .truncated: return "truncated"
    case .malformedMetadata(let m): return "malformed(\(m))"
    case .splitPart(let i, let n): return "split(\(i)/\(n))"
    case .auxiliary(let a): return "auxiliary(\(a))"
    case .unreadable(let r): return "unreadable(\(r))"
    }
}

// MARK: - inspect

func runInspect(_ args: [String]) -> Int32 {
    guard let folder = args.first else {
        printErr("usage: hunch-eval inspect <folder>")
        return ExitCode.usage
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
        printErr("not a folder: \(folder)")
        return ExitCode.failure
    }
    let url = URL(fileURLWithPath: folder)
    let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension.lowercased() == "gguf" }
        .sorted { $0.path < $1.path }
    if files.isEmpty {
        printOut("no .gguf files under \(folder)")
        return ExitCode.ok
    }
    let detector = DefaultModelProfileDetector()
    let registry = DefaultFramerRegistry()
    for file in files {
        let entry = makeEntry(path: file.path)
        let size = String(format: "%.2f GB", Double(entry.byteSize) / 1e9)
        var line = "\(file.lastPathComponent)  [\(size)]  \(describe(entry.validity))"
        if let summary = entry.summary, entry.validity == .valid {
            let profile = detector.detect(summary, fileName: file.lastPathComponent)
            let framer = registry.framer(for: profile, override: nil).id
            line += "\n    arch=\(summary.architecture ?? "?")  name=\(summary.name ?? "?")  "
                + "kind=\(profile.isInstruct ? "instruct" : "base")  family=\(profile.family.rawValue)  "
                + "ctx=\(summary.contextLength.map(String.init) ?? "?")  addBOS(meta)=\(summary.addBOS.map { "\($0)" } ?? "?")  "
                + "chatMarkers=\(profile.markers != nil)\n    framer=\(framer)"
        }
        printOut(line)
    }
    return ExitCode.ok
}
