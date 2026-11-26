import Darwin
import Foundation
import HunchCore
import HunchLlama
import IOKit.ps

/// Watches what Dynamic Power Mode reacts to. Everything is event-driven (macOS notifies; nothing
/// runs in between) except GPU load, which macOS doesn't announce: it is sampled every few seconds,
/// only while that signal is on and a model is loaded. While no model is loaded (idle release) the
/// last GPU reading is kept (see `GPUReading`).
///
/// Hunch's own work is left out: GPU samples taken while a local model runs (suggestions, Write
/// for me, dictation, loads) or within `quietSeconds` after are dropped, and memory pressure only
/// counts once Hunch has been quiet for `quietSeconds` and the pressure is still there.
@MainActor
final class SystemLoadMonitor {
    /// GPU and memory readings are trusted only after this long without local model work.
    static let quietSeconds: TimeInterval = 5
    /// GPU samples averaged into one reading (smooths single spikes).
    static let gpuWindow = 3

    private(set) var load = SystemLoad()
    var onChange: ((SystemLoad) -> Void)?
    /// True while a model is loaded (the GPU is sampled only then).
    var modelLoaded: () -> Bool = { false }

    private var running = false
    private var watchGPU = false
    private var powerSource: CFRunLoopSource?
    private var observers: [any NSObjectProtocol] = []
    private var memorySource: (any DispatchSourceMemoryPressure)?
    private var memoryRecheck: Timer?
    private var gpuTimer: Timer?
    private var gpu = GPUReading(window: SystemLoadMonitor.gpuWindow)

    /// Starts watching (no-op if running); `gpu` turns GPU sampling on or off.
    func start(gpu: Bool) {
        setGPU(gpu)
        guard !running else { return }
        running = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemLoadMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.readPower() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPower() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readHeat() }
        })
        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memory.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readMemory() }
        }
        memory.activate()
        memorySource = memory

        var next = load
        next.onBattery = Self.onBattery()
        next.batteryPercent = Self.batteryPercent()
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.heat = Self.heat(ProcessInfo.processInfo.thermalState)
        set(next)
        readMemory()
    }

    func stop() {
        guard running else { return }
        running = false
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        memorySource?.cancel()
        memorySource = nil
        memoryRecheck?.invalidate()
        memoryRecheck = nil
        setGPU(false)
        load = SystemLoad()
    }

    func setGPU(_ on: Bool) {
        watchGPU = on
        refreshGPUTimer()
    }

    /// Call when the model loads or is released: GPU sampling runs only while one is loaded.
    func modelStateChanged() { refreshGPUTimer() }

    // MARK: Readings

    private func set(_ next: SystemLoad) {
        guard next != load else { return }
        load = next
        onChange?(next)
    }

    private func readPower() {
        var next = load
        next.onBattery = Self.onBattery()
        next.batteryPercent = Self.batteryPercent()
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        set(next)
    }

    private func readHeat() {
        var next = load
        next.heat = Self.heat(ProcessInfo.processInfo.thermalState)
        set(next)
    }

    /// Lower pressure applies at once; higher pressure only once Hunch has been quiet (its own
    /// model work isn't a reason to step down), re-checked until then.
    private func readMemory() {
        memoryRecheck?.invalidate()
        memoryRecheck = nil
        let level = Self.memoryPressure()
        if level > load.memory, !LocalWork.isQuiet(for: Self.quietSeconds) {
            let t = Timer(timeInterval: Self.quietSeconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.readMemory() }
            }
            RunLoop.main.add(t, forMode: .common)
            memoryRecheck = t
            return
        }
        var next = load
        next.memory = level
        set(next)
    }

    private func refreshGPUTimer() {
        let wanted = running && watchGPU && modelLoaded()
        if wanted {
            guard gpuTimer == nil else { return }
            let t = Timer(timeInterval: DynamicPower.gpuSampleSeconds, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleGPU() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            gpuTimer = t
        } else {
            // Also when already paused: turning the signal off must clear a reading kept meanwhile.
            gpuTimer?.invalidate()
            gpuTimer = nil
            gpu.pause(watching: running && watchGPU)
            var next = load
            next.gpuPercent = gpu.percent
            set(next)
        }
    }

    private func sampleGPU() {
        guard LocalWork.isQuiet(for: Self.quietSeconds), let busy = GPUUtilization.current() else { return }
        var next = load
        next.gpuPercent = gpu.add(busy)
        set(next)
    }

    // MARK: macOS reads

    /// Desktops (no battery) and unreadable power info count as AC power.
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// The internal battery's charge in percent; nil without one.
    static func batteryPercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    /// The kernel's current level (1 normal, 2 warning, 4 critical).
    static func memoryPressure() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...: return .warning
        default: return .normal
        }
    }

    static func heat(_ state: ProcessInfo.ThermalState) -> HeatLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}
