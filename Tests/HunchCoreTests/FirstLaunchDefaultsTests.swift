import Testing
@testable import HunchCore

/// A new install's settings: tuned defaults, nothing personal, no diagnostics.
struct FirstLaunchDefaultsTests {
    @Test func nothingPersonalAndNoDiagnostics() {
        let s = HunchSettings.firstLaunch
        #expect(s.aboutMe.isEmpty && s.customInstructions.isEmpty)
        #expect(s.modelsFolderPath == nil && s.activeModel == nil && s.writeModel == nil && s.addedModels.isEmpty)
        #expect(s.dictation.speechModel == nil && s.writeShapes == WriteShapeLibrary(custom: [.aiImagePrompts]))
        #expect(s.onboardingCompletedVersion == nil)
        #expect(!s.debugLogging)
        #expect(!s.dictation.showTimings)
    }

    @Test func tunedChoices() {
        let s = HunchSettings.firstLaunch
        #expect(s.autocorrectFixAutomatically && s.autocorrectStrength == .balanced && s.autocorrectRewritePause == 0.5)
        #expect(s.midLineByDefault && s.suggestionPauseMs == 50 && s.runtime.contextTokens == 2048)
        #expect(s.learning.enabled && s.learning.styleExamplesEnabled)
        // A new install usually has one model, so there's nothing to step down to.
        #expect(!s.dynamicPower.enabled)
        #expect(s.suggestedRepliesEnabled && s.suggestedRepliesLayout == .inlineAtCaret)
    }

    @Test func shipsThePawsEffect() {
        let s = HunchSettings.firstLaunch
        #expect(s.appearance.animation == .paws && s.appearance != AppearanceSettings())
        #expect(!s.effectsForQuickReplies)
        #expect(AppearanceSettings.firstLaunchDecode.animation == .decode)
    }
}
