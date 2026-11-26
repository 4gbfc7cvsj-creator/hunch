import Foundation
import Testing
import HunchCore
@testable import HunchPolicy

private func patch(_ f: (inout AppPolicyPatch) -> Void) -> AppPolicyPatch { var p = AppPolicyPatch(); f(&p); return p }

@Suite struct ResolverTests {
    @Test func baseUsesDefaultFlag() {
        #expect(DefaultPolicyResolver(completionsEnabledByDefault: false).resolve(bundleID: "a.b", urlHost: nil).policy.enabled == false)
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true).resolve(bundleID: "a.b", urlHost: nil)
        #expect(r.policy.enabled && r.sources.isEmpty)
    }

    @Test func seedApplies() {
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true)
        let pm = r.resolve(bundleID: "com.1password.1password", urlHost: nil)
        #expect(pm.policy.secureExcluded && !pm.policy.enabled && pm.sources == [.app(bundleID: "com.1password.1password")])
        #expect(r.resolve(bundleID: "com.apple.Terminal", urlHost: nil).policy.enabled)
        #expect(!r.resolve(bundleID: "com.microsoft.VSCode", urlHost: nil).policy.enabled)
        #expect(r.resolve(bundleID: "com.tinyspeck.slackmacgap", urlHost: nil).policy.wakeChromiumAX)
        #expect(r.resolve(bundleID: "com.apple.mail", urlHost: nil).policy.acceptWordKey == .shortcuts)
        #expect(r.resolve(bundleID: "com.apple.iCal", urlHost: nil).policy.estimatedGeometryOnly)
        #expect(r.resolve(bundleID: "com.apple.systempreferences", urlHost: nil).policy.estimatedGeometryOnly)
        #expect(!r.resolve(bundleID: "com.apple.TextEdit", urlHost: nil).policy.estimatedGeometryOnly)
    }

    @Test func layering() {
        let id = "com.microsoft.VSCode"
        let user: [PolicyKey: AppPolicyPatch] = [
            .app(bundleID: id): patch { $0.enabled = true; $0.maxWordsOverride = 4 },
            .domain(pattern: "example.com"): patch { $0.maxWordsOverride = 9 },
        ]
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { user })
        let a = r.resolve(bundleID: id, urlHost: nil)
        #expect(a.policy.enabled && a.policy.maxWordsOverride == 4)
        let b = r.resolve(bundleID: id, urlHost: "www.Example.com")
        #expect(b.policy.maxWordsOverride == 9 && b.policy.enabled)
        #expect(b.sources == [.app(bundleID: id), .domain(pattern: "example.com")])
    }

    @Test func domainMatching() {
        let p = patch { $0.enabled = false }
        func m(_ host: String, _ patterns: [String]) -> PolicyKey? {
            var d: [PolicyKey: AppPolicyPatch] = [:]
            for s in patterns { d[.domain(pattern: s)] = p }
            return DefaultPolicyResolver.bestDomainMatch(host: host, in: d)?.0
        }
        #expect(m("example.com", ["example.com"]) == .domain(pattern: "example.com"))
        #expect(m("www.example.com", ["example.com"]) == .domain(pattern: "example.com"))
        #expect(m("mail.example.com", ["example.com"]) == nil)
        #expect(m("mail.example.com", ["*.example.com"]) == .domain(pattern: "*.example.com"))
        #expect(m("example.com", ["*.example.com"]) == nil)
        #expect(m("badexample.com", ["*.example.com"]) == nil)
        #expect(m("a.b.example.com", ["*.example.com", "*.b.example.com"]) == .domain(pattern: "*.b.example.com"))
        #expect(m("mail.example.com", ["*.example.com", "mail.example.com"]) == .domain(pattern: "mail.example.com"))
        #expect(m("EXAMPLE.COM", ["Example.com"]) != nil)
    }

    @Test func temporaryOverrideExpires() {
        let clock = Mutex(Date(timeIntervalSince1970: 1000))
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, now: { clock.withLock { $0 } })
        r.setTemporaryOverride(bundleID: "a.b", enabled: false, until: Date(timeIntervalSince1970: 1100))
        #expect(!r.resolve(bundleID: "a.b", urlHost: nil).policy.enabled)
        #expect(r.resolve(bundleID: "c.d", urlHost: nil).policy.enabled)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1100) }
        #expect(r.resolve(bundleID: "a.b", urlHost: nil).policy.enabled)
        r.setTemporaryOverride(bundleID: "a.b", enabled: false, until: Date(timeIntervalSince1970: 2000))
        r.clearTemporaryOverride(bundleID: "a.b")
        #expect(r.resolve(bundleID: "a.b", urlHost: nil).policy.enabled)
    }

    @Test func renderingTweaksLayer() {
        let user: [PolicyKey: AppPolicyPatch] = [
            .app(bundleID: "a.b"): patch {
                $0.fontSizeAdjustmentFactor = 1.2; $0.verticalAlignmentOffset = 2; $0.greySuggestionColorEnabled = true
            },
            .domain(pattern: "example.com"): patch { $0.verticalAlignmentOffset = -1.5 },
        ]
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { user })
        let a = r.resolve(bundleID: "a.b", urlHost: nil).policy
        #expect(a.fontSizeAdjustmentFactor == 1.2 && a.verticalAlignmentOffset == 2 && a.greySuggestionColorEnabled)
        let site = r.resolve(bundleID: "a.b", urlHost: "example.com").policy
        #expect(site.fontSizeAdjustmentFactor == 1.2 && site.verticalAlignmentOffset == -1.5 && site.greySuggestionColorEnabled)
    }

    @Test func renderingTweaksDefaultWithoutPatch() {
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true,
                                      userPatches: { [.app(bundleID: "a.b"): patch { $0.maxWordsOverride = 3 }] })
        for id in ["a.b", "c.d", "com.apple.mail"] {
            let p = r.resolve(bundleID: id, urlHost: nil).policy
            #expect(p.fontSizeAdjustmentFactor == 1 && p.verticalAlignmentOffset == 0 && !p.greySuggestionColorEnabled)
        }
    }

    @Test func featureTogglesLayer() {
        let id = "com.apple.Notes"
        let user: [PolicyKey: AppPolicyPatch] = [
            .app(bundleID: id): patch {
                $0.autocorrectEnabled = false; $0.emoticonEmojiEnabled = false; $0.smartQuotesEnabled = false
                $0.excludeSearchFields = true
            },
            .domain(pattern: "example.com"): patch { $0.autocorrectEnabled = true; $0.emojiSearchEnabled = false },
        ]
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { user })
        // Base: the general settings (autocorrect and emoji on), smart quotes on, search fields allowed.
        let base = r.resolve(bundleID: "other.app", urlHost: nil).policy
        #expect(base.autocorrectEnabled && base.emoticonEmojiEnabled && base.emojiSearchEnabled)
        #expect(base.smartQuotesEnabled && !base.excludeSearchFields)
        let app = r.resolve(bundleID: id, urlHost: nil).policy
        #expect(!app.autocorrectEnabled && !app.emoticonEmojiEnabled && app.emojiSearchEnabled)
        #expect(!app.smartQuotesEnabled && app.excludeSearchFields)
        // The domain patch wins over the app patch only for the fields it sets.
        let site = r.resolve(bundleID: id, urlHost: "example.com").policy
        #expect(site.autocorrectEnabled && !site.emoticonEmojiEnabled && !site.emojiSearchEnabled)
        #expect(!site.smartQuotesEnabled && site.excludeSearchFields)
    }

    @Test func shellCommandModeIsAutomaticUnlessChosen() throws {
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: {
            [.app(bundleID: "com.googlecode.iterm2"): patch { $0.shellCommandsEnabled = true },
             .app(bundleID: "com.mitchellh.ghostty"): patch { $0.shellCommandsEnabled = false },
             .app(bundleID: "com.cmuxterm.app"): patch { $0.shellCommandsEnabled = true; $0.shellCommandMode = .automatic }]
        })
        func mode(_ id: String) -> ShellCommandMode { r.resolve(bundleID: id, urlHost: nil).policy.shellCommandMode }
        #expect(mode("com.apple.Terminal") == .automatic)
        // The older On/Off switch keeps its meaning; the new mode wins when both are saved.
        #expect(mode("com.googlecode.iterm2") == .always)
        #expect(mode("com.mitchellh.ghostty") == .never)
        #expect(mode("com.cmuxterm.app") == .automatic)
        #expect(Seeds.table.values.allSatisfy { $0.layerShellCommandMode == nil })
        let old = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"shellCommandsEnabled":true}"#.utf8))
        #expect(old.layerShellCommandMode == .always)
        let new = patch { $0.shellCommandMode = .never }
        #expect(try JSONDecoder().decode(AppPolicyPatch.self, from: JSONEncoder().encode(new)) == new)
        #expect(InheritedPolicy(bundleID: "com.apple.Terminal", settings: HunchSettings()).shellCommandMode == .automatic)
    }

    @Test func featureTogglesDefaultToTheGeneralSettings() {
        let user: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "a.b"): patch { $0.autocorrectEnabled = true }]
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { user })
        r.setAutocorrectByDefault(false)
        r.setEmojiByDefault(false)
        let p = r.resolve(bundleID: "c.d", urlHost: nil).policy
        #expect(!p.autocorrectEnabled && !p.emoticonEmojiEnabled && !p.emojiSearchEnabled)
        // An explicit per-app choice overrides the general setting either way.
        #expect(r.resolve(bundleID: "a.b", urlHost: nil).policy.autocorrectEnabled)
        r.setAutocorrectByDefault(true)
        r.setEmojiByDefault(true)
        let q = r.resolve(bundleID: "c.d", urlHost: nil).policy
        #expect(q.autocorrectEnabled && q.emoticonEmojiEnabled && q.emojiSearchEnabled)
    }

    @Test func insertionWorkaroundsLayer() {
        let id = "com.example.editor"
        let user: [PolicyKey: AppPolicyPatch] = [
            .app(bundleID: id): patch { $0.nonBreakingSpaces = true; $0.backspaceAfterPaste = true },
            .domain(pattern: "example.com"): patch { $0.backspaceAfterPaste = false; $0.spaceAsKeyEvent = true },
        ]
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { user })
        #expect(r.resolve(bundleID: "other.app", urlHost: nil).policy.insertionWorkarounds == InsertionWorkarounds())
        #expect(r.resolve(bundleID: id, urlHost: nil).policy.insertionWorkarounds
                == InsertionWorkarounds(nonBreakingSpaces: true, backspaceAfterPaste: true))
        // The site keeps what it doesn't set and overrides the rest.
        #expect(r.resolve(bundleID: id, urlHost: "example.com").policy.insertionWorkarounds
                == InsertionWorkarounds(nonBreakingSpaces: true, spaceAsKeyEvent: true, backspaceAfterPaste: false))
        // No built-in rule turns a workaround on.
        #expect(Seeds.table.values.allSatisfy {
            $0.nonBreakingSpaces == nil && $0.spaceAsKeyEvent == nil && $0.backspaceAfterPaste == nil })
    }

    @Test func codeEditorsAreOffWithTabLeftToTheEditor() {
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true)
        for id in Seeds.codeEditors {
            let p = r.resolve(bundleID: id, urlHost: nil).policy
            #expect(!p.enabled && p.acceptWordKey == .chord(.rightArrow) && p.acceptFullKey == .shortcuts,
                    Comment(rawValue: id))
        }
        // Switching an editor on keeps Right arrow for the next word unless the user also changes that.
        let user: [PolicyKey: AppPolicyPatch] = [.app(bundleID: "com.todesktop.230313mzl4w4u92"): patch { $0.enabled = true }]
        let on = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { user })
            .resolve(bundleID: "com.todesktop.230313mzl4w4u92", urlHost: nil).policy
        #expect(on.enabled && on.acceptWordKey == .chord(.rightArrow))
    }

    @Test func olderTabSwitchMapsToAcceptKeys() {
        let editor = "com.microsoft.VSCode"
        func resolve(_ p: AppPolicyPatch, _ id: String = "com.apple.Notes") -> AppPolicy {
            DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { [.app(bundleID: id): p] })
                .resolve(bundleID: id, urlHost: nil).policy
        }
        #expect(resolve(patch { $0.tabAcceptEnabled = false }).acceptWordKey == .off)
        // On in a code editor meant Tab accepts: the Shortcuts key, not the seeded Right arrow.
        #expect(resolve(patch { $0.tabAcceptEnabled = true }, editor).acceptWordKey == .shortcuts)
        // A recorded key wins over the older switch.
        let both = patch { $0.tabAcceptEnabled = false; $0.acceptWordKey = .chord(.controlTab) }
        #expect(resolve(both).acceptWordKey == .chord(.controlTab))
        #expect(resolve(patch { $0.acceptFullKey = .off }).acceptFullKey == .off)
        #expect(resolve(AppPolicyPatch()).acceptWordKey == .shortcuts)
    }

    @Test func acceptKeysSurviveSaving() throws {
        let p = patch { $0.acceptWordKey = .chord(.optionRight); $0.acceptFullKey = .off }
        let back = try JSONDecoder().decode(AppPolicyPatch.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        // Files from before these keys still decode.
        let old = try JSONDecoder().decode(AppPolicyPatch.self, from: Data(#"{"tabAcceptEnabled":false}"#.utf8))
        #expect(old.layerAcceptWordKey == AcceptKey.off && old.acceptFullKey == nil)
    }

    @Test func seedCounts() {
        // Terminals have no seed patch: they stay enabled and HunchFocus limits them to agent prompts.
        #expect(Seeds.table.count == Seeds.passwordManagers.count + Seeds.codeEditors.count
                + Seeds.chromiumHosts.count + Seeds.mail.count + Seeds.estimatedGeometryHosts.count)
    }
}

import Synchronization

@Suite struct StoreTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/policy.json")
        let store = JSONPolicyStore(fileURL: url)
        #expect(store.userPatches.isEmpty)
        let a = patch { $0.enabled = false; $0.customInstructions = "formal"; $0.insertion = .paste }
        try store.setPatch(a, for: .app(bundleID: "a.b"))
        try store.setPatch(patch { $0.maxWordsOverride = 3 }, for: .domain(pattern: "*.x.com"))
        let reloaded = JSONPolicyStore(fileURL: url)
        #expect(reloaded.userPatches == store.userPatches)
        #expect(reloaded.userPatches[.app(bundleID: "a.b")] == a)
        try reloaded.setPatch(nil, for: .app(bundleID: "a.b"))
        #expect(JSONPolicyStore(fileURL: url).userPatches.count == 1)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("schemaVersion"))
    }

    @Test func renderingTweaksRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = patch { $0.fontSizeAdjustmentFactor = 1.25; $0.verticalAlignmentOffset = -2.5; $0.greySuggestionColorEnabled = false }
        try JSONPolicyStore(fileURL: url).setPatch(a, for: .app(bundleID: "a.b"))
        #expect(JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")] == a)
    }

    @Test func fileWithoutTweaksStillDecodes() throws {
        // Written by the version before rendering tweaks existed.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = """
        {"schemaVersion":1,"entries":[{"key":{"app":{"bundleID":"a.b"}},"patch":{"enabled":false,"maxWordsOverride":3}}]}
        """
        try Data(old.utf8).write(to: url)
        let p = try #require(JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")])
        #expect(p.enabled == false && p.maxWordsOverride == 3)
        #expect(p.fontSizeAdjustmentFactor == nil && p.verticalAlignmentOffset == nil && p.greySuggestionColorEnabled == nil)
    }

    @Test func featureTogglesRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = patch {
            $0.autocorrectEnabled = false; $0.emoticonEmojiEnabled = true; $0.emojiSearchEnabled = false
            $0.smartQuotesEnabled = false; $0.excludeSearchFields = true
        }
        try JSONPolicyStore(fileURL: url).setPatch(a, for: .app(bundleID: "a.b"))
        #expect(JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")] == a)
        let decoded = try JSONDecoder().decode(AppPolicyPatch.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
    }

    @Test func fileFromPreviousVersionLoads() throws {
        // Written before the feature toggles existed: no new keys, all of them stay nil.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = """
        {
          "entries" : [
            {
              "key" : { "app" : { "bundleID" : "a.b" } },
              "patch" : { "enabled" : false, "insertion" : "paste", "learningAllowed" : false }
            }
          ],
          "schemaVersion" : 1
        }
        """
        try Data(old.utf8).write(to: url)
        let loaded = try #require(JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")])
        #expect(loaded == patch { $0.enabled = false; $0.insertion = .paste; $0.learningAllowed = false })
        #expect(loaded.autocorrectEnabled == nil && loaded.emoticonEmojiEnabled == nil && loaded.emojiSearchEnabled == nil)
        #expect(loaded.smartQuotesEnabled == nil && loaded.excludeSearchFields == nil)
    }

    @Test func insertionWorkaroundsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = patch { $0.nonBreakingSpaces = true; $0.spaceAsKeyEvent = false; $0.backspaceAfterPaste = true }
        try JSONPolicyStore(fileURL: url).setPatch(p, for: .app(bundleID: "a.b"))
        let reloaded = JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")]
        #expect(reloaded == p)
        #expect(reloaded?.spaceAsKeyEvent == false)
    }

    @Test func fileWithoutWorkaroundsStillDecodes() throws {
        // Written by the version before insertion workarounds existed.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = #"""
        {"entries":[{"key":{"app":{"bundleID":"a.b"}},"patch":{"enabled":false,"insertion":"paste"}}],"schemaVersion":1}
        """#
        try Data(old.utf8).write(to: url)
        let loaded = JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")]
        #expect(loaded == patch { $0.enabled = false; $0.insertion = .paste })
        #expect(loaded?.nonBreakingSpaces == nil && loaded?.spaceAsKeyEvent == nil && loaded?.backspaceAfterPaste == nil)
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true, userPatches: { [.app(bundleID: "a.b"): loaded!] })
        #expect(r.resolve(bundleID: "a.b", urlHost: nil).policy.insertionWorkarounds == InsertionWorkarounds())
    }

    @Test func overlayFileWrittenBeforeMirrorStillDecodes() throws {
        // app-policies.json from before `mirror` existed: its overlay choices load unchanged.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = """
        {"schemaVersion":1,"entries":[{"key":{"app":{"bundleID":"a.b"}},"patch":{"overlay":"card"}},\
        {"key":{"domain":{"pattern":"example.com"}},"patch":{"overlay":"inline","enabled":true}}]}
        """
        try Data(old.utf8).write(to: url)
        let patches = JSONPolicyStore(fileURL: url).userPatches
        #expect(patches[.app(bundleID: "a.b")]?.overlay == .card)
        #expect(patches[.domain(pattern: "example.com")]?.overlay == .inline)
    }

    @Test func mirrorPreferenceRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONPolicyStore(fileURL: url).setPatch(patch { $0.overlay = .mirror }, for: .app(bundleID: "a.b"))
        #expect(JSONPolicyStore(fileURL: url).userPatches[.app(bundleID: "a.b")]?.overlay == .mirror)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"mirror\""))
        // Resolved per app only: other apps keep the automatic choice.
        let r = DefaultPolicyResolver(completionsEnabledByDefault: true,
                                      userPatches: { [.app(bundleID: "a.b"): patch { $0.overlay = .mirror }] })
        #expect(r.resolve(bundleID: "a.b", urlHost: nil).policy.overlay == .mirror)
        #expect(r.resolve(bundleID: "c.d", urlHost: nil).policy.overlay == .automatic)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("nope".utf8).write(to: url)
        #expect(JSONPolicyStore(fileURL: url).userPatches.isEmpty)
    }
}

@Suite struct CodeSurfaceRulesTests {
    @Test func codeBuffersNeverLearn() {
        let allowed = AppPolicy(learningAllowed: true)
        let denied = AppPolicy(learningAllowed: false)
        #expect(CodeSurfaceRules.learningAllowed(policy: allowed, surface: .email))
        #expect(CodeSurfaceRules.learningAllowed(policy: allowed, surface: .unknown))
        #expect(!CodeSurfaceRules.learningAllowed(policy: allowed, surface: .code))
        #expect(!CodeSurfaceRules.learningAllowed(policy: denied, surface: .email))
        #expect(!CodeSurfaceRules.learningAllowed(policy: denied, surface: .code))
    }

    @Test func codeBuffersGetNoAutocorrectOrEmojiGhosts() {
        for surface in SurfaceKind.allCases {
            #expect(CodeSurfaceRules.replacementsAllowed(surface: surface) == (surface != .code), "\(surface)")
        }
    }
}

@Suite struct LocalModelWantedTests {
    @Test func localGlobalAlwaysWants() {
        #expect(EngineSelection.localModelWanted(globalEngine: .local, endpointConfigured: true, anyLocalOverride: false))
        #expect(EngineSelection.localModelWanted(globalEngine: .local, endpointConfigured: false, anyLocalOverride: false))
    }

    @Test func endpointWithoutConfigFallsBackToLocal() {
        #expect(EngineSelection.localModelWanted(globalEngine: .endpoint, endpointConfigured: false, anyLocalOverride: false))
    }

    @Test func endpointDefersUnlessAnOverrideWantsLocal() {
        #expect(!EngineSelection.localModelWanted(globalEngine: .endpoint, endpointConfigured: true, anyLocalOverride: false))
        #expect(EngineSelection.localModelWanted(globalEngine: .endpoint, endpointConfigured: true, anyLocalOverride: true))
    }
}

@Suite struct StoreRecoveryTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString)")
    }

    private func backups(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains(".unreadable-") }
    }

    @Test func oneUnreadableEntryKeepsTheOthersAndBacksUpTheFile() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app-policies.json")
        // The second entry has a value from a newer build (an insertion mode this build doesn't know).
        let file = """
        {"schemaVersion":1,"entries":[
          {"key":{"app":{"bundleID":"a.b"}},"patch":{"enabled":false}},
          {"key":{"app":{"bundleID":"c.d"}},"patch":{"insertion":"telepathy"}},
          {"key":{"domain":{"pattern":"x.com"}},"patch":{"customInstructions":"short"}}],
         "categories":[{"name":"Work","patch":{"overlay":"hologram"}},{"name":"AI","patch":{"enabled":true}}],
         "migrations":["categorySettings1"]}
        """
        try Data(file.utf8).write(to: url)
        let store = JSONPolicyStore(fileURL: url)
        #expect(store.userPatches[.app(bundleID: "a.b")]?.enabled == false)
        #expect(store.userPatches[.domain(pattern: "x.com")]?.customInstructions == "short")
        #expect(store.userPatches[.category(name: "AI")]?.enabled == true)
        #expect(store.userPatches.count == 3)
        #expect(store.hasRun("categorySettings1"))
        let saved = try #require(backups(in: dir).first)
        #expect(try String(contentsOf: saved, encoding: .utf8) == file)
    }

    @Test func unreadableFileIsBackedUpBeforeTheNextWrite() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app-policies.json")
        try Data("{not json".utf8).write(to: url)
        let store = JSONPolicyStore(fileURL: url)
        #expect(store.userPatches.isEmpty)
        try store.setPatch(patch { $0.enabled = false }, for: .app(bundleID: "a.b"))
        #expect(backups(in: dir).count == 1)
    }

    @Test func newerSchemaIsBackedUp() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app-policies.json")
        try Data(#"{"schemaVersion":99,"entries":[]}"#.utf8).write(to: url)
        #expect(JSONPolicyStore(fileURL: url).userPatches.isEmpty)
        #expect(backups(in: dir).count == 1)
    }

    @Test func readableFileMakesNoBackup() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app-policies.json")
        try JSONPolicyStore(fileURL: url).setPatch(patch { $0.enabled = false }, for: .app(bundleID: "a.b"))
        #expect(JSONPolicyStore(fileURL: url).userPatches.count == 1)
        #expect(backups(in: dir).isEmpty)
    }
}
