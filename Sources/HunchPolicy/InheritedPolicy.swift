import Foundation
import HunchCore

/// What an app's per-app choices come to when left at "Default": the base from the general
/// settings, then the built-in rule (seed), then the app's category, then the general switches that gate a per-app one
/// (screen context, learning, personal information only work when they are on in general too).
/// For the Settings UI labels ("Default (On)"); the resolver remains the source of truth at runtime.
public struct InheritedPolicy: Sendable, Equatable {
    public var suggestions: Bool
    public var acceptWordKey: AcceptKey
    public var acceptFullKey: AcceptKey
    public var midLine: Bool
    public var screenContext: Bool
    public var learning: Bool
    public var personalInfo: Bool
    public var insertion: InsertionMode
    public var overlay: OverlayPreference
    public var autocorrect: Bool
    /// Autocorrect Strength here: the app's or category's own, else the general one.
    public var strength: AutocorrectStrength
    /// "Apply Corrections Automatically": on here and on in general (with general autocorrect).
    public var fixAutomatically: Bool
    /// "Allow chat shorthand": on here and on in general.
    public var leavesChatShorthand: Bool
    /// "Auto-capitalization": on here and on in general (with general autocorrect).
    public var autoCapitalization: Bool
    public var appliesTextReplacements: Bool
    /// Fix punctuation: on here and on in general.
    public var fixesPunctuation: Bool
    /// "Fix commonly confused words": on here and on in general.
    public var fixConfusedWords: Bool
    public var emoticonEmoji: Bool
    public var emojiSearch: Bool
    public var smartQuotes: Bool
    public var excludeSearchFields: Bool
    /// Suggested replies: on here and on in General.
    public var suggestedReplies: Bool
    public var shellCommandMode: ShellCommandMode
    public var writeShape: WriteShape
    public var writeCustomShapeID: UUID?
    public var customInstructions: String?
    public var instructionsReplaceGlobal: Bool
    /// "Own look" from below; nil = Settings → Appearance.
    public var appearance: AppearanceSettings?
    /// Suggestion length and start point from below, ending at the general settings.
    public var length: LengthPreset
    public var minWordsBeforeSuggesting: Int

    /// `bundleID` nil: a category's own Default (the general settings only, no built-in rule).
    /// `category`: the settings of the category the app is in.
    public init(bundleID: String?, settings: HunchSettings, seeds: [PolicyKey: AppPolicyPatch] = Seeds.table,
                category: AppPolicyPatch? = nil) {
        var p = AppPolicy(enabled: settings.completionsEnabledByDefault, midLineEnabled: settings.midLineByDefault,
                          autocorrectEnabled: settings.autocorrectEnabled, autocorrectStrength: settings.autocorrectStrength,
                          emoticonEmojiEnabled: settings.emoji.enabled, emojiSearchEnabled: settings.emoji.enabled)
        if let bundleID, let seed = seeds[.app(bundleID: bundleID)] { p = p.applying(seed) }
        if let category { p = p.applying(category.behavior) }
        customInstructions = p.customInstructions
        instructionsReplaceGlobal = p.instructionsReplaceGlobal
        appearance = p.appearance
        length = p.length ?? settings.length
        minWordsBeforeSuggesting = p.minWordsBeforeSuggesting ?? settings.minWordsBeforeSuggesting
        // The general Suggestions switch is the hard gate: off there, no app gets suggestions.
        suggestions = settings.enabled && p.enabled
        acceptWordKey = p.acceptWordKey
        acceptFullKey = p.acceptFullKey
        midLine = p.midLineEnabled
        screenContext = settings.screenContextEnabled && p.screenContextAllowed
        learning = settings.learning.enabled && p.learningAllowed
        personalInfo = settings.usePersonalInfo && p.personalInfoAllowed
        insertion = p.insertion
        overlay = p.overlay
        autocorrect = p.autocorrectEnabled
        strength = p.autocorrectStrength
        fixAutomatically = settings.autocorrectEnabled && settings.autocorrectFixAutomatically
            && p.fixAutomaticallyAllowed
        leavesChatShorthand = settings.autocorrectLeaveChatShorthand && p.leavesChatShorthand
        autoCapitalization = settings.autocorrectEnabled && settings.autocorrectCapitalization
            && p.autoCapitalizationAllowed
        appliesTextReplacements = p.appliesTextReplacements
        fixesPunctuation = settings.fixPunctuation && p.fixesPunctuation
        fixConfusedWords = settings.autocorrectFixConfusedWords && p.fixConfusedWordsAllowed
        emoticonEmoji = p.emoticonEmojiEnabled
        emojiSearch = p.emojiSearchEnabled
        smartQuotes = p.smartQuotesEnabled
        excludeSearchFields = p.excludeSearchFields
        suggestedReplies = settings.suggestedRepliesEnabled && p.suggestedRepliesAllowed
        shellCommandMode = p.shellCommandMode
        writeShape = p.writeShape
        writeCustomShapeID = p.writeCustomShapeID
    }
}
