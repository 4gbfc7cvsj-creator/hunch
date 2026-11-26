import HunchCore

/// Instruct-model framing (design §5.1, style `chatPrefill`):
/// user turn [instruction + optional context] → turn close → model turn opened → the healed
/// before-caret text as the start of the model's own reply. The model therefore continues the
/// person's text instead of answering them. Markers are `.control`; everything else `.content`.
/// The model's turn is left open on purpose.
///
/// Two wordings exist side by side so the eval can compare them (`ChatPrefillFramer()` is v1,
/// `ChatPrefillFramer(.v2)` is v2). v2 separates the writer's own instructions, which the model
/// must follow, from reference text (screen, after-caret), which it must not copy.
public struct ChatPrefillFramer: PromptFramer {
    public static let frameID = "chat-prefill-v1"
    public static let frameIDv2 = "chat-prefill-v2"
    public static let frameIDv5 = "chat-prefill-v5"

    /// Framer-authored text. Versioned: a wording change needs a new id.
    public struct Wording: Sendable, Equatable {
        var id: String
        var instruction: String
        var writerNotes: String
        var aboutWriter: String
        var languages: String
        var surfacePrefix: String
        var surfaceSuffix: String
        var placePrefix: String
        var placeSuffix: String
        var appNotes: String
        var screen: String
        var clipboard: String
        var style: String
        var after: String
        /// Instruction for a code buffer, in place of `instruction`.
        var codeInstruction: String
        /// Put the writing samples before the screen text, so the newest screen lines sit closest to
        /// the writer's text (v6 experiments).
        var samplesBeforeScreen = false
        /// Extra sentence after the surface line, per surface (v6 experiments).
        var surfaceHints: [SurfaceKind: String] = [:]
        /// Label for the writer's learned words (`PromptInput.vocabulary`); nil leaves them out.
        var vocabulary: String? = nil
        /// Put the vocabulary block last, just before the turn closes, for a list that can change
        /// from keystroke to keystroke (gated notes): only that block and the caret text are reprocessed.
        var vocabularyLast = false

        /// Wording v1.
        public static let v1 = Wording(
            id: ChatPrefillFramer.frameID,
            instruction: """
                Continue my text from the exact point where it stops, writing the next few words as me. \
                Match my voice, tone, and language, and keep my point of view. \
                Write only the continuation itself; never reply to me, explain, or add quotation marks. \
                Anything below is background only.
                """,
            writerNotes: "\n\nAbout me and how I write:\n",
            aboutWriter: "\n\nAbout me:\n",
            languages: "\n\nLanguages I write in: ",
            surfacePrefix: "\n\nI am writing ", surfaceSuffix: ".",
            placePrefix: "\n\nI am typing in ", placeSuffix: ".",
            appNotes: "\n\nNotes for this app:\n",
            screen: "\n\nText visible on my screen near where I am typing (reference only):\n",
            clipboard: "\n\nText I copied a moment ago (reference only):\n",
            style: "\n\nSentences I wrote earlier, shown only for my tone and word choice:\n",
            after: "\n\nText that already comes after my cursor (reference only):\n",
            codeInstruction: """
                Continue my code from the exact point where it stops, writing the next few tokens as I would. \
                Keep my language, naming, and indentation. \
                Write only the continuation itself; never reply to me, explain, or add Markdown fences. \
                Anything below is background only.
                """)

