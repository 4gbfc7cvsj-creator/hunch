import Foundation
import HunchCore

/// Settings search: what can be found (every setting row, plus the per-app settings an app, site or
/// category can override) and how a query ranks it. The Settings window draws the results and
/// jumps to them; each `anchor` matches a `.searchAnchor(_:)` on a row there.
///
/// An anchor is "<pane>.<name>"; the part before the dot is the pane's raw name ("general",
/// "apps"…). Adding a searchable row means adding one line here.
public enum SettingsSearch {

    /// A row that is only drawn while some other setting is on.
    public enum Requirement: Sendable, Equatable {
        case suggestionsOn, autocorrectOn, dictationOn, strongAutocorrect, voiceInstructionsOn, suggestedRepliesOn

        public func isMet(_ s: HunchSettings) -> Bool {
            switch self {
            case .suggestionsOn: s.enabled
            case .autocorrectOn: s.autocorrectEnabled
            case .dictationOn: s.dictation.enabled
            case .strongAutocorrect: s.autocorrectEnabled && s.autocorrectStrength == .strong
            case .voiceInstructionsOn: s.experimentalVoiceInstructions
            case .suggestedRepliesOn: s.enabled && s.suggestedRepliesEnabled
            }
        }

        /// The switch that shows the row, and the words for "turn on … first".
        public var gate: (anchor: String, name: String) {
            switch self {
            case .suggestionsOn: ("general.suggestions", "Suggestions")
            case .autocorrectOn: ("autocorrect.suggest", "Suggest Corrections")
            case .dictationOn: ("general.dictation", "Dictation")
            case .strongAutocorrect: ("autocorrect.strength", "Strong autocorrect")
            case .voiceInstructionsOn: ("general.voiceInstructions", "Voice instructions")
            case .suggestedRepliesOn: ("general.suggestedReplies", "Quick replies")
            }
        }
    }

    /// One setting row in a pane.
    public struct Entry: Sendable, Identifiable, Equatable {
        public let anchor: String
        public let title: String
        /// The section it sits in, shown in the result's path; nil when the pane has no sections.
        public let section: String?
        public let keywords: [String]
        public let requires: Requirement?
        public var id: String { anchor }
        public var pane: String { SettingsSearch.pane(of: anchor) }

        public init(_ anchor: String, _ title: String, section: String? = nil, keywords: [String] = [],
                    requires: Requirement? = nil) {
            self.anchor = anchor
            self.title = title
            self.section = section
            self.keywords = keywords
            self.requires = requires
        }
    }

    /// A setting an app, site or category can set for itself in Apps & Sites.
    public struct PlaceSetting: Sendable, Identifiable {
        public let anchor: String
        public let title: String
        public let keywords: [String]
        /// True when the patch changes this setting from Default.
        public let isSet: @Sendable (AppPolicyPatch) -> Bool
        public var id: String { anchor }

        public init(_ anchor: String, _ title: String, keywords: [String] = [],
                    isSet: @escaping @Sendable (AppPolicyPatch) -> Bool) {
            self.anchor = anchor
            self.title = title
            self.keywords = keywords
            self.isSet = isSet
        }
    }

    public static func pane(of anchor: String) -> String {
        String(anchor.prefix { $0 != "." })
    }

    // MARK: Ranking

    /// Lower is better; nil = no match. Every word of the query must be found in the title, a
    /// keyword or the context (section and pane names). Case and accents are ignored.
    public static func score(_ query: String, title: String, keywords: [String] = [],
                             context: [String] = []) -> Int? {
        let q = fold(query)
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let t = fold(title)
        let titleWords = splitWords(t)
        let keys = keywords.map(fold)
        let keyWords = keys.flatMap(splitWords)
        let contextWords = context.map(fold).flatMap(splitWords)
        var total = 0
        for word in words {
            let best: Int
            if titleWords.contains(where: { $0.hasPrefix(word) }) { best = 1 }
            else if word.count >= 3 && t.contains(word) { best = 3 }
            else if keyWords.contains(where: { $0.hasPrefix(word) }) { best = 4 }
            else if word.count >= 3 && keys.contains(where: { $0.contains(word) }) { best = 6 }
            else if contextWords.contains(where: { $0.hasPrefix(word) }) { best = 8 }
            else { return nil }
            total += best
        }
        // The whole query starting the title ranks first ("sugg" → "Suggestions"), then a title
        // that starts with it at a word, e.g. "length" → "Suggestion length".
        if t.hasPrefix(q) { total -= 10 } else if t.contains(" " + q) { total -= 5 }
        return total
    }

