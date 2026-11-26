import Foundation
import Testing
@testable import HunchCore

private typealias C = HunchURLCommand

/// Stand-in for `KnownPlacesStore.siteKey(fromInput:)` (HunchPolicy), which the app injects; the real
/// one is exercised with the parser in HunchPolicyTests/URLCommandSiteTests.swift.
private func stubSiteKey(_ raw: String) -> PolicyKey? {
    let text = raw.lowercased()
    let body = text.hasPrefix("*.") ? String(text.dropFirst(2)) : text
    guard body.contains("."), !body.hasPrefix("."), !body.hasSuffix("."),
          !body.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "*" }) else { return nil }
    return .domain(pattern: text)
}

private func parse(_ s: String) -> C.Command? {
    C.parse(URL(string: s)!, siteKey: stubSiteKey)
}

private func rejection(_ s: String) -> C.Rejection? {
    guard case .failure(let r)? = C.validate(URL(string: s)!, siteKey: stubSiteKey) else { return nil }
    return r
}

@Suite struct URLCommandTests {
    @Test func everyCommandParses() {
        #expect(parse("hunch://toggle") == .toggle)
        #expect(parse("hunch://pause?minutes=15") == .pause(minutes: 15))
        #expect(parse("hunch://toggleApp?app=com.apple.Notes&minutes=10")
                == .toggleApp(bundleID: "com.apple.Notes", minutes: 10))
        #expect(parse("hunch://toggleApp") == .toggleApp(bundleID: nil, minutes: 5))
        #expect(parse("hunch://setOverride?app=com.apple.Notes&tabAcceptEnabled=false")
                == .setOverride(.app(bundleID: "com.apple.Notes"),
                                [.init(field: .tabAcceptEnabled, value: .bool(false))]))
        #expect(parse("hunch://clearOverride?domain=*.example.com")
                == .clearOverride(.domain(pattern: "*.example.com")))
        #expect(parse("hunch://settings?pane=apps&select=com.apple.Notes")
                == .settings(.init(pane: "apps", place: .app(bundleID: "com.apple.Notes"))))
        #expect(parse("hunch://settings") == .settings(.init()))
        #expect(parse("hunch://set?autocorrect=off") == .set([.init(field: .autocorrect, value: .bool(false))]))
        #expect(parse("hunch://model?select=gemma-3-4b-it-Q4_K_M.gguf") == .model(select: "gemma-3-4b-it-Q4_K_M.gguf"))
    }

    @Test func hostAndSchemeCaseInsensitiveTrailingSlashAllowed() {
        #expect(parse("Hunch://TOGGLE/") == .toggle)
        #expect(parse("hunch://setoverride?app=a.b&enabled=on")
                == .setOverride(.app(bundleID: "a.b"), [.init(field: .enabled, value: .bool(true))]))
    }

    @Test func unknownOrForeignIsNil() {
        #expect(parse("hunch://reboot") == nil)
        #expect(rejection("hunch://reboot") == .unknownCommand)
        #expect(parse("hunch:") == nil)
        #expect(parse("https://toggle") == nil)
        #expect(C.validate(URL(string: "https://toggle")!, siteKey: stubSiteKey) == nil)
        #expect(rejection("hunch://toggle/extra") == .unexpectedPath)
    }

    @Test func percentDecoding() {
        #expect(parse("hunch://setOverride?domain=%2A.example.com&overlay=card")
                == .setOverride(.domain(pattern: "*.example.com"), [.init(field: .overlay, value: .overlay(.card))]))
        #expect(parse("hunch://model?select=sub%2Fmy%20model.gguf") == .model(select: "sub/my model.gguf"))
        #expect(parse("hunch://pause?minutes=%35") == .pause(minutes: 5))
    }

    @Test func boolAndEnumValues() {
        for (raw, value) in [("true", true), ("FALSE", false), ("1", true), ("0", false), ("on", true), ("Off", false)] {
            #expect(parse("hunch://setOverride?app=a.b&midLineEnabled=\(raw)")
                    == .setOverride(.app(bundleID: "a.b"), [.init(field: .midLineEnabled, value: .bool(value))]))
        }
        #expect(rejection("hunch://setOverride?app=a.b&midLineEnabled=yes") == .invalid("midLineEnabled"))
        #expect(rejection("hunch://setOverride?app=a.b&midLineEnabled=") == .invalid("midLineEnabled"))
        #expect(parse("hunch://setOverride?app=a.b&insertion=pastematchstyle&engineOverride=local")
                == .setOverride(.app(bundleID: "a.b"), [.init(field: .insertion, value: .insertion(.pasteMatchStyle)),
                                                        .init(field: .engineOverride, value: .engine(.local))]))
        #expect(rejection("hunch://setOverride?app=a.b&overlay=floating") == .invalid("overlay"))
        #expect(rejection("hunch://setOverride?app=a.b&insertion=true") == .invalid("insertion"))
    }

    @Test func freeTextNumbersAndUnknownFieldsRejected() {
        #expect(rejection("hunch://setOverride?app=a.b&customInstructions=be%20rude") == .notSettable("customInstructions"))
        #expect(rejection("hunch://setOverride?app=a.b&appCategory=Work") == .notSettable("appCategory"))
        #expect(rejection("hunch://setOverride?app=a.b&maxWordsOverride=3") == .notSettable("maxWordsOverride"))
        #expect(rejection("hunch://setOverride?app=a.b&injectionChunkSize=8") == .notSettable("injectionChunkSize"))
        #expect(rejection("hunch://setOverride?app=a.b&tabAcceptEnabled=false&bogus=1") == .unknownParameter("bogus"))
        #expect(rejection("hunch://setOverride?app=a.b&TabAcceptEnabled=false") == .unknownParameter("TabAcceptEnabled"))
        #expect(rejection("hunch://setOverride?app=a.b") == .noChanges)
        #expect(rejection("hunch://setOverride?app=a.b&enabled=1&enabled=0") == .duplicate("enabled"))
        #expect(rejection("hunch://toggle?x=1") == .unknownParameter("x"))
        #expect(rejection("hunch://clearOverride?app=a.b&enabled=1") == .unknownParameter("enabled"))
    }

    @Test func secureExclusionCanBeAddedNeverLifted() {
        #expect(rejection("hunch://setOverride?app=a.b&secureExcluded=false") == .secureExclusionCannotBeLifted)
        #expect(rejection("hunch://setOverride?app=a.b&secureExcluded=off") == .secureExclusionCannotBeLifted)
        #expect(parse("hunch://setOverride?app=a.b&secureExcluded=true")
                == .setOverride(.app(bundleID: "a.b"), [.init(field: .secureExcluded, value: .bool(true))]))
    }

    @Test func targetValidation() {
        #expect(rejection("hunch://setOverride?enabled=0") == .missing("app"))
        #expect(rejection("hunch://setOverride?app=a.b&domain=x.com&enabled=0") == .appAndDomain)
        #expect(rejection("hunch://setOverride?app=a.b&category=Work&enabled=0") == .appAndDomain)
        #expect(rejection("hunch://clearOverride?domain=x.com&category=Work") == .appAndDomain)
        #expect(rejection("hunch://setOverride?app=notes&enabled=0") == .invalid("app"))
        #expect(rejection("hunch://setOverride?app=com..apple&enabled=0") == .invalid("app"))
        #expect(rejection("hunch://setOverride?app=com.apple%20Notes&enabled=0") == .invalid("app"))
        #expect(rejection("hunch://setOverride?domain=localhost&enabled=0") == .invalid("domain"))
        #expect(rejection("hunch://setOverride?domain=a.com%2Fpath&enabled=0") == .invalid("domain"))
        #expect(rejection("hunch://toggleApp?app=bad%0Aid") == .invalid("app"))
        #expect(C.isBundleID("com.example." + String(repeating: "a", count: 243)))
        #expect(!C.isBundleID("com.example." + String(repeating: "a", count: 244)))
        #expect(C.isBundleID("com.microsoft.VSCode-insiders_2"))
        #expect(!C.isBundleID(".com.apple"))
    }

    @Test func minutesValidation() {
        #expect(rejection("hunch://pause") == .missing("minutes"))
        #expect(rejection("hunch://pause?minutes=0") == .invalid("minutes"))
        #expect(rejection("hunch://pause?minutes=-5") == .invalid("minutes"))
        #expect(rejection("hunch://pause?minutes=1.5") == .invalid("minutes"))
        #expect(rejection("hunch://pause?minutes=1441") == .invalid("minutes"))
        #expect(parse("hunch://pause?minutes=1440") == .pause(minutes: 1440))
    }

    @Test func settingsAndModelValidation() {
        #expect(parse("hunch://settings?select=*.example.com")
                == .settings(.init(place: .domain(pattern: "*.example.com"))))
        #expect(parse("hunch://settings?pane=Model") == .settings(.init(pane: "model")))
        #expect(rejection("hunch://settings?pane=../x") == .invalid("pane"))
        #expect(rejection("hunch://settings?pane=model&select=a.b") == .invalid("select"))
        #expect(rejection("hunch://settings?select=not%20a%20place") == .invalid("select"))
        #expect(rejection("hunch://model") == .missing("select"))
        #expect(rejection("hunch://model?select=../../etc/x.gguf") == .invalid("select"))
        #expect(rejection("hunch://model?select=%2Ftmp%2Fx.gguf") == .invalid("select"))
        #expect(rejection("hunch://model?select=") == .invalid("select"))
    }

    @Test func changesApplyToPatch() {
        guard case .setOverride(_, let changes)? =
                parse("hunch://setOverride?app=a.b&tabAcceptEnabled=0&overlay=inline&learningAllowed=off")
        else { Issue.record("no parse"); return }
        var patch = AppPolicyPatch()
        patch.customInstructions = "kept"
        for c in changes { c.apply(to: &patch) }
        #expect(patch.tabAcceptEnabled == false)
        #expect(patch.overlay == .inline)
        #expect(patch.learningAllowed == false)
        #expect(patch.customInstructions == "kept")
        #expect(changes.map(\.summary) == ["tabAcceptEnabled = false", "overlay = inline", "learningAllowed = false"])
    }

    @Test func clearKeepsCategoryAndSecureExclusion() {
        var patch = AppPolicyPatch()
        patch.enabled = false
        patch.customInstructions = "x"
        #expect(C.cleared(patch) == nil)
        #expect(C.cleared(nil) == nil)
        patch.appCategory = "Work"
        patch.secureExcluded = true
        var kept = AppPolicyPatch()
        kept.appCategory = "Work"
        kept.secureExcluded = true
        #expect(C.cleared(patch) == kept)
    }

    @Test func rejectionMessagesTruncateLongNames() {
        let long = String(repeating: "k", count: 200)
        #expect(C.Rejection.unknownParameter(long).message.count < 100)
    }
}

