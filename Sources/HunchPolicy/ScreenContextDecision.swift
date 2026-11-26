import Foundation
import HunchCore

/// When the app may ask for a screen excerpt, and which cached excerpt may go into a prompt.
/// Screen context never blocks a request: callers use the latest cached excerpt only.
public enum ScreenContextDecision {
    public enum Trigger: Sendable, Equatable { case fieldFocused, typingPaused(Duration) }

    /// Minimum typing pause before a refresh.
    public static let typingPause: Duration = .seconds(1)
    /// Older excerpts are not sent (the screen has most likely changed).
    public static let maxExcerptAge: Duration = .seconds(120)

    /// All gates must hold: the global opt-in, the app/site policy (enabled and screen context
    /// allowed), and the Screen Recording permission. Focus triggers immediately; typing only after
    /// a pause.
    public static func shouldFetch(globallyEnabled: Bool, policy: AppPolicy, permitted: Bool, trigger: Trigger) -> Bool {
        guard globallyEnabled, permitted, policy.enabled, !policy.secureExcluded, policy.screenContextAllowed else {
            return false
        }
        switch trigger {
        case .fieldFocused: return true
        case .typingPaused(let idle): return idle >= typingPause
        }
    }

    /// The cached excerpt, only if it belongs to `field`, is recent, and the gates still hold.
    public static func usableExcerpt(cachedField: FieldID?, excerpt: ScreenExcerpt?, field: FieldID,
                                     globallyEnabled: Bool, policy: AppPolicy,
                                     now: ContinuousClock.Instant = .now) -> ScreenExcerpt? {
        guard globallyEnabled, policy.enabled, !policy.secureExcluded, policy.screenContextAllowed,
              let excerpt, cachedField == field, now - excerpt.capturedAt <= maxExcerptAge,
              !excerpt.text.isEmpty else { return nil }
        return excerpt
    }
}
