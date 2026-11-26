import Testing
@testable import HunchCore

/// Chrome is on, except on bank.example; Vault is secure-excluded; Mail is off.
private struct FakePolicies: AppPolicyResolving {
    func resolve(bundleID: String, urlHost: String?) -> ResolvedPolicy {
        var policy = AppPolicy.default
        switch (bundleID, urlHost) {
        case ("com.google.Chrome", "bank.example"): policy.enabled = false
        case ("com.example.vault", _): policy.secureExcluded = true
        case ("com.apple.mail", _): policy.enabled = false
        default: break
        }
        return ResolvedPolicy(policy: policy, sources: [])
    }
}

@Suite struct ClipboardSourceTests {
    let chrome = "com.google.Chrome"
    fileprivate let policies = FakePolicies()

    @Test func copyOnAnExcludedSiteIsChecked() {
        let excluded = ClipboardSource.noticed(frontmost: chrome, appSwitchedSincePoll: false,
                                               focus: .init(bundleID: chrome, urlHost: "bank.example"))
        #expect(excluded == .place(bundleID: chrome, urlHost: "bank.example"))
        #expect(!excluded.allows(policies))
        let other = ClipboardSource.noticed(frontmost: chrome, appSwitchedSincePoll: false,
                                            focus: .init(bundleID: chrome, urlHost: "news.example"))
        #expect(other.allows(policies))
    }

    @Test func blockedFocusTaintsTheCopy() {
        // An excluded page with no readable field: the focus engine reports it blocked.
        for reason: BlockReason in [.appDisabled, .secureExcludedApp, .secureRole, .sensitiveMarker,
                                    .protectedContent, .secureEventInput(ownerPID: nil), .trackingPaused,
                                    .globallyDisabled] {
            let source = ClipboardSource.noticed(frontmost: chrome, appSwitchedSincePoll: false,
                                                 focus: .init(bundleID: chrome, blockReason: reason))
            #expect(source == .blocked)
            #expect(!source.allows(policies))
        }
    }

    @Test func harmlessBlocksKeepTheSite() {
        let source = ClipboardSource.noticed(frontmost: chrome, appSwitchedSincePoll: false,
                                             focus: .init(bundleID: chrome, urlHost: nil, blockReason: .notEditable))
        #expect(source == .place(bundleID: chrome, urlHost: nil))
        #expect(source.allows(policies))
    }

    @Test func appSwitchSincePollIsUnclear() {
        let source = ClipboardSource.noticed(frontmost: "com.apple.Notes", appSwitchedSincePoll: true,
                                             focus: .init(bundleID: "com.apple.Notes"))
        #expect(source == .unclear)
        #expect(!source.allows(policies))
        #expect(ClipboardSource.noticed(frontmost: nil, appSwitchedSincePoll: false, focus: nil) == .unclear)
    }

    @Test func staleFocusForAnotherAppIsIgnored() {
        let source = ClipboardSource.noticed(frontmost: "com.apple.Notes", appSwitchedSincePoll: false,
                                             focus: .init(bundleID: chrome, blockReason: .appDisabled))
        #expect(source == .place(bundleID: "com.apple.Notes", urlHost: nil))
        #expect(source.allows(policies))
    }

    @Test func offAndSecureAppsAreRefused() {
        #expect(!ClipboardSource.place(bundleID: "com.apple.mail", urlHost: nil).allows(policies))
        #expect(!ClipboardSource.place(bundleID: "com.example.vault", urlHost: nil).allows(policies))
    }
}
