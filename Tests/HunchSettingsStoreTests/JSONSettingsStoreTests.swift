import Foundation
import Testing
import HunchCore
@testable import HunchSettingsStore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-settings-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("settings.json")
}

@Suite struct JSONSettingsStoreTests {
    @Test func missingFileGivesFreshDefaults() {
        var fresh = HunchSettings()
        fresh.modelsFolderPath = "/x"
        let store = JSONSettingsStore(fileURL: tempURL(), freshDefaults: fresh)
        #expect(store.current() == fresh)
    }

    @Test func roundTripsAcrossInstances() throws {
        let url = tempURL()
        let a = JSONSettingsStore(fileURL: url)
        try a.update {
            $0.length = .long
            $0.customInstructions = "I write English and 中文."
            $0.bindings.toggleGlobal = KeyChord(keyCode: 40, modifiers: 0x80000)
            $0.wordUnits.includeTrailingSpace = true
        }
        let b = JSONSettingsStore(fileURL: url)
        #expect(b.current() == a.current())
        #expect(b.current().length == .long)
    }

    @Test func m1FileWithoutVersionLoads() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var s = HunchSettings()
        s.enabled = false
        s.debugLogging = true
        try JSONEncoder().encode(s).write(to: url)
        #expect(JSONSettingsStore(fileURL: url).current() == s)
    }

    @Test func missingKeysUseDefaults() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"enabled": false, "length": "ultra", "bindings": {"word": {"keyCode": 49, "modifiers": 0}}}"#.utf8).write(to: url)
        let c = JSONSettingsStore(fileURL: url).current()
        #expect(c.enabled == false)
        #expect(c.length == .ultra)
        #expect(c.bindings.word == KeyChord(keyCode: 49))
        #expect(c.bindings.full == .optionTab)
        #expect(c.escapeBehavior == HunchSettings().escapeBehavior)
    }

    @Test func oldPauseKeyMovesOffWriteForMeChord() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"bindings": {"toggleCurrentApp": {"keyCode": 48, "modifiers": 655360}, "word": {"keyCode": 48, "modifiers": 0}}}"#.utf8).write(to: url)
        let c = JSONSettingsStore(fileURL: url).current()
        #expect(c.bindings.toggleCurrentApp == nil)
        #expect(c.bindings.writeForMe == .optionShiftTab)
    }

    @Test func customPauseKeyIsKept() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"bindings": {"toggleCurrentApp": {"keyCode": 35, "modifiers": 262144}}}"#.utf8).write(to: url)
        let c = JSONSettingsStore(fileURL: url).current()
        #expect(c.bindings.toggleCurrentApp == KeyChord(keyCode: 35, modifiers: 262144))
        #expect(c.bindings.writeForMe == .optionShiftTab)
    }

    @Test func clearedKeysStayClearedAcrossReload() throws {
        let url = tempURL()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.bindings.forceActivate = nil; $0.bindings.writeForMe = nil }
        let reloaded = JSONSettingsStore(fileURL: url).current()
        #expect(reloaded.bindings.forceActivate == nil)
        #expect(reloaded.bindings.writeForMe == nil)
        #expect(reloaded.bindings.toggleCurrentApp == nil)
    }

    @Test func pauseKeyOnOldChordIsKeptOnceWriteKeyIsSaved() throws {
        // The user put the pause back on Shift+Option+Tab after recording another write key.
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"bindings": {"toggleCurrentApp": {"keyCode": 48, "modifiers": 655360}, "writeForMe": {"keyCode": 36, "modifiers": 262144}}}"#.utf8).write(to: url)
        let c = JSONSettingsStore(fileURL: url).current()
        #expect(c.bindings.toggleCurrentApp == .optionShiftTab)
        #expect(c.bindings.writeForMe == KeyChord(keyCode: 36, modifiers: 262144))
    }

    @Test func badValueFallsBackPerKey() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"length": "enormous", "debugLogging": true}"#.utf8).write(to: url)
        let c = JSONSettingsStore(fileURL: url).current()
        #expect(c.length == HunchSettings().length)
        #expect(c.debugLogging == true)
    }

    @Test func garbageAndNewerSchemaFallBack() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(JSONSettingsStore(fileURL: url).current() == HunchSettings())
        try Data(#"{"schemaVersion": 99, "enabled": false}"#.utf8).write(to: url)
        #expect(JSONSettingsStore(fileURL: url).current().enabled == true)
    }

    @Test func writtenFileCarriesSchemaVersion() throws {
        let url = tempURL()
        let store = JSONSettingsStore(fileURL: url)
        try store.update { $0.enabled = false }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["schemaVersion"] as? Int == JSONSettingsStore.schemaVersion)
    }

    @Test func changesYieldsCurrentThenUpdates() async throws {
        let store = JSONSettingsStore(fileURL: tempURL())
        var it = store.changes().makeAsyncIterator()
        #expect(await it.next()?.length == HunchSettings().length)
        try store.update { $0.length = .short }
        #expect(await it.next()?.length == .short)
    }

    @Test func concurrentUpdatesAreAllApplied() async throws {
        let store = JSONSettingsStore(fileURL: tempURL())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { try? store.update { $0.framerOverrides["m\(i)"] = "f" } }
            }
        }
        #expect(store.current().framerOverrides.count == 50)
    }
}