    /// Entries matching the query, best first.
    public static func search(_ query: String, in list: [Entry] = entries,
                              paneTitles: [String: String] = [:]) -> [Entry] {
        list.compactMap { e -> (Entry, Int)? in
            let context = [e.section, paneTitles[e.pane]].compactMap { $0 }
            return score(query, title: e.title, keywords: e.keywords, context: context).map { (e, $0) }
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.title.count != $1.0.title.count { return $0.0.title.count < $1.0.title.count }
            return $0.0.title < $1.0.title
        }
        .map(\.0)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func splitWords(_ s: String) -> [String] {
        s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: The index

    public static let entries: [Entry] = general + personalization + autocorrect + appearance
        + shortcuts + models + privacy + about

    private static let general: [Entry] = [
        Entry("general.openAtLogin", "Open at login", section: "Startup",
              keywords: ["launch", "startup", "login items", "boot"]),
        Entry("general.suggestions", "Suggestions", section: "Suggestions",
              keywords: ["autocomplete", "completions", "predictions", "turn off", "enable", "disable"]),
        Entry("general.midSentence", "Mid-sentence suggestion", section: "Suggestions",
              keywords: ["mid-line", "middle", "inside text"], requires: .suggestionsOn),
        Entry("general.length", "Suggestion length", section: "Suggestions",
              keywords: ["words", "short", "long", "how many words"], requires: .suggestionsOn),
        Entry("general.startAfter", "Start suggesting after", section: "Suggestions",
              keywords: ["minimum words", "first words", "delay"], requires: .suggestionsOn),
        Entry("general.pause", "Wait for pause", section: "Suggestions",
              keywords: ["debounce", "delay", "battery", "gpu", "typing speed"], requires: .suggestionsOn),
        Entry("general.suggestedReplies", "Quick replies", section: "Suggestions",
              keywords: ["reply", "replies", "answer", "respond", "empty field", "suggested replies"],
              requires: .suggestionsOn),
        Entry("general.suggestedRepliesLayout", "Quick replies layout", section: "Suggestions",
              keywords: ["reply", "replies", "bubble", "chips", "horizontal", "vertical", "inline", "layout"],
              requires: .suggestedRepliesOn),
        Entry("general.stream", "Stream suggestions", section: "Suggestions",
              keywords: ["streaming", "faster", "partial", "show while writing"], requires: .suggestionsOn),
        Entry("general.confidence", "Suggestion confidence", section: "Suggestions",
              keywords: ["threshold", "unsure", "floor", "probability", "quality"], requires: .suggestionsOn),
        Entry("general.trailingSpace", "Trailing space", section: "Suggestions",
              keywords: ["accept", "space after word"], requires: .suggestionsOn),
        Entry("general.trailingPunctuation", "Include trailing punctuation", section: "Suggestions",
              keywords: ["accept", "comma", "period"], requires: .suggestionsOn),
        Entry("general.escape", "Esc key", section: "Suggestions",
              keywords: ["escape", "dismiss", "hide suggestion"], requires: .suggestionsOn),
        Entry("general.emoji", "Emoji suggestions", section: "Suggestions",
              keywords: ["emoji", "colon", "smiley"], requires: .suggestionsOn),
        Entry("general.skinTone", "Skin tone", section: "Suggestions",
              keywords: ["emoji"], requires: .suggestionsOn),
        Entry("general.alsoYellow", "Also offer yellow", section: "Suggestions",
              keywords: ["emoji", "skin tone"], requires: .suggestionsOn),
        Entry("general.emojiPeople", "People", section: "Suggestions",
              keywords: ["emoji", "gender"], requires: .suggestionsOn),
        Entry("general.dictation", "Dictation", section: "Dictation",
              keywords: ["voice", "speech", "speak", "microphone", "whisper"]),
        Entry("general.cleanupOn", "AI cleanup", section: "Dictation",
              keywords: ["dictation", "filler", "punctuation", "voice"], requires: .dictationOn),
        Entry("general.cleanupLevel", "Cleanup", section: "Dictation",
              keywords: ["dictation", "light", "standard", "polished", "voice"], requires: .dictationOn),
        Entry("general.offerPolish", "Offer Polish", section: "Dictation",
              keywords: ["dictation", "write for me", "sparkles"], requires: .dictationOn),
        Entry("general.voiceInstructions", "Voice instructions for Write for me", section: "Experimental",
              keywords: ["voice", "speak", "experimental", "translate"]),
        Entry("general.welcomeTour", "Welcome tour",
              keywords: ["onboarding", "tutorial", "introduction", "help"]),
    ]

    private static let personalization: [Entry] = [
        Entry("personalization.personalInfo", "Personal info", section: "About me",
              keywords: ["name", "privacy", "me"]),
        Entry("personalization.aboutMe", "About me",
              keywords: ["bio", "role", "profile", "job", "who I am"]),
        Entry("personalization.howIWrite", "How I write",
              keywords: ["style", "tone", "custom instructions", "voice", "languages"]),
        Entry("personalization.styles", "Suggestion styles",
              keywords: ["casual", "formal", "concise", "detailed", "tone", "style", "shortcut"],
              requires: .suggestionsOn),
        Entry("personalization.windowTitle", "Window title", section: "Suggestions Context",
              keywords: ["context", "privacy"], requires: .suggestionsOn),
        Entry("personalization.clipboard", "Recent clipboard", section: "Suggestions Context",
              keywords: ["context", "copy", "paste", "pasteboard"], requires: .suggestionsOn),
        Entry("personalization.screenAwareness", "Screen Awareness", section: "Suggestions Context",
              keywords: ["screen context", "screen text", "nearby text", "ocr"], requires: .suggestionsOn),
        Entry("personalization.screenAmount", "Screen text amount", section: "Suggestions Context",
              keywords: ["tokens", "screen context"], requires: .suggestionsOn),
        Entry("personalization.learnWords", "Learn words and phrases", section: "Suggestions Context",
              keywords: ["learning", "vocabulary", "history", "names", "jargon"], requires: .suggestionsOn),
        Entry("personalization.wordChoice", "Personalize word choice", section: "Suggestions Context",
              keywords: ["learning strength", "learned words"], requires: .suggestionsOn),
        Entry("personalization.learnStyle", "Learn writing style", section: "Suggestions Context",
              keywords: ["learning", "examples", "sound like me"], requires: .suggestionsOn),
        Entry("personalization.learnFromFixes", "Learn from fixes", section: "Dictation Cleanup Context",
              keywords: ["dictation", "mishearing", "learning"], requires: .dictationOn),
        Entry("personalization.dictationContext", "Dictation Cleanup Context",
              keywords: ["dictation", "learned words", "names on screen", "text before cursor", "languages"],
              requires: .dictationOn),
        Entry("personalization.learnedData", "Learned data",
              keywords: ["delete", "history", "learned words", "vocabulary", "add word", "often mistyped", "typos", "learned replies", "usual answers", "avatar", "discord"]),
    ]

    private static let autocorrect: [Entry] = [
        Entry("autocorrect.suggest", "Suggest Corrections", section: "Corrections",
              keywords: ["autocorrect", "spelling", "typos", "spell check"]),
        Entry("autocorrect.automatic", "Apply Corrections Automatically", section: "Corrections",
              keywords: ["autocorrect", "auto fix", "spelling"], requires: .autocorrectOn),
        Entry("autocorrect.strength", "Autocorrect strength", section: "Strength",
              keywords: ["light", "balanced", "strong", "rewrite", "spell checker"], requires: .autocorrectOn),
        Entry("autocorrect.rewritePause", "Reread after a pause of", section: "Strength",
              keywords: ["strong", "rewrite", "delay"], requires: .strongAutocorrect),
        Entry("autocorrect.capitalization", "Auto-capitalization", section: "Customizations",
              keywords: ["capital letters", "uppercase", "caps"], requires: .autocorrectOn),
        Entry("autocorrect.punctuation", "Fix punctuation", section: "Customizations",
              keywords: ["period", "comma", "apostrophe"], requires: .autocorrectOn),
        Entry("autocorrect.confused", "Fix commonly confused words", section: "Customizations",
              keywords: ["their there", "grammar", "real-word"], requires: .autocorrectOn),
        Entry("autocorrect.shorthand", "Allow chat shorthand", section: "Customizations",
              keywords: ["lol", "slang", "abbreviations", "informal"], requires: .autocorrectOn),
    ]

    /// The search anchor of one effect's row in Appearance ("decode" → "appearance.effectDecode").
    public static func effectAnchor(_ raw: String) -> String {
        "appearance.effect" + raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// The effects Appearance lists (`PopInAnimation` raw value and the name shown), so each can be
    /// found by name. Keep in step with `AppearancePane.effects` and `AppearancePane.name(_:)`.
    public static let effects: [(raw: String, name: String, keywords: [String])] = [
        ("none", "None", ["no animation", "off"]),
        ("fade", "Fade in", []),
        ("materialize", "Materialize", []),
        ("typewriter", "Typewriter", []),
        ("ghost", "Ghost", []),
        ("decode", "Matrix", ["decode", "code"]),
        ("neon", "Neon", []),
        ("ocean", "Ocean", []),
        ("stardust", "Stardust", ["sparkle"]),
        ("ember", "Ember", ["fire"]),
        ("wisteria", "Wisteria", []),
        ("autumn", "Autumn", []),
        ("winter", "Winter", ["snow"]),
        ("custom", "Custom", ["build your own"]),
    ]

    private static let appearance: [Entry] = [
        Entry("appearance.preview", "Preview", keywords: ["replay", "animation"]),
        Entry("appearance.effects", "Effects",
              keywords: ["animation", "pop-in", "fade", "style", "motion"]),
    ] + effects.map {
        Entry(effectAnchor($0.raw), $0.name, section: "Effects", keywords: $0.keywords)
    } + [
        Entry("appearance.color", "Color", section: "Color",
              keywords: ["custom color", "tint", "grey", "gray", "accent", "suggestion color"]),
        Entry("appearance.strength", "Strength", section: "Color",
              keywords: ["opacity", "transparency", "faint", "visibility"]),
        Entry("appearance.dictation", "In dictation", section: "Also use the effect",
              keywords: ["effect", "animation"]),
        Entry("appearance.writeForMe", "In Write for me", section: "Also use the effect",
              keywords: ["effect", "animation", "draft"]),
        Entry("appearance.quickReplies", "In quick replies", section: "Also use the effect",
              keywords: ["effect", "animation", "suggested replies"]),
        Entry("appearance.appIcon", "App icon", section: "Icons",
              keywords: ["icon", "dock", "finder", "cat", "color"]),
        Entry("appearance.menuBarIcon", "Menu bar icon", section: "Icons",
              keywords: ["icon", "status bar", "menu bar", "cat", "paw", "glyph"]),
    ]

    private static let shortcuts: [Entry] = [
        Entry("shortcuts.acceptWord", "Accept next word", keywords: ["hotkey", "keyboard", "tab", "key"]),
        Entry("shortcuts.acceptAll", "Accept whole suggestion", keywords: ["hotkey", "keyboard", "tab", "key"]),
        Entry("shortcuts.nextAlternative", "Next alternative suggestion", keywords: ["hotkey", "keyboard", "cycle"]),
        Entry("shortcuts.previousAlternative", "Previous alternative suggestion",
              keywords: ["hotkey", "keyboard", "cycle"]),
        Entry("shortcuts.styleNext", "Next suggestion style", keywords: ["hotkey", "keyboard", "casual", "tone"]),
        Entry("shortcuts.stylePrevious", "Previous suggestion style", keywords: ["hotkey", "keyboard", "formal", "tone"]),
        Entry("shortcuts.suggestNow", "Suggest now", keywords: ["hotkey", "keyboard", "force", "trigger"]),
        Entry("shortcuts.writeForMe", "Write for me", keywords: ["hotkey", "keyboard", "draft", "polish"]),
        Entry("shortcuts.catchUp", "Fix a missed word", keywords: ["hotkey", "keyboard", "autocorrect"]),
        Entry("shortcuts.revertFix", "Undo a fix", keywords: ["hotkey", "keyboard", "autocorrect", "revert"]),
        Entry("shortcuts.dictation", "Dictation shortcut", keywords: ["hotkey", "keyboard", "voice"]),
        Entry("shortcuts.voiceInstruction", "Voice instruction shortcut",
              keywords: ["hotkey", "keyboard", "experimental"], requires: .voiceInstructionsOn),
        Entry("shortcuts.pauseApp", "Pause in this app", keywords: ["hotkey", "keyboard", "disable app"]),
        Entry("shortcuts.toggleGlobal", "Turn Hunch on/off", keywords: ["hotkey", "keyboard", "disable"]),
    ]

    private static let models: [Entry] = [
        Entry("model.dynamicPower", "Dynamic Power Mode", section: "Performance",
              keywords: ["battery", "efficiency", "low power", "gpu", "heat", "memory"]),
        Entry("model.autocomplete", "Language Model",
              keywords: ["llm", "model", "gguf", "download", "hugging face", "endpoint", "server", "api"]),
        Entry("model.writing", "Writing Model",
              keywords: ["separate writing model", "write for me", "llm", "endpoint"]),
        Entry("model.speechToText", "Speech to Text",
              keywords: ["whisper", "dictation model", "voice"]),
        Entry("model.folder", "Models folder", keywords: ["location", "rescan", "directory", "path"]),
    ]

    private static let privacy: [Entry] = [
        Entry("privacy.permissions", "Permissions",
              keywords: ["accessibility", "input monitoring", "screen recording", "microphone"]),
        Entry("privacy.privacy", "Privacy", keywords: ["what Hunch sees", "data", "stored"]),
        Entry("privacy.debugLogging", "Debug logging", section: "Diagnostics",
              keywords: ["logs", "alignment check", "eval captures", "typing samples", "suggestion outcomes",
                         "dictation log"]),
        Entry("privacy.savedLogs", "Saved logs", section: "Diagnostics",
              keywords: ["logs", "eval captures", "typing samples", "outcomes", "dictation log", "delete log",
                         "show in finder"]),
        Entry("privacy.console", "Diagnostic console", section: "Diagnostics",
              keywords: ["debug", "requests", "prompt"]),
        Entry("privacy.dictationTimings", "Show timings after each dictation", section: "Diagnostics",
              keywords: ["dictation", "speed"]),
        Entry("privacy.interceptors", "Apps that intercept keys", section: "Diagnostics",
              keywords: ["secure input", "key tap", "keyboard", "conflict"]),
    ]

    private static let about: [Entry] = [
        Entry("about.version", "Version", keywords: ["update", "build"]),
        Entry("about.licenses", "License notices", section: "Acknowledgements",
              keywords: ["acknowledgements", "open source", "credits"]),
    ]

    // MARK: Per-app settings

    /// Anchors in the Apps & Sites editor, matching its row titles.
    public static let placeSettings: [PlaceSetting] = [
        PlaceSetting("apps.suggestions", "Suggestions", keywords: ["autocomplete", "turn off"]) { $0.enabled != nil },
        PlaceSetting("apps.searchFields", "Search fields suggestions") { $0.excludeSearchFields != nil },
        PlaceSetting("apps.suggestedReplies", "Quick replies", keywords: ["replies", "reply bubble", "suggested replies"]) {
            $0.suggestedRepliesAllowed != nil
        },
        PlaceSetting("apps.autocorrect", "Suggest Corrections", keywords: ["autocorrect", "spelling"]) {
            $0.autocorrectEnabled != nil
        },
        PlaceSetting("apps.autocorrectStrength", "Autocorrect strength", keywords: ["autocorrect"]) {
            $0.autocorrectStrength != nil
        },
        PlaceSetting("apps.fixAutomatically", "Apply Corrections Automatically", keywords: ["autocorrect"]) {
            $0.fixAutomaticallyAllowed != nil
        },
        PlaceSetting("apps.capitalization", "Auto-capitalization", keywords: ["autocorrect", "caps"]) {
            $0.autoCapitalizationAllowed != nil
        },
        PlaceSetting("apps.punctuation", "Fix punctuation", keywords: ["autocorrect"]) { $0.fixesPunctuation != nil },
        PlaceSetting("apps.confused", "Fix commonly confused words", keywords: ["autocorrect"]) {
            $0.fixConfusedWordsAllowed != nil
        },
        PlaceSetting("apps.shorthand", "Allow chat shorthand", keywords: ["autocorrect", "slang"]) {
            $0.leavesChatShorthand != nil
        },
        PlaceSetting("apps.textReplacements", "Apply Text Replacements", keywords: ["autocorrect", "expansion"]) {
            $0.appliesTextReplacements != nil
        },
        PlaceSetting("apps.length", "Suggestion length", keywords: ["words"]) {
            $0.length != nil || $0.maxWordsOverride != nil
        },
        PlaceSetting("apps.start", "Start suggesting after", keywords: ["suggestion start", "minimum words"]) {
            $0.minWordsBeforeSuggesting != nil
        },
        PlaceSetting("apps.acceptWord", "Accept word with", keywords: ["tab", "key", "shortcut"]) {
            $0.acceptWordKey != nil || $0.tabAcceptEnabled != nil
        },
        PlaceSetting("apps.acceptAll", "Accept all with", keywords: ["tab", "key", "shortcut"]) {
            $0.acceptFullKey != nil
        },
        PlaceSetting("apps.midSentence", "Mid-sentence suggestion", keywords: ["mid-line"]) { $0.midLineEnabled != nil },
        PlaceSetting("apps.emoticon", "Emoticon to emoji", keywords: ["smiley"]) { $0.emoticonEmojiEnabled != nil },
        PlaceSetting("apps.emoji", "Emoji", keywords: ["emoji suggestions"]) { $0.emojiSearchEnabled != nil },
        PlaceSetting("apps.smartQuotes", "Smart quotes", keywords: ["curly quotes"]) { $0.smartQuotesEnabled != nil },
        PlaceSetting("apps.shell", "Suggest shell commands", keywords: ["terminal", "command line"]) {
            $0.shellCommandMode != nil || $0.shellCommandsEnabled != nil
        },
        PlaceSetting("apps.writeShape", "Write for me", keywords: ["shape", "email", "message", "draft"]) {
            $0.writeShape != nil || $0.writeCustomShapeID != nil
        },
        PlaceSetting("apps.insertion", "Insertion method", keywords: ["paste", "type it"]) { $0.insertion != nil },
        PlaceSetting("apps.nonBreakingSpaces", "Use non-breaking spaces", keywords: ["advanced insertion"]) {
            $0.nonBreakingSpaces != nil
        },
        PlaceSetting("apps.spaceAsKey", "Space as keypress", keywords: ["advanced insertion"]) {
            $0.spaceAsKeyEvent != nil
        },
        PlaceSetting("apps.backspaceAfterPaste", "Backspace after paste", keywords: ["advanced insertion"]) {
            $0.backspaceAfterPaste != nil
        },
        PlaceSetting("apps.screenContext", "Allow screen context", keywords: ["screen awareness"]) {
            $0.screenContextAllowed != nil
        },
        PlaceSetting("apps.learning", "Learning", keywords: ["learn words"]) { $0.learningAllowed != nil },
        PlaceSetting("apps.personalInfo", "Personal info", keywords: ["about me", "name"]) {
            $0.personalInfoAllowed != nil
        },
        PlaceSetting("apps.instructions", "Instructions", keywords: ["how I write", "style", "custom instructions"]) {
            $0.customInstructions != nil
        },
        PlaceSetting("apps.display", "Suggestion display", keywords: ["inline", "below the line", "mirror"]) {
            $0.overlay != nil
        },
        PlaceSetting("apps.look", "Look", keywords: ["own look", "appearance", "color", "effect"]) {
            $0.appearance != nil
        },
        PlaceSetting("apps.textSize", "Text size", keywords: ["advanced appearance", "font size"]) {
            $0.fontSizeAdjustmentFactor != nil
        },
        PlaceSetting("apps.verticalOffset", "Vertical offset", keywords: ["advanced appearance", "alignment"]) {
            $0.verticalAlignmentOffset != nil
        },
    ]

    /// Where a jump to `anchor` (from a `hunch://settings?setting=` link) goes: the row itself, or
    /// the switch that shows it while that switch is off. Nil for an anchor no row has.
    public static func jumpTarget(_ anchor: String, settings: HunchSettings) -> String? {
        if placeSettings.contains(where: { $0.anchor == anchor }) { return anchor }
        guard let entry = entries.first(where: { $0.anchor == anchor }) else { return nil }
        if let req = entry.requires, !req.isMet(settings) { return req.gate.anchor }
        return anchor
    }

    /// Anchors in the Apps & Sites editor that sit inside a closed-by-default disclosure group.
    public static let advancedInsertionAnchors: Set<String> =
        ["apps.nonBreakingSpaces", "apps.spaceAsKey", "apps.backspaceAfterPaste"]
    public static let advancedAppearanceAnchors: Set<String> = ["apps.textSize", "apps.verticalOffset"]
}
