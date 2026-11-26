import Foundation
import Testing
import HunchCore
@testable import HunchPolicy

private let field = FieldID(pid: 10, elementHash: 1, generation: 1)
private let other = FieldID(pid: 10, elementHash: 2, generation: 1)
private func app(_ pid: pid_t = 10) -> AppIdentity { AppIdentity(bundleID: "x.y", pid: pid, localizedName: nil) }
private func policy(_ p: AppPolicy = .default) -> ResolvedPolicy { ResolvedPolicy(policy: p, sources: []) }
private func sys(secure: Bool = false, owner: pid_t? = nil, pid: pid_t = 10, own: pid_t = 99,
                 paused: Bool = false, global: Bool = true, autocorrect: Bool = true) -> SystemProbe {
    SystemProbe(secureEventInputEnabled: secure, secureInputOwnerPID: owner, frontmost: app(pid), ownPID: own,
                trackingPaused: paused, globallyEnabled: global, autocorrectActive: autocorrect)
}
private func block(_ r: Result<SecureGatePass, BlockReasonError>) -> BlockReason? {
    if case .failure(let e) = r { return e.reason }
    return nil
}

@Suite struct SystemGateTests {
    let gate = DefaultSecureGate()

    @Test func allow() { #expect(gate.evaluateSystem(sys(), policy: policy()) == .allow) }

    @Test func eachBranch() {
        #expect(gate.evaluateSystem(sys(secure: true, owner: 5), policy: policy()) == .block(.secureEventInput(ownerPID: 5)))
        #expect(gate.evaluateSystem(sys(global: false), policy: policy(AppPolicy(autocorrectEnabled: false))) == .block(.globallyDisabled))
        #expect(gate.evaluateSystem(sys(pid: 99), policy: policy()) == .block(.ownProcess))
        #expect(gate.evaluateSystem(sys(paused: true), policy: policy()) == .block(.trackingPaused))
        #expect(gate.evaluateSystem(sys(), policy: policy(AppPolicy(secureExcluded: true))) == .block(.secureExcludedApp))
        #expect(gate.evaluateSystem(sys(), policy: policy(AppPolicy(enabled: false, autocorrectEnabled: false))) == .block(.appDisabled))
    }

    /// Autocorrect works where suggestions are off: the gate lets the field through, the coordinator
    /// keeps everything else off.
    @Test func autocorrectKeepsAnAppWithSuggestionsOffReadable() {
        #expect(gate.evaluateSystem(sys(), policy: policy(AppPolicy(enabled: false, autocorrectEnabled: true))) == .allow)
        // Secure Input, secure-excluded apps and a timed pause still block it.
        #expect(gate.evaluateSystem(sys(secure: true), policy: policy(AppPolicy(enabled: false, autocorrectEnabled: true)))
                == .block(.secureEventInput(ownerPID: nil)))
        #expect(gate.evaluateSystem(sys(paused: true), policy: policy(AppPolicy(enabled: false, autocorrectEnabled: true)))
                == .block(.trackingPaused))
        // Suggestions off globally: autocorrect (on for the app) keeps the field readable; a timed pause
        // (autocorrect inactive) or autocorrect off for the app does not.
        #expect(gate.evaluateSystem(sys(global: false), policy: policy(AppPolicy(autocorrectEnabled: true))) == .allow)
        #expect(gate.evaluateSystem(sys(global: false, autocorrect: false), policy: policy(AppPolicy(autocorrectEnabled: true)))
                == .block(.globallyDisabled))
        #expect(gate.evaluateSystem(sys(global: false), policy: policy(AppPolicy(autocorrectEnabled: false)))
                == .block(.globallyDisabled))
    }

    @Test func order() {
        let worst = AppPolicy(enabled: false, secureExcluded: true, autocorrectEnabled: false)
        #expect(gate.evaluateSystem(sys(secure: true, pid: 99, paused: true, global: false), policy: policy(worst))
                == .block(.secureEventInput(ownerPID: nil)))
        #expect(gate.evaluateSystem(sys(pid: 99, paused: true, global: false), policy: policy(worst)) == .block(.globallyDisabled))
        #expect(gate.evaluateSystem(sys(pid: 99, paused: true), policy: policy(worst)) == .block(.ownProcess))
        #expect(gate.evaluateSystem(sys(paused: true), policy: policy(worst)) == .block(.trackingPaused))
        #expect(gate.evaluateSystem(sys(), policy: policy(worst)) == .block(.secureExcludedApp))
    }
}

