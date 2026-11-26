// Idle release and mmap reload against the dev model (own host; skipped when the drive is absent).
import Foundation
import Testing
import HunchCore
@testable import HunchLlama

@Suite(.serialized, .enabled(if: DevModel.available, "dev model not mounted"))
final class IdleReleaseTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }
    @Test func releaseFreesAndMmapReloadIsFast() async throws {
        let host = LlamaModelHost()
        var options = DevModel.options(.mmap)
        options.idleReleaseAfterSeconds = nil
        await host.load(DevModel.entry(), options: options)
        guard case .ready = await host.state() else { Issue.record("load failed"); return }
        var id: UInt64 = 0
        func touch() async throws {
            id += 1
            _ = try await host.withSession(RequestID(id)) { s in
                let prompt = try s.tokenize([content("The meeting is scheduled for")], addBOS: true)
                _ = try s.syncPrompt(prompt, plan: cold)
                var lp: [Float] = []
                try s.logProbs(.primary, into: &lp)
            }
        }
        try await touch()
        let loaded = ProcessMemory.snapshot()

        host.releaseNow()
        for await state in host.states() { if case .releasedIdle = state { break } }
        let released = ProcessMemory.snapshot()

        let start = ContinuousClock.now
        try await touch()   // transparent reload plus first request
        let reload = ContinuousClock.now - start
        guard case .ready = await host.state() else { Issue.record("reload failed"); return }
        print("[HunchLlama] idle release: footprint loaded=\(loaded.map { mb($0.physFootprint) } ?? "?") "
              + "released=\(released.map { mb($0.physFootprint) } ?? "?") resident loaded=\(loaded.map { mb($0.residentSize) } ?? "?") "
              + "released=\(released.map { mb($0.residentSize) } ?? "?") | reload+first request=\(fmt(reload))")
        if let loaded, let released {
            #expect(released.physFootprint < loaded.physFootprint)
        }
        #expect(reload < .seconds(10))
        await host.unload()
    }
}

@Suite(.serialized, .enabled(if: DevModel.available, "dev model not mounted"))
final class RetargetTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }

    /// Dynamic Power Mode on a released model: the reload target changes, nothing loads.
    @Test func retargetWhileReleasedLoadsNothing() async throws {
        let host = LlamaModelHost()
        var options = DevModel.options(.mmap)
        options.idleReleaseAfterSeconds = nil
        let entry = DevModel.entry()
        await host.load(entry, options: options)
        guard case .ready = await host.state() else { Issue.record("load failed"); return }
        // Loaded: retarget refuses (the caller loads instead).
        #expect(await host.retargetIfReleased(entry, options: options) == false)

        host.releaseNow()
        for await state in host.states() { if case .releasedIdle = state { break } }
        let released = ProcessMemory.snapshot()
        #expect(await host.retargetIfReleased(entry, options: options))
        guard case .releasedIdle = await host.state() else { Issue.record("retarget loaded the model"); return }
        let after = ProcessMemory.snapshot()
        if let released, let after {
            // Still released: no model came back into memory.
            #expect(after.physFootprint < released.physFootprint + 200 * 1_048_576)
        }
        // The next request reloads the new target.
        _ = try await host.withSession(RequestID(1)) { _ in }
        guard case .ready = await host.state() else { Issue.record("reload failed"); return }
        await host.unload()
        // After an explicit unload there's nothing to retarget.
        #expect(await host.retargetIfReleased(entry, options: options) == false)
    }
}
