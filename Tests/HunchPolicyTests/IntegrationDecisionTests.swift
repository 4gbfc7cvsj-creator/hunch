import Foundation
import Testing
import HunchCore
@testable import HunchPolicy

@Suite struct MidLineDefaultTests {
    @Test func baseLayerFollowsSetter() {
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(r.resolve(bundleID: "x.y", urlHost: nil).policy.midLineEnabled == false)
        r.setMidLineByDefault(true)
        #expect(r.resolve(bundleID: "x.y", urlHost: nil).policy.midLineEnabled == true)
        r.setMidLineByDefault(false)
        #expect(r.resolve(bundleID: "x.y", urlHost: nil).policy.midLineEnabled == false)
    }

    @Test func userPatchesStillOverride() {
        var off = AppPolicyPatch()
        off.midLineEnabled = false
        var on = AppPolicyPatch()
        on.midLineEnabled = true
        let user: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "a.off"): off, .domain(pattern: "docs.example.com"): on]
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, seeds: [:], userPatches: { user })
        r.setMidLineByDefault(true)
        #expect(r.resolve(bundleID: "a.off", urlHost: nil).policy.midLineEnabled == false)
        r.setMidLineByDefault(false)
        #expect(r.resolve(bundleID: "a.off", urlHost: "docs.example.com").policy.midLineEnabled == true)
    }

    @Test func doesNotTouchEnabledDefault() {
        let r = DefaultPolicyResolver(completionsEnabledByDefault: false, seeds: [:])
        r.setMidLineByDefault(true)
        let p = r.resolve(bundleID: "x.y", urlHost: nil).policy
        #expect(p.midLineEnabled && !p.enabled)
    }
}

@Suite struct EngineSelectionTests {
    @Test(arguments: [
        (EngineKind.local, true, EngineKind?.none, EngineKind.local),
        (.endpoint, true, nil, .endpoint),
        (.endpoint, false, nil, .local),          // no endpoint configured
        (.local, true, .endpoint, .endpoint),      // app override wins
        (.endpoint, true, .local, .local),
        (.local, false, .endpoint, .local),
    ])
    func choice(global: EngineKind, configured: Bool, override: EngineKind?, expected: EngineKind) {
        #expect(EngineSelection.kind(globalEngine: global, endpointConfigured: configured, appOverride: override) == expected)
    }
}

@Suite struct ScreenContextDecisionTests {
    private let field = FieldID(pid: 42, elementHash: 7, generation: 1)

    @Test func allGatesRequired() {
        let ok = AppPolicy()
        #expect(ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: ok, permitted: true, trigger: .fieldFocused))
        #expect(!ScreenContextDecision.shouldFetch(globallyEnabled: false, policy: ok, permitted: true, trigger: .fieldFocused))
        #expect(!ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: ok, permitted: false, trigger: .fieldFocused))
        var denied = ok
        denied.screenContextAllowed = false
        #expect(!ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: denied, permitted: true, trigger: .fieldFocused))
        var disabled = ok
        disabled.enabled = false
        #expect(!ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: disabled, permitted: true, trigger: .fieldFocused))
        var secure = ok
        secure.secureExcluded = true
        #expect(!ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: secure, permitted: true, trigger: .fieldFocused))
    }

    @Test func typingNeedsAPause() {
        let ok = AppPolicy()
        #expect(!ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: ok, permitted: true,
                                                   trigger: .typingPaused(.milliseconds(400))))
        #expect(ScreenContextDecision.shouldFetch(globallyEnabled: true, policy: ok, permitted: true,
                                                  trigger: .typingPaused(.seconds(1))))
    }

    @Test func excerptMustMatchFieldAndBeFresh() {
        let now = ContinuousClock.now
        let excerpt = ScreenExcerpt(text: "hello", capturedAt: now, signature: 1)
        let ok = AppPolicy()
        #expect(ScreenContextDecision.usableExcerpt(cachedField: field, excerpt: excerpt, field: field,
                                                    globallyEnabled: true, policy: ok, now: now) == excerpt)
        let other = FieldID(pid: 42, elementHash: 7, generation: 2)
        #expect(ScreenContextDecision.usableExcerpt(cachedField: field, excerpt: excerpt, field: other,
                                                    globallyEnabled: true, policy: ok, now: now) == nil)
        #expect(ScreenContextDecision.usableExcerpt(cachedField: field, excerpt: excerpt, field: field,
                                                    globallyEnabled: false, policy: ok, now: now) == nil)
        let later = now + ScreenContextDecision.maxExcerptAge + .seconds(1)
        #expect(ScreenContextDecision.usableExcerpt(cachedField: field, excerpt: excerpt, field: field,
                                                    globallyEnabled: true, policy: ok, now: later) == nil)
        let empty = ScreenExcerpt(text: "", capturedAt: now, signature: 2)
        #expect(ScreenContextDecision.usableExcerpt(cachedField: field, excerpt: empty, field: field,
                                                    globallyEnabled: true, policy: ok, now: now) == nil)
        var denied = ok
        denied.screenContextAllowed = false
        #expect(ScreenContextDecision.usableExcerpt(cachedField: field, excerpt: excerpt, field: field,
                                                    globallyEnabled: true, policy: denied, now: now) == nil)
    }
}
