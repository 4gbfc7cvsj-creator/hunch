import Foundation

/// Locates what the user (or our own insertion) added after a suggestion's anchor, tolerating
/// the before-caret window sliding forward in long documents (`TextContext.before` is bounded).
public enum AnchorMatcher {
    /// How much of the anchor's end is compared once the window has slid.
    public static let tailLength = 256

    public enum Match: Equatable, Sendable {
        /// `before` is the anchor followed by `delta`, and `delta` is a prefix of the continuation.
        case extended(delta: String)
        /// The text no longer continues the anchor along the expected continuation.
        case diverged
    }

    /// - Parameters:
    ///   - before: the new before-caret text.
    ///   - anchor: the before-caret text the continuation was computed for.
    ///   - continuation: text expected to follow the anchor (pending accepted text + ghost remainder).
    public static func match(before: String, anchor: String, continuation: String,
                             tailLength: Int = AnchorMatcher.tailLength) -> Match {
        // Exact path: the window start didn't move.
        if before.hasPrefix(anchor) {
            let delta = String(before.dropFirst(anchor.count))
            return continuation.hasPrefix(delta) ? .extended(delta: delta) : .diverged
        }
        // Sliding path: find the anchor's tail as a boundary near the end of `before`, followed by
        // a prefix of the continuation. The smallest delta wins (the most conservative reading).
        let tail = String(anchor.suffix(tailLength))
        guard !tail.isEmpty else { return .diverged }
        var delta = ""
        var rest = Substring(continuation)
        while true {
            if before.hasSuffix(tail + delta) { return .extended(delta: delta) }
            guard let next = rest.first, delta.count < before.count else { return .diverged }
            delta.append(next)
            rest = rest.dropFirst()
        }
    }
}
