import Foundation

public enum SuppressReason: String, Sendable, Codable {
    case empty, punctuationOnly, aiVoice, metaReply, echoesBefore, echoesAfter, repetitionLoop
    case lowConfidence, likelyTypo, markupLeak, tooShort, copiesStyleExample, foreignScript
    /// The completion is a web address (outside search fields).
    case webAddress
    /// The completion goes on to repeat a run of on-screen text word for word.
    case copiesScreen
}

public enum PostOutcome: Sendable, Equatable {
    case show(String)
    case suppress(SuppressReason)
}

/// How a suggestion's quotes are written: like the field's existing ones, or always straight.
public enum QuotePreference: String, Sendable, Codable, Equatable { case matchField, straight }

public struct PostContext: Sendable, Equatable {
    public var before: String
    public var after: String
    public var requiredPrefix: String
    public var allowNewlines: Bool
    public var maxWords: Int
    /// Earlier sentences shown to the model as style background; a completion that repeats a run of them is dropped.
    public var styleExamples: [String]
    /// On-screen text shown to the model as reference; a completion that repeats a long run of it is cut.
    public var screenText: String?
    /// Script names (see `ScriptGuard`) the writer can type or already uses; letters in any other script
    /// cut the completion. nil disables the guard.
    public var allowedScripts: Set<String>?
    /// Han variant of the writer's Chinese keyboards; used when the surrounding text does not decide.
    public var preferredHanScript: HanVariant?
    /// Quotes as the field uses them, or always straight (the app or site turned smart quotes off).
    public var quoteStyle: QuotePreference
    /// Web-address completions are allowed (search fields, code); elsewhere they are cut or suppressed.
    public var allowsURLs: Bool
    /// What kind of field the text is for. `.code` switches the processor to its code profile
    /// (no typo or quote rules, character-based clamp) and `.shell` to its command profile (one
    /// line, no prose rules); every other kind uses the prose rules.
    public var surface: SurfaceKind
    /// Learned words the request put in play (vocabulary notes, mid-word bias entries): a completion
    /// of the half-typed word that starts one of them but ends as neither it nor a dictionary word is
    /// dropped (`TypoDetector`), so "microsp" never becomes "microspeak".
    public var learnedWords: [String] = []
    public init(before: String, after: String, requiredPrefix: String, allowNewlines: Bool, maxWords: Int,
                styleExamples: [String] = [], allowedScripts: Set<String>? = nil,
                preferredHanScript: HanVariant? = nil, quoteStyle: QuotePreference = .matchField,
                allowsURLs: Bool = false, surface: SurfaceKind = .unknown, screenText: String? = nil) {
        self.screenText = screenText
        self.surface = surface
        self.allowsURLs = allowsURLs
        self.quoteStyle = quoteStyle
        self.preferredHanScript = preferredHanScript
        self.allowedScripts = allowedScripts
        self.styleExamples = styleExamples
        self.before = before
        self.after = after
        self.requiredPrefix = requiredPrefix
        self.allowNewlines = allowNewlines
        self.maxWords = maxWords
    }
}

extension PostContext {
    /// Web addresses belong in search fields, code and shell commands; in prose they come from screen text.
    public static func allowsURLs(on surface: SurfaceKind) -> Bool { [.search, .code, .shell].contains(surface) }
}

public protocol SuggestionPostProcessing: Sendable {
    func process(_ raw: String, meanLogProb: Float?, context: PostContext) -> PostOutcome
}

public protocol AIVoiceClassifying: Sendable {
    func isAIVoice(before: String, completion: String) -> Bool
}

public struct WordUnitOptions: Codable, Sendable, Equatable {
    public var includeTrailingSpace: Bool
    public var includeTrailingPunctuation: Bool
    public init(includeTrailingSpace: Bool = false, includeTrailingPunctuation: Bool = false) {
        self.includeTrailingSpace = includeTrailingSpace
        self.includeTrailingPunctuation = includeTrailingPunctuation
    }
}

public protocol WordSegmenting: Sendable {
    /// Splits a suggestion into acceptance units; leading whitespace belongs to the unit it precedes.
    func units(of suggestion: String, options: WordUnitOptions) -> [Substring]
}

public protocol SentenceBoundaryDetecting: Sendable {
    func isSentenceEnd(text: String, at index: String.Index) -> Bool
}

/// Which Chinese script a writer uses.
public enum HanVariant: String, Sendable, Equatable, CaseIterable {
    case traditional, simplified
}
