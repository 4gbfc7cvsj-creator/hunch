import Foundation
import Testing
@testable import HunchCore

@Test func HunchCoreModuleLinks() {
    #expect(Bool(true))
}

@Suite struct DictationSettingsTests {
    @Test func olderSettingsWithTheRemovedLogSwitchStillDecode() throws {
        let old = try JSONDecoder().decode(DictationSettings.self,
                                           from: Data(#"{"showTimings":false,"keepLog":true}"#.utf8))
        #expect(!old.showTimings)
    }

    @Test func dictationPrivacyRefusesSecurePlaces() {
        for reason: BlockReason in [.secureEventInput(ownerPID: nil), .secureExcludedApp, .secureRole,
                                    .sensitiveMarker, .protectedContent] {
            #expect(DictationPrivacy.decide(policy: .default, blockReason: reason) == .refuse)
        }
        var secure = AppPolicy.default
        secure.secureExcluded = true
        #expect(DictationPrivacy.decide(policy: secure, blockReason: nil) == .refuse)
        // Secure wins over merely disabled.
        secure.enabled = false
        #expect(DictationPrivacy.decide(policy: secure, blockReason: .appDisabled) == .refuse)
    }

    @Test func dictationPrivacyKeepsNothingWhereOffOrNotLearning() {
        for reason: BlockReason in [.globallyDisabled, .appDisabled, .trackingPaused] {
            #expect(DictationPrivacy.decide(policy: .default, blockReason: reason) == .keepNothing)
        }
        var off = AppPolicy.default
        off.enabled = false
        #expect(DictationPrivacy.decide(policy: off, blockReason: nil) == .keepNothing)
        var noLearning = AppPolicy.default
        noLearning.learningAllowed = false
        #expect(DictationPrivacy.decide(policy: noLearning, blockReason: nil) == .keepNothing)
    }

    @Test func dictationPrivacyNormalElsewhere() {
        #expect(DictationPrivacy.decide(policy: .default, blockReason: nil) == .normal)
        #expect(DictationPrivacy.decide(policy: .default, blockReason: .notEditable) == .normal)
        #expect(DictationPrivacy.decide(policy: .default, blockReason: .searchField) == .normal)
    }

    @Test func blindInsertGoesInWhereNothingChanged() {
        // Hunch off in the app: same app in front, still a text field, no password field.
        #expect(DictationBlindInsert.allowed(startPID: 42, frontPID: 42, secureInput: false,
                                             privacy: .keepNothing, onTextField: true))
        #expect(DictationBlindInsert.allowed(startPID: 42, frontPID: 42, secureInput: false,
                                             privacy: .normal, onTextField: true))
    }

    @Test func blindInsertRefusesWhenAnythingChanged() {
        // Another app in front, or none known.
        #expect(!DictationBlindInsert.allowed(startPID: 42, frontPID: 7, secureInput: false,
                                              privacy: .keepNothing, onTextField: true))
        #expect(!DictationBlindInsert.allowed(startPID: nil, frontPID: 42, secureInput: false,
                                              privacy: .keepNothing, onTextField: true))
        #expect(!DictationBlindInsert.allowed(startPID: 42, frontPID: nil, secureInput: false,
                                              privacy: .keepNothing, onTextField: true))
        // A password field now: Secure Input, or a secure field the focus read refused.
        #expect(!DictationBlindInsert.allowed(startPID: 42, frontPID: 42, secureInput: true,
                                              privacy: .keepNothing, onTextField: true))
        #expect(!DictationBlindInsert.allowed(startPID: 42, frontPID: 42, secureInput: false,
                                              privacy: .refuse, onTextField: true))
        // Focus left the text box.
        #expect(!DictationBlindInsert.allowed(startPID: 42, frontPID: 42, secureInput: false,
                                              privacy: .keepNothing, onTextField: false))
    }

    @Test func cancelledRunIsNoLongerCurrent() {
        var runs = DictationRuns()
        let first = runs.next()
        #expect(runs.isCurrent(first))
        // Esc, then a new dictation before the first one's work has wound down.
        runs.next()
        let second = runs.next()
        #expect(!runs.isCurrent(first))
        #expect(runs.isCurrent(second))
        // Cancelling the second leaves no run current.
        runs.next()
        #expect(!runs.isCurrent(second))
    }

    @Test func learnFromFixesDefaultsOnForOlderSettings() throws {
        let old = try JSONDecoder().decode(DictationSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.learnFromFixes)
        var off = DictationSettings()
        off.learnFromFixes = false
        let back = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(off))
        #expect(!back.learnFromFixes)
    }

    @Test func fixKeyFoldsCaseAndSpaces() {
        #expect(DictationFix.key(" Clock   Code ") == "clock code")
        #expect(DictationFix(heard: "Clock Code", written: "Claude Code").id == "clock code")
    }

    @Test func tapLatchesAndHoldIsPushToTalk() {
        var t = DictationTrigger()
        // Tap: starts, keeps recording after release, the next press-and-release stops.
        #expect(t.keyDown(at: 0) == .start)
        #expect(t.keyUp(at: 0.1) == .none)
        #expect(t.phase == .latched)
        #expect(t.keyDown(at: 3) == .none)
        #expect(t.keyDown(at: 3.05) == .none)  // key repeat
        #expect(t.keyUp(at: 3.1) == .stop)
        #expect(t.phase == .idle)
        // Hold: stops on release.
        #expect(t.keyDown(at: 10) == .start)
        #expect(t.keyDown(at: 10.5) == .none)
        #expect(t.keyUp(at: 12) == .stop)
        // Reset from anywhere.
        _ = t.keyDown(at: 20)
        t.reset()
        #expect(t.keyDown(at: 21) == .start)
    }

    @Test func defaultsAndOldFiles() throws {
        let d = DictationSettings()
        #expect(d.shortcut == DictationSettings.defaultShortcut && d.cleanupEnabled && d.preset == .standard)
        #expect(d.context.learnedWords && !d.context.aboutMe)
        // A file without the key, or with partial keys, takes the defaults for what's missing.
        let partial = try JSONDecoder().decode(DictationSettings.self,
                                               from: Data(#"{"preset":"light","context":{"aboutMe":true}}"#.utf8))
        #expect(partial.preset == .light && partial.context.aboutMe && partial.context.textBefore)
        #expect(partial.shortcut == DictationSettings.defaultShortcut)
        // A cleared shortcut survives a round trip.
        var cleared = d
        cleared.shortcut = nil
        let back = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(cleared))
        #expect(back.shortcut == nil)
        #expect(try JSONDecoder().decode(HunchSettings.self, from: JSONEncoder().encode(HunchSettings()))
                .dictation == d)
    }
}

