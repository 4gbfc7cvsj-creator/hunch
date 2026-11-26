import CoreGraphics
import Foundation
import HunchCore
import HunchPolicy

// Contract for opt-in screen-aware suggestions (M2 track S). Owned by the integrator.
// Capture requires a SecureGatePass, so no screenshot can be taken for a field the gate blocked.

public protocol ScreenContextProviding: Sendable {
    /// Captures the area around the field, runs on-device OCR, and returns a bounded, sanitized
    /// excerpt. Returns nil when the permission is missing, capture fails, or nothing useful is
    /// visible. The image is discarded immediately and never stored.
    func excerpt(app: AppIdentity, fieldFrame: CGRect?, caretRect: CGRect, pass: SecureGatePass,
                 maxCharacters: Int) async -> ScreenExcerpt?
    /// Whether the Screen Recording permission is currently granted (no prompt).
    func isPermitted() -> Bool
}
