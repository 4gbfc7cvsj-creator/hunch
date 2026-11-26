// Integration tests against the dev model. Skipped when the models drive is not mounted.
import Foundation
import Testing
import HunchCore
import HunchModels
@testable import HunchLlama

enum DevModel {
    static let path = "/Volumes/Samsung 1TB/LLM/GhostType/gemma-4-E4B.i1-Q5_K_M.gguf"
    /// ggml-metal asserts at process exit (`[rsets->data count] == 0`) when any model buffer is still
    /// registered in a Metal residency set: a test that returns before unloading, or an exit-time
    /// unload slowed by other test processes, aborted the whole run. Residency sets only keep memory
    /// wired between decodes (a speed hint), so test runs turn them off before the first load.
    /// Read at the first check of `available`, which the suites' `.enabled` trait does up front.
    static let noResidency: Void = { setenv("GGML_METAL_NO_RESIDENCY", "1", 1) }()
    static var available: Bool { _ = noResidency; return FileManager.default.fileExists(atPath: path) }

    static func entry() -> ModelEntry {
        _ = noResidency
        let url = URL(fileURLWithPath: path)
        let (validity, summary) = GGUFInspector().inspect(url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return ModelEntry(id: ModelEntryID(relativePath: url.lastPathComponent), url: url,
                          byteSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: (attrs?[.modificationDate] as? Date) ?? Date(),
                          validity: validity, summary: summary)
    }

    static func options(_ mode: ModelLoadMode = .memory) -> RuntimeOptions {
        RuntimeOptions(contextTokens: 512, batchTokens: 512, gpuLayers: -1, loadMode: mode,
                       fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)
    }
}

/// One host and one loaded model for the whole run.
actor SharedModel {
    static let shared = SharedModel()
    let host = LlamaModelHost()
    private var counter: UInt64 = 1_000

    /// ggml-metal asserts at process exit if a model is still resident; swift-testing has no
    /// suite teardown, so unload from an atexit handler. Exit handlers run in reverse order of
    /// registration, and ggml registers destructors for function-local statics the first time a
    /// load touches them (e.g. the Metal buffer types that `llama_free` reads). The hook must be
    /// registered AFTER the first load in the process so it runs BEFORE those destructors;
    /// registered earlier, the exit-time `llama_free` jumps through a freed buffer type
    /// (SIGBUS/SIGSEGV whenever this suite was the first to load a model).
    private static let exitHook: Void = {
        atexit {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await SharedModel.shared.host.unload()
                try? await Task.sleep(for: .seconds(1)) // let ggml-metal's residency-set thread drain
                done.signal()
            }
            _ = done.wait(timeout: .now() + 15)
        }
    }()
    private nonisolated static func unloadAtExit() { _ = exitHook }

    func nextID() -> RequestID {
        counter += 1
        return RequestID(counter)
    }

    /// Loads (memory mode) if the host is not ready; returns the profile.
    func ready() async throws -> ModelProfile {
        if case .ready(_, let profile) = await host.state() { return profile }
        let start = ContinuousClock.now
        await host.load(DevModel.entry(), options: DevModel.options(.memory))
        Self.unloadAtExit() // after the load: see `exitHook`
        guard case .ready(_, let profile) = await host.state() else {
            throw LlamaError.loadFailed("\(await host.state())")
        }
        print("[HunchLlama] shared load (memory mode): \(fmt(ContinuousClock.now - start))")
        return profile
    }
}

