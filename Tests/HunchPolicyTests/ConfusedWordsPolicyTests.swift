import Foundation
import HunchCore
import Testing
@testable import HunchPolicy

/// Per-app "Fix commonly confused words": on by default, off in the Chats category, the user's
/// choice wins; the general switch gates it.
struct ConfusedWordsPolicyTests {
    @Test func onByDefaultOffInChats() {
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.fixConfusedWordsAllowed)
        #expect(!resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.fixConfusedWordsAllowed)
        #expect(!resolver.resolve(bundleID: "net.whatsapp.WhatsApp", urlHost: nil).policy.fixConfusedWordsAllowed)
        #expect(HunchSettings().autocorrectFixConfusedWords)
    }

    @Test func userChoiceOverridesTheChatsDefault() {
        var on = AppPolicyPatch()
        on.fixConfusedWordsAllowed = true
        var off = AppPolicyPatch()
        off.fixConfusedWordsAllowed = false
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.MobileSMS"): on,
                                                    .app(bundleID: "com.apple.Notes"): off]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.fixConfusedWordsAllowed)
        #expect(!resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.fixConfusedWordsAllowed)
    }

    @Test func defaultLabelFollowsTheCategoryAndTheGeneralSwitch() {
        var s = HunchSettings()
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).fixConfusedWords)
        #expect(!InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).fixConfusedWords)
        s.autocorrectFixConfusedWords = false
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).fixConfusedWords)
    }

    @Test func savedValuesDecodeAndMigrate() throws {
        let p = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"fixAutomaticallyAllowed":false}"#.utf8))
        #expect(p.fixConfusedWordsAllowed == nil)
        var mine = AppPolicyPatch()
        mine.fixConfusedWordsAllowed = false
        CategoryMigration.clearMatching(&mine, try #require(CategoryPresets.preset(named: CategoryNames.chats)))
        #expect(mine.fixConfusedWordsAllowed == nil)
    }
}

/// The global "Leave chat shorthand" switch gates the per-app one (on in Chats).
struct ChatShorthandGateTests {
    @Test func onByDefault() {
        #expect(HunchSettings().autocorrectLeaveChatShorthand)
    }

    @Test func globalSwitchGatesThePerAppLabel() {
        var s = HunchSettings()
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        #expect(InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).leavesChatShorthand)
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).leavesChatShorthand)
        s.autocorrectLeaveChatShorthand = false
        #expect(!InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).leavesChatShorthand)
    }
}

/// General → Suggestions is the hard gate for every per-app Suggestions label; autocorrect has its own.
struct SuggestionsGateLabelTests {
    @Test func generalOffMakesEveryDefaultOff() {
        var s = HunchSettings()
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).suggestions)
        s.enabled = false
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).suggestions)
        #expect(!InheritedPolicy(bundleID: nil, settings: s).suggestions)
    }

    @Test func autocorrectLabelIsIndependentOfSuggestions() {
        var s = HunchSettings()
        s.enabled = false
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).autocorrect)
        s.completionsEnabledByDefault = false
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).autocorrect)
    }
}
