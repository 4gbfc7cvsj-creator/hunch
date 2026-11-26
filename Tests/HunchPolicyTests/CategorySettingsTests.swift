import Foundation
import HunchCore
import Testing
@testable import HunchPolicy

// Categories carry settings: built-in rule < category < app; browser < site's category < site.

private func patch(_ configure: (inout AppPolicyPatch) -> Void) -> AppPolicyPatch {
    var p = AppPolicyPatch()
    configure(&p)
    return p
}

private func resolver(_ user: [PolicyKey: AppPolicyPatch],
                      automatic: AutoCategories = .none) -> DefaultPolicyResolver {
    DefaultPolicyResolver(completionsEnabledByDefault: true, seeds: [:], userPatches: { user },
                          automaticCategories: automatic)
}

@Test func appFollowsItsPresetCategory() {
    let user: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "a.mail"): patch { $0.appCategory = "work" }]
    let r = resolver(user).resolve(bundleID: "a.mail", urlHost: nil)
    #expect(r.policy.writeShape == .email)
    #expect(r.policy.instructionsReplaceGlobal)
    #expect(r.policy.customInstructions?.hasPrefix("Here I\u{2019}m writing to coworkers") == true)
    #expect(!r.policy.emojiSearchEnabled && !r.policy.emoticonEmojiEnabled)
    #expect(r.sources.contains(.category(name: "Work")))
}

@Test func appsOwnChoiceWinsOverCategory() {
    let user: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "a.mail"): patch {
        $0.appCategory = "Work"; $0.emojiSearchEnabled = true; $0.writeShape = .message
    }]
    let p = resolver(user).resolve(bundleID: "a.mail", urlHost: nil).policy
    #expect(p.emojiSearchEnabled && p.writeShape == .message)
    #expect(!p.emoticonEmojiEnabled)   // still from Work
}

@Test func categoryCannotTurnOnOverABuiltInRule() {
    // A code editor's built-in rule turns suggestions off; a category set to On doesn't override it
    // (categories only turn suggestions off; the app itself can still be turned on).
    let seeds: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "ed"): patch { $0.enabled = false }]
    let user: [PolicyKey: AppPolicyPatch] = [
        .app(bundleID: "ed"): patch { $0.appCategory = "Code" },
        .category(name: "Code"): patch { $0.enabled = true },
    ]
    let r = DefaultPolicyResolver(completionsEnabledByDefault: true, seeds: seeds, userPatches: { user },
                                  automaticCategories: .none)
    #expect(!r.resolve(bundleID: "ed", urlHost: nil).policy.enabled)
}

@Test func savedCategoryReplacesPresetCompletely() {
    let user: [PolicyKey: AppPolicyPatch] = [
        .app(bundleID: "x"): patch { $0.appCategory = "Private" },
        .category(name: "private"): patch { $0.screenContextAllowed = false },
    ]
    let p = resolver(user).resolve(bundleID: "x", urlHost: nil).policy
    #expect(!p.screenContextAllowed)
    #expect(p.learningAllowed)          // the preset turned it off; the saved settings don't
}

@Test func siteCategoryLayersOverBrowser() {
    let user: [PolicyKey: AppPolicyPatch] = [
        .app(bundleID: "browser"): patch { $0.appCategory = "Private" },
        .domain(pattern: "chat.example"): patch { $0.appCategory = "Chats" },
    ]
    let r = resolver(user).resolve(bundleID: "browser", urlHost: "chat.example")
    #expect(r.policy.customInstructions?.hasPrefix("here i\u{2019}m texting") == true)
    #expect(!r.policy.learningAllowed)  // Chats leaves learning on Default, so the browser's Private wins
    #expect(r.sources == [.category(name: "Private"), .app(bundleID: "browser"), .category(name: "Chats"),
                          .domain(pattern: "chat.example")])
}

@Test func automaticCategoryAppliesUntilUserPicks() {
    let auto = AutoCategories(apps: ["m": "Work"], sites: ["*.chat.example": "Chats"])
    #expect(resolver([:], automatic: auto).resolve(bundleID: "m", urlHost: nil).policy.writeShape == .email)
    #expect(resolver([:], automatic: auto).resolve(bundleID: "b", urlHost: "eu.chat.example").policy
        .customInstructions?.hasPrefix("here i") == true)

    let none: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "m"): patch { $0.appCategory = "" }]
    #expect(resolver(none, automatic: auto).resolve(bundleID: "m", urlHost: nil).policy.writeShape == .adaptive)

    let moved: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "m"): patch { $0.appCategory = "AI" }]
    #expect(resolver(moved, automatic: auto).resolve(bundleID: "m", urlHost: nil).policy.writeShape == .aiPrompt)
}