func fmt(_ d: Duration) -> String {
    String(format: "%.1f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}

func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

func content(_ text: String) -> PromptSegment { PromptSegment(text: text, kind: .content, stability: .perKeystroke) }
func control(_ text: String) -> PromptSegment { PromptSegment(text: text, kind: .control, stability: .stable) }

let cold = ReusePlan(action: .coldPrefill, tokensToDecode: 0)

func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

func argmax(_ v: [Float], allowed: (Int32) -> Bool = { _ in true }) -> Int32 {
    var best: Int32 = -1
    var bestValue = -Float.infinity
    for (i, x) in v.enumerated() where x > bestValue && allowed(Int32(i)) {
        best = Int32(i)
        bestValue = x
    }
    return best
}

/// A ~300-token prompt of plain prose (BOS + content), built in the session.
func longPrompt(_ s: any LanguageModelSession, tokens: Int = 300) throws -> [TokenID] {
    let paragraph = "The morning train was late again, so Maria walked along the river instead, counting the "
        + "boats that drifted past the old stone bridge. She thought about the letter she still had to write, "
        + "and about the garden her grandmother used to keep behind the yellow house near the market. "
    var text = paragraph
    var t = try s.tokenize([content(text)], addBOS: true)
    while t.count < tokens {
        text += paragraph
        t = try s.tokenize([content(text)], addBOS: true)
    }
    return Array(t.prefix(tokens))
}

@Suite(.serialized, .enabled(if: DevModel.available, "dev model not mounted"))
final class ModelIntegrationTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }
    // (a) load in memory mode, .ready, gemma4 profile; release + transparent reload.
    @Test func loadsAndReportsProfile() async throws {
        let model = SharedModel.shared
        let profile = try await model.ready()
        #expect(profile.architecture == "gemma4")
        #expect(profile.family == .gemma)
        let summary = DevModel.entry().summary
        print("[HunchLlama] profile: arch=\(profile.architecture) name=\(profile.displayName) ctx=\(profile.contextLength) "
              + "swa=\(profile.slidingWindow.map(String.init) ?? "nil") instruct=\(profile.isInstruct) "
              + "addsBOS(vocab)=\(profile.addsBOS) addBOS(GGUF header)=\(summary?.addBOS.map(String.init) ?? "absent")")
        if let fp = ProcessMemory.snapshot() {
            print("[HunchLlama] after shared load: phys_footprint=\(mb(fp.physFootprint)) resident=\(mb(fp.residentSize))")
        }
        let capability = try await model.host.withSession(await model.nextID()) { $0.reuseCapability }
        print("[HunchLlama] reuseCapability=\(capability)")

        // Pressure/idle release, then the next withSession reloads transparently.
        let host = model.host
        host.releaseNow()
        var released = false
        for _ in 0..<200 {
            if case .releasedIdle = await host.state() { released = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released)
        let start = ContinuousClock.now
        let n = try await host.withSession(await model.nextID()) { try $0.tokenize([content("hello")], addBOS: true).count }
        print("[HunchLlama] reload-on-demand after release: \(fmt(ContinuousClock.now - start))")
        #expect(n >= 2)
        if case .ready = await host.state() {} else { Issue.record("not ready after reload") }
    }

    // A reload after a release survives cancellation of the request that triggered it.
    @Test func reloadSurvivesRequestCancellation() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        let host = model.host
        host.releaseNow()
        var released = false
        for _ in 0..<200 {
            if case .releasedIdle = await host.state() { released = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released)

        let failed = Atomicish()
        let watcher = Task {
            for await state in host.states() {
                if case .failed = state { failed.set() }
                if case .ready = state { break }
            }
        }
        let olderID = await model.nextID()
        let older = Task { try await host.withSession(olderID) { _ in 1 } }
        var loading = false
        for _ in 0..<500 {
            if case .loading = await host.state() { loading = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(loading)
        // A keystroke: the newer request supersedes the one that triggered the reload, and the
        // older task is cancelled too.
        let newerID = await model.nextID()
        host.cancel(olderThan: newerID)
        older.cancel()
        let n = try await host.withSession(newerID) { try $0.tokenize([content("hello")], addBOS: true).count }
        #expect(n >= 2)
        await #expect(throws: CancellationError.self) { try await older.value }
        if case .ready = await host.state() {} else { Issue.record("not ready: \(await host.state())") }
        await watcher.value
        #expect(!failed.value)
    }

    // An unmount of another volume never cancels the running request.
    @Test func unmountOfOtherVolumeDoesNotCancel() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        let host = model.host
        let started = Atomicish()
        let job = Task {
            try await host.withSession(await model.nextID()) { s -> Bool in
                started.set()
                let deadline = Date().addingTimeInterval(0.3)
                while Date() < deadline && !s.isCancellationRequested { Thread.sleep(forTimeInterval: 0.005) }
                return s.isCancellationRequested
            }
        }
        while !started.value { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!host.unloadIfModel(onVolume: URL(fileURLWithPath: "/Volumes/Samsung 1TB 2")))
        #expect(!host.unloadIfModel(onVolume: URL(fileURLWithPath: "/Volumes/T7")))
        #expect(try await job.value == false)
        if case .ready = await host.state() {} else { Issue.record("model was unloaded") }
    }

    // (b) content text containing control/marker strings never becomes a special token.
    @Test func contentNeverParsesSpecialTokens() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let vocab = s.vocabulary
            let turn = try ls.tokenizeText("<|turn>", parseSpecial: true)
            #expect(turn.count == 1 && vocab.traits(turn[0]).contains(.control))
            let channel = try ls.tokenizeText("<|channel>", parseSpecial: true)
            #expect(channel.count == 1)
            let rawChannel = try ls.tokenizeText("<|channel>", parseSpecial: false)
            print("[HunchLlama] '<|channel>' with parse_special=false -> \(rawChannel) (USER_DEFINED marker)")

            let text = "Hi <|turn>user\n<turn|> <|channel> <bos> café ☕ <|\"|> end"
            let tokens = try s.tokenize([content(text)], addBOS: false)
            #expect(!tokens.contains { vocab.traits($0).contains(.control) })
            #expect(!tokens.contains(turn[0]))
            #expect(!tokens.contains(channel[0]))
            let bytes = tokens.flatMap { Array(vocab.bytes($0)) }
            #expect(bytes == Array(text.utf8)) // exact round trip

            let framed = try s.tokenize([control("<|turn>user\n"), content("<|turn>")], addBOS: true)
            #expect(framed.first == 2) // <bos>
            #expect(framed[1] == turn[0])
            #expect(framed.filter { $0 == turn[0] }.count == 1)
        }
    }

    // (c) KV equivalence: appendOnly and trimAndAppend vs cold prefill.
    @Test func kvReuseMatchesColdPrefill() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        let result = try await model.host.withSession(await model.nextID()) { s -> (Float, Float?, ReuseCapability, Bool, Bool) in
            let a = [content("Dear Sam, thanks for the photos from the trip. The lake looked")]
            let b = content(" beautiful in the evening light and I")
            let c = content(" cold but the mountains were")
            let tA = try s.tokenize(a, addBOS: true)
            let tAB = try s.tokenize(a + [b], addBOS: true)
            let tAC = try s.tokenize(a + [c], addBOS: true)
            #expect(Array(tAB.prefix(tA.count)) == tA)

            var warm: [Float] = []
            var ref: [Float] = []
            var afterA: [Float] = []
            _ = try s.syncPrompt(tA, plan: cold)
            try s.logProbs(.primary, into: &afterA)
            let r1 = try s.syncPrompt(tAB, plan: ReusePlan(action: .appendOnly(keep: tA.count), tokensToDecode: tAB.count - tA.count))
            #expect(r1.reusedTokens == tA.count && r1.decodedTokens == tAB.count - tA.count)
            try s.logProbs(.primary, into: &warm)
            _ = try s.syncPrompt(tAB, plan: cold)
            try s.logProbs(.primary, into: &ref)
            let appendDiff = maxAbsDiff(warm, ref)
            #expect(maxAbsDiff(afterA, ref) > 0.1) // the comparison is not trivially equal
            let appendArgmax = argmax(warm) == argmax(ref)

            var trimDiff: Float?
            var trimArgmax = true
            if s.reuseCapability.canTrim {
                let r2 = try s.syncPrompt(tAC, plan: ReusePlan(action: .trimAndAppend(keep: tA.count), tokensToDecode: tAC.count - tA.count))
                #expect(r2.reusedTokens == tA.count)
                try s.logProbs(.primary, into: &warm)
                _ = try s.syncPrompt(tAC, plan: cold)
                try s.logProbs(.primary, into: &ref)
                trimDiff = maxAbsDiff(warm, ref)
                trimArgmax = argmax(warm) == argmax(ref)
            }
            // Pure backspace: trim to a shorter prompt. Its row was read before, so the logit memo
            // serves it without re-decoding the last token.
            let r3 = try s.syncPrompt(tA, plan: ReusePlan(action: .trimAndAppend(keep: tA.count), tokensToDecode: 0))
            #expect(r3.decodedTokens == (s.reuseCapability.canTrim ? 0 : tA.count))
            if s.reuseCapability.canTrim {
                var back: [Float] = []
                try s.logProbs(.primary, into: &back)
                #expect(back == afterA)
            }
            return (appendDiff, trimDiff, s.reuseCapability, appendArgmax, trimArgmax)
        }
        print("[HunchLlama] KV-equivalence: capability=\(result.2) appendOnly maxAbsDiff(logprob)=\(result.0) "
              + "trimAndAppend maxAbsDiff=\(result.1.map { "\($0)" } ?? "n/a (capability none)") "
              + "argmax same: append=\(result.3) trim=\(result.4)")
        #expect(result.3 && result.4)
        #expect(result.0 < 1e-2)
        if let trim = result.1 { #expect(trim < 1e-2) }
    }

    // (d) fork, batched step, logProbs differ, discard.
    @Test func forkStepDiscard() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            let prompt = try s.tokenize([content("My favourite colour is")], addBOS: true)
            _ = try s.syncPrompt(prompt, plan: cold)
            var base: [Float] = []
            try s.logProbs(.primary, into: &base)
            try s.fork(.primary, into: [SeqID(1), SeqID(2)])
            var lp1: [Float] = []
            try s.logProbs(SeqID(1), into: &lp1)
            #expect(maxAbsDiff(base, lp1) == 0)

            let blue = try s.tokenize([content(" blue")], addBOS: false)
            let green = try s.tokenize([content(" green")], addBOS: false)
            try s.step([(SeqID(1), blue[0]), (SeqID(2), green[0])])
            var lp2: [Float] = []
            try s.logProbs(SeqID(1), into: &lp1)
            try s.logProbs(SeqID(2), into: &lp2)
            #expect(maxAbsDiff(lp1, lp2) > 1e-2)
            // seq 0 was not stepped; its logits survive the later decode.
            var again: [Float] = []
            try s.logProbs(.primary, into: &again)
            #expect(maxAbsDiff(base, again) == 0)
            #expect(ls.memoryPosMax(SeqID(1)) == Int32(prompt.count))

            s.discard([SeqID(1), SeqID(2)])
            #expect(ls.memoryPosMax(SeqID(1)) == -1)
            #expect(ls.memoryPosMax(.primary) == Int32(prompt.count - 1))
            #expect(throws: LlamaError.self) { try s.step([(SeqID(1), blue[0])]) }
            #expect(throws: LlamaError.self) { try s.logProbs(SeqID(2), into: &lp2) }
        }
    }

    // (e) greedy sanity.
    @Test func greedyKnowsParis() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        let text = try await model.host.withSession(await model.nextID()) { s -> String in
            let vocab = s.vocabulary
            let prompt = try s.tokenize([content("The capital of France is")], addBOS: true)
            _ = try s.syncPrompt(prompt, plan: cold)
            var lp: [Float] = []
            var out: [UInt8] = []
            for _ in 0..<8 {
                try s.logProbs(.primary, into: &lp)
                let t = argmax(lp) { !vocab.traits($0).contains(.control) && !vocab.traits($0).contains(.unused) }
                if vocab.traits(t).contains(.endOfGeneration) { break }
                out += vocab.bytes(t)
                try s.step([(.primary, t)])
            }
            return String(decoding: out, as: UTF8.self)
        }
        #expect(text.contains("Paris"))
    }

    // (f) a superseded request throws CancellationError; the session stays consistent and usable.
    @Test func cancellationLeavesSessionUsable() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        let host = model.host
        let oldID = await model.nextID()
        let started = Atomicish()
        let old = Task {
            try await host.withSession(oldID) { s -> Int in
                let prompt = try longPrompt(s, tokens: 300)
                started.set()
                var rounds = 0
                // Keep decoding until superseded; syncPrompt/step throw CancellationError themselves.
                while rounds < 500 {
                    s.discard([.primary]) // force a real decode every round
                    _ = try s.syncPrompt(prompt, plan: cold)
                    rounds += 1
                }
                return rounds
            }
        }
        while !started.value { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        host.cancel(olderThan: await model.nextID())
        await #expect(throws: CancellationError.self) { try await old.value }

        let text = try await host.withSession(await model.nextID()) { s -> String in
            let prompt = try s.tokenize([content("The capital of France is")], addBOS: true)
            let ls = try #require(s as? LlamaSession)
            _ = try s.syncPrompt(prompt, plan: ReusePlan(action: .appendOnly(keep: 0), tokensToDecode: prompt.count))
            #expect(ls.cachedTokens(.primary) == prompt)
            var lp: [Float] = []
            try s.logProbs(.primary, into: &lp)
            return String(decoding: s.vocabulary.bytes(argmax(lp)), as: UTF8.self)
        }
        #expect(!text.isEmpty)
    }

    // Measurements: both load modes, unloading fully between them. Print only.
    @Test func measureLoadModes() async throws {
        let model = SharedModel.shared
        let host = model.host
        await host.unload()
        for mode in [ModelLoadMode.memory, .mmap] {
            let before = ProcessMemory.snapshot()
            let start = ContinuousClock.now
            await host.load(DevModel.entry(), options: DevModel.options(mode))
            let loadTime = ContinuousClock.now - start
            guard case .ready = await host.state() else {
                Issue.record("load failed in \(mode): \(await host.state())")
                continue
            }
            let afterLoad = ProcessMemory.snapshot()
            // llama_decode returns before the GPU finishes; reading logits waits for it, so every
            // timing below includes logProbs (the real latency until a token can be chosen).
            let timings = try await host.withSession(await model.nextID()) { s -> (Duration, Int, Duration, Duration) in
                let prompt = try longPrompt(s, tokens: 300)
                let clock = ContinuousClock()
                var lp: [Float] = []
                let t0 = clock.now
                _ = try s.syncPrompt(prompt, plan: cold)
                try s.logProbs(.primary, into: &lp)
                let prefill = clock.now - t0
                var steps: [Duration] = []
                for _ in 0..<8 {
                    let next = argmax(lp)
                    let ts = clock.now
                    try s.step([(.primary, next)])
                    try s.logProbs(.primary, into: &lp)
                    steps.append(clock.now - ts)
                }
                let total = steps.reduce(Duration.zero, +)
                return (prefill, prompt.count, steps[0], total / steps.count)
            }
            let afterGen = ProcessMemory.snapshot()
            let prefillSeconds = Double(timings.0.components.attoseconds) / 1e18 + Double(timings.0.components.seconds)
            print("[HunchLlama] mode=\(mode) load=\(fmt(loadTime)) "
                  + "footprint before=\(before.map { mb($0.physFootprint) } ?? "?") "
                  + "afterLoad=\(afterLoad.map { mb($0.physFootprint) } ?? "?") resident=\(afterLoad.map { mb($0.residentSize) } ?? "?") "
                  + "afterGen=\(afterGen.map { mb($0.physFootprint) } ?? "?") resident=\(afterGen.map { mb($0.residentSize) } ?? "?") | "
                  + "first decode (cold prefill \(timings.1) tok)=\(fmt(timings.0)) "
                  + String(format: "(%.0f tok/s)", Double(timings.1) / prefillSeconds)
                  + " first step=\(fmt(timings.2)) avg step=\(fmt(timings.3)) (decode+logProbs)")
            await host.unload()
        }
        if let after = ProcessMemory.snapshot() {
            print("[HunchLlama] after final unload: phys_footprint=\(mb(after.physFootprint)) resident=\(mb(after.residentSize))")
        }
    }
}