@Suite struct URLCommandConfirmationTests {
    @Test func turningOnAsksTurningOffDoesNot() {
        let on: (String?) -> Bool = { _ in true }
        #expect(C.turnsReadingOn(.toggle, isOn: false, appEnabled: on))
        #expect(!C.turnsReadingOn(.toggle, isOn: true, appEnabled: on))
    }

    @Test func pauseAsksOnlyWhenItWouldEndOn() {
        let on: (String?) -> Bool = { _ in true }
        #expect(!C.turnsReadingOn(.pause(minutes: 5), isOn: true, appEnabled: on))
        // Off or already paused: the pause ends with Hunch on.
        #expect(C.turnsReadingOn(.pause(minutes: 1), isOn: false, appEnabled: on))
    }

    @Test func toggleAppAsksOnlyForAnAppThatIsOff() {
        let mailOff: (String?) -> Bool = { $0 != "com.apple.mail" }
        #expect(C.turnsReadingOn(.toggleApp(bundleID: "com.apple.mail", minutes: 5), isOn: true, appEnabled: mailOff))
        #expect(!C.turnsReadingOn(.toggleApp(bundleID: "com.apple.Notes", minutes: 5), isOn: true,
                                  appEnabled: mailOff))
        // No app: the frontmost one, decided by the caller.
        #expect(C.turnsReadingOn(.toggleApp(bundleID: nil, minutes: 5), isOn: true, appEnabled: { _ in false }))
    }

    @Test func otherCommandsHaveTheirOwnHandling() {
        let off: (String?) -> Bool = { _ in false }
        #expect(!C.turnsReadingOn(.settings(.init()), isOn: false, appEnabled: off))
        #expect(!C.turnsReadingOn(.set([.init(field: .dictation, value: .bool(true))]), isOn: false, appEnabled: off))
        #expect(!C.turnsReadingOn(.model(select: "a.gguf"), isOn: false, appEnabled: off))
        #expect(!C.turnsReadingOn(.clearOverride(.app(bundleID: "com.apple.mail")), isOn: false, appEnabled: off))
    }
}

