import Foundation
import HunchCore

/// What a whole-field rewrite pass (autocorrect's Top strength) sends the model.
public struct RewriteRequest: Sendable, Equatable {
    /// The part the model may correct (whole sentences up to the caret).
    public var target: String
    /// The field's text before the target and after the caret (reference only).
    public var before: String
    public var after: String
    public var surface: SurfaceKind
    public var appName: String?
    /// Names and terms on the screen, spelled as they appear there.
    public var screenWords: [String]
    /// The app's autocorrect switches, as the prompt words them.
    public var fixesCapitals: Bool
    public var fixesPunctuation: Bool
    public var keepsShorthand: Bool

    public init(target: String, before: String = "", after: String = "", surface: SurfaceKind = .unknown,
                appName: String? = nil, screenWords: [String] = [], fixesCapitals: Bool = true,
                fixesPunctuation: Bool = true, keepsShorthand: Bool = false) {
        self.target = target
        self.before = before
        self.after = after
        self.surface = surface
        self.appName = appName
        self.screenWords = screenWords
        self.fixesCapitals = fixesCapitals
        self.fixesPunctuation = fixesPunctuation
        self.keepsShorthand = keepsShorthand
    }
}

/// The prompt for a rewrite pass: one user turn with the job (stable, so its tokens stay cached
/// across passes), the place and reference text, then the text to correct last. Instruct models
/// only; the model answers with the corrected text, which `FieldRewrite` compares word by word.
public struct RewriteFramer: Sendable {
    public static let frameID = "rewrite-v1"

    public init() {}

    static let job = """
        I type fast and make slips. Correct only my slips in the text at the end: misspelled or garbled \
        words, words run together or split apart, a real word typed by mistake for another one (form for \
        from, their for there, of for off, then for than), a small word I left out or typed twice, and \
        small grammar slips (he go for he goes, a apple for an apple). Leave everything else exactly as I \
        wrote it: my words, word order, tone and slang. Do not rephrase, do not make it more formal or \
        polished, and do not add or remove anything I meant to say. Names, terms, links, numbers and code \
        stay as they are. If nothing needs fixing, repeat my text unchanged. Output only the corrected text, \
        with no notes or quotation marks.

        Example. My text: i realy think we shoud move the the meeting form monday, its to early
        Corrected: i really think we should move the meeting from monday, its too early
        """

    static let keepCapitals = "Keep my capitalization as it is, even where it is all lowercase."
    static let keepPunctuation = "Keep my punctuation and apostrophes as they are."
    static let fixPunctuation = "Fix missing apostrophes (dont for don't) and doubled or missing sentence punctuation."
    static let keepShorthand = "Chat shorthand (idk, tbh, u, ur, rn, lol) is on purpose: keep it."

    static let placePrefix = "\n\nWhere I am typing: "
    static let screenPrefix = "\n\nNames and terms on my screen, spelled as they should be: "
    static let beforePrefix = "\n\nEarlier text in the box, already checked (reference only; do not repeat it):\n"
    static let afterPrefix = "\n\nText after my cursor (reference only; do not repeat it):\n"
    static let targetPrefix = "\n\nMy text:\n"

    /// Characters of reference text kept on each side.
    static let beforeLimit = 800
    static let afterLimit = 300
    static let screenWordLimit = 40

    public func frame(_ request: RewriteRequest, markers: ChatMarkers) -> FramedPrompt {
        var job = Self.job
        var rules: [String] = []
        if !request.fixesCapitals { rules.append(Self.keepCapitals) }
        rules.append(request.fixesPunctuation ? Self.fixPunctuation : Self.keepPunctuation)
        if request.keepsShorthand { rules.append(Self.keepShorthand) }
        job += "\n\n" + rules.joined(separator: " ")
        var segments = [PromptSegment(text: markers.userOpen, kind: .control, stability: .stable),
                        PromptSegment(text: job, kind: .control, stability: .stable, label: "task")]
        var place = Self.surfaceWords(request.surface)
        if let app = request.appName?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            place = place.map { "\($0) in \(app)" } ?? app
        }
        if let place {
            segments.append(PromptSegment(text: Self.placePrefix + place + ".", kind: .content, stability: .perField))
        }
        let words = Array(request.screenWords.prefix(Self.screenWordLimit))
        if !words.isEmpty {
            segments.append(PromptSegment(text: Self.screenPrefix + words.joined(separator: ", ") + ".",
                                          kind: .content, stability: .perField))
        }
        let before = Self.tail(request.before, Self.beforeLimit)
        if !before.isEmpty {
            segments.append(PromptSegment(text: Self.beforePrefix + before, kind: .content, stability: .perKeystroke))
        }
        let after = Self.head(request.after, Self.afterLimit)
        if !after.isEmpty {
            segments.append(PromptSegment(text: Self.afterPrefix + after, kind: .content, stability: .perKeystroke))
        }
        segments.append(PromptSegment(text: Self.targetPrefix, kind: .control, stability: .perKeystroke))
        segments.append(PromptSegment(text: request.target, kind: .content, stability: .perKeystroke, label: "target"))
        segments.append(PromptSegment(text: markers.turnClose, kind: .control, stability: .perKeystroke))
        segments.append(PromptSegment(text: markers.assistantOpen, kind: .control, stability: .perKeystroke))
        if let off = markers.reasoningOff {
            segments.append(PromptSegment(text: off, kind: .control, stability: .perKeystroke))
        }
        return FramedPrompt(segments: segments, requiredPrefix: "", framerID: Self.frameID, style: .chatPrefill)
    }

    static func surfaceWords(_ surface: SurfaceKind) -> String? {
        switch surface {
        case .chat: "a chat message"
        case .email: "an email"
        case .document: "a document"
        case .note: "a note"
        case .search: "a search box"
        default: nil
        }
    }

    /// The last `limit` characters, from a word start.
    static func tail(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        let cut = String(t.suffix(limit))
        guard let space = cut.firstIndex(where: \.isWhitespace) else { return cut }
        return "…" + cut[space...].trimmingCharacters(in: .whitespaces)
    }

    static func head(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        let cut = String(t.prefix(limit))
        guard let space = cut.lastIndex(where: \.isWhitespace) else { return cut }
        return cut[..<space] + "…"
    }
}