        /// Wording v2: the writer's instructions are rules to follow; reference text is labeled
        /// as such where it appears instead of a blanket "background only" line.
        public static let v2 = Wording(
            id: ChatPrefillFramer.frameIDv2,
            instruction: """
                Help me finish what I am typing. Pick up exactly where my text breaks off and add the \
                next few words the way I would write them, in the same language, tone, and point of view. \
                Output only the continuation: no reply to me, no commentary, no quotation marks.
                """,
            writerNotes: "\n\nMy own instructions for how I write. Follow them:\n",
            aboutWriter: "\n\nAbout me:\n",
            languages: "\n\nI write in: ",
            surfacePrefix: "\n\nRight now I am writing ", surfaceSuffix: ".",
            placePrefix: "\n\nThe place I am typing this: ", placeSuffix: ".",
            appNotes: "\n\nMy instructions for this app. Follow them too:\n",
            screen: "\n\nFor reference only, text on my screen near my cursor. "
                + "Use it to understand the situation, but do not copy it:\n",
            clipboard: "\n\nFor reference only, something I copied a moment ago. "
                + "It may or may not be relevant; do not copy it:\n",
            style: "\n\nFor reference only, a few sentences I wrote earlier. "
                + "They show how I phrase things; do not repeat them:\n",
            after: "\n\nFor reference only, text that already follows my cursor. "
                + "Lead into it naturally, but do not repeat it:\n",
            codeInstruction: """
                Help me finish the line of code I am typing. Pick up exactly where it breaks off and add the \
                next few tokens the way I would write them, in the same language, naming, and indentation. \
                Output only the continuation: no reply to me, no commentary, no Markdown fences.
                """)

        /// Wording v5: v1 plus a line against the AI voice that instruct models fall into on openers
        /// such as "I am an". Phrased with no noun phrase the model could echo: v3/v4 ("I am a person
        /// typing my own words") got echoed as "I am a person typing my own", and examples were copied.
        public static let v5: Wording = {
            var w = v1
            w.id = ChatPrefillFramer.frameIDv5
            w.instruction = """
                Continue my text from the exact point where it stops, writing the next few words as me. \
                Match my voice, tone, and language, and keep my point of view. \
                The words are mine and speak for me; never write as an AI, an assistant, or a chatbot. \
                Write only the continuation itself; never reply to me, explain, or add quotation marks. \
                Anything below is background only.
                """
            return w
        }()

        // MARK: v6 screening wordings (2026-11-04 framer bake-off, stage 1). Each is v5 plus one
        // change; three per goal: context layout (a), consistency (b), voice (c).

        static let v5Lines = (
            start: "Continue my text from the exact point where it stops, writing the next few words as me. ",
            voice: "Match my voice, tone, and language, and keep my point of view. ",
            mine: "The words are mine and speak for me; never write as an AI, an assistant, or a chatbot. ",
            only: "Write only the continuation itself; never reply to me, explain, or add quotation marks. ",
            background: "Anything below is background only.")

        private static func v6(_ id: String, start: String = v5Lines.start, voice: String = v5Lines.voice,
                               extra: String = "", _ edit: (inout Wording) -> Void = { _ in }) -> Wording {
            var w = v5
            w.id = id
            let l = v5Lines
            w.instruction = start + voice + l.mine + l.only + l.background + extra
            edit(&w)
            return w
        }

        static let screenNewestLast = "\n\nThe conversation or page on my screen, oldest first; its last lines are "
            + "the newest, just above where I am typing (reference only):\n"

        /// a1: the screen block says what it is and where the newest lines are.
        public static let v6a1 = v6("chat-prefill-v6a1") { $0.screen = screenNewestLast }
        /// a2: samples before the screen, so the newest screen lines are nearest the text.
        public static let v6a2 = v6("chat-prefill-v6a2") { $0.samplesBeforeScreen = true }
        /// a3: a1 and a2 together.
        public static let v6a3 = v6("chat-prefill-v6a3") {
            $0.screen = screenNewestLast
            $0.samplesBeforeScreen = true
        }

        /// b1: consistency with what was said.
        public static let v6b1 = v6("chat-prefill-v6b1",
            extra: " Stay consistent with it: never contradict it or repeat back what someone just told me.")
        /// b2: no invented specifics.
        public static let v6b2 = v6("chat-prefill-v6b2",
            extra: " Never add names, dates, places, or other details that it does not mention.")
        /// b3: both in one sentence.
        public static let v6b3 = v6("chat-prefill-v6b3",
            extra: " Stay consistent with it: never contradict it, repeat it back, or add details it does not mention.")