@Suite struct URLCommandNewerFieldTests {
    private func changes(_ s: String) -> [C.OverrideChange]? {
        guard case .setOverride(_, let c)? = parse(s) else { return nil }
        return c
    }

    @Test func newerSwitchesParseAndApply() {
        let names = ["autocorrectEnabled", "fixAutomaticallyAllowed", "autoCapitalizationAllowed", "fixesPunctuation",
                     "fixConfusedWordsAllowed", "leavesChatShorthand", "appliesTextReplacements",
                     "emoticonEmojiEnabled", "emojiSearchEnabled", "smartQuotesEnabled", "excludeSearchFields",
                     "nonBreakingSpaces", "spaceAsKeyEvent", "backspaceAfterPaste", "greySuggestionColorEnabled"]
        let link = "hunch://setOverride?app=a.b&" + names.map { "\($0)=on" }.joined(separator: "&")
        guard let c = changes(link) else { Issue.record("no parse"); return }
        #expect(c.map(\.field.rawValue) == names)
        var patch = AppPolicyPatch()
        for change in c { change.apply(to: &patch) }
        let values: [Bool?] = [patch.autocorrectEnabled, patch.fixAutomaticallyAllowed, patch.autoCapitalizationAllowed,
                               patch.fixesPunctuation, patch.fixConfusedWordsAllowed, patch.leavesChatShorthand,
                               patch.appliesTextReplacements, patch.emoticonEmojiEnabled, patch.emojiSearchEnabled,
                               patch.smartQuotesEnabled, patch.excludeSearchFields, patch.nonBreakingSpaces,
                               patch.spaceAsKeyEvent, patch.backspaceAfterPaste, patch.greySuggestionColorEnabled]
        #expect(values.allSatisfy { $0 == true })
    }