@Test func olderFileGetsDefaultTypingPause() {
    let old = #"{"enabled":true,"minWordsBeforeSuggesting":3}"#
    let s = JSONSettingsStore.decodeTolerant(Data(old.utf8))
    #expect(s?.suggestionPauseMs == 0)
    #expect(s?.minWordsBeforeSuggesting == 3)
}

@Test func olderFileShowsSuggestionsWhileWritten() {
    let old = #"{"enabled":true}"#
    #expect(JSONSettingsStore.decodeTolerant(Data(old.utf8))?.showWhileWriting == true)
}

@Test func olderFileWithAnEndpointKeepsWritingOnIt() throws {
    var old = HunchSettings()
    old.endpoint = EndpointConfig(baseURL: URL(string: "http://127.0.0.1:8080")!, model: "local-llm")
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    for key in ["writeEngine", "writeEndpoint", "speechEngine", "speechEndpoint"] { object.removeValue(forKey: key) }
    let s = JSONSettingsStore.decodeTolerant(try JSONSerialization.data(withJSONObject: object))
    #expect(s?.writeEngine == .endpoint)
    #expect(s?.writeEndpoint == old.endpoint)
    #expect(s?.engine == .local)
    #expect(s?.speechEngine == .local)
}

@Test func olderFileWithoutAnEndpointWritesLocally() {
    let s = JSONSettingsStore.decodeTolerant(Data(#"{"enabled":true}"#.utf8))
    #expect(s?.writeEngine == .local)
    #expect(s?.writeEndpoint == nil)
}

@Test func writingSourceIsNotMigratedTwice() {
    let file: [String: Any] = ["writeEngine": "local", "endpoint": ["model": "x"]]
    #expect(JSONSettingsStore.migrateWriteSource(file)["writeEngine"] as? String == "local")
}

@Test func olderFileGetsTheLanguageModelOnce() throws {
    // Before the Language Model: the separate writing model goes off and a switch is pending.
    let old = JSONSettingsStore.decodeTolerant(Data(#"{"schemaVersion":2,"useWritingModel":true}"#.utf8))
    #expect(old?.useWritingModel == false)
    #expect(old?.instructSwitchPending == true)
    // Once saved (switch done, toggle turned back on), the file is left as it is.
    var done = try #require(old)
    done.instructSwitchPending = false
    done.useWritingModel = true
    let back = JSONSettingsStore.decodeTolerant(try JSONSettingsStore.encode(done))
    #expect(back?.useWritingModel == true)
    #expect(back?.instructSwitchPending == false)
    // New installs: no switch, no separate writing model.
    #expect(HunchSettings().instructSwitchPending == false)
    #expect(HunchSettings().useWritingModel == false)
}

@Test func addedModelsRoundTripAndDefaultEmpty() throws {
    #expect(JSONSettingsStore.decodeTolerant(Data(#"{"enabled":true}"#.utf8))?.addedModels == [])
    var s = HunchSettings()
    s.addedModels = [AddedModel(path: "/Volumes/Other/m.gguf", use: "writing"), AddedModel(path: "sub/b.gguf", use: "autocomplete")]
    let back = JSONSettingsStore.decodeTolerant(try JSONSettingsStore.encode(s))
    #expect(back?.addedModels == s.addedModels)
    #expect(s.addedModels.map(\.isOutsideFolder) == [true, false])
}

@Test func olderFileHasNoFinishedWelcomeTour() {
    let old = #"{"schemaVersion":2,"enabled":false,"length":"long"}"#
    let s = JSONSettingsStore.decodeTolerant(Data(old.utf8))
    #expect(s != nil)
    #expect(s?.onboardingCompletedVersion == nil)
    #expect(s?.enabled == false)
    #expect(s?.length == .long)
}

@Test func finishedWelcomeTourVersionRoundTrips() throws {
    let url = tempURL()
    try JSONSettingsStore(fileURL: url).update { $0.onboardingCompletedVersion = 1 }
    #expect(JSONSettingsStore(fileURL: url).current().onboardingCompletedVersion == 1)
}

@Test func olderFileGetsEmptyShapeLibraryAndShapesRoundTrip() throws {
    #expect(JSONSettingsStore.decodeTolerant(Data(#"{"enabled":true}"#.utf8))?.writeShapes == WriteShapeLibrary())
    var s = HunchSettings()
    s.writeShapes = WriteShapeLibrary(presetTexts: ["email": "Formal."],
                                      custom: [CustomWriteShape(name: "Team update", text: "Bullets.")])
    #expect(JSONSettingsStore.decodeTolerant(try JSONSettingsStore.encode(s))?.writeShapes == s.writeShapes)
}

@Test func olderFileGetsDynamicPowerOff() throws {
    let old = #"{"enabled":true,"length":"long"}"#
    let s = try #require(JSONSettingsStore.decodeTolerant(Data(old.utf8)))
    #expect(s.dynamicPower == DynamicPowerSettings())
    #expect(!s.dynamicPower.enabled)
    let partial = #"{"dynamicPower":{"enabled":true,"batteryPercent":10}}"#
    let p = try #require(JSONSettingsStore.decodeTolerant(Data(partial.utf8)))
    #expect(p.dynamicPower.enabled)
    #expect(p.dynamicPower.batteryPercent == 10)
    #expect(p.dynamicPower.gpuPercent == 90)
}

@Test func appearanceWithRemovedReplaySwitchKeepsItsChoices() {
    // Saved while the "Replay on every redraw" testing switch existed; the key is now ignored.
    let old = #"{"appearance": {"animation": "wisteria", "color": "grey", "opacity": 0.7, "presetTuning": {}, "replayOnRedraw": true}}"#
    let a = JSONSettingsStore.decodeTolerant(Data(old.utf8))?.appearance
    #expect(a?.animation == .wisteria && a?.color == .grey && a?.opacity == 0.7)
}

@Test func appearanceFromBeforeFollowEffectSwitchesOnceAndKeepsFinalColors() throws {
    // Match text (the old default) becomes Follow effect; tuned styles get their final color.
    let old = #"{"appearance": {"animation": "wisteria", "color": "matchText", "opacity": 0.5, "presetTuning": {"wisteria": {"hangOn": true, "hangMaxMs": 900}, "fade": {"fadeOn": true, "fadeMs": 300}}}}"#
    let a = try #require(JSONSettingsStore.decodeTolerant(Data(old.utf8))?.appearance)
    #expect(a.color == .followEffect && a.version == AppearanceSettings.currentVersion)
    let wisteria = try #require(a.presetTuning["wisteria"])
    #expect(wisteria.hangMaxMs == 900 && wisteria.finalColorOn && wisteria.finalColor == PopInRecipe.preset(.wisteria).finalColor)
    #expect(a.presetTuning["fade"]?.finalColorOn == false)
    #expect(a.effectColor == PopInRecipe.preset(.wisteria).finalColor)
    // Another deliberate choice stays.
    let grey = #"{"appearance": {"color": "grey"}}"#
    #expect(JSONSettingsStore.decodeTolerant(Data(grey.utf8))?.appearance.color == .grey)
    // Once migrated, Match text is a choice like any other.
    let chosen = #"{"appearance": {"color": "matchText", "version": 1, "presetTuning": {"wisteria": {"hangOn": true, "finalColorOn": false}}}}"#
    let c = try #require(JSONSettingsStore.decodeTolerant(Data(chosen.utf8))?.appearance)
    #expect(c.color == .matchText && c.presetTuning["wisteria"]?.finalColorOn == false)
}

@Test func voiceInstructionsAreOffByDefaultAndAClearedShortcutStaysCleared() throws {
    let fresh = HunchSettings()
    #expect(!fresh.experimentalVoiceInstructions)
    #expect(fresh.voiceInstruction.shortcut == VoiceInstructionSettings.defaultShortcut)
    // An older file without the keys: off, default shortcut.
    let old = JSONSettingsStore.decodeTolerant(Data(#"{"enabled": true}"#.utf8))
    #expect(old?.experimentalVoiceInstructions == false)
    #expect(old?.voiceInstruction.shortcut == VoiceInstructionSettings.defaultShortcut)
    // Turned on, shortcut cleared: both survive a save and reload.
    var s = HunchSettings()
    s.experimentalVoiceInstructions = true
    s.voiceInstruction.shortcut = nil
    let back = JSONSettingsStore.decodeTolerant(try JSONSettingsStore.encode(s))
    #expect(back?.experimentalVoiceInstructions == true)
    #expect(back?.voiceInstruction.shortcut == nil)
    // The default doesn't clash with dictation's.
    #expect(VoiceInstructionSettings.defaultShortcut != DictationSettings.defaultShortcut)
}

@Test func olderFileGetsAutoCapitalizationOn() {
    let old = #"{"enabled":true,"autocorrectFixAutomatically":true}"#
    #expect(JSONSettingsStore.decodeTolerant(Data(old.utf8))?.autocorrectCapitalization == true)
}

@Test func olderFileLeavesChatShorthandOn() {
    let old = #"{"enabled":true,"autocorrectFixAutomatically":true}"#
    #expect(JSONSettingsStore.decodeTolerant(Data(old.utf8))?.autocorrectLeaveChatShorthand == true)
    let off = #"{"autocorrectLeaveChatShorthand":false}"#
    #expect(JSONSettingsStore.decodeTolerant(Data(off.utf8))?.autocorrectLeaveChatShorthand == false)
}

@Test func olderFileGetsTheDefaultSuggestionConfidence() {
    // Files from before the setting (some with the old -1.0 inside decode) move to the default.
    let old = #"{"enabled":true,"decode":{"minMeanLogProb":-2.5,"wordStartMinFirstLogProb":-1.0}}"#
    let s = JSONSettingsStore.decodeTolerant(Data(old.utf8))
    #expect(s?.suggestionConfidence == .standard)
    #expect(s?.suggestionConfidence.wordStartMinFirstLogProb == -1.5)
}

@Test func suggestionConfidenceOffRoundTrips() throws {
    for level in SuggestionConfidence.allCases {
        var settings = HunchSettings()
        settings.suggestionConfidence = level
        let s = JSONSettingsStore.decodeTolerant(try JSONEncoder().encode(settings))
        #expect(s?.suggestionConfidence == level)
    }
    #expect(SuggestionConfidence.off.wordStartMinFirstLogProb == nil)
    #expect(SuggestionConfidence.minus1_75.wordStartMinFirstLogProb == -1.75)
}

@Test func suggestedRepliesAreOffByDefaultAndSurviveAReload() throws {
    #expect(!HunchSettings().suggestedRepliesEnabled)
    #expect(HunchSettings.firstLaunch.suggestedRepliesEnabled)
    let old = JSONSettingsStore.decodeTolerant(Data(#"{"enabled": true}"#.utf8))
    #expect(old?.suggestedRepliesEnabled == false)
    #expect(old?.suggestedRepliesLayout == .verticalStack)
    var s = HunchSettings()
    s.suggestedRepliesEnabled = true
    s.suggestedRepliesLayout = .inlineAtCaret
    let back = JSONSettingsStore.decodeTolerant(try JSONSettingsStore.encode(s))
    #expect(back?.suggestedRepliesEnabled == true)
    #expect(back?.suggestedRepliesLayout == .inlineAtCaret)
}

@Test func suggestedRepliesUseNoWaitAnd1000ScreenTokens() {
    #expect(HunchSettings.suggestedRepliesDelayMs == 0)
    #expect(HunchSettings.suggestedRepliesScreenTokens == 1000)
    // Settings saved while the tuning sliders existed still load.
    let old = JSONSettingsStore.decodeTolerant(Data(#"{"enabled": true, "suggestedRepliesDelayMs": 1500, "suggestedRepliesScreenTokens": 500}"#.utf8))
    #expect(old?.enabled == true)
}
