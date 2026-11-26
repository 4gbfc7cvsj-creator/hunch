/// 64-bit FNV-1a. Stable across launches (unlike `Hasher`), so signatures can be compared and logged.
public struct FNV1a64: Sendable, Equatable {
    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let prime: UInt64 = 0x0000_0100_0000_01b3
    public private(set) var value: UInt64 = FNV1a64.offsetBasis

    public init() {}

    public mutating func combine(byte: UInt8) {
        value ^= UInt64(byte)
        value &*= Self.prime
    }

    public mutating func combine<S: Sequence>(bytes: S) where S.Element == UInt8 {
        for b in bytes { combine(byte: b) }
    }

    public mutating func combine(_ value: UInt64) {
        var v = value
        for _ in 0..<8 {
            combine(byte: UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
    }
}

public enum ContentSignature {
    /// Hash of before|after|selection. The unit separator keeps ("ab","c") distinct from ("a","bc").
    public static func make(before: String, after: String, selectionLength: Int) -> UInt64 {
        var h = FNV1a64()
        h.combine(bytes: before.utf8)
        h.combine(byte: 0x1F)
        h.combine(bytes: after.utf8)
        h.combine(byte: 0x1F)
        h.combine(UInt64(bitPattern: Int64(selectionLength)))
        return h.value
    }
}
