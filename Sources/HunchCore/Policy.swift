import Foundation

public enum InsertionMode: String, Codable, Sendable, CaseIterable { case unicodeEvents, paste, pasteMatchStyle }
/// `mirror` is opt-in per app only: `automatic` never picks it.
public enum OverlayPreference: String, Codable, Sendable, CaseIterable { case automatic, inline, card, mirror }
public enum EngineKind: String, Codable, Sendable, CaseIterable { case local, endpoint }

/// Host quirks that only some apps need when Hunch inserts text. All off by default; no
/// built-in rule turns any on until a host is confirmed to need it.
public struct InsertionWorkarounds: Codable, Sendable, Equatable {
    /// Type U+00A0 for every space: some hosts collapse or drop spaces in synthetic Unicode events.
    /// Applied before `spaceAsKeyEvent`, so with both on no Space key is pressed.
    public var nonBreakingSpaces: Bool
    /// Press the Space key (virtual key 49) for each space: some hosts only react to a real Space.
    public var spaceAsKeyEvent: Bool
    /// Press Backspace once after a successful paste: some hosts add a stray character or newline.
    public var backspaceAfterPaste: Bool

    public init(nonBreakingSpaces: Bool = false, spaceAsKeyEvent: Bool = false, backspaceAfterPaste: Bool = false) {
        self.nonBreakingSpaces = nonBreakingSpaces
        self.spaceAsKeyEvent = spaceAsKeyEvent
        self.backspaceAfterPaste = backspaceAfterPaste
    }
}

/// A per-app accept key: the key set in Shortcuts, no key (`off`, shown as "None"), or
/// a key recorded for this app or site.
public enum AcceptKey: Codable, Sendable, Hashable {
    case shortcuts, off
    case chord(KeyChord)

    /// The chord that accepts here, given the Shortcuts binding.
    public func resolved(_ shortcut: KeyChord?) -> KeyChord? {
        switch self {
        case .shortcuts: shortcut
        case .off: nil
        case .chord(let c): c
        }
    }
}