@Test func appCategoriesExplicitNoneAndAutomatic() {
    let auto = AutoCategories(apps: ["mail": "Work", "msg": "Chats"], sites: ["*.slack.com": "Work"])
    let c = AppCategories(patches: [
        .app(bundleID: "msg"): patch { $0.appCategory = "" },
        .domain(pattern: "x.slack.com"): patch { $0.appCategory = " Private " },
    ], automatic: auto)
    #expect(c.category(ofApp: "mail") == "Work")
    #expect(c.category(ofApp: "msg") == nil)
    #expect(c.category(ofSite: "x.slack.com") == "Private")
    #expect(c.category(ofSite: "team.slack.com") == "Work")
    #expect(c.names == ["Private"])
    #expect(c.sameCategory("mail", "team.slack.com"))
    #expect(!c.isExplicit(.app(bundleID: "mail")) && c.isExplicit(.app(bundleID: "msg")))
}

@Test func builtInAutomaticCategoriesUsePresetNames() {
    let names = Set(AutoCategories.builtIn.apps.values).union(AutoCategories.builtIn.sites.values)
    #expect(names.isSubset(of: Set(CategoryNames.presets)))
    #expect(AutoCategories.builtIn.apps["com.apple.mail"] == "Work")
    #expect(AutoCategories.builtIn.apps["com.anthropic.claudefordesktop"] == "AI")
    #expect(AutoCategories.builtIn.apps["com.hnc.Discord"] == "Chats")
    for id in ["com.openai.codex", "com.todesktop.230313mzl4w4u92", "ai.elementlabs.lmstudio", "com.nousresearch.hermes"] {
        #expect(AutoCategories.builtIn.apps[id] == "AI", "\(id)")
    }
    #expect(AppCategories(automatic: .builtIn).category(ofSite: "team.slack.com") == "Work")
    #expect(AutoCategories.builtIn.apps["com.google.Chrome"] == nil)   // browsers are never categorized automatically
}

@Test func allNamesListsPresetsThenOwn() {
    let user: [PolicyKey: AppPolicyPatch] = [.category(name: "zeta"): AppPolicyPatch(), .category(name: "work"): AppPolicyPatch()]
    #expect(CategoryPresets.allNames(user, used: ["AI Image", "chats"]) == ["AI", "Work", "Chats", "Private", "AI Image", "zeta"])
}

@Test func inheritedIncludesCategory() {
    let s = HunchSettings()
    let work = CategoryPresets.preset(named: "Work")
    let i = InheritedPolicy(bundleID: "com.example.app", settings: s, category: work)
    #expect(i.writeShape == .email && !i.emojiSearch && i.instructionsReplaceGlobal)
    #expect(i.customInstructions == work?.customInstructions)
    let bare = InheritedPolicy(bundleID: nil, settings: s)
    #expect(bare.writeShape == .adaptive && bare.customInstructions == nil)
}

@Test func ownLookResolvesThroughLayers() {
    var look = AppearanceSettings()
    look.animation = .neon
    let user: [PolicyKey: AppPolicyPatch] = [
        .app(bundleID: "x"): patch { $0.appCategory = "Fun" },
        .category(name: "Fun"): patch { $0.appearance = look },
    ]
    #expect(resolver(user).resolve(bundleID: "x", urlHost: nil).policy.appearance?.animation == .neon)
    #expect(resolver(user).resolve(bundleID: "y", urlHost: nil).policy.appearance == nil)
    #expect(GhostTweaks(resolver(user).resolve(bundleID: "x", urlHost: nil).policy).appearance?.animation == .neon)
}

// MARK: Migration