    @Test func newerChoicesParseAndReplaceTheOlderField() {
        guard let c = changes("hunch://setOverride?category=Work&autocorrectStrength=Strong&length=veryLong"
                              + "&shellCommandMode=never&writeShape=aiPrompt&acceptWordKey=off&acceptFullKey=shortcuts")
        else { Issue.record("no parse"); return }
        var patch = AppPolicyPatch()
        patch.maxWordsOverride = 3
        patch.shellCommandsEnabled = true
        patch.writeCustomShapeID = UUID()
        patch.tabAcceptEnabled = true
        for change in c { change.apply(to: &patch) }
        #expect(patch.autocorrectStrength == .strong)
        #expect(patch.length == .veryLong && patch.maxWordsOverride == nil)
        #expect(patch.shellCommandMode == .never && patch.shellCommandsEnabled == nil)
        #expect(patch.writeShape == .aiPrompt && patch.writeCustomShapeID == nil)
        #expect(patch.acceptWordKey == .off && patch.tabAcceptEnabled == nil)
        #expect(patch.acceptFullKey == .shortcuts)
        #expect(c.map(\.summary) == ["autocorrectStrength = strong", "length = veryLong", "shellCommandMode = never",
                                     "writeShape = aiPrompt", "acceptWordKey = off", "acceptFullKey = shortcuts"])
    }

    @Test func badChoicesRejected() {
        #expect(rejection("hunch://setOverride?app=a.b&writeShape=paragraph") == .invalid("writeShape"))
        #expect(rejection("hunch://setOverride?app=a.b&length=huge") == .invalid("length"))
        #expect(rejection("hunch://setOverride?app=a.b&acceptWordKey=cmd-k") == .invalid("acceptWordKey"))
        #expect(rejection("hunch://setOverride?app=a.b&autocorrectStrength=on") == .invalid("autocorrectStrength"))
        #expect(rejection("hunch://setOverride?app=a.b&autocorrectEnabled=strong") == .invalid("autocorrectEnabled"))
        #expect(rejection("hunch://setOverride?app=a.b&fontSizeAdjustmentFactor=2") == .notSettable("fontSizeAdjustmentFactor"))
        #expect(rejection("hunch://setOverride?app=a.b&minWordsBeforeSuggesting=2") == .notSettable("minWordsBeforeSuggesting"))
    }

    @Test func defaultResetsOneField() {
        guard let c = changes("hunch://setOverride?app=a.b&length=default&autocorrectEnabled=Default&acceptWordKey=default")
        else { Issue.record("no parse"); return }
        var patch = AppPolicyPatch()
        patch.length = .short
        patch.maxWordsOverride = 2
        patch.autocorrectEnabled = false
        patch.acceptWordKey = .off
        patch.tabAcceptEnabled = false
        patch.midLineEnabled = false
        for change in c { change.apply(to: &patch) }
        #expect(patch.length == nil && patch.maxWordsOverride == nil)
        #expect(patch.autocorrectEnabled == nil)
        #expect(patch.acceptWordKey == nil && patch.tabAcceptEnabled == nil)
        #expect(patch.midLineEnabled == false)
        #expect(c.map(\.summary) == ["length = Default", "autocorrectEnabled = Default", "acceptWordKey = Default"])
        #expect(rejection("hunch://setOverride?app=a.b&secureExcluded=default") == .secureExclusionCannotBeLifted)
    }

    @Test func categoryTarget() {
        #expect(parse("hunch://setOverride?category=%20Work%20&midLineEnabled=0")
                == .setOverride(.category(name: "Work"), [.init(field: .midLineEnabled, value: .bool(false))]))
        #expect(parse("hunch://clearOverride?category=Work") == .clearOverride(.category(name: "Work")))
        #expect(rejection("hunch://clearOverride?category=%20") == .invalid("category"))
        #expect(rejection("hunch://clearOverride?category=a%0Ab") == .invalid("category"))
        #expect(rejection("hunch://clearOverride?category=" + String(repeating: "w", count: 65)) == .invalid("category"))
    }
}

