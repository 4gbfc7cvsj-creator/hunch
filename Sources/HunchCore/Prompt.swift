import Foundation

public enum ModelFamily: String, Codable, Sendable, CaseIterable { case gemma, qwen, llama, phi, mistral, smollm, unknown }
public enum FramingStyle: String, Codable, Sendable, CaseIterable { case document, chatPrefill }

/// Literal control-token strings for one chat-template family. Verified against the loaded
/// vocabulary at load time (each must tokenize to a single control token).
public struct ChatMarkers: Sendable, Equatable {
    public var bos: String?
    public var systemOpen: String?
    public var userOpen: String
    public var turnClose: String
    public var assistantOpen: String
    public var reasoningOff: String?
    public init(bos: String? = nil, systemOpen: String? = nil, userOpen: String, turnClose: String,
                assistantOpen: String, reasoningOff: String? = nil) {
        self.bos = bos
        self.systemOpen = systemOpen
        self.userOpen = userOpen
        self.turnClose = turnClose
        self.assistantOpen = assistantOpen
        self.reasoningOff = reasoningOff
    }
}

public struct ModelProfile: Sendable, Equatable {
    public var family: ModelFamily
    public var isInstruct: Bool
    public var markers: ChatMarkers?
    public var addsBOS: Bool
    public var contextLength: Int
    public var slidingWindow: Int?
    public var architecture: String
    public var displayName: String
    public init(family: ModelFamily, isInstruct: Bool, markers: ChatMarkers?, addsBOS: Bool, contextLength: Int,
                slidingWindow: Int?, architecture: String, displayName: String) {
        self.family = family
        self.isInstruct = isInstruct
        self.markers = markers
        self.addsBOS = addsBOS
        self.contextLength = contextLength
        self.slidingWindow = slidingWindow
        self.architecture = architecture
        self.displayName = displayName
    }
}

public protocol ModelProfileDetecting: Sendable {
    /// From GGUF metadata (general.type, general.finetune, general.name, tokenizer.chat_template,
    /// architecture), with the file name as a tie-breaker. Pure.
    func detect(_ summary: GGUFSummary, fileName: String) -> ModelProfile
}

/// How often a prompt segment changes. Ordering segments stable → perKeystroke maximizes KV reuse.
public enum SegmentStability: Int, Sendable, Comparable {
    case stable, perField, perKeystroke
    public static func < (lhs: SegmentStability, rhs: SegmentStability) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SegmentKind: Sendable, Equatable {
    /// Framer-authored control text; tokenized WITH special-token parsing.
    case control
    /// User or field text; tokenized with special-token parsing OFF (injection safety).
    case content
}

public struct PromptSegment: Sendable, Equatable {
    public var text: String
    public var kind: SegmentKind
    public var stability: SegmentStability
    /// Which prompt block this is ("writer: About the writer", "screen", "text"), for the debug
    /// prompt log's per-block token counts. Never part of the prompt.
    public var label: String?
    public init(text: String, kind: SegmentKind, stability: SegmentStability, label: String? = nil) {
        self.label = label
        self.text = text
        self.kind = kind
        self.stability = stability
    }

