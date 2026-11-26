import Foundation
import Testing
@testable import HunchCore

private let on = DynamicPowerSettings(enabled: true)
private let efficient = PowerMode.efficiency

@Suite struct DynamicPowerReadingTests {
    private func mode(_ load: SystemLoad, _ s: DynamicPowerSettings = on) -> PowerMode {
        DynamicPower.reading(load, settings: s).mode
    }

    @Test func calmMacIsPerformance() {
        #expect(DynamicPower.reading(SystemLoad(), settings: on) == PowerReading())
    }

    @Test func batteryAtOrBelowTheThreshold() {
        #expect(mode(SystemLoad(onBattery: true, batteryPercent: 41)) == .performance)
        #expect(mode(SystemLoad(onBattery: true, batteryPercent: 40)) == efficient)
        // Plugged in: the charge doesn't matter.
        #expect(mode(SystemLoad(onBattery: false, batteryPercent: 5)) == .performance)
        #expect(DynamicPower.reading(SystemLoad(onBattery: true, batteryPercent: 18), settings: on).reason
                == "battery 18%")
    }

    @Test func gpuAtOrAboveTheThreshold() {
        #expect(mode(SystemLoad(gpuPercent: 89)) == .performance)
        #expect(mode(SystemLoad(gpuPercent: 90)) == efficient)
        #expect(mode(SystemLoad(gpuPercent: nil)) == .performance)   // not measured yet
    }

    @Test func memoryDefaultsToCritical() {
        #expect(mode(SystemLoad(memory: .warning)) == .performance)
        #expect(mode(SystemLoad(memory: .critical)) == efficient)
        var s = on
        s.memoryLevel = .warning
        #expect(mode(SystemLoad(memory: .warning), s) == efficient)
    }

    @Test func heatDefaultsToSerious() {
        #expect(mode(SystemLoad(heat: .fair)) == .performance)
        #expect(mode(SystemLoad(heat: .serious)) == efficient)
        #expect(mode(SystemLoad(heat: .critical)) == efficient)
    }

    @Test func lowPowerMode() {
        #expect(DynamicPower.reading(SystemLoad(lowPowerMode: true), settings: on)
                == PowerReading(mode: .efficiency, reason: "Low Power Mode"))
    }

    @Test func uncheckedSignalsAreIgnored() {
        let busy = SystemLoad(onBattery: true, batteryPercent: 3, lowPowerMode: true, memory: .critical,
                              gpuPercent: 100, heat: .critical)
        let none = DynamicPowerSettings(enabled: true, useBattery: false, useLowPowerMode: false, useMemory: false,
                                        useGPU: false, useHeat: false)
        #expect(DynamicPower.reading(busy, settings: none) == PowerReading())
    }

    @Test func firstSignalNamesTheReason() {
        let load = SystemLoad(onBattery: true, batteryPercent: 35, gpuPercent: 95)
        #expect(DynamicPower.reading(load, settings: on).reason == "battery 35%")
    }
}

@Suite struct DynamicPowerPickTests {
    private let models: [(id: String, size: Int64)] = [("8b", 8), ("3b", 3), ("1b", 1)]

    @Test func performanceIsTheHandPick() {
        #expect(DynamicPower.pick(mode: .performance, performance: "8b", efficiencyChoice: "1b", available: models)
                == "8b")
    }

    @Test func efficiencyUsesTheChoice() {
        #expect(DynamicPower.pick(mode: .efficiency, performance: "8b", efficiencyChoice: "3b", available: models)
                == "3b")
    }

    @Test func automaticIsTheSmallest() {
        #expect(DynamicPower.pick(mode: .efficiency, performance: "8b", efficiencyChoice: nil, available: models)
                == "1b")
    }

    @Test func aMissingChoiceFallsBackToTheSmallest() {
        #expect(DynamicPower.efficiencyModel(chosen: "gone", available: models) == "1b")
    }

    @Test func nothingAvailableKeepsPerformance() {
        #expect(DynamicPower.pick(mode: .efficiency, performance: "8b", efficiencyChoice: nil, available: []) == "8b")
    }
}

@Suite struct PowerGateTests {
    private let low = PowerReading(mode: .efficiency, reason: "battery 35%")
    private let calm = PowerReading()

    @Test func efficiencyAtOnce() {
        var g = PowerGate()
        #expect(g.observe(low, now: 0) == .apply(low))
    }

    @Test func performanceOnlyAfterTheRecovery() {
        var g = PowerGate(recovery: 60)
        _ = g.observe(low, now: 0)
        #expect(g.observe(calm, now: 10) == .wait(until: 70))
        #expect(g.fire(now: 50) == .wait(until: 70))
        #expect(g.fire(now: 70) == .apply(calm))
        #expect(g.applied == calm)
    }

