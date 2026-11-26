import Foundation
import HunchCore
import Testing
@testable import HunchPolicy

struct AutocorrectStrengthTests {
    @Test func defaultIsBalanced() {
        #expect(HunchSettings().autocorrectStrength == .balanced)
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.autocorrectStrength == .balanced)
        #expect(!CorrectionMode.resolve(chosen: .balanced, efficiency: false).strength.isLight)
    }

    @Test func strongNeedsAutomaticCorrections() {
        #expect(AutocorrectStrength.allowed(.strong, automatic: false) == .balanced)
        #expect(AutocorrectStrength.allowed(.strong, automatic: true) == .strong)
        #expect(AutocorrectStrength.allowed(.light, automatic: false) == .light)
        #expect(AutocorrectStrength.maxIndex(automatic: false) == AutocorrectStrength.allCases.firstIndex(of: .balanced))
        #expect(AutocorrectStrength.maxIndex(automatic: true) == AutocorrectStrength.allCases.count - 1)
    }

    @Test func generalSettingIsTheBaseLayer() {
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        resolver.setAutocorrectStrengthByDefault(.light)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.autocorrectStrength == .light)
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.autocorrectStrength == .light)
    }

    @Test func perAppOverrideWinsAndOthersInherit() {
        var mine = AppPolicyPatch()
        mine.autocorrectStrength = .strong
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.Notes"): mine]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        resolver.setAutocorrectStrengthByDefault(.light)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.autocorrectStrength == .strong)
        #expect(resolver.resolve(bundleID: "com.apple.TextEdit", urlHost: nil).policy.autocorrectStrength == .light)
    }

    @Test func categoryCanSetItAndTheAppOverridesTheCategory() {
        var chat = AppPolicyPatch()
        chat.autocorrectStrength = .light
        var s = HunchSettings()
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).strength == .balanced)
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s, category: chat).strength == .light)
        s.autocorrectStrength = .strong
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).strength == .strong)
        #expect(InheritedPolicy(bundleID: nil, settings: s).strength == .strong)
    }

    @Test func presetsLeaveItAlone() {
        for name in [CategoryNames.chats] {
            #expect(CategoryPresets.preset(named: name)?.autocorrectStrength == nil)
        }
    }

    @Test func savedValuesDecodeAndMigrate() throws {
        let old = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"fixAutomaticallyAllowed":false}"#.utf8))
        #expect(old.autocorrectStrength == nil)
        let saved = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"autocorrectStrength":"light"}"#.utf8))
        #expect(saved.autocorrectStrength == .light)
        var mine = AppPolicyPatch()
        mine.autocorrectStrength = .light
        CategoryMigration.clearMatching(&mine, saved)
        #expect(mine.autocorrectStrength == nil)
    }

    // MARK: Which strength is in effect

    @Test func lightNeverUsesTheModel() {
        #expect(!CorrectionMode.resolve(chosen: .light, efficiency: false).usesModel)
        #expect(CorrectionMode.resolve(chosen: .balanced, efficiency: false).usesModel)
        #expect(CorrectionMode.resolve(chosen: .strong, efficiency: false).usesModel)
    }

    @Test func efficiencyPowerModeActsLikeLight() {
        for chosen in AutocorrectStrength.allCases {
            let mode = CorrectionMode.resolve(chosen: chosen, efficiency: true)
            #expect(mode.strength == .light)
            #expect(!mode.usesModel)
        }
    }

    @Test func strongActsLikeBalancedForNow() {
        let strong = CorrectionMode.resolve(chosen: .strong, efficiency: false)
        #expect(strong.usesModel)
    }
}

private extension AutocorrectStrength { var isLight: Bool { self == .light } }
