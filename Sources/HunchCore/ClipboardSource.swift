import Foundation

/// Where copied text came from, decided when the copy is noticed (the clipboard is polled).
public enum ClipboardSource: Sendable, Equatable {
    /// The app changed between the last poll and this one: the copy may come from either app.
    case unclear
    /// Hunch was off, paused or blocked for privacy where the copy was made.
    case blocked
    case place(bundleID: String, urlHost: String?)

    /// What the focus engine last said about the app in front: its readable field's site, or why
    /// focus there was blocked.
    public struct Focus: Sendable, Equatable {
        public var bundleID: String
        public var urlHost: String?
        public var blockReason: BlockReason?
        public init(bundleID: String, urlHost: String? = nil, blockReason: BlockReason? = nil) {
            self.bundleID = bundleID
            self.urlHost = urlHost
            self.blockReason = blockReason
        }
    }

    /// The source of a copy noticed now. `appSwitchedSincePoll`: the frontmost app changed after
    /// the previous poll, so the copy can't be credited to the app in front now.
    public static func noticed(frontmost: String?, appSwitchedSincePoll: Bool, focus: Focus?) -> ClipboardSource {
        guard !appSwitchedSincePoll, let frontmost else { return .unclear }
        // Focus state for another app is stale: the site and block reason are unknown.
        guard let focus, focus.bundleID == frontmost else { return .place(bundleID: frontmost, urlHost: nil) }
        if let reason = focus.blockReason, taints(reason) { return .blocked }
        return .place(bundleID: frontmost, urlHost: focus.urlHost)
    }

    /// Text copied here may be used as context in other apps: a known place that is on and not
    /// secure-excluded, checked with its site.
    public func allows(_ policies: any AppPolicyResolving) -> Bool {
        guard case .place(let bundleID, let urlHost) = self else { return false }
        let policy = policies.resolve(bundleID: bundleID, urlHost: urlHost).policy
        return policy.enabled && !policy.secureExcluded
    }

    /// Blocks that mean Hunch wasn't allowed to look there; the rest (not editable, a search
    /// field, a selection) say nothing about privacy.
    static func taints(_ reason: BlockReason) -> Bool {
        switch reason {
        case .secureEventInput, .globallyDisabled, .appDisabled, .secureExcludedApp, .secureRole, .sensitiveMarker,
             .protectedContent, .trackingPaused:
            true
        case .ownProcess, .markedText, .selectionActive, .midLineDisallowed, .notEditable, .searchField,
             .hostExposesNoText:
            false
        }
    }
}