    @Test func aSpikeDuringRecoveryRestartsIt() {
        var g = PowerGate(recovery: 60)
        _ = g.observe(low, now: 0)
        _ = g.observe(calm, now: 10)
        #expect(g.observe(low, now: 30) == .none)
        #expect(g.fire(now: 70) == .none)
        #expect(g.observe(calm, now: 80) == .wait(until: 140))
    }

    @Test func newReasonInEfficiencyUpdatesTheLabel() {
        var g = PowerGate()
        _ = g.observe(low, now: 0)
        let lower = PowerReading(mode: .efficiency, reason: "battery 34%")
        #expect(g.observe(lower, now: 5) == .apply(lower))
        #expect(g.observe(lower, now: 6) == .none)
    }

    @Test func calmStaysCalm() {
        var g = PowerGate()
        #expect(g.observe(calm, now: 0) == .none)
    }
}

@Suite struct DynamicPowerSettingsTests {
    @Test func defaults() {
        let d = DynamicPowerSettings()
        #expect(!d.enabled)
        #expect(d.batteryPercent == 40)
        #expect(d.gpuPercent == 90)
        #expect(d.memoryLevel == .critical)
        #expect(d.heatLevel == .serious)
        #expect(d.languageEfficiencyModel == nil && d.speechEfficiencyModel == nil)
    }

    @Test func decodesTolerantly() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(DynamicPowerSettings.self, from: Data("{}".utf8)) == DynamicPowerSettings())
        let odd = #"{"enabled":true,"memoryLevel":"apocalyptic","gpuPercent":75,"batteryStepDownPercent":40}"#
        let d = try decoder.decode(DynamicPowerSettings.self, from: Data(odd.utf8))
        #expect(d.enabled)
        #expect(d.memoryLevel == .critical)
        #expect(d.gpuPercent == 75)
        let full = DynamicPowerSettings(enabled: true, heatLevel: .fair, languageEfficiencyModel: "a.gguf",
                                        speechEfficiencyModel: "ggml-tiny.bin")
        #expect(try decoder.decode(DynamicPowerSettings.self, from: JSONEncoder().encode(full)) == full)
    }
}

@Suite(.serialized) struct LocalWorkTests {
    @Test func quietOnlyAfterWorkEndsAndTheWindowPasses() {
        let now = ProcessInfo.processInfo.systemUptime
        LocalWork.begin()
        #expect(!LocalWork.isQuiet(for: 0, now: now + 100))
        LocalWork.end()
        #expect(!LocalWork.isQuiet(for: 5))
        #expect(LocalWork.isQuiet(for: 5, now: ProcessInfo.processInfo.systemUptime + 6))
    }
}

/// Regression (tier 3 review, finding 3): an idle release paused GPU sampling and cleared the
/// reading, which read as a calm GPU; 60 s later Dynamic Power Mode went back to Performance and
/// the next keystroke loaded the big model while another app still kept the GPU busy.
@Suite struct GPUReadingTests {
    private let gpuOnly: DynamicPowerSettings = {
        var s = DynamicPowerSettings(enabled: true)
        s.useBattery = false; s.useMemory = false; s.useHeat = false; s.useLowPowerMode = false
        s.useGPU = true
        return s
    }()

    @Test func averagesTheLastWindow() {
        var gpu = GPUReading(window: 3)
        #expect(gpu.percent == nil)
        #expect(gpu.add(90) == 90)
        #expect(gpu.add(60) == 75)
        gpu.add(30)
        #expect(gpu.add(0) == 30)   // 60, 30, 0
        #expect(gpu.samples.count == 3)
    }

    @Test func idleReleaseKeepsEfficiencyPastRecovery() {
        var gpu = GPUReading(window: 3)
        var gate = PowerGate()
        for _ in 0..<3 { gpu.add(95) }
        let busy = DynamicPower.reading(SystemLoad(gpuPercent: gpu.percent), settings: gpuOnly)
        #expect(busy.mode == .efficiency)
        #expect(gate.observe(busy, now: 0) == .apply(busy))

        // The model is idle-released: sampling pauses while the GPU signal stays on.
        gpu.pause(watching: true)
        #expect(gpu.percent == 95)
        let whileReleased = DynamicPower.reading(SystemLoad(gpuPercent: gpu.percent), settings: gpuOnly)
        #expect(whileReleased == busy)
        #expect(gate.observe(whileReleased, now: 600) == .none)
        #expect(gate.fire(now: 600 + DynamicPower.recoverySeconds * 2) == .none)
        #expect(gate.applied.mode == .efficiency)

        // The next keystroke reloads (the small model); the first quiet sample starts a fresh average.
        #expect(gpu.add(10) == 10)
        #expect(gpu.samples == [10])
    }

    @Test func turningTheSignalOffClearsTheKeptReading() {
        var gpu = GPUReading(window: 3)
        gpu.add(95)
        gpu.pause(watching: true)      // idle release
        gpu.pause(watching: false)     // then GPU signal (or Dynamic Power Mode) turned off
        #expect(gpu.percent == nil)
        #expect(gpu.samples.isEmpty)
    }
}