@Test func migrationClearsValuesEqualToCategory() {
    let work = CategoryPresets.preset(named: "Work")!
    var patches: [PolicyKey: AppPolicyPatch] = [
        .app(bundleID: "mail"): patch {
            $0.appCategory = "Work"
            $0.customInstructions = work.customInstructions! + "\n"   // trailing newline still matches
            $0.instructionsReplaceGlobal = true
            $0.emojiSearchEnabled = false
            $0.emoticonEmojiEnabled = true                             // differs: kept
            $0.writeShape = .email
            $0.fontSizeAdjustmentFactor = 1.1                          // not a category setting: kept
        },
        .app(bundleID: "chrome"): patch {
            $0.appCategory = "Private"
            $0.learningAllowed = false; $0.screenContextAllowed = false; $0.personalInfoAllowed = false
            $0.emojiSearchEnabled = false; $0.emoticonEmojiEnabled = false
        },
        .app(bundleID: "other"): patch { $0.emojiSearchEnabled = false },  // no category: untouched
    ]
    CategoryMigration.migrate(&patches, mainAppearance: AppearanceSettings(), automatic: .none)
    let mail = patches[.app(bundleID: "mail")]!
    #expect(mail.customInstructions == nil && mail.instructionsReplaceGlobal == nil && mail.writeShape == nil)
    #expect(mail.emojiSearchEnabled == nil && mail.emoticonEmojiEnabled == true && mail.fontSizeAdjustmentFactor == 1.1)
    #expect(patches[.app(bundleID: "chrome")] == patch { $0.appCategory = "Private" })
    #expect(patches[.app(bundleID: "other")]?.emojiSearchEnabled == false)
}

@Test func migrationTurnsAlwaysGreyIntoOwnLook() {
    var main = AppearanceSettings()
    main.animation = .ember
    var patches: [PolicyKey: AppPolicyPatch] = [
        .app(bundleID: "g"): patch { $0.greySuggestionColorEnabled = true },
        .app(bundleID: "h"): patch { $0.greySuggestionColorEnabled = false; $0.midLineEnabled = true },
    ]
    CategoryMigration.migrate(&patches, mainAppearance: main, automatic: .none)
    let g = patches[.app(bundleID: "g")]!
    #expect(g.greySuggestionColorEnabled == nil && g.appearance?.color == .grey && g.appearance?.animation == .ember)
    #expect(patches[.app(bundleID: "h")] == patch { $0.midLineEnabled = true })
}

// MARK: Store

@Test func storeKeepsCategoriesApartAndRunsMigrationsOnce() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("p.json")
    let store = JSONPolicyStore(fileURL: url)
    try store.setPatch(patch { $0.appCategory = "Work" }, for: .app(bundleID: "a"))
    try store.setPatch(patch { $0.learningAllowed = false }, for: .category(name: "Mine"))
    var runs = 0
    try store.runMigration("m1") { _ in runs += 1 }
    try store.runMigration("m1") { _ in runs += 1 }
    #expect(runs == 1)

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect((json["entries"] as! [Any]).count == 1)
    #expect((json["categories"] as! [[String: Any]]).first?["name"] as? String == "Mine")
    #expect(json["migrations"] as? [String] == ["m1"])

    let reloaded = JSONPolicyStore(fileURL: url)
    #expect(reloaded.userPatches[.category(name: "Mine")]?.learningAllowed == false)
    #expect(reloaded.hasRun("m1"))
}

@Test func storeReadsFilesFromBeforeCategorySettings() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("p.json")
    let old = #"{"schemaVersion":1,"entries":[{"key":{"app":{"bundleID":"a"}},"patch":{"appCategory":"Chats"}}]}"#
    try Data(old.utf8).write(to: url)
    let store = JSONPolicyStore(fileURL: url)
    #expect(store.userPatches[.app(bundleID: "a")]?.appCategory == "Chats")
    #expect(!store.hasRun(CategoryMigration.id))
}