        /// c1: the voice line points at the writer's own register; samples labeled as tone, not content.
        public static let v6c1 = v6("chat-prefill-v6c1",
            voice: "Match my voice, tone, and language as my own writing shows them, casual or formal, and keep my point of view. ") {
            $0.style = "\n\nSentences I wrote earlier; copy their tone and word choice, never their content:\n"
        }
        /// c2: one register sentence.
        public static let v6c2 = v6("chat-prefill-v6c2",
            extra: " Keep it exactly as casual or as formal as my own writing here, never more polished.")
        /// c3: register hint per surface for the casual ones.
        public static let v6c3 = v6("chat-prefill-v6c3") {
            $0.surfaceHints = [
                .chat: " I type these casually, the way I text.",
                .agentPrompt: " I type these quickly and plainly, in everyday words.",
            ]
        }

        public static let v6Screening: [Wording] = [v6a1, v6a2, v6a3, v6b1, v6b2, v6b3, v6c1, v6c2, v6c3]

        // MARK: v7 bake-off combinations of the stage-1 winners (a3 context, b3 consistency, c3 voice).

        /// v7a: a3 + b3.
        public static let v7a: Wording = {
            var w = v6a3
            w.id = "chat-prefill-v7a"
            w.instruction = v6b3.instruction
            return w
        }()
        /// v7b: a3 + b3 + c3.
        public static let v7b: Wording = {
            var w = v7a
            w.id = "chat-prefill-v7b"
            w.surfaceHints = v6c3.surfaceHints
            return w
        }()

        public static let v7Combinations: [Wording] = [v7a, v7b]

        // MARK: Instruction framing (2026-11-19): personal instructions shortened chat suggestions
        // ("Short and friendly" -> one-word suggestions). Each is v6b3 plus one change.

        /// i1: the writer's notes are labeled as notes about the whole finished message.
        public static let i1: Wording = {
            var w = v6b3
            w.id = "chat-prefill-i1"
            w.writerNotes = "\n\nMy notes on how my finished messages should read as a whole:\n"
            w.appNotes = "\n\nMy notes on how my finished messages in this app should read as a whole:\n"
            return w
        }()
        /// i2: one sentence saying the notes don't limit how much to continue.
        public static let i2: Wording = {
            var w = v6b3
            w.id = "chat-prefill-i2"
            w.instruction = v6b3.instruction + " My notes never limit how many words you continue with."
            return w
        }()

        public static let instructionFraming: [Wording] = [i1, i2]

        // MARK: Vocabulary notes (2026-11-19): the writer's learned words listed as notes in the prompt,
        // instead of (or besides) the logit bias. Each is i1 plus a vocabulary block.

        /// n1: a plain label with the "only when they fit" caveat.
        public static let i1n1: Wording = {
            var w = i1
            w.id = "chat-prefill-i1n1"
            w.vocabulary = "\n\nSpecial words and names I use (only when they fit):\n"
            return w
        }()
        /// n2: in i1's notes style.
        public static let i1n2: Wording = {
            var w = i1
            w.id = "chat-prefill-i1n2"
            w.vocabulary = "\n\nMy notes on words and names I often use in this app, for when they fit what I am saying:\n"
            return w
        }()

        /// g1: n1's label, placed last, for relevance-gated words (`PromptInput.vocabulary` holds the
        /// few words that pass `VocabularyGate`, so it may change as the writer types).
        public static let i1g1: Wording = {
            var w = i1n1
            w.id = "chat-prefill-i1g1"
            w.vocabularyLast = true
            return w
        }()

        public static let vocabularyNotes: [Wording] = [i1n1, i1n2, i1g1]
    }

    /// v1 instruction paragraph (kept for tests and comparison).
    static var instruction: String { Wording.v1.instruction }

    public let wording: Wording
    private let fallback: DocumentFramer
    /// Secret redaction for user-derived text, cached per field.
    private let redactor = PromptRedactor()

    public init(_ wording: Wording = .v1) {
        self.wording = wording
        self.fallback = wording == .v1 ? DocumentFramer() : DocumentFramer(.v2)
    }