    /// The label is debug metadata, not prompt text: equality ignores it.
    public static func == (lhs: PromptSegment, rhs: PromptSegment) -> Bool {
        lhs.text == rhs.text && lhs.kind == rhs.kind && lhs.stability == rhs.stability
    }
}

public struct PromptInput: Sendable, Equatable {
    public var before: String
    public var after: String
    public var surface: SurfaceKind
    /// The user's single "Custom instructions" text (who they are, languages, style).
    public var globalInstructions: String?
    public var appInstructions: String?
    /// A suggestion style picked with the style keys ("Casual", "Concise"): its instructions, which
    /// framers put last, nearest the text, so they win over the tone and length notes above.
    public var styleInstructions: String? = nil
    /// Facts about the writer the app knows on its own (their name, when allowed). Who they are and
    /// how they write otherwise lives in the custom instructions (decision 7).
    public var aboutWriter: String?
    public var preferredLanguages: [String]
    public var maxWords: Int
    public var allowNewlines: Bool
    /// Opt-in screen context (M2 track S): bounded, sanitized OCR text near the field. Never stored.
    public var screenContext: String?
    /// Interface lines next to the field (status boxes, toolbars) left out of `screenContext`.
    /// Diagnostics only.
    public var screenInterfaceDropped = 0
    /// Most tokens of `screenContext` a framer puts in the prompt (the lines nearest the field are
    /// kept); nil = only the overall prompt budget limits it.
    public var screenTokenLimit: Int?
    /// Opt-in clipboard context (M3): recently copied plain text, bounded and sanitized by the app.
    /// Background only; never stored.
    public var clipboard: String?
    /// Where the user is writing (background): the app's display name ("Discord"), the site for
    /// browsers ("mail.google.com"), and, when the user opted in, the window title.
    public var appName: String?
    public var domain: String?
    public var windowTitle: String?
    /// The field's own label or placeholder ("Subject", "Message #general", "Reply to Alex…"):
    /// what kind of text belongs there. UI metadata, not typed text.
    public var fieldLabel: String?
    /// Earlier sentences the user wrote, chosen for relevance to the current text (M4). Background for
    /// tone and word choice only; never stored, and never sent to non-loopback endpoints.
    public var styleExamples: [String]
    /// Writing systems the user can type (enabled keyboards) plus Latin; nil = no script guard. Names as in `ScriptGuard`.
    public var allowedScripts: Set<String>?
    /// Han variant implied by the enabled Chinese keyboards (nil when unknown or both).
    public var preferredHanScript: HanVariant?
    /// Quote handling for the post-processor (`.straight` when the app or site turned smart quotes off).
    public var quoteStyle: QuotePreference
    /// The writer's own words and names for this app or its category (learned words, strongest first
    /// or in a stable order), for framers that list them as notes. Kept stable per app so the prompt
    /// prefix stays cacheable; empty = none. Framers without a vocabulary label ignore it.
    public var vocabulary: [String] = []
    public init(before: String, after: String = "", surface: SurfaceKind = .unknown, globalInstructions: String? = nil,
                appInstructions: String? = nil, aboutWriter: String? = nil, preferredLanguages: [String] = [],
                maxWords: Int = 6, allowNewlines: Bool = false, screenContext: String? = nil,
                clipboard: String? = nil, appName: String? = nil, domain: String? = nil, windowTitle: String? = nil,
                styleExamples: [String] = [], allowedScripts: Set<String>? = nil,
                preferredHanScript: HanVariant? = nil, fieldLabel: String? = nil,
                quoteStyle: QuotePreference = .matchField) {
        self.quoteStyle = quoteStyle
        self.fieldLabel = fieldLabel
        self.preferredHanScript = preferredHanScript
        self.allowedScripts = allowedScripts
        self.styleExamples = styleExamples
        self.clipboard = clipboard
        self.appName = appName
        self.domain = domain
        self.windowTitle = windowTitle
        self.before = before
        self.after = after
        self.surface = surface
        self.globalInstructions = globalInstructions
        self.appInstructions = appInstructions
        self.aboutWriter = aboutWriter
        self.preferredLanguages = preferredLanguages
        self.maxWords = maxWords
        self.allowNewlines = allowNewlines
        self.screenContext = screenContext
    }
}

/// Result of moving the trailing whitespace + partial word out of the prompt (§5.2 "healing").
public struct HealingSplit: Sendable, Equatable {
    public var promptText: String
    public var requiredPrefix: String
    public init(promptText: String, requiredPrefix: String) {
        self.promptText = promptText
        self.requiredPrefix = requiredPrefix
    }
}

public struct FramedPrompt: Sendable, Equatable {
    /// Ordered stable → perField → perKeystroke; the caret text is always last.
    public var segments: [PromptSegment]
    /// Healed bytes the output must start with; stripped before display.
    public var requiredPrefix: String
    public var framerID: String
    public var style: FramingStyle
    /// Blocks the token budget dropped or shortened (diagnostic console only; not part of the prompt).
    public var budgetNotes: [BudgetNote]
    public init(segments: [PromptSegment], requiredPrefix: String, framerID: String, style: FramingStyle,
                budgetNotes: [BudgetNote] = []) {
        self.segments = segments
        self.requiredPrefix = requiredPrefix
        self.framerID = framerID
        self.style = style
        self.budgetNotes = budgetNotes
    }
}

public protocol TokenCounting: Sendable {
    func tokenCount(_ text: String) -> Int
}

public protocol PromptFramer: Sendable {
    var id: String { get }
    var style: FramingStyle { get }
    func supports(_ profile: ModelProfile) -> Bool
    func frame(_ input: PromptInput, profile: ModelProfile, budget: Int, counter: any TokenCounting) -> FramedPrompt
    /// The framer names the writer's learned words in the prompt (`PromptInput.vocabulary`). The engine
    /// then keeps only the learned-word bias that finishes a half-typed word (`LearnedBias.midWordOnly`);
    /// framers that don't (base models' document framing) get the full bias, as before.
    var listsVocabulary: Bool { get }
}

extension PromptFramer {
    public var listsVocabulary: Bool { false }
}

public protocol FramerRegistry: Sendable {
    func framer(for profile: ModelProfile, override: String?) -> any PromptFramer
    var all: [any PromptFramer] { get }
}

/// Text recognized on screen near the focused field (M2 track S). The screenshot itself is
/// discarded immediately after OCR and never stored or logged.
public struct ScreenExcerpt: Sendable, Equatable {
    public var text: String
    public var capturedAt: ContinuousClock.Instant
    /// Hash of the captured pixels' recognized lines; unchanged → reuse, no new generation.
    public var signature: UInt64
    /// Interface lines next to the field (status boxes, toolbars) left out of `text`.
    public var interfaceDropped = 0
    /// Message blocks labeled "Me" because they match a sent message, and blocks whose "Me" label was
    /// taken away for matching nothing sent below the newest match.
    public var sentConfirmed = 0
    public var sentVetoed = 0
    /// List chats (Discord): the writer's avatar, learned on this read from a group holding a message
    /// they sent, to be remembered for later reads.
    public var learnedAvatars: [MyAvatar] = []
    public init(text: String, capturedAt: ContinuousClock.Instant, signature: UInt64) {
        self.text = text
        self.capturedAt = capturedAt
        self.signature = signature
    }
}
