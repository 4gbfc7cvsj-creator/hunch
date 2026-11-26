import CoreGraphics
import Foundation
import HunchCore

/// Minimal description of an on-screen window, decoupled from ScreenCaptureKit for testing.
public struct WindowInfo: Equatable, Sendable {
    public let id: UInt32
    public let pid: pid_t
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool
    public init(id: UInt32, pid: pid_t, frame: CGRect, layer: Int, isOnScreen: Bool) {
        self.id = id; self.pid = pid; self.frame = frame; self.layer = layer; self.isOnScreen = isOnScreen
    }
}

public enum WindowSelection {
    /// Window IDs mapped to their stacking position (0 = frontmost) from the window server.
    /// ScreenCaptureKit's window list is not in stacking order, so callers sort with this before
    /// `select`; without it a window behind (Mail's viewer behind a compose window) can win.
    public static func stackingOrder() -> [UInt32: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var order: [UInt32: Int] = [:]
        for (i, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? UInt32 ?? (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                order[id] = i
            }
        }
        return order
    }

    /// `windows` sorted front to back by `order`; windows missing from it go last, keeping their order.
    public static func frontToBack(_ windows: [WindowInfo], order: [UInt32: Int]) -> [WindowInfo] {
        windows.enumerated().sorted { a, b in
            let oa = order[a.element.id] ?? Int.max, ob = order[b.element.id] ?? Int.max
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)
    }

    /// Picks the single window to capture: a normal-layer, on-screen window owned by `targetPid`
    /// (never our own process) that holds the field anchor, else the one overlapping the band most.
    /// `windows` is expected front-to-back; ties go to the earlier (frontmost) window.
    public static func select(windows: [WindowInfo], targetPid: pid_t, ownPid: pid_t,
                              anchor: CGPoint, band: CGRect) -> WindowInfo? {
        guard targetPid != ownPid else { return nil }
        let candidates = windows.filter {
            $0.pid == targetPid && $0.layer == 0 && $0.isOnScreen && !$0.frame.isEmpty
                && $0.frame.intersects(band)
        }
        if let holder = candidates.first(where: { $0.frame.contains(anchor) }) { return holder }
        func overlap(_ w: WindowInfo) -> CGFloat {
            let r = w.frame.intersection(band)
            return r.isNull ? 0 : r.width * r.height
        }
        var best: WindowInfo?
        for w in candidates where overlap(w) > (best.map(overlap) ?? 0) { best = w }
        return best
    }
}

/// The single cached excerpt plus throttle state; `purge()` forgets everything for all fields.
struct ExcerptCacheStore<Excerpt: Sendable>: Sendable {
    var cached: (field: FieldID, excerpt: Excerpt?)?
    var throttle: CaptureThrottle

    init(interval: Duration) { throttle = CaptureThrottle(interval: interval) }

    mutating func purge() {
        cached = nil
        throttle = CaptureThrottle(interval: throttle.interval)
    }
}