    public var id: String { wording.id }
    public var style: FramingStyle { .chatPrefill }
    public var listsVocabulary: Bool { wording.vocabulary != nil }
    public func supports(_ profile: ModelProfile) -> Bool { profile.markers != nil }

    public func frame(_ input: PromptInput, profile: ModelProfile, budget: Int,
                      counter: any TokenCounting) -> FramedPrompt {
        guard let markers = profile.markers else {
            return fallback.frame(input, profile: profile, budget: budget, counter: counter)
        }
        let input = redactor.redacted(input)
        let w = wording
        let healed = Healing.split(before: input.before)
        var layout: [LayoutItem] = [
            .fixed(PromptSegment(text: markers.userOpen, kind: .control, stability: .stable)),
            .block(Block(prefix: input.surface == .code ? w.codeInstruction : w.instruction, content: "", suffix: "",
                         priority: .instruction, stability: .stable, keep: .whole)),
        ]
        // Who the writer is, then how they write.
        if let about = cleaned(input.aboutWriter) {
            layout.append(.block(Block(prefix: w.aboutWriter, content: about, suffix: "",
                                       priority: .writer, stability: .stable)))
        }
        if let notes = cleaned(input.globalInstructions) {
            layout.append(.block(Block(prefix: w.writerNotes, content: notes, suffix: "",
                                       priority: .writer, stability: .stable)))
        }
        if let languages = languageList(input.preferredLanguages) {
            layout.append(.block(Block(prefix: w.languages, content: languages, suffix: "",
                                       priority: .writer, stability: .stable)))
        }
        let vocabularyBlock = w.vocabulary.flatMap { label in vocabularyList(input.vocabulary).map { (label, $0) } }
        if !w.vocabularyLast, let (label, words) = vocabularyBlock {
            layout.append(.block(Block(prefix: label, content: words, suffix: "",
                                       priority: .writer, stability: .perField, keep: .start)))
        }
        if let kind = surfacePhrase(input.surface, windowTitle: input.windowTitle) {
            layout.append(.block(Block(prefix: w.surfacePrefix, content: kind,
                                       suffix: w.surfaceSuffix + (w.surfaceHints[input.surface] ?? ""),
                                       priority: .instruction, stability: .perField, keep: .whole)))
        }
        if let place = placeDescription(appName: input.appName, domain: input.domain, windowTitle: input.windowTitle,
                                         field: input.fieldLabel) {
            layout.append(.block(Block(prefix: w.placePrefix, content: place, suffix: w.placeSuffix,
                                       priority: .place, stability: .perField, keep: .whole)))
        }
        if let notes = cleaned(input.appInstructions) {
            layout.append(.block(Block(prefix: w.appNotes, content: notes, suffix: "",
                                       priority: .appInstructions, stability: .perField)))
        }
        let styleBlock = styleBackground(input, counter: counter).map {
            LayoutItem.block(Block(prefix: w.style, content: $0, suffix: "", priority: .style,
                                   stability: .perField, keep: .whole))
        }
        if w.samplesBeforeScreen, let styleBlock { layout.append(styleBlock) }
        if let screen = cleaned(input.screenContext) {
            layout.append(.block(Block(prefix: w.screen,
                                       content: screen, suffix: "", priority: .screen,
                                       stability: .perField,
                                       // Reading order puts the lines just above the field last: keep them.
                                       keep: .end, maxContentTokens: input.screenTokenLimit)))
        }
        if let clip = clipboardBackground(input) {
            layout.append(.block(Block(prefix: w.clipboard, content: clip, suffix: "", priority: .clipboard,
                                       stability: .perField, maxContentTokens: clipboardTokenLimit)))
        }
        if !w.samplesBeforeScreen, let styleBlock { layout.append(styleBlock) }
        if let after = cleaned(input.after) {
            layout.append(.block(Block(prefix: w.after, content: after, suffix: "", priority: .afterCaret,
                                       stability: .perField, maxContentTokens: 64)))
        }
        if let style = cleaned(input.styleInstructions) {
            layout.append(.block(Block(prefix: suggestionStyleLabel, content: style, suffix: "",
                                       priority: .instruction, stability: .perField, keep: .whole)))
        }
        if w.vocabularyLast, let (label, words) = vocabularyBlock {
            layout.append(.block(Block(prefix: label, content: words, suffix: "", priority: .writer,
                                       stability: .perKeystroke, keep: .start)))
        }
        layout.append(.fixed(PromptSegment(text: markers.turnClose, kind: .control, stability: .perField)))
        layout.append(.fixed(PromptSegment(text: markers.assistantOpen, kind: .control, stability: .perField)))
        if let off = markers.reasoningOff {
            layout.append(.fixed(PromptSegment(text: off, kind: .control, stability: .perField)))
        }
        layout.append(.caret)

        let assembled = FrameAssembler.assembleNoted(layout: layout, caretText: healed.promptText, budget: budget,
                                                     counter: counter)
        return FramedPrompt(segments: assembled.segments, requiredPrefix: healed.requiredPrefix, framerID: id,
                            style: style, budgetNotes: assembled.notes)
    }
}

