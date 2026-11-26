import Foundation

extension HunchSettings {
    /// What a new install starts with (no settings file yet): the setup Hunch is tuned and
    /// tested with. `HunchSettings()` keeps the plain defaults that files missing a key, tests
    /// and the evals rely on.
    ///
    /// Nothing personal or machine-specific goes here (About me, custom instructions, models
    /// folder, model files), and every diagnostic stays off. Per-app and per-site defaults are
    /// `FirstLaunchPolicies` (HunchPolicy).
    public static var firstLaunch: HunchSettings {
        var s = HunchSettings()

        // Suggestions
        s.escapeBehavior = .dismiss
        s.midLineByDefault = true
        s.suggestionPauseMs = 50
        s.runtime.contextTokens = 2048
        s.bindings.full = nil
        s.bindings.forceActivate = nil
        s.bindings.catchUp = .optionTab
        s.bindings.writeForMe = KeyChord(keyCode: 48, modifiers: 0x20000)  // ⇧Tab
        // Style chip: ⌃⌥⇧→ / ⌃⌥⇧←
        s.bindings.styleNext = KeyChord(keyCode: 124, modifiers: 0x40000 | 0x80000 | 0x20000)
        s.bindings.stylePrevious = KeyChord(keyCode: 123, modifiers: 0x40000 | 0x80000 | 0x20000)

        // Quick replies, shown at the caret
        s.suggestedRepliesEnabled = true
        s.suggestedRepliesLayout = .inlineAtCaret

        // Appearance: the Paws effect; effects in Write for me and dictation, not quick replies
        s.appearance = .firstLaunch
        s.effectsForQuickReplies = false

        // Context and learning
        s.screenContextEnabled = true
        s.clipboardContextEnabled = true
        s.windowTitleContextEnabled = true
        s.learning.enabled = true
        s.learning.styleExamplesEnabled = true

        // Autocorrect
        s.autocorrectFixAutomatically = true
        s.autocorrectStrength = .balanced
        s.autocorrectRewritePause = 0.5

        // Dictation: ⌘⇧'
        s.dictation.shortcut = KeyChord(keyCode: 39, modifiers: 0x100000 | 0x20000)

        // Voice instructions (experimental): ⌥⇧A
        s.experimentalVoiceInstructions = true
        s.voiceInstruction.shortcut = KeyChord(keyCode: 0, modifiers: 0x80000 | 0x20000)

        // Write for me: a shape for image-generator prompts (Draw Things uses it).
        s.writeShapes.custom = [.aiImagePrompts]

        // Dynamic Power Mode: off, since a new install usually has one model. When switched on it
        // steps down under GPU load or memory pressure only.
        s.dynamicPower.enabled = false
        s.dynamicPower.useBattery = false
        s.dynamicPower.useHeat = false
        s.dynamicPower.useLowPowerMode = false

        // Diagnostics: all off.
        s.debugLogging = false
        s.dictation.showTimings = false
        return s
    }
}

extension CustomWriteShape {
    /// The built-in "AI Image Prompts" shape. Its ID is fixed so per-app defaults can point at it.
    public static let aiImagePrompts = CustomWriteShape(
        id: UUID(uuidString: "FE022DD4-726E-4D8D-B0FB-93A704EB4B28")!,
        name: "AI Image Prompts",
        text: "It is a prompt I will paste into an AI image generator: write the prompt itself, not a reply to me or a description of what I asked for. Keep my core idea and everything I specified, then add the visual details it needs: the subject and what it is doing, the setting, the composition and camera angle, the lighting, the color palette, and the art style or medium. Unlike other writing, adding visual details I did not mention is the point here, as long as they fit my idea. Write it as one paragraph of plain, concrete sentences, with the main subject first. No keyword lists, no tags or weights, no title, no quotation marks.")
}
