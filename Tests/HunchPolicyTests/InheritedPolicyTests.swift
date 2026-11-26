import HunchCore
import Testing
@testable import HunchPolicy

// What "Default" shows in Settings → Apps & Sites must match what the resolver does.

@Test func inheritedFollowsSeedAndGeneralSettings() {
    var s = HunchSettings()
    s.completionsEnabledByDefault = true
    s.midLineByDefault = false
    s.screenContextEnabled = false
    s.learning.enabled = true
    s.usePersonalInfo = true

    let editor = InheritedPolicy(bundleID: "com.microsoft.VSCode", settings: s)
    #expect(!editor.suggestions)            // built-in rule: code editors off
    let notes = InheritedPolicy(bundleID: "com.apple.Notes", settings: s)
    #expect(notes.suggestions && notes.acceptWordKey == .shortcuts && !notes.midLine)
    #expect(!notes.screenContext)           // off in general, so off here
    #expect(notes.learning && notes.personalInfo)
    #expect(notes.insertion == .unicodeEvents && notes.overlay == .automatic)

    s.screenContextEnabled = true
    s.learning.enabled = false
    s.midLineByDefault = true
    let after = InheritedPolicy(bundleID: "com.apple.Notes", settings: s)
    #expect(after.screenContext && !after.learning && after.midLine)
}

@Test func inheritedMatchesResolverWithoutUserPatches() {
    let s = HunchSettings()
    let resolver = DefaultPolicyResolver(completionsEnabledByDefault: s.completionsEnabledByDefault)
    resolver.setMidLineByDefault(s.midLineByDefault)
    for id in Seeds.passwordManagers + Seeds.codeEditors + Seeds.mail + Seeds.terminals + ["com.apple.Notes"] {
        let p = resolver.resolve(bundleID: id, urlHost: nil).policy
        let i = InheritedPolicy(bundleID: id, settings: s)
        #expect(i.suggestions == p.enabled && i.acceptWordKey == p.acceptWordKey && i.acceptFullKey == p.acceptFullKey && i.midLine == p.midLineEnabled
                && i.insertion == p.insertion && i.overlay == p.overlay, "\(id)")
    }
}

@Test func inheritedFeatureTogglesFollowGeneralSettings() {
    var s = HunchSettings()
    let on = InheritedPolicy(bundleID: "com.apple.Notes", settings: s)
    #expect(on.autocorrect && on.emoticonEmoji && on.emojiSearch)
    #expect(on.smartQuotes && !on.excludeSearchFields)   // no general switch: smart quotes on, search allowed

    s.autocorrectEnabled = false
    s.emoji.enabled = false
    let off = InheritedPolicy(bundleID: "com.apple.Notes", settings: s)
    #expect(!off.autocorrect && !off.emoticonEmoji && !off.emojiSearch)
    #expect(off.smartQuotes && !off.excludeSearchFields)
    // Suggested replies follow their General switch.
    #expect(!off.suggestedReplies)
    s.suggestedRepliesEnabled = true
    #expect(InheritedPolicy(bundleID: "com.apple.Notes", settings: s).suggestedReplies)

    // Same answer as the resolver fed the same general settings.
    let resolver = DefaultPolicyResolver(completionsEnabledByDefault: s.completionsEnabledByDefault)
    resolver.setAutocorrectByDefault(s.autocorrectEnabled)
    resolver.setEmojiByDefault(s.emoji.enabled)
    for id in Seeds.passwordManagers + Seeds.codeEditors + Seeds.mail + ["com.apple.Notes"] {
        let p = resolver.resolve(bundleID: id, urlHost: nil).policy
        let i = InheritedPolicy(bundleID: id, settings: s)
        #expect(i.autocorrect == p.autocorrectEnabled && i.emoticonEmoji == p.emoticonEmojiEnabled
                && i.emojiSearch == p.emojiSearchEnabled && i.smartQuotes == p.smartQuotesEnabled
                && i.excludeSearchFields == p.excludeSearchFields, "\(id)")
    }
}
