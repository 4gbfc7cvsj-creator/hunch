import CoreGraphics

/// Tag written into `.eventSourceUserData` of every event Hunch posts, so its own taps
/// can recognize and ignore them. Arbitrary Hunch-specific value.
public enum EventMarker {
    public static let userData: Int64 = 0x4754_7970_4576_0001
    /// High half of the tag on a user's key press Hunch held and posted again (`KeyHoldQueue`);
    /// the low half is the press's order number. Replays are the user's typing, not Hunch's.
    static let replayBase: Int64 = 0x4754_5270_0000_0000

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }

    static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    /// The order number of a replayed press, or nil for any other event.
    static func replayOrder(_ event: CGEvent) -> Int? {
        let value = event.getIntegerValueField(.eventSourceUserData)
        guard value & ~0xFFFF_FFFF == replayBase else { return nil }
        return Int(value & 0xFFFF_FFFF)
    }

    static func tagReplay(_ event: CGEvent, order: Int) {
        event.setIntegerValueField(.eventSourceUserData, value: replayBase | (Int64(order) & 0xFFFF_FFFF))
    }
}
