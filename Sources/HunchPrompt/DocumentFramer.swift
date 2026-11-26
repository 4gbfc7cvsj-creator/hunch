import Foundation
import HunchCore

/// Base-model framing (design §5.1, style `document`): a short, neutral document-genre header,
/// optional notes about the writer and the piece, a blank line, then the healed before-caret
/// text last. No framer-authored text mentions machines, assistants, or completion of any kind;
/// a unit test enforces this.
///
/// `DocumentFramer()` is v1; `DocumentFramer(.v2)` names the writer's notes as the rules the text
/// follows and labels reference text as not part of the piece.
public struct DocumentFramer: PromptFramer {
    public static let frameID = "document-v1"
    public static let frameIDv2 = "document-v2"

    /// Framer-authored text. Versioned: a wording change needs a new id.
    public struct Wording: Sendable, Equatable {
        var id: String
        var header: String
        var writerNotes: String
        var aboutWriter: String
        var languages: String
        var surface: String
        var place: String
        var appNotes: String
        var screen: String
        var clipboard: String
        var style: String
        var after: String
        /// Header for a code buffer, in place of `header`.
        var codeHeader: String
        /// Label on its own line between the context and the writer's text, used only when screen text
        /// is shown (v3 experiments).
        var caretLabel = ""
        /// Extra words after the "Kind of text" phrase, per surface (v3 experiments).
        var surfaceHints: [SurfaceKind: String] = [:]
        /// Header in Chinese (traditional, simplified) for Chinese-dominant text (v3 experiments).
        var chineseHeaders: [String] = []

        public static let v1 = Wording(
            id: DocumentFramer.frameID,
            header: "A personal piece of writing, reproduced exactly as its author typed it.",
            writerNotes: "Notes on the writer and their style: ",
            aboutWriter: "About the writer: ",
            languages: "Languages the writer uses: ",
            surface: "Kind of text: ",
            place: "Place of writing: ",
            appNotes: "Notes on this piece: ",
            screen: "Nearby text visible alongside this piece (reference):\n",
            clipboard: "Passage the writer recently copied (reference):\n",
            style: "Earlier sentences by the same writer (for tone and word choice only): ",
            after: "Text that already follows this passage (reference): ",
            codeHeader: "A source file, reproduced exactly as its author typed it.")

        public static let v2 = Wording(
            id: DocumentFramer.frameIDv2,
            header: "Written by one person in their own words, exactly as they typed it.",
            writerNotes: "The author's own notes on how they write, which this text follows: ",
            aboutWriter: "About the author: ",
            languages: "The author writes in: ",
            surface: "Type of writing: ",
            place: "Where this piece was typed: ",
            appNotes: "The author's notes for this piece, which it follows: ",
            screen: "Material the author had open nearby (not part of this text):\n",
            clipboard: "Excerpt the author copied earlier (not part of this text):\n",
            style: "Earlier lines by this author, showing how they phrase things (not part of this text): ",
            after: "Text that comes later in this piece (not to be repeated here): ",
            codeHeader: "Source code written by one person, exactly as they typed it.")

        // MARK: v3 screening wordings (2026-11-07 base framer bake-off, stage 1). Each is v1 plus one
        // change; three per goal: grounding in the screen (a), consistency (b), kind of text (c).

        private static func v3(_ id: String, _ edit: (inout Wording) -> Void) -> Wording {
            var w = v1
            w.id = id
            edit(&w)
            return w
        }

        static let screenNewestLast = "The conversation or page open alongside this piece, oldest first; "
            + "its last lines are the newest, just before this piece (reference):\n"
        static let followsOn = "The author's piece, which follows on from the text above:"
        static let consistent = " The author had read the text shown alongside it, and the piece stays consistent with it."
        static let noInvented = " It mentions no names, dates, or facts beyond what the surrounding text gives."
        static let both = " The author had read the text shown alongside it; the piece stays consistent with it "
            + "and adds no names, dates, or facts that it does not give."
        static let casualHints: [SurfaceKind: String] = [
            .chat: ", typed casually, the way people text",
            .agentPrompt: ", typed quickly in plain everyday words",
            .note: ", short notes for the author's own use",
        ]
        static let chinese = ["一篇個人撰寫的文字，完全照作者輸入的原樣呈現。", "一篇个人撰写的文字，完全照作者输入的原样呈现。"]

