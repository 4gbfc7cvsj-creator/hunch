import Darwin

/// Conversion between `mach_absolute_time` ticks and nanoseconds, overflow-safe.
public struct MachTimebase: Sendable, Equatable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = max(numer, 1)
        self.denom = max(denom, 1)
    }

    public static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS else { return MachTimebase(numer: 1, denom: 1) }
        return MachTimebase(numer: info.numer, denom: info.denom)
    }()

    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        Self.scale(ticks, by: UInt64(numer), over: UInt64(denom))
    }

    public func ticks(fromNanoseconds nanos: UInt64) -> UInt64 {
        Self.scale(nanos, by: UInt64(denom), over: UInt64(numer))
    }

    /// value * mul / div, saturating at UInt64.max instead of trapping.
    static func scale(_ value: UInt64, by mul: UInt64, over div: UInt64) -> UInt64 {
        let wide = value.multipliedFullWidth(by: mul)
        guard wide.high < div else { return .max }
        return div.dividingFullWidth(wide).quotient
    }
}

/// Snapshot freshness rule: a snapshot is usable while it is at most `maxAgeTicks` old.
/// A publish time slightly after `now` (a race between publish and the tap callback reading
/// the clock) counts as age zero.
public enum Freshness {
    public static let defaultMaxAgeNanoseconds: UInt64 = 1_500_000_000

    public static func isFresh(publishedAt: UInt64, now: UInt64, maxAgeTicks: UInt64) -> Bool {
        guard now > publishedAt else { return true }
        return now - publishedAt <= maxAgeTicks
    }
}