/// Effective per-app behavior after layering seeds and user overrides.
public struct AppPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var secureExcluded: Bool
    public var customInstructions: String?
    public var insertion: InsertionMode
    /// "Accept next word with:" here.
    public var acceptWordKey: AcceptKey
    /// "Accept whole suggestion with:" here.
    public var acceptFullKey: AcceptKey
    public var midLineEnabled: Bool
    public var overlay: OverlayPreference
    public var maxWordsOverride: Int?
    /// Suggestion length here instead of the general one; nil follows the general setting.
    public var length: LengthPreset?
    /// Words typed on the line before suggestions appear here; nil follows the general setting.
    public var minWordsBeforeSuggesting: Int?
    public var engineOverride: EngineKind?
    public var wakeChromiumAX: Bool
    public var injectionChunkSize: Int?
    public var omitSurfaceContext: Bool
    /// Per-app switch for screen context (only effective when the global opt-in is on).
    public var screenContextAllowed: Bool
    /// Per-app switch for learning from the user's writing (only effective when learning is on).
    public var learningAllowed: Bool
    /// Per-app switch for the user's personal information (only effective when it is on globally).
    public var personalInfoAllowed: Bool
    /// This app's or site's instructions replace "How I write" instead of adding to it (only when
    /// it has instructions of its own).
    public var instructionsReplaceGlobal: Bool
    /// Multiplies the ghost's point size (after the learned width scale) for hosts that report a
    /// misleading font size. 1 = unchanged.
    public var fontSizeAdjustmentFactor: Double
    /// Moves the inline ghost's baseline by this many points (positive = up), on top of the
    /// calibrated position, for hosts whose baseline is still off. 0 = unchanged.
    public var verticalAlignmentOffset: Double
    /// Draw the ghost in the default grey instead of a tint of the host's text color.
    public var greySuggestionColorEnabled: Bool
    /// Strikethrough fix for a misspelled last word. Base value: the general autocorrect setting.
    public var autocorrectEnabled: Bool
    /// How far autocorrect goes here. Base value: the general Strength setting.
    public var autocorrectStrength: AutocorrectStrength
    /// Per-app switch for "Apply Corrections Automatically" (only effective where autocorrect is on and Fix
    /// automatically is on in general). Off in Chats by default.
    public var fixAutomaticallyAllowed: Bool
    /// "Allow chat shorthand": leave chat shorthand ("ofc", "id", "tbh") alone instead of fixing it (`ChatShorthand`). On in
    /// Chats by default. Meant to fold into a later per-app "fix punctuation / capitalization /
    /// shorthand" switch (fix in formal apps, leave alone in chat apps).
    public var leavesChatShorthand: Bool
    /// Auto-capitalization (THe → The, tHIS → This, i → I, monday → Monday, iphone → iPhone), a "formal
    /// apps only" fix: on by default, off in Chats. Needs the general switch too.
    public var autoCapitalizationAllowed: Bool
    /// Type the user's macOS Text Replacements where the host app doesn't apply them itself (only
    /// with Fix automatically). Shortcuts are never treated as typos, whatever this says.
    public var appliesTextReplacements: Bool
    /// Fix punctuation: missing apostrophes ("dont" → "don't"), a space before punctuation, no space
    /// after a full stop, doubled spaces (only where autocorrect is on and the general switch is on).
    /// Off in Chats by default: chat typing is loose on purpose.
    public var fixesPunctuation: Bool
    /// "Fix commonly confused words" here (their/there, your/you're, then/than...; only with Fix
    /// automatically, and only where the general switch is on). Off in Chats by default.
    public var fixConfusedWordsAllowed: Bool
    /// Emoji for emoticons such as ":)". Base value: the general emoji setting.
    public var emoticonEmojiEnabled: Bool
    /// Emoji search after ":" (":smile"). Base value: the general emoji setting.
    public var emojiSearchEnabled: Bool
    /// Curly or straight quotes as the field already uses (true), or always straight (false),
    /// e.g. for apps that need plain ASCII quotes.
    public var smartQuotesEnabled: Bool
    /// Search fields (AXSearchField) are blocked before any text is read. Off by default.
    public var excludeSearchFields: Bool
    /// Suggested replies may show in this app's empty fields (with the feature on in General). On by default.
    public var suggestedRepliesAllowed: Bool
    /// Per-app insertion quirks (non-breaking spaces, Space key presses, Backspace after paste).
    public var insertionWorkarounds: InsertionWorkarounds
    /// Terminals only: valid shell commands at the shell prompt, or prose in AI agent prompts
    /// (Claude Code, Gemini CLI, Codex, Aider). Automatic picks one from the window title.
    public var shellCommandMode: ShellCommandMode
    /// Never ask the host for text bounds; place the caret from the field frame. For apps where
    /// precise bounds queries move focus or scroll (design §11).
    public var estimatedGeometryOnly: Bool
    /// Shape of a write-for-me draft here; `adaptive` picks it from the kind of field.
    public var writeShape: WriteShape
    /// A saved custom shape (`WriteShapeLibrary.custom`) used here instead of `writeShape` on a
    /// write. An id that is no longer saved counts as not set.
    public var writeCustomShapeID: UUID?
    /// "Own look" here (effect, color, strength) instead of Settings → Appearance; nil follows it.
    public var appearance: AppearanceSettings?

    public init(enabled: Bool = true, secureExcluded: Bool = false, customInstructions: String? = nil,
                insertion: InsertionMode = .unicodeEvents, acceptWordKey: AcceptKey = .shortcuts,
                acceptFullKey: AcceptKey = .shortcuts,
                midLineEnabled: Bool = false, overlay: OverlayPreference = .automatic,
                maxWordsOverride: Int? = nil, engineOverride: EngineKind? = nil, wakeChromiumAX: Bool = false,
                injectionChunkSize: Int? = nil, omitSurfaceContext: Bool = false, screenContextAllowed: Bool = true,
                learningAllowed: Bool = true, personalInfoAllowed: Bool = true,
                instructionsReplaceGlobal: Bool = false, fontSizeAdjustmentFactor: Double = 1,
                verticalAlignmentOffset: Double = 0, greySuggestionColorEnabled: Bool = false,
                autocorrectEnabled: Bool = true, fixAutomaticallyAllowed: Bool = true,
                leavesChatShorthand: Bool = false, autoCapitalizationAllowed: Bool = true,
                appliesTextReplacements: Bool = true, fixesPunctuation: Bool = true,
                fixConfusedWordsAllowed: Bool = true, autocorrectStrength: AutocorrectStrength = .balanced,
                emoticonEmojiEnabled: Bool = true, emojiSearchEnabled: Bool = true,
                smartQuotesEnabled: Bool = true, excludeSearchFields: Bool = false, suggestedRepliesAllowed: Bool = true,
                insertionWorkarounds: InsertionWorkarounds = .init(), shellCommandMode: ShellCommandMode = .automatic,
                estimatedGeometryOnly: Bool = false, writeShape: WriteShape = .adaptive,
                writeCustomShapeID: UUID? = nil, appearance: AppearanceSettings? = nil,
                length: LengthPreset? = nil, minWordsBeforeSuggesting: Int? = nil) {
        self.length = length
        self.minWordsBeforeSuggesting = minWordsBeforeSuggesting
        self.appearance = appearance
        self.writeShape = writeShape
        self.writeCustomShapeID = writeCustomShapeID
        self.shellCommandMode = shellCommandMode
        self.estimatedGeometryOnly = estimatedGeometryOnly
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.greySuggestionColorEnabled = greySuggestionColorEnabled
        self.personalInfoAllowed = personalInfoAllowed
        self.instructionsReplaceGlobal = instructionsReplaceGlobal
        self.enabled = enabled
        self.secureExcluded = secureExcluded
        self.customInstructions = customInstructions
        self.insertion = insertion
        self.acceptWordKey = acceptWordKey
        self.acceptFullKey = acceptFullKey
        self.midLineEnabled = midLineEnabled
        self.overlay = overlay
        self.maxWordsOverride = maxWordsOverride
        self.engineOverride = engineOverride
        self.wakeChromiumAX = wakeChromiumAX
        self.injectionChunkSize = injectionChunkSize
        self.omitSurfaceContext = omitSurfaceContext
        self.screenContextAllowed = screenContextAllowed
        self.learningAllowed = learningAllowed
        self.autocorrectEnabled = autocorrectEnabled
        self.fixAutomaticallyAllowed = fixAutomaticallyAllowed
        self.leavesChatShorthand = leavesChatShorthand
        self.autoCapitalizationAllowed = autoCapitalizationAllowed
        self.appliesTextReplacements = appliesTextReplacements
        self.fixesPunctuation = fixesPunctuation
        self.fixConfusedWordsAllowed = fixConfusedWordsAllowed
        self.autocorrectStrength = autocorrectStrength
        self.emoticonEmojiEnabled = emoticonEmojiEnabled
        self.emojiSearchEnabled = emojiSearchEnabled
        self.smartQuotesEnabled = smartQuotesEnabled
        self.excludeSearchFields = excludeSearchFields
        self.suggestedRepliesAllowed = suggestedRepliesAllowed
        self.insertionWorkarounds = insertionWorkarounds
    }

    public static let `default` = AppPolicy()
}