@Suite struct URLCommandSettingsLinkTests {
    @Test func searchAndJump() {
        #expect(parse("hunch://settings?pane=apps&search=insertion")
                == .settings(.init(pane: "apps", search: "insertion")))
        #expect(parse("hunch://settings?search=%20smart%20quotes%20") == .settings(.init(search: "smart quotes")))
        #expect(parse("hunch://settings?search=%E6%A8%99%E9%BB%9E") == .settings(.init(search: "標點")))
        #expect(parse("hunch://settings?setting=general.length") == .settings(.init(setting: "general.length")))
        #expect(parse("hunch://settings?pane=general&setting=general.length")
                == .settings(.init(pane: "general", setting: "general.length")))
        #expect(parse("hunch://settings?select=com.apple.Notes&setting=apps.insertion")
                == .settings(.init(place: .app(bundleID: "com.apple.Notes"), setting: "apps.insertion")))
        #expect(parse("hunch://settings?category=Work&setting=apps.length")
                == .settings(.init(place: .category(name: "Work"), setting: "apps.length")))
    }

    @Test func resolvedPane() {
        #expect(C.SettingsRequest(pane: "general", setting: "autocorrect.strength").resolvedPane == "autocorrect")
        #expect(C.SettingsRequest(place: .category(name: "Work")).resolvedPane == "apps")
        #expect(C.SettingsRequest(pane: "model").resolvedPane == "model")
        #expect(C.SettingsRequest().resolvedPane == nil)
    }

    @Test func badSettingsLinksRejected() {
        #expect(rejection("hunch://settings?setting=general") == .invalid("setting"))
        #expect(rejection("hunch://settings?setting=General.length") == .invalid("setting"))
        #expect(rejection("hunch://settings?setting=general.length.x") == .invalid("setting"))
        #expect(rejection("hunch://settings?setting=general.a-b") == .invalid("setting"))
        #expect(rejection("hunch://settings?pane=model&setting=general.length") == .conflicting("pane", "setting"))
        #expect(rejection("hunch://settings?setting=apps.insertion") == .missing("select"))
        #expect(rejection("hunch://settings?select=a.b&setting=general.length") == .invalid("select"))
        #expect(rejection("hunch://settings?category=Work&pane=model") == .invalid("category"))
        #expect(rejection("hunch://settings?select=a.b&category=Work") == .conflicting("select", "category"))
        #expect(rejection("hunch://settings?search=") == .invalid("search"))
        #expect(rejection("hunch://settings?search=%20%20") == .invalid("search"))
        #expect(rejection("hunch://settings?search=a%0Ab") == .invalid("search"))
        #expect(rejection("hunch://settings?search=" + String(repeating: "q", count: 101)) == .invalid("search"))
        #expect(parse("hunch://settings?search=" + String(repeating: "q", count: 100)) != nil)
        #expect(rejection("hunch://settings?setting=general.length&search=x") == .conflicting("setting", "search"))
        #expect(rejection("hunch://settings?query=x") == .unknownParameter("query"))
    }
}

