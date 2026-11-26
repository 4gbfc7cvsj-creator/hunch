import Foundation
import Synchronization

// MARK: Dynamic Power Mode
//
// While on, Hunch switches between Performance (the hand-picked Language Model and speech
// model) and Efficiency (smaller models), driven by battery level, Low Power Mode, memory pressure,
// GPU load from other apps and heat. Everything here is pure; `SystemLoadMonitor` (app) feeds it.

/// macOS memory pressure, as Activity Monitor shows it.
public enum MemoryPressureLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case normal, warning, critical

    var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// macOS thermal state (`ProcessInfo.ThermalState`).
public enum HeatLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case nominal, fair, serious, critical

    var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// What the Mac looks like right now.
public struct SystemLoad: Sendable, Equatable {
    public var onBattery: Bool
    /// 0–100; nil on desktops or when macOS doesn't say.
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var memory: MemoryPressureLevel
    /// GPU busy % while Hunch itself was idle (other apps); nil until measured or when not watched.
    public var gpuPercent: Int?
    public var heat: HeatLevel

    public init(onBattery: Bool = false, batteryPercent: Int? = nil, lowPowerMode: Bool = false,
                memory: MemoryPressureLevel = .normal, gpuPercent: Int? = nil, heat: HeatLevel = .nominal) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.memory = memory
        self.gpuPercent = gpuPercent
        self.heat = heat
    }
}

/// Which model set is in use.
public enum PowerMode: String, Sendable, Equatable {
    /// The hand-picked (larger) models.
    case performance
    /// The Efficiency models.
    case efficiency
}

/// A mode and the signal behind it ("battery 18%"); nil reason in Performance.
public struct PowerReading: Sendable, Equatable {
    public var mode: PowerMode
    public var reason: String?
    public init(mode: PowerMode = .performance, reason: String? = nil) {
        self.mode = mode
        self.reason = reason
    }
}

/// "Dynamic Power Mode" in Settings → Performance & Models.
public struct DynamicPowerSettings: Codable, Sendable, Equatable {
    public var enabled: Bool

    public var useBattery: Bool
    /// Efficiency at or below this charge (on battery only).
    public var batteryPercent: Int
    /// Low Power Mode on means Efficiency.
    public var useLowPowerMode: Bool
    public var useMemory: Bool
    /// Efficiency at or above this memory pressure.
    public var memoryLevel: MemoryPressureLevel
    public var useGPU: Bool
    /// Efficiency at or above this GPU load from other apps.
    public var gpuPercent: Int
    public var useHeat: Bool
    /// Efficiency at or above this thermal state.
    public var heatLevel: HeatLevel

    /// The Language Model (relative path) and speech model (file name) used in Efficiency; nil uses
    /// the smallest one available. The Performance models are the normal picks.
    public var languageEfficiencyModel: String?
    public var speechEfficiencyModel: String?

    public init(enabled: Bool = false,
                useBattery: Bool = true, batteryPercent: Int = 40,
                useLowPowerMode: Bool = true,
                useMemory: Bool = true, memoryLevel: MemoryPressureLevel = .critical,
                useGPU: Bool = true, gpuPercent: Int = 90,
                useHeat: Bool = true, heatLevel: HeatLevel = .serious,
                languageEfficiencyModel: String? = nil, speechEfficiencyModel: String? = nil) {
        self.enabled = enabled
        self.useBattery = useBattery
        self.batteryPercent = batteryPercent
        self.useLowPowerMode = useLowPowerMode
        self.useMemory = useMemory
        self.memoryLevel = memoryLevel
        self.useGPU = useGPU
        self.gpuPercent = gpuPercent
        self.useHeat = useHeat
        self.heatLevel = heatLevel
        self.languageEfficiencyModel = languageEfficiencyModel
        self.speechEfficiencyModel = speechEfficiencyModel
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, useBattery, batteryPercent, useLowPowerMode, useMemory, memoryLevel, useGPU, gpuPercent,
             useHeat, heatLevel, languageEfficiencyModel, speechEfficiencyModel
    }

    /// Missing or unreadable keys (an older or newer file) take their defaults one by one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DynamicPowerSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = value(.enabled, d.enabled)
        useBattery = value(.useBattery, d.useBattery)
        batteryPercent = value(.batteryPercent, d.batteryPercent)
        useLowPowerMode = value(.useLowPowerMode, d.useLowPowerMode)
        useMemory = value(.useMemory, d.useMemory)
        memoryLevel = value(.memoryLevel, d.memoryLevel)
        useGPU = value(.useGPU, d.useGPU)
        gpuPercent = value(.gpuPercent, d.gpuPercent)
        useHeat = value(.useHeat, d.useHeat)
        heatLevel = value(.heatLevel, d.heatLevel)
        languageEfficiencyModel = try? c.decodeIfPresent(String.self, forKey: .languageEfficiencyModel)
        speechEfficiencyModel = try? c.decodeIfPresent(String.self, forKey: .speechEfficiencyModel)
    }
}

public enum DynamicPower {
    /// How long conditions must stay calm before going back to Performance, in seconds.
    public static let recoverySeconds: TimeInterval = 60
    /// How often the GPU is sampled while that signal is on and a model is loaded, in seconds.
    public static let gpuSampleSeconds: TimeInterval = 5