/// Partial override. Layered in order: built-in seed < user app override < user domain override.
public struct AppPolicyPatch: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var secureExcluded: Bool?
    public var customInstructions: String?
    public var insertion: InsertionMode?
    /// The older "Accept with Tab" switch, still read from saved files and URL commands: Off means
    /// no next-word key, On the Shortcuts key. `acceptWordKey` wins when both are set.
    public var tabAcceptEnabled: Bool?
    public var acceptWordKey: AcceptKey?
    public var acceptFullKey: AcceptKey?
    public var midLineEnabled: Bool?
    public var overlay: OverlayPreference?
    /// Older word limit, never shown in Settings; still decoded. `length` is the setting now.
    public var maxWordsOverride: Int?
    /// "Suggestion length" here; nil = Default (the layer below, then General).
    public var length: LengthPreset?
    /// "Start suggesting after" here, in words; nil = Default.
    public var minWordsBeforeSuggesting: Int?
    public var engineOverride: EngineKind?
    public var wakeChromiumAX: Bool?
    public var injectionChunkSize: Int?
    public var omitSurfaceContext: Bool?
    public var screenContextAllowed: Bool?
    public var learningAllowed: Bool?
    /// Per-app switch for "Use my personal information" (name and About me).
    public var personalInfoAllowed: Bool?
    /// `customInstructions` replace "How I write" here (true) or add to it (nil/false).
    public var instructionsReplaceGlobal: Bool?
    /// User-named app category ("Work"): apps and sites in one category share saved sentences
    /// and learned-word strength (see `AppCategories`) and follow the category's settings.
    /// "" is an explicit None (no automatic category). Not a behavior; reset keeps it.
    public var appCategory: String?
    /// Ghost point size multiplier (0.5…2.0; nil = 1). Optional so older files still decode.
    public var fontSizeAdjustmentFactor: Double?
    /// Inline ghost baseline shift in points, positive = up (nil = 0).
    public var verticalAlignmentOffset: Double?
    /// Force the default grey instead of the host's text color (nil = off).
    public var greySuggestionColorEnabled: Bool?
    /// Per-app autocorrect; nil follows the general setting.
    public var autocorrectEnabled: Bool?
    /// Per-app autocorrect Strength; nil follows the general setting.
    public var autocorrectStrength: AutocorrectStrength?
    /// Per-app "Apply Corrections Automatically"; nil follows the layer below (on, gated by the general switch).
    public var fixAutomaticallyAllowed: Bool?
    /// Per-app "Allow chat shorthand"; nil follows the layer below (off, on in Chats).
    public var leavesChatShorthand: Bool?
    /// Per-app "Auto-capitalization"; nil follows the layer below (on, off in Chats).
    public var autoCapitalizationAllowed: Bool?
    /// Per-app "Apply Text Replacements"; nil follows the layer below (on).
    public var appliesTextReplacements: Bool?
    /// Per-app "Fix punctuation"; nil follows the layer below (on, off in Chats).
    public var fixesPunctuation: Bool?
    /// Per-app "Fix commonly confused words"; nil follows the layer below (on, off in Chats; gated by
    /// the general switch).
    public var fixConfusedWordsAllowed: Bool?
    /// Per-app emoticon emoji (":)"); nil follows the general emoji setting.
    public var emoticonEmojiEnabled: Bool?
    /// Per-app ":" emoji search; nil follows the general emoji setting.
    public var emojiSearchEnabled: Bool?
    /// false forces straight quotes in suggestions; nil/true match the field.
    public var smartQuotesEnabled: Bool?
    /// true blocks search fields here; nil/false leave them allowed.
    public var excludeSearchFields: Bool?
    /// false keeps suggested replies out of this app; nil/true follow the layer below.
    public var suggestedRepliesAllowed: Bool?
    /// `InsertionWorkarounds` flags; nil follows the layer below (off by default).
    public var nonBreakingSpaces: Bool?
    public var spaceAsKeyEvent: Bool?
    public var backspaceAfterPaste: Bool?
    /// The older "Suggest shell commands" switch, still read from saved files: On means Always,
    /// Off Never. `shellCommandMode` wins when both are set.
    public var shellCommandsEnabled: Bool?
    /// Terminals: shell commands, agent prompts, or Automatic (window title decides; nil = Default).
    public var shellCommandMode: ShellCommandMode?
    /// Caret from the field frame only, no text-bounds queries (nil/false = query the host).
    public var estimatedGeometryOnly: Bool?
    /// "Write for me" draft shape; nil = Default (adaptive). `paragraph` is no longer offered and
    /// counts as nil (older files).
    public var writeShape: WriteShape?
    /// A saved custom shape instead of a preset. Set alone: choosing a preset clears it.
    public var writeCustomShapeID: UUID?
    /// "Own look": the whole appearance used here instead of Settings → Appearance (nil follows the
    /// layer below, and in the end Settings → Appearance).
    public var appearance: AppearanceSettings?
    public init() {}

    /// This patch as a category's settings: without its category membership, and with suggestions
    /// only ever turned off. A category never turns suggestions back on over an app or browser that
    /// is off by default, by a built-in rule or by the user (each app or site can still be turned on).
    public var behavior: AppPolicyPatch {
        var p = self
        p.appCategory = nil
        if p.enabled == true { p.enabled = nil }
        return p
    }

    /// The next-word key this layer sets, counting the older Tab switch.
    public var layerAcceptWordKey: AcceptKey? {
        acceptWordKey ?? tabAcceptEnabled.map { $0 ? .shortcuts : .off }
    }

    /// The shell-command mode this layer sets, counting the older switch.
    public var layerShellCommandMode: ShellCommandMode? {
        shellCommandMode ?? shellCommandsEnabled.map { $0 ? .always : .never }
    }
}