        /// a1: the screen block says what it is and where its newest lines are.
        public static let v3a1 = v3("document-v3a1") { $0.screen = screenNewestLast }
        /// a2: a label just before the text ties it to the screen text above.
        public static let v3a2 = v3("document-v3a2") { $0.caretLabel = followsOn }
        /// a3: a1 and a2 together.
        public static let v3a3 = v3("document-v3a3") {
            $0.screen = screenNewestLast
            $0.caretLabel = followsOn
        }
        /// b1: the piece is consistent with what is shown alongside it.
        public static let v3b1 = v3("document-v3b1") { $0.header += consistent }
        /// b2: no invented specifics.
        public static let v3b2 = v3("document-v3b2") { $0.header += noInvented }
        /// b3: both in one sentence.
        public static let v3b3 = v3("document-v3b3") { $0.header += both }
        /// c1: register hint on the kind-of-text line for casual surfaces.
        public static let v3c1 = v3("document-v3c1") { $0.surfaceHints = casualHints }
        /// c2: the header in Chinese when the text is mostly Chinese.
        public static let v3c2 = v3("document-v3c2") { $0.chineseHeaders = chinese }
        /// c3: c1 and c2 together.
        public static let v3c3 = v3("document-v3c3") {
            $0.surfaceHints = casualHints
            $0.chineseHeaders = chinese
        }

        public static let v3Screening: [Wording] = [v3a1, v3a2, v3a3, v3b1, v3b2, v3b3, v3c1, v3c2, v3c3]

        // MARK: v4 bake-off combinations of the stage-1 winners (a1 screen label, b3 consistency,
        // c3 register hints + Chinese header). With c3, mostly-Chinese text gets the Chinese header
        // instead of the English one, so the b3 sentence is not shown for it.

        /// v4a: a1 + b3.
        public static let v4a = v3("document-v4a") {
            $0.screen = screenNewestLast
            $0.header += both
        }
        /// v4b: a1 + b3 + c3.
        public static let v4b = v3("document-v4b") {
            $0.screen = screenNewestLast
            $0.header += both
            $0.surfaceHints = casualHints
            $0.chineseHeaders = chinese
        }
        /// v4c: b3 + c3.
        public static let v4c = v3("document-v4c") {
            $0.header += both
            $0.surfaceHints = casualHints
            $0.chineseHeaders = chinese
        }

        public static let v4Combinations: [Wording] = [v4a, v4b, v4c]
    }

