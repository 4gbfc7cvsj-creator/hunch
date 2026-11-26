import Foundation
import HunchCore

// Contract for the secure gate (design §7.1). Owned by the integrator; implementations live in
// other files of this module.

/// Stage 1 input: system state only. No element access at all.
public struct SystemProbe: Sendable, Equatable {
    public var secureEventInputEnabled: Bool
    public var secureInputOwnerPID: pid_t?
    public var frontmost: AppIdentity
    public var ownPID: pid_t
    public var trackingPaused: Bool
    public var globallyEnabled: Bool
    /// Autocorrect may read fields where suggestions are off (globally or for the app).
    public var autocorrectActive: Bool
    public init(secureEventInputEnabled: Bool, secureInputOwnerPID: pid_t?, frontmost: AppIdentity, ownPID: pid_t,
                trackingPaused: Bool, globallyEnabled: Bool, autocorrectActive: Bool = false) {
        self.secureEventInputEnabled = secureEventInputEnabled
        self.secureInputOwnerPID = secureInputOwnerPID
        self.frontmost = frontmost
        self.ownPID = ownPID
        self.trackingPaused = trackingPaused
        self.globallyEnabled = globallyEnabled
        self.autocorrectActive = autocorrectActive
    }
}

/// Stage 2 input: element METADATA attributes only. Never AXValue, selected text, or ranges.
public struct ElementProbe: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var identifier: String?
    public var title: String?
    public var placeholder: String?
    public var protectedContent: Bool?
    public var isEditable: Bool
    public init(role: String? = nil, subrole: String? = nil, roleDescription: String? = nil, identifier: String? = nil,
                title: String? = nil, placeholder: String? = nil, protectedContent: Bool? = nil, isEditable: Bool) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.title = title
        self.placeholder = placeholder
        self.protectedContent = protectedContent
        self.isEditable = isEditable
    }
}

/// Proof that both gate stages passed for one field. Only HunchPolicy can create one
/// (the initializer is internal), so no other module can read field text without it.
public struct SecureGatePass: Sendable, Equatable {
    public let field: FieldID
    public let issuedAt: ContinuousClock.Instant
    /// A pass is valid for one field and at most this long.
    public static let lifetime: Duration = .seconds(1)

    init(field: FieldID, issuedAt: ContinuousClock.Instant = .now) {
        self.field = field
        self.issuedAt = issuedAt
    }

    public func isValid(for field: FieldID, now: ContinuousClock.Instant = .now) -> Bool {
        field == self.field && now - issuedAt <= Self.lifetime
    }
}

public enum GateDecision: Sendable, Equatable {
    case allow
    case block(BlockReason)
}

public protocol SecureGating: Sendable {
    func evaluateSystem(_ probe: SystemProbe, policy: ResolvedPolicy) -> GateDecision
    func evaluateElement(_ probe: ElementProbe, field: FieldID, policy: ResolvedPolicy) -> Result<SecureGatePass, BlockReasonError>
}

/// `BlockReason` wrapped as an Error so it can travel in a `Result`.
public struct BlockReasonError: Error, Sendable, Equatable {
    public let reason: BlockReason
    public init(_ reason: BlockReason) { self.reason = reason }
}