@Test func lengthAndStartLayerLikeOtherSettings() {
    let user: [PolicyKey: AppPolicyPatch] = [
        .category(name: "Chats"): patch { $0.length = .short; $0.minWordsBeforeSuggesting = 3 },
        .app(bundleID: "chat"): patch { $0.appCategory = "Chats" },
        .app(bundleID: "chat2"): patch { $0.appCategory = "Chats"; $0.length = .long },
        .domain(pattern: "site.example"): patch { $0.minWordsBeforeSuggesting = 1 },
    ]
    let r = resolver(user)
    let a = r.resolve(bundleID: "chat", urlHost: nil).policy
    #expect(a.length == .short && a.minWordsBeforeSuggesting == 3)
    let b = r.resolve(bundleID: "chat2", urlHost: nil).policy
    #expect(b.length == .long && b.minWordsBeforeSuggesting == 3)   // own length, category's start
    let site = r.resolve(bundleID: "chat", urlHost: "site.example").policy
    #expect(site.length == .short && site.minWordsBeforeSuggesting == 1)  // browser's length, site's start
    let plain = r.resolve(bundleID: "other", urlHost: nil).policy
    #expect(plain.length == nil && plain.minWordsBeforeSuggesting == nil)  // General applies
}

@Test func inheritedLengthShowsCategoryElseGeneral() {
    var s = HunchSettings()
    s.length = .medium
    s.minWordsBeforeSuggesting = 2
    let general = InheritedPolicy(bundleID: nil, settings: s)
    #expect(general.length == .medium && general.minWordsBeforeSuggesting == 2)
    let chats = InheritedPolicy(bundleID: "x", settings: s, seeds: [:],
                                category: patch { $0.length = .short })
    #expect(chats.length == .short && chats.minWordsBeforeSuggesting == 2)
}

@Test func lengthSettingsSurviveSaving() throws {
    let p = patch { $0.length = .veryLong; $0.minWordsBeforeSuggesting = 4 }
    let back = try JSONDecoder().decode(AppPolicyPatch.self, from: JSONEncoder().encode(p))
    #expect(back == p)
    let old = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"enabled":true}"#.utf8))
    #expect(old.length == nil && old.minWordsBeforeSuggesting == nil)
}

@Suite struct CategoryOnlyTurnsOffTests {
    private func resolver(_ user: [PolicyKey: AppPolicyPatch], byDefault: Bool = true,
                          seeds: [PolicyKey: AppPolicyPatch] = [:]) -> DefaultPolicyResolver {
        DefaultPolicyResolver(completionsEnabledByDefault: byDefault, seeds: seeds, userPatches: { user },
                              automaticCategories: AutoCategories(apps: [:], sites: [:]))
    }

    @Test func categorySetToOnDoesNotReenableAnAppTurnedOffBelowIt() {
        var on = AppPolicyPatch(); on.enabled = true
        var member = AppPolicyPatch(); member.appCategory = "AI"
        var off = AppPolicyPatch(); off.enabled = false
        // Seeded off (a built-in rule), in a category set to On: stays off.
        let seeded = resolver([.category(name: "AI"): on, .app(bundleID: "a.b"): member],
                              seeds: [.app(bundleID: "a.b"): off])
        #expect(!seeded.resolve(bundleID: "a.b", urlHost: nil).policy.enabled)
        // Global default off: a category set to On doesn't turn its apps on.
        let global = resolver([.category(name: "AI"): on, .app(bundleID: "a.b"): member], byDefault: false)
        #expect(!global.resolve(bundleID: "a.b", urlHost: nil).policy.enabled)
    }

    @Test func siteCategorySetToOnDoesNotReenableAnOffBrowser() {
        var on = AppPolicyPatch(); on.enabled = true
        var browserOff = AppPolicyPatch(); browserOff.enabled = false
        var site = AppPolicyPatch(); site.appCategory = "AI"
        let r = resolver([.category(name: "AI"): on, .app(bundleID: "com.google.Chrome"): browserOff,
                          .domain(pattern: "claude.ai"): site])
        #expect(!r.resolve(bundleID: "com.google.Chrome", urlHost: "claude.ai").policy.enabled)
    }

    @Test func categoryCanStillTurnOffAndAPlaceCanStillTurnOn() {
        var off = AppPolicyPatch(); off.enabled = false
        var member = AppPolicyPatch(); member.appCategory = "Private"
        var memberOn = AppPolicyPatch(); memberOn.appCategory = "Private"; memberOn.enabled = true
        let r = resolver([.category(name: "Private"): off, .app(bundleID: "a.b"): member,
                          .app(bundleID: "c.d"): memberOn])
        #expect(!r.resolve(bundleID: "a.b", urlHost: nil).policy.enabled)
        #expect(r.resolve(bundleID: "c.d", urlHost: nil).policy.enabled)
    }
}