    /// Efficiency when any ticked signal crosses its threshold; the first one (in Settings order)
    /// names the reason. Battery counts only while on battery.
    public static func reading(_ load: SystemLoad, settings s: DynamicPowerSettings) -> PowerReading {
        if s.useBattery, load.onBattery, let p = load.batteryPercent, p <= s.batteryPercent {
            return PowerReading(mode: .efficiency, reason: "battery \(p)%")
        }
        if s.useGPU, let g = load.gpuPercent, g >= s.gpuPercent {
            return PowerReading(mode: .efficiency, reason: "GPU busy \(g)%")
        }
        if s.useMemory, load.memory != .normal, load.memory >= s.memoryLevel {
            return PowerReading(mode: .efficiency, reason: "memory pressure \(load.memory.rawValue)")
        }
        if s.useHeat, load.heat != .nominal, load.heat >= s.heatLevel {
            return PowerReading(mode: .efficiency, reason: "Mac is \(heatWord(load.heat))")
        }
        if s.useLowPowerMode, load.lowPowerMode {
            return PowerReading(mode: .efficiency, reason: "Low Power Mode")
        }
        return PowerReading()
    }

    private static func heatWord(_ heat: HeatLevel) -> String {
        switch heat {
        case .nominal: "cool"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "very hot"
        }
    }

    /// The Efficiency model: the chosen one while it is available, else the smallest available.
    public static func efficiencyModel<ID: Hashable>(chosen: ID?, available: [(id: ID, size: Int64)]) -> ID? {
        if let chosen, available.contains(where: { $0.id == chosen }) { return chosen }
        return available.min { $0.size < $1.size }?.id
    }

    /// The model to use: the Performance pick, or the Efficiency model (the Performance pick when
    /// there is none).
    public static func pick<ID: Hashable>(mode: PowerMode, performance: ID, efficiencyChoice: ID?,
                                          available: [(id: ID, size: Int64)]) -> ID {
        guard mode == .efficiency else { return performance }
        return efficiencyModel(chosen: efficiencyChoice, available: available) ?? performance
    }
}

/// Switches to Efficiency at once and back to Performance only after readings have stayed in
/// Performance for `recovery` seconds. Times are monotonic seconds (e.g.
/// `ProcessInfo.systemUptime`), injected for tests.
public struct PowerGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case none
        /// Use this reading now.
        case apply(PowerReading)
        /// Performance is waiting out the recovery; call `fire(now:)` at this time.
        case wait(until: TimeInterval)
    }

    public let recovery: TimeInterval
    public private(set) var applied: PowerReading
    /// When readings first went back to Performance.
    private var calmSince: TimeInterval?

    public init(initial: PowerReading = PowerReading(), recovery: TimeInterval = DynamicPower.recoverySeconds) {
        applied = initial
        self.recovery = recovery
    }

    public mutating func observe(_ reading: PowerReading, now: TimeInterval) -> Decision {
        if reading.mode == .efficiency || applied.mode == .performance {
            calmSince = nil
            // Still Efficiency with a new reason ("battery 19%") updates the label, not the model.
            guard reading != applied else { return .none }
            applied = reading
            return .apply(reading)
        }
        calmSince = calmSince ?? now
        return fire(now: now)
    }

    public mutating func fire(now: TimeInterval) -> Decision {
        guard let since = calmSince else { return .none }
        guard now - since >= recovery else { return .wait(until: since + recovery) }
        calmSince = nil
        applied = PowerReading()
        return .apply(applied)
    }
}

/// The GPU signal's reading: a short moving average of samples, taken only while a model is
/// loaded. Pure; `SystemLoadMonitor` drives it.
///
/// Sampling pauses while no model is loaded (an idle release), and the last reading is KEPT: a
/// reading that just stopped being measured is not a calm GPU, and clearing it would let Dynamic
/// Power Mode drift back to Performance and reload the big model on the next keystroke. The
/// reading is cleared only when the GPU signal or the whole monitor is turned off.
public struct GPUReading: Sendable, Equatable {
    public let window: Int
    public private(set) var samples: [Int] = []
    /// What `SystemLoad.gpuPercent` should be; nil until measured or while not watched.
    public private(set) var percent: Int?

    public init(window: Int) { self.window = max(1, window) }

    /// Adds a sample (other apps' GPU busy %) and returns the new average.
    @discardableResult
    public mutating func add(_ busy: Int) -> Int {
        samples.append(busy)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        let average = samples.reduce(0, +) / samples.count
        percent = average
        return average
    }

    /// Sampling stopped. `watching` = the monitor runs with the GPU signal on (sampling stopped
    /// only because no model is loaded): the reading stays and the next sample starts a fresh
    /// average. Otherwise the reading is cleared.
    public mutating func pause(watching: Bool) {
        samples = []
        if !watching { percent = nil }
    }
}

/// Hunch's own model work in progress (suggestions, Write for me, dictation), so the GPU
/// sampler can leave out readings that are Hunch's own load.
public enum LocalWork {
    private struct State { var active = 0; var lastEnd: TimeInterval = -.infinity }
    private static let state = Mutex(State())

    public static func begin() { state.withLock { $0.active += 1 } }
    public static func end() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.active = max(0, $0.active - 1); $0.lastEnd = now }
    }

    /// Runs `body` counted as local work.
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        begin()
        defer { end() }
        return try body()
    }

    /// Nothing running now, and nothing ended within `seconds`.
    public static func isQuiet(for seconds: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        state.withLock { $0.active == 0 && now - $0.lastEnd >= seconds }
    }
}
