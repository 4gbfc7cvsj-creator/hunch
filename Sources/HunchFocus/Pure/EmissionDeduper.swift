import CoreGraphics
import Foundation
import HunchCore

/// Suppresses repeated focus events so an unchanged field emits nothing on each poll tick.
public struct EmissionDeduper: Sendable {
    public enum Key: Hashable, Sendable {
        case context(field: FieldID, signature: UInt64, markedText: Bool, caret: RectKey, quality: Int)
        case blocked(reason: String, pid: pid_t?)
        case focusLost
    }

    /// A rect rounded to whole points, so sub-point jitter doesn't count as a change.
    public struct RectKey: Hashable, Sendable {
        public let x, y, w, h: Int
        public init(_ r: CGRect) {
            func r0(_ v: CGFloat) -> Int { v.isFinite ? Int(v.rounded()) : Int.min }
            x = r0(r.minX); y = r0(r.minY); w = r0(r.width); h = r0(r.height)
        }
    }

    private var last: Key?

    public init() {}

    public static func key(for event: FocusEvent) -> Key {
        switch event {
        case .context(let ctx, let geo):
            return .context(field: ctx.field, signature: ctx.contentSignature, markedText: ctx.hasMarkedText,
                            caret: RectKey(geo.caretRect), quality: geo.quality.rawValue)
        case .blocked(let reason, let app):
            return .blocked(reason: String(describing: reason), pid: app?.pid)
        case .focusLost:
            return .focusLost
        }
    }

    /// Returns true when the event differs from the last emitted one (and records it).
    public mutating func shouldEmit(_ event: FocusEvent) -> Bool {
        let k = Self.key(for: event)
        if k == last { return false }
        last = k
        return true
    }

    /// Records an event emitted outside the deduper (e.g. the pause notice).
    public mutating func record(_ event: FocusEvent) { last = Self.key(for: event) }

    public mutating func reset() { last = nil }
}

/// Extracts a lowercase host from a URL string, ignoring non-web schemes.
public enum URLHostExtractor {
    public static func host(from string: String) -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.lowercased()
    }
}

/// Final delivery decision, evaluated under the tracker lock right before yielding.
public enum FocusEmissionGate {
    /// Context events are dropped while paused; blocked/focusLost always pass.
    public static func shouldDeliver(_ event: FocusEvent, paused: Bool) -> Bool {
        if paused, case .context = event { return false }
        return true
    }
}