    /// Every framer-authored header and label across wordings, for an echo-of-preface check in the
    /// post-processor (`DefaultPostProcessor.prefaceTexts`). Labels are trimmed of trailing colons/spaces.
    public static var prefacePhrases: [String] {
        ([Wording.v1, Wording.v2] + Wording.v3Screening + Wording.v4Combinations).flatMap { w in
            [w.header, w.codeHeader, w.writerNotes, w.aboutWriter, w.languages, w.surface, w.place, w.appNotes, w.screen,
             w.clipboard, w.style, w.after, w.caretLabel] + w.chineseHeaders
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))) }
            .filter { !$0.isEmpty }
    }

    /// v1 header (kept for tests and comparison).
    static var header: String { Wording.v1.header }

    public let wording: Wording
    /// Secret redaction for user-derived text, cached per field.
    private let redactor = PromptRedactor()

    public init(_ wording: Wording = .v1) {
        self.wording = wording
    }

    /// Fewer CJK characters than this (with no earlier line) counts as a short start.
    static let shortCJKLimit = 12

    /// True when the text so far is one line, CJK-dominant, and shorter than `shortCJKLimit` CJK
    /// characters: the header is dropped for such prefixes.
    static func isShortCJKStart(_ before: String) -> Bool {
        let body = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !body.contains(where: \.isNewline) else { return false }
        var cjk = 0, latin = 0
        for c in body {
            if TextClass.isCJK(c) { cjk += 1 } else if c.isLetter { latin += 1 }
        }
        return cjk > 0 && cjk < shortCJKLimit && cjk >= latin
    }

    /// True when the text's last 200 characters are mostly Chinese (Han, no kana): the v3c header
    /// switches to Chinese for such text.
    static func isChineseDominant(_ before: String) -> Bool {
        var han = 0, latin = 0
        for c in before.suffix(200) {
            if c.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return false }
            if TextClass.isCJK(c) { han += 1 } else if c.isLetter { latin += 1 }
        }
        return han > 0 && han >= latin
    }

    public var id: String { wording.id }
    public var style: FramingStyle { .document }
    public func supports(_ profile: ModelProfile) -> Bool { true }

    public func frame(_ input: PromptInput, profile: ModelProfile, budget: Int,
                      counter: any TokenCounting) -> FramedPrompt {
        let input = redactor.redacted(input)
        let w = wording
        let healed = Healing.split(before: input.before)
        var layout: [LayoutItem] = []
        // A short Chinese/Japanese start gives the model too little to anchor on, and it tends to
        // echo (or translate) the English header as the continuation. Nothing to echo, nothing leaks.
        let omitHeader = Self.isShortCJKStart(input.before)
        if !omitHeader {
            // A code buffer is a source file, not a piece of writing.
            var header = input.surface == .code ? w.codeHeader : w.header
            if input.surface != .code, w.chineseHeaders.count == 2, Self.isChineseDominant(input.before) {
                header = HanScript.usesSimplified(input.before) && !HanScript.usesTraditional(input.before)
                    ? w.chineseHeaders[1] : w.chineseHeaders[0]
            }
            layout.append(.block(Block(prefix: header, content: "", suffix: "\n", priority: .instruction,
                                       stability: .stable, keep: .whole)))
        }
        // Who the writer is, then how they write.
        if let about = cleaned(input.aboutWriter) {
            layout.append(.block(Block(prefix: w.aboutWriter, content: about, suffix: "\n",
                                       priority: .writer, stability: .stable)))
        }
        if let notes = cleaned(input.globalInstructions) {
            layout.append(.block(Block(prefix: w.writerNotes, content: notes, suffix: "\n",
                                       priority: .writer, stability: .stable)))
        }
        if let languages = languageList(input.preferredLanguages) {
            layout.append(.block(Block(prefix: w.languages, content: languages, suffix: "\n",
                                       priority: .writer, stability: .stable)))
        }
        if let kind = surfacePhrase(input.surface, windowTitle: input.windowTitle) {
            layout.append(.block(Block(prefix: w.surface, content: kind,
                                       suffix: (w.surfaceHints[input.surface] ?? "") + "\n",
                                       priority: .instruction, stability: .perField, keep: .whole)))
        }
        if let place = placeDescription(appName: input.appName, domain: input.domain, windowTitle: input.windowTitle,
                                         field: input.fieldLabel) {
            layout.append(.block(Block(prefix: w.place, content: place, suffix: "\n",
                                       priority: .place, stability: .perField, keep: .whole)))
        }
        if let notes = cleaned(input.appInstructions) {
            layout.append(.block(Block(prefix: w.appNotes, content: notes, suffix: "\n",
                                       priority: .appInstructions, stability: .perField)))
        }
        if let style = cleaned(input.styleInstructions) {
            layout.append(.block(Block(prefix: "Style for what follows: ", content: style, suffix: "\n",
                                       priority: .instruction, stability: .perField, keep: .whole)))
        }
        let screen = cleaned(input.screenContext)
        if let screen {
            layout.append(.block(Block(prefix: w.screen,
                                       content: screen, suffix: "\n", priority: .screen, stability: .perField,
                                       // Reading order puts the lines just above the field last: keep them.
                                       keep: .end, maxContentTokens: input.screenTokenLimit)))
        }
        if let clip = clipboardBackground(input) {
            layout.append(.block(Block(prefix: w.clipboard, content: clip, suffix: "\n", priority: .clipboard,
                                       stability: .perField, maxContentTokens: clipboardTokenLimit)))
        }
        if let style = styleBackground(input, counter: counter) {
            layout.append(.block(Block(prefix: w.style, content: style, suffix: "\n", priority: .style,
                                       stability: .perField, keep: .whole)))
        }
        if let after = cleaned(input.after) {
            layout.append(.block(Block(prefix: w.after,
                                       content: after, suffix: "\n", priority: .afterCaret, stability: .perField,
                                       maxContentTokens: 64)))
        }
        if !layout.isEmpty {
            layout.append(.fixed(PromptSegment(text: "\n", kind: .content, stability: .perField)))
        }
        if screen != nil, !w.caretLabel.isEmpty {
            layout.append(.fixed(PromptSegment(text: w.caretLabel + "\n", kind: .content, stability: .perField)))
        }
        layout.append(.caret)

        let assembled = FrameAssembler.assembleNoted(layout: layout, caretText: healed.promptText, budget: budget,
                                                     counter: counter)
        return FramedPrompt(segments: assembled.segments, requiredPrefix: healed.requiredPrefix, framerID: id,
                            style: style, budgetNotes: assembled.notes)
    }
}