/// Heading of the suggestion style block (instruct framers): the style overrides tone and length.
let suggestionStyleLabel = "\n\nStyle for this continuation. It comes first, over any tone or length notes above:\n"

/// The vocabulary block's content: words in the order given, comma-separated, without blanks or
/// duplicates (case-insensitive); nil when none are left.
func vocabularyList(_ words: [String]) -> String? {
    var seen = Set<String>()
    let kept = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.contains("\n") && seen.insert($0.lowercased()).inserted }
    return kept.isEmpty ? nil : kept.joined(separator: ", ")
}

/// Chooses chat-prefill for instruct profiles with known markers, document otherwise.
/// An override id wins when that framer supports the profile.
public struct DefaultFramerRegistry: FramerRegistry {
    public let all: [any PromptFramer]

    /// Automatic selection takes the first framer of the wanted style, so order sets the default.
    /// Instruct: chat-prefill-i1g1 (2026-11-19 gated-notes study: i1 plus the few learned words that
    /// pass `VocabularyGate`, named last; the engine then keeps only the mid-word learned-word bias).
    /// Earlier:
    /// document-v1 for base models, chat-prefill-i1 for instruct ones (2026-11-19 instruction-framing
    /// study: v6b3 with the writer's instructions labeled as notes on the whole finished message, so
    /// "short and friendly" stops shortening the suggestion; v6b3 and v5 stay for comparison).
    public static let standardFramers: [any PromptFramer] = [
        DocumentFramer(), ChatPrefillFramer(.i1g1), ChatPrefillFramer(.i1), ChatPrefillFramer(.v6b3), ChatPrefillFramer(.v5), ChatPrefillFramer(), DocumentFramer(.v2),
        ChatPrefillFramer(.v2),
    ] + (ChatPrefillFramer.Wording.v6Screening.filter { $0.id != ChatPrefillFramer.Wording.v6b3.id }
        + ChatPrefillFramer.Wording.v7Combinations + ChatPrefillFramer.Wording.instructionFraming.filter { $0.id != ChatPrefillFramer.Wording.i1.id }
        + ChatPrefillFramer.Wording.vocabularyNotes.filter { $0.id != ChatPrefillFramer.Wording.i1g1.id }).map { ChatPrefillFramer($0) }
        + (DocumentFramer.Wording.v3Screening + DocumentFramer.Wording.v4Combinations).map { DocumentFramer($0) }

    public init(framers: [any PromptFramer] = DefaultFramerRegistry.standardFramers) {
        self.all = framers
    }

    public func framer(for profile: ModelProfile, override: String?) -> any PromptFramer {
        if let override, let chosen = all.first(where: { $0.id == override }), chosen.supports(profile) {
            return chosen
        }
        let wanted: FramingStyle = (profile.isInstruct && profile.markers != nil) ? .chatPrefill : .document
        if let match = all.first(where: { $0.style == wanted && $0.supports(profile) }) { return match }
        return all.first(where: { $0.supports(profile) }) ?? DocumentFramer()
    }
}