@Suite struct URLCommandGlobalSetTests {
    @Test func parsesInLinkOrder() {
        #expect(parse("hunch://set?dictation=on&autocorrect=0&autocorrectStrength=Balanced&suggestions=off")
                == .set([.init(field: .dictation, value: .bool(true)), .init(field: .autocorrect, value: .bool(false)),
                         .init(field: .autocorrectStrength, value: .strength(.balanced)),
                         .init(field: .suggestions, value: .bool(false))]))
    }

    @Test func rejects() {
        #expect(rejection("hunch://set") == .noChanges)
        #expect(rejection("hunch://set?autocorrect=maybe") == .invalid("autocorrect"))
        #expect(rejection("hunch://set?autocorrectStrength=on") == .invalid("autocorrectStrength"))
        #expect(rejection("hunch://set?autocorrect=default") == .invalid("autocorrect"))
        #expect(rejection("hunch://set?emoji=on") == .unknownParameter("emoji"))
        #expect(rejection("hunch://set?dictation=on&dictation=off") == .duplicate("dictation"))
    }

    @Test func turningOffRunsTurningOnOrStrengthAsks() {
        let current: (C.GlobalField) -> C.OverrideValue = {
            switch $0 {
            case .suggestions: .bool(true)
            case .autocorrect: .bool(true)
            case .dictation: .bool(false)
            case .autocorrectStrength: .strength(.balanced)
            }
        }
        func asks(_ link: String) -> Bool {
            guard case .set(let c)? = parse(link) else { return false }
            return C.setAsks(c, current: current)
        }
        #expect(!asks("hunch://set?autocorrect=off&suggestions=off"))
        #expect(!asks("hunch://set?dictation=off"))            // already off
        #expect(!asks("hunch://set?autocorrect=on"))           // already on: nothing turns on
        #expect(!asks("hunch://set?autocorrectStrength=balanced"))
        #expect(asks("hunch://set?dictation=on"))
        #expect(asks("hunch://set?autocorrect=off&dictation=on"))
        #expect(asks("hunch://set?autocorrectStrength=strong"))
        guard case .set(let c)? = parse("hunch://set?dictation=on&autocorrectStrength=light") else { return }
        #expect(c.map(\.summary) == ["dictation = on", "autocorrectStrength = light"])
    }
}