@Suite struct ElementGateTests {
    let gate = DefaultSecureGate()
    func eval(_ p: ElementProbe) -> Result<SecureGatePass, BlockReasonError> {
        gate.evaluateElement(p, field: field, policy: policy())
    }

    @Test func passes() {
        let r = eval(ElementProbe(role: "AXTextArea", isEditable: true))
        guard case .success(let pass) = r else { Issue.record("expected pass"); return }
        #expect(pass.field == field)
    }

    @Test func secureRoleAndSubrole() {
        #expect(block(eval(ElementProbe(role: "AXSecureTextField", isEditable: true))) == .secureRole)
        #expect(block(eval(ElementProbe(role: "AXTextField", subrole: "AXSecureTextField", isEditable: true))) == .secureRole)
        #expect(block(eval(ElementProbe(role: "AXSecureTextField", isEditable: false))) == .secureRole)
    }

    @Test func protectedAndOrder() {
        #expect(block(eval(ElementProbe(protectedContent: true, isEditable: true))) == .protectedContent)
        #expect(block(eval(ElementProbe(title: "Password", protectedContent: true, isEditable: false))) == .protectedContent)
        #expect(block(eval(ElementProbe(title: "Password", isEditable: false))) == .sensitiveMarker)
        #expect(block(eval(ElementProbe(isEditable: false))) == .notEditable)
        #expect(block(eval(ElementProbe(protectedContent: false, isEditable: true))) == nil)
    }

    @Test(arguments: [
        "Password", "password field", "passwordField", "Enter your PIN", "pin", "One-Time Code", "OTP", "otpField",
        "Verification code", "2FA code", "Security Code", "CVV", "cvc", "Card number", "Credit Card", "SSN",
        "Social Security number", "API secret", "Private Key", "Recovery phrase", "Seed Phrase", "Passcode",
        "Passphrase", "输入密码", "验证码", "口令", "secure text field", "passwords", "user_password", "PINField",
    ])
    func markersMatch(_ s: String) {
        for probe in [ElementProbe(identifier: s, isEditable: true), ElementProbe(title: s, isEditable: true),
                      ElementProbe(placeholder: s, isEditable: true), ElementProbe(roleDescription: s, isEditable: true)] {
            #expect(block(eval(probe)) == .sensitiveMarker, "\(s)")
        }
    }

    @Test(arguments: [
        "Spinach recipes", "pinned notes", "Opinion", "Search", "Message", "Compose", "Shipping", "Secretary",
        "Pinterest", "Cover letter", "Subject", "Notes", "Description", "Pining",
    ])
    func falsePositivesPass(_ s: String) {
        #expect(block(eval(ElementProbe(roleDescription: s, identifier: s, title: s, placeholder: s, isEditable: true))) == nil, "\(s)")
    }

    @Test func searchFieldsPassByDefault() {
        for probe in [ElementProbe(role: "AXSearchField", isEditable: true),
                      ElementProbe(role: "AXTextField", subrole: "AXSearchField", isEditable: true)] {
            #expect(block(eval(probe)) == nil)
        }
    }

    @Test func searchFieldsBlockedWhenExcluded() {
        let excluding = policy(AppPolicy(excludeSearchFields: true))
        func evalExcluding(_ p: ElementProbe) -> BlockReason? {
            block(gate.evaluateElement(p, field: field, policy: excluding))
        }
        #expect(evalExcluding(ElementProbe(role: "AXSearchField", isEditable: true)) == .searchField)
        #expect(evalExcluding(ElementProbe(role: "AXTextField", subrole: "AXSearchField", isEditable: true)) == .searchField)
        // Other text fields still pass; security reasons still come first.
        #expect(evalExcluding(ElementProbe(role: "AXTextField", isEditable: true)) == nil)
        #expect(evalExcluding(ElementProbe(role: "AXTextArea", isEditable: true)) == nil)
        #expect(evalExcluding(ElementProbe(role: "AXSearchField", title: "Password", isEditable: true)) == .sensitiveMarker)
        #expect(evalExcluding(ElementProbe(role: "AXSearchField", isEditable: false)) == .notEditable)
    }

    @Test func passValidity() {
        let t0 = ContinuousClock.now
        let pass = SecureGatePass(field: field, issuedAt: t0)
        #expect(pass.isValid(for: field, now: t0))
        #expect(!pass.isValid(for: other, now: t0))
        #expect(pass.isValid(for: field, now: t0 + .milliseconds(900)))
        #expect(!pass.isValid(for: field, now: t0 + .milliseconds(1100)))
    }
}
