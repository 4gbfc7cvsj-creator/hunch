import Foundation
import HunchCore
import Testing
@testable import HunchPolicy

/// Per-app "Fix automatically": on by default (Chats too), off in the Private category, the user's choice wins.
struct FixAutomaticallyPolicyTests {
    @Test func onByDefaultOffInPrivate() {
        var privateApp = AppPolicyPatch()
        privateApp.appCategory = CategoryNames.private
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.Safari"): privateApp]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.fixAutomaticallyAllowed)
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.fixAutomaticallyAllowed)
        #expect(!resolver.resolve(bundleID: "com.apple.Safari", urlHost: nil).policy.fixAutomaticallyAllowed)
        // Autocorrect itself stays on in Private: the fix waits for Tab.
        #expect(resolver.resolve(bundleID: "com.apple.Safari", urlHost: nil).policy.autocorrectEnabled)
    }

    @Test func userChoiceOverridesTheChatsDefault() {
        var on = AppPolicyPatch()
        on.fixAutomaticallyAllowed = true
        var off = AppPolicyPatch()
        off.fixAutomaticallyAllowed = false
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.MobileSMS"): on,
                                                    .app(bundleID: "com.apple.Notes"): off]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.fixAutomaticallyAllowed)
        #expect(!resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.fixAutomaticallyAllowed)
    }

    @Test func defaultLabelFollowsTheGeneralSwitches() {
        var s = HunchSettings()
        s.autocorrectEnabled = true
        s.autocorrectFixAutomatically = true
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        let personal = CategoryPresets.preset(named: CategoryNames.private)
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).fixAutomatically)
        #expect(InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).fixAutomatically)
        #expect(!InheritedPolicy(bundleID: "com.apple.Safari", settings: s, category: personal).fixAutomatically)
        s.autocorrectFixAutomatically = false
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).fixAutomatically)
    }

    @Test func oldSavedPatchesStillDecode() throws {
        let data = Data(#"{"autocorrectEnabled":true}"#.utf8)
        let p = try JSONDecoder().decode(AppPolicyPatch.self, from: data)
        #expect(p.fixAutomaticallyAllowed == nil && p.autocorrectEnabled == true)
    }
}

/// Per-app "Leave chat shorthand": off by default, on in the Chats category, the user's choice wins.
struct ChatShorthandPolicyTests {
    @Test func offByDefaultOnInChats() {
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(!resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.leavesChatShorthand)
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.leavesChatShorthand)
        #expect(resolver.resolve(bundleID: "net.whatsapp.WhatsApp", urlHost: nil).policy.leavesChatShorthand)
    }

    @Test func userChoiceOverridesTheChatsDefault() {
        var on = AppPolicyPatch()
        on.leavesChatShorthand = true
        var off = AppPolicyPatch()
        off.leavesChatShorthand = false
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.MobileSMS"): off,
                                                    .app(bundleID: "com.apple.Notes"): on]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(!resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.leavesChatShorthand)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.leavesChatShorthand)
    }

    @Test func defaultLabelFollowsTheCategory() {
        let s = HunchSettings()
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).leavesChatShorthand)
        #expect(InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).leavesChatShorthand)
    }

    @Test func oldSavedPatchesStillDecode() throws {
        let p = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"fixAutomaticallyAllowed":false}"#.utf8))
        #expect(p.leavesChatShorthand == nil && p.fixAutomaticallyAllowed == false)
    }
}

struct TextReplacementsPolicyTests {
    @Test func onByDefaultAndSwitchableAndDecodesOldPatches() throws {
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(resolver.resolve(bundleID: "com.example.App", urlHost: nil).policy.appliesTextReplacements)
        var off = AppPolicyPatch()
        off.appliesTextReplacements = false
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.example.App"): off]
        let custom = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(!custom.resolve(bundleID: "com.example.App", urlHost: nil).policy.appliesTextReplacements)
        let old = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"fixAutomaticallyAllowed":false}"#.utf8))
        #expect(old.appliesTextReplacements == nil)
    }
}

/// Per-app "Fix punctuation": on by default, off in the Chats category, the user's choice wins.
struct FixPunctuationPolicyTests {
    @Test func onByDefaultOffInChats() {
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.fixesPunctuation)
        #expect(!resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.fixesPunctuation)
        #expect(!resolver.resolve(bundleID: "net.whatsapp.WhatsApp", urlHost: nil).policy.fixesPunctuation)
    }

    @Test func userChoiceOverridesTheChatsDefault() {
        var on = AppPolicyPatch()
        on.fixesPunctuation = true
        var off = AppPolicyPatch()
        off.fixesPunctuation = false
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.MobileSMS"): on,
                                                    .app(bundleID: "com.apple.Notes"): off]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.fixesPunctuation)
        #expect(!resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.fixesPunctuation)
    }

    @Test func defaultLabelFollowsTheGeneralSwitch() {
        var s = HunchSettings()
        #expect(s.fixPunctuation)   // on by default
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).fixesPunctuation)
        #expect(!InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).fixesPunctuation)
        s.fixPunctuation = false
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).fixesPunctuation)
    }

    @Test func oldSavedPatchesStillDecode() throws {
        let p = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"autocorrectEnabled":true}"#.utf8))
        #expect(p.fixesPunctuation == nil)
    }

    @Test func categoryMigrationClearsIt() {
        // Same list as the other autocorrect switches: a per-app value equal to the category's is dropped.
        var p = AppPolicyPatch()
        p.fixesPunctuation = false
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        #expect(chats?.fixesPunctuation == false && p.fixesPunctuation == chats?.fixesPunctuation)
    }
}

/// Per-app "Auto-capitalization": on by default, off in the Chats category, the user's choice wins.
struct AutoCapitalizationPolicyTests {
    @Test func onByDefaultOffInChats() {
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true)
        #expect(resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.autoCapitalizationAllowed)
        #expect(!resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.autoCapitalizationAllowed)
        #expect(!resolver.resolve(bundleID: "net.whatsapp.WhatsApp", urlHost: nil).policy.autoCapitalizationAllowed)
    }

    @Test func userChoiceOverridesTheChatsDefault() {
        var on = AppPolicyPatch()
        on.autoCapitalizationAllowed = true
        var off = AppPolicyPatch()
        off.autoCapitalizationAllowed = false
        let patches: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.apple.MobileSMS"): on,
                                                    .app(bundleID: "com.apple.Notes"): off]
        let resolver = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { patches })
        #expect(resolver.resolve(bundleID: "com.apple.MobileSMS", urlHost: nil).policy.autoCapitalizationAllowed)
        #expect(!resolver.resolve(bundleID: "com.apple.Notes", urlHost: nil).policy.autoCapitalizationAllowed)
    }

    @Test func defaultLabelFollowsTheGlobalSwitchAndTheCategory() {
        var s = HunchSettings()
        let chats = CategoryPresets.preset(named: CategoryNames.chats)
        #expect(s.autocorrectCapitalization)
        #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).autoCapitalization)
        #expect(!InheritedPolicy(bundleID: "com.apple.MobileSMS", settings: s, category: chats).autoCapitalization)
        s.autocorrectCapitalization = false
        #expect(!InheritedPolicy(bundleID: "com.apple.Notes", settings: s).autoCapitalization)
    }

    @Test func oldSavedPatchesAndSettingsStillDecode() throws {
        let p = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"fixAutomaticallyAllowed":false}"#.utf8))
        #expect(p.autoCapitalizationAllowed == nil && p.fixAutomaticallyAllowed == false)
        #expect(HunchSettings().autocorrectCapitalization)
    }
}
