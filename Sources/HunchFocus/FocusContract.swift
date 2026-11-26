import ApplicationServices
import Foundation
import HunchCore
import HunchPolicy

// Contract for focus tracking and context reading (design §4.2, §7.1). Owned by the integrator.

public protocol FocusTracking: AnyObject, Sendable {
    func start(gate: any SecureGating, policies: any AppPolicyResolving)
    func stop()
    func pause(_ reason: PauseReason)
    func resume(_ reason: PauseReason)
    func events() -> AsyncStream<FocusEvent>
    /// Called from the event-tap thread to speed up polling while the user types.
    func noteTypingActivity()
}

public protocol ContextReading {
    /// Metadata attributes only. Never reads AXValue or text ranges.
    func probe(_ element: AXUIElement) -> ElementProbe
    /// The ONLY API that reads field text. Requires a valid pass for this field.
    func read(_ element: AXUIElement, field: FieldID, pass: SecureGatePass, limits: ContextLimits) throws -> TextContext
    /// Caret geometry for `element`, which must be the element `field` was issued for.
    func caret(_ element: AXUIElement, field: FieldID, pass: SecureGatePass) -> CaretGeometry
}