@Suite struct DictationLearningTests {
    @Test func learnedWordsNeedTheGlobalSwitch() {
        let off = DictationLearning.decide(learnFromFixes: true, learnFromWriting: false, appAllowsLearning: true,
                                           surface: .email, keepNothing: false)
        #expect(off == DictationLearning(rules: true, words: false))
        let on = DictationLearning.decide(learnFromFixes: true, learnFromWriting: true, appAllowsLearning: true,
                                          surface: .email, keepNothing: false)
        #expect(on == DictationLearning(rules: true, words: true))
    }

    @Test func nothingWhereLearningIsOff() {
        let none = DictationLearning(rules: false, words: false)
        #expect(DictationLearning.decide(learnFromFixes: false, learnFromWriting: true, appAllowsLearning: true,
                                         surface: .email, keepNothing: false) == none)
        #expect(DictationLearning.decide(learnFromFixes: true, learnFromWriting: true, appAllowsLearning: false,
                                         surface: .email, keepNothing: false) == none)
        #expect(DictationLearning.decide(learnFromFixes: true, learnFromWriting: true, appAllowsLearning: true,
                                         surface: .code, keepNothing: false) == none)
        #expect(DictationLearning.decide(learnFromFixes: true, learnFromWriting: true, appAllowsLearning: true,
                                         surface: nil, keepNothing: true) == none)
    }
}
