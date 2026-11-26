import Foundation
import IOKit

/// The GPU's own busy figure ("Device Utilization %" in the IOAccelerator's PerformanceStatistics),
/// read without admin rights. It covers every process on the GPU, not only Hunch. Nil when the
/// driver doesn't publish it.
public enum GPUUtilization {
    public static func current() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            if let value = (stats["Device Utilization %"] as? NSNumber)?.intValue {
                best = max(best ?? 0, value)
            }
        }
        return best
    }
}

/// Samples `GPUUtilization` on a background timer and summarizes what it saw.
public final class GPUSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int] = []
    private var timer: DispatchSourceTimer?

    public init() {}

    public func start(every interval: TimeInterval = 0.25) {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let value = GPUUtilization.current() else { return }
            self?.lock.withLock { self?.samples.append(value) }
        }
        lock.withLock { timer = t }
        t.resume()
    }

    /// Stops sampling; returns (mean, 95th percentile, count) of the busy percentages.
    @discardableResult
    public func stop() -> (mean: Double, p95: Int, count: Int) {
        lock.withLock { timer?.cancel(); timer = nil }
        let values = lock.withLock { samples }.sorted()
        guard !values.isEmpty else { return (0, 0, 0) }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        return (mean, values[min(values.count - 1, values.count * 95 / 100)], values.count)
    }
}