/// What a terminal suggests: shell commands at the shell prompt (`always`), prose in AI agent
/// prompts only (`never`), or whichever the window title shows is running (`automatic`).
public enum ShellCommandMode: String, Codable, Sendable, CaseIterable {
    case automatic, always, never
}

/// An app, a site, or a category's own settings (the layer between the built-in rule and the
/// app's or site's choices; see `AppCategories`).
public enum PolicyKey: Hashable, Codable, Sendable {
    case app(bundleID: String)
    case domain(pattern: String)
    case category(name: String)

    /// An app or a site (a place that can be listed and categorized), not a category.
    public var isPlace: Bool {
        if case .category = self { false } else { true }
    }
}

public struct ResolvedPolicy: Sendable, Equatable {
    public let policy: AppPolicy
    /// Which layers contributed, lowest first. For the Settings UI and debugging.
    public let sources: [PolicyKey]
    /// The layer whose instructions are in effect (the app or site itself, or its category); nil
    /// when none has any.
    public let instructionsSource: PolicyKey?
    public init(policy: AppPolicy, sources: [PolicyKey], instructionsSource: PolicyKey? = nil) {
        self.policy = policy
        self.sources = sources
        self.instructionsSource = instructionsSource
    }
}

public protocol AppPolicyResolving: Sendable {
    func resolve(bundleID: String, urlHost: String?) -> ResolvedPolicy
}

public protocol AppPolicyStoring: AnyObject {
    var userPatches: [PolicyKey: AppPolicyPatch] { get }
    func setPatch(_ patch: AppPolicyPatch?, for key: PolicyKey) throws
}
