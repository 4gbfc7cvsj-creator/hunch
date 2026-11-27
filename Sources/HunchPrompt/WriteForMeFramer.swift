import Foundation
import HunchCore

/// Prompts for "write for me" (design: write-for-me spec v2). Instruct models get one user turn:
/// the task, the shape, the writer, the place, the reference text, then the instruction or the text
/// to polish last, and an open model turn. Base models get a document whose next part is the draft.
///
/// Reference text (screen, clipboard, the field's other text) is labeled as such; the source text
/// and the writer's own notes are the only things the model is told to follow.
public struct WriteForMeFramer: Sendable {
    public static let frameID = "write-for-me-v1"

    public init() {}

    // MARK: Wording

    static let writeTask = """
        Write the text I need, as me, from my short instruction at the end. The reference material is \
        background only: use its details (for example, from the message I am replying to: names, dates, \
        amounts, and the steps that were asked of me) where they belong in this text, and ignore it when \
        it has nothing to do with my instruction. Never describe, quote, or mention the reference material \
        itself. Do not invent people, facts, dates, prices, files, or promises that are in neither my \
        instruction nor the reference material. Write in my voice and in the language of my instruction. \
        Output only the finished text, ready to send: no title, no notes to me, no quotation marks, no \
        Markdown.
        """

    /// A write with nothing on screen, copied or in the box: only the instruction to go on. Telling
    /// the model to use "the reference material" then makes it invent one (a message from a made-up
    /// sender, with a date and file names).
    static let writeTaskBare = """
        Write the text I need, as me, from my short instruction at the end. My instruction is all you \
        have to go on: build the text only from what it says, and do not make up people, names, dates, \
        prices, files, or other details it does not give. Write in my voice and in the language of my \
        instruction. Output only the finished text, ready to send: no title, no notes to me, no quotation \
        marks, no Markdown.
        """

    static let polishTask = """
        Polish the text at the end, which I wrote. Fix grammar, spelling, word choice, and flow so it reads \
        well, in my own voice. Keep every fact, point, name, number, and commitment exactly as it is, in the \
        same order and at about the same length. Do not add anything new: no new details, offers, \
        promises, greetings, or sign-offs that are not already there. Keep the language I wrote in. Output \
        only the polished text: no notes to me, no quotation marks, no Markdown.
        """

    /// Polish for a prompt to an AI: the wording, and also what makes the request clear to its reader.
    static let polishPromptTask = """
        The text at the end is a prompt I wrote to send to an AI assistant or coding agent. Polish it; do \
        not answer it or carry it out. Fix grammar, spelling, and word choice, and make it clear to the AI \
        that reads it: where the reference material makes it clear, replace vague words such as "it", \
        "this", or "that thing" with the concrete name (the file, the error, the feature); put the main \
        request first, then the context and constraints; split a run of separate asks into a short list, one \
        "- " line each; and cut filler and pleasantries ("could you maybe please", "thanks so much") that \
        add nothing. Keep every fact, ask, name, number, and constraint, and keep my plain, direct tone and \
        the language I wrote in. Do not add requirements I did not ask for. Output only the polished prompt: \
        no title, no notes, no quotation marks, no bold or headings. If the prompt leaves out something the \
        AI will clearly need to know (for example, which file, or what result I want), end with one last \
        line that starts with "Missing:" and names it in a few words; otherwise leave that line out.
        """

    /// An instruction on the user's text (voice instructions): the instruction says what to change,
    /// the rest stays. The instruction and the text may be in different languages.
    static let transformTask = """
        Rewrite the text below, which I wrote, the way my instruction after it asks (for example: \
        make it shorter, change the tone, translate it, turn it into a list). Change only what the \
        instruction asks for: keep every fact, name, number, and commitment unless the instruction says to \
        change or drop it, and do not add new details, offers, or promises. Keep my voice. Keep the \
        language of the text unless the instruction asks for another language, even when the instruction \
        itself is in a different language. Output only the rewritten text: no notes to me, no quotation \
        marks, no headings or bold; use "- " lines only for a list or bullet points.
        """

    /// The shape line a write sends: the request's own wording when it has one (an edited preset
    /// or a custom shape; empty means none), else the built-in line.
    static func shapeLine(for request: WriteRequest) -> String? {
        guard let text = request.shapeText else { return shapeLine(request.shape) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The built-in wording of a shape, as Settings shows it; nil for `adaptive`.
    public static func builtInShapeText(_ shape: WriteShape) -> String? { shapeLine(shape) }

    static func shapeLine(_ shape: WriteShape) -> String? {
        switch shape {
        case .email:
            return "Write it as a complete email body: a greeting with the recipient's name when it is known, "
                + "the body in short paragraphs, a sign-off, and my name as the signature (with my business or "
                + "title when I have given one). No subject line."
        case .message:
            return "Write it as a short chat message: no greeting line, no sign-off, no signature."
        case .paragraph:
            return "Write it as one or a few well-formed paragraphs, with no greeting, sign-off, or signature."
        case .aiPrompt:
            return "It is a prompt I will send to an AI assistant or coding agent: write the request itself, "
                + "worded as I would type it to the AI (\"Why do I get…\", not \"Ask why…\"); do not answer it "
                + "or do the task. Say directly what I want first, then only the context that my instruction "
                + "or the reference material actually gives (names, files, errors), any constraints I stated, "
                + "and, only when it is not obvious, what a good result looks like. Mention what I already "
                + "tried only if I said so. Do not pad it with background, examples, or details I did not "
                + "give. Write in the first "
                + "person, in my plain, direct tone, with clarity for the AI first. Use short paragraphs, "
                + "and a short list (one \"- \" line each) only for several separate asks or constraints. "
                + "No greeting, no thanks, no sign-off, no headings. Add only what my instruction implies; "
                + "do not invent requirements."
        case .adaptive:
            return nil
        }
    }

    static let aboutWriter = "\n\nAbout me:\n"
    static let writerNotes = "\n\nMy own instructions for how I write. Follow them:\n"
    static let languages = "\n\nI write in: "
    static let surfacePrefix = "\n\nI am writing "
    static let placePrefix = "\n\nWhere I am typing: "
    static let appNotes = "\n\nMy instructions for this app. Follow them too:\n"
    static let screen = "\n\nReference material: text on my screen near the box I am typing in "
        + "(for example, the message I am replying to). Use it for the facts; do not copy it:\n"
    static let clipboard = "\n\nReference material: something I copied a moment ago. It may or may not be relevant:\n"
    static let style = "\n\nA few sentences I wrote earlier, to show how I phrase things (do not repeat them):\n"
    static let fieldBefore = "\n\nText already in the box above the part you are writing (reference only; "
        + "do not repeat it):\n"
    static let fieldAfter = "\n\nText already in the box below the part you are writing (reference only; "
        + "do not repeat it):\n"
    static let previousDraft = "\n\nYour previous draft:\n"
    static let refinements = "\n\nChange the draft as I ask now:\n"
    static let instructionHeader = "\n\nMy instruction:\n"
    static let polishHeader = "\n\nThe text to polish:\n"
    static let transformTextHeader = "\n\nMy text:\n"
    static let transformInstructionHeader = "\n\nMy instruction for it:\n"

    // MARK: Framing

    /// - Parameter budget: prompt tokens available (the model's context minus room for the draft).
    public func frame(_ request: WriteRequest, profile: ModelProfile, budget: Int,
                      counter: any TokenCounting) -> FramedPrompt {
        // A dictation cleanup rides on the write path (same writers, same model) with its own prompt.
        if let dictation = request.dictation {
            return DictationFramer().frame(dictation, profile: profile, budget: budget, counter: counter)
        }
        if let replies = request.replies {
            return frameReplies(request, replies: replies, profile: profile, budget: budget, counter: counter)
        }
        // Base models can carry chat markers (Gemma 4 base does) but don't follow instructions.
        guard profile.isInstruct, let markers = profile.markers else {
            return frameDocument(request, budget: budget, counter: counter)
        }
        let input = Self.redacted(request.context)
        var layout: [LayoutItem] = [
            .fixed(PromptSegment(text: markers.userOpen, kind: .control, stability: .stable)),
        ]
        var task: String
        switch request.mode {
        case .write: task = Self.hasReference(input) ? Self.writeTask : Self.writeTaskBare
        case .polish: task = request.shape == .aiPrompt ? Self.polishPromptTask : Self.polishTask
        case .transform: task = Self.transformTask
        }
        if request.mode == .write, let shape = Self.shapeLine(for: request) { task += " " + shape }
        layout.append(.fixed(PromptSegment(text: task, kind: .control, stability: .stable, label: "task")))
        appendContext(input, to: &layout, counter: counter, withStyle: request.shape != .aiPrompt)
        if let draft = cleaned(request.previousDraft), !request.refinements.isEmpty {
            layout.append(.block(Block(prefix: Self.previousDraft, content: draft, suffix: "",
                                       priority: .instruction, stability: .perKeystroke, keep: .whole)))
        }
        let asks = request.refinements.compactMap(cleaned).map { "- \($0)" }.joined(separator: "\n")
        if !asks.isEmpty {
            layout.append(.block(Block(prefix: Self.refinements, content: asks, suffix: "",
                                       priority: .instruction, stability: .perKeystroke, keep: .whole)))
        }
        // The source is never cut: it is a fixed segment, and the optional blocks share what is left.
        let header = switch request.mode {
        case .write: Self.instructionHeader
        case .polish: Self.polishHeader
        case .transform: Self.transformTextHeader
        }
        layout.append(.fixed(PromptSegment(text: header, kind: .control, stability: .perKeystroke)))
        layout.append(.fixed(PromptSegment(text: Self.source(request), kind: .content, stability: .perKeystroke,
                                           label: "source")))
        if request.mode == .transform {
            layout.append(.fixed(PromptSegment(text: Self.transformInstructionHeader, kind: .control,
                                               stability: .perKeystroke)))
            layout.append(.fixed(PromptSegment(text: Self.transformInstruction(request), kind: .content,
                                               stability: .perKeystroke, label: "instruction")))
        }
        layout.append(.fixed(PromptSegment(text: markers.turnClose, kind: .control, stability: .perKeystroke)))
        layout.append(.fixed(PromptSegment(text: markers.assistantOpen, kind: .control, stability: .perKeystroke)))
        if let off = markers.reasoningOff {
            layout.append(.fixed(PromptSegment(text: off, kind: .control, stability: .perKeystroke)))
        }
        let assembled = FrameAssembler.assembleNoted(layout: layout, caretText: "", budget: budget, counter: counter)
        return FramedPrompt(segments: assembled.segments.filter { !$0.text.isEmpty }, requiredPrefix: "",
                            framerID: Self.frameID, style: .chatPrefill, budgetNotes: assembled.notes)
    }

    /// The writer, the place and the reference text, in the order the suggestion framers use.
    /// `withStyle: false` leaves out the learned sentences (a prompt to an AI wants clarity, not the
    /// writer's turns of phrase).
    func appendContext(_ input: PromptInput, to layout: inout [LayoutItem], counter: any TokenCounting,
                               withStyle: Bool = true, screenLimit: Int? = nil) {
        if let about = cleaned(input.aboutWriter) {
            layout.append(.block(Block(prefix: Self.aboutWriter, content: about, suffix: "", priority: .writer,
                                       stability: .stable)))
        }
        if let notes = cleaned(input.globalInstructions) {
            layout.append(.block(Block(prefix: Self.writerNotes, content: notes, suffix: "", priority: .writer,
                                       stability: .stable)))
        }
        if let langs = languageList(input.preferredLanguages) {
            layout.append(.block(Block(prefix: Self.languages, content: langs, suffix: ".", priority: .writer,
                                       stability: .stable)))
        }
        if let kind = surfacePhrase(input.surface, windowTitle: input.windowTitle) {
            layout.append(.block(Block(prefix: Self.surfacePrefix, content: kind, suffix: ".", priority: .place,
                                       stability: .perField, keep: .whole)))
        }
        if let place = placeDescription(appName: input.appName, domain: input.domain, windowTitle: input.windowTitle,
                                         field: input.fieldLabel) {
            layout.append(.block(Block(prefix: Self.placePrefix, content: place, suffix: ".", priority: .place,
                                       stability: .perField, keep: .whole)))
        }
        if let notes = cleaned(input.appInstructions) {
            layout.append(.block(Block(prefix: Self.appNotes, content: notes, suffix: "", priority: .appInstructions,
                                       stability: .perField)))
        }
        if let screen = cleaned(input.screenContext) {
            layout.append(.block(Block(prefix: Self.screen, content: screen, suffix: "", priority: .screen,
                                       stability: .perField, keep: .end, maxContentTokens: screenLimit)))
        }
        if let clip = clipboardBackground(input) {
            layout.append(.block(Block(prefix: Self.clipboard, content: clip, suffix: "", priority: .clipboard,
                                       stability: .perField, maxContentTokens: clipboardTokenLimit)))
        }
        if withStyle, let style = styleBackground(input, counter: counter) {
            layout.append(.block(Block(prefix: Self.style, content: style, suffix: "", priority: .style,
                                       stability: .perField, keep: .whole)))
        }
        if let before = cleaned(input.before) {
            layout.append(.block(Block(prefix: Self.fieldBefore, content: before, suffix: "", priority: .afterCaret,
                                       stability: .perField, keep: .end, maxContentTokens: 400)))
        }
        if let after = cleaned(input.after) {
            layout.append(.block(Block(prefix: Self.fieldAfter, content: after, suffix: "", priority: .afterCaret,
                                       stability: .perField, maxContentTokens: 400)))
        }
    }

    /// Secrets in the reference text (keys, card numbers) are masked as in suggestion prompts. The
    /// source itself is left exactly as typed.
    static func redacted(_ input: PromptInput) -> PromptInput {
        var out = input
        func r(_ text: String) -> String { SecretSanitizer.redact(text, surface: input.surface) }
        out.before = r(input.before)
        out.after = r(input.after)
        out.screenContext = input.screenContext.map(r)
        out.clipboard = input.clipboard.map(r)
        out.styleExamples = input.styleExamples.map(r)
        return out
    }

    /// Whether the write has any reference text: the screen, the clipboard, or the box's other text.
    static func hasReference(_ input: PromptInput) -> Bool {
        cleaned(input.screenContext) != nil || clipboardBackground(input) != nil || cleaned(input.before) != nil
            || cleaned(input.after) != nil
    }

    /// The source as the prompt shows it. A write instruction that starts by naming the feature
    /// ("Write for me the effect doesn't play…", selected and sent with the shortcut) loses those
    /// words: they are said to Hunch, not part of what to write. Polish and transform text is left as is.
    static func source(_ request: WriteRequest) -> String {
        guard request.mode == .write else { return request.source }
        let text = request.source
        let pattern = "^\\s*(please\\s+)?write\\s+for\\s+me\\b[\\s:,.\\-–—]*"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return text
        }
        let rest = String(text[range.upperBound...])
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : rest
    }

    // MARK: Base models

    static let documentHeader = "Notes and messages written by one person, each followed by the finished version."
    static let documentWriteLead = "\n\nWhat they had to answer:\n"
    static let documentNotes = "\n\nTheir quick note on what to say:\n"
    static let documentWritten = "\n\nThe full message they wrote from that note, in their own name and "
        + "in the note's language:\n\n"
    static let documentRough = "\n\nTheir rough draft:\n"
    static let documentPolished = "\n\nThe same text after a careful edit for grammar and flow, in the same "
        + "language, every fact unchanged:\n\n"
    static let documentPromptForm = "\n\nForm: a prompt they send to an AI assistant or coding agent: a direct "
        + "request in the first person, then the context and constraints it needs, with no greeting or sign-off."
    static let documentPromptNotes = "\n\nTheir quick note on what to ask the AI:\n"
    static let documentPromptWritten = "\n\nThe full prompt they wrote from that note, clear and specific, in "
        + "the note's language:\n\n"
    static let documentPromptRough = "\n\nTheir rough prompt to an AI:\n"
    static let documentPromptPolished = "\n\nThe same prompt after a careful edit for clarity: the main request "
        + "first, vague references made concrete, filler cut, every fact and ask unchanged, in the same "
        + "language:\n\n"

    static let documentTransformText = "\n\nTheir text:\n"
    static let documentTransformAsk = "\n\nWhat they wanted changed: "
    static let documentTransformDone = "\n\nThe same text after that change, every other fact unchanged:\n\n"

    /// The spoken instruction, trimmed; a request without one asks for a light edit. When the
    /// instruction and the text are in different scripts (a Chinese instruction on English text, or
    /// the reverse) and the instruction names no language, a note says which language to answer in:
    /// models otherwise answer in the instruction's language (E4B-it did on both eval cases).
    static func transformInstruction(_ request: WriteRequest) -> String {
        let text = request.instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return "Improve it a little." }
        guard let language = languageToKeep(instruction: text, source: request.source) else { return text }
        return text + "\n(Write the result in " + language + ", the language of my text, not the language of "
            + "this instruction.)"
    }

    /// Words that name a language or ask for a translation: then the instruction decides the language.
    static let languageWords = ["translat", "english", "chinese", "mandarin", "japanese", "korean", "spanish",
                                "french", "german", "taiwanese", "cantonese", "language", "翻譯", "翻译", "英文",
                                "英語", "英语", "中文", "華語", "华语", "國語", "国语", "日文", "日語", "日语", "韓文",
                                "韩文", "法文", "德文", "西班牙文", "語言", "语言"]

    /// "English" or "(Traditional / Simplified) Chinese" when the text and the instruction are mostly in different scripts
    /// (Han vs. Latin) and the instruction names no language; nil otherwise.
    static func languageToKeep(instruction: String, source: String) -> String? {
        let lower = instruction.lowercased()
        if languageWords.contains(where: { lower.contains($0) }) { return nil }
        guard let a = hanShare(instruction), let b = hanShare(source) else { return nil }
        if a >= 0.5, b < 0.1 { return "English" }
        if a < 0.1, b >= 0.5 {
            if HanScript.usesTraditional(source) { return "Traditional Chinese" }
            if HanScript.usesSimplified(source) { return "Simplified Chinese" }
            return "Chinese"
        }
        return nil
    }

    /// Share of letters that are Han characters; nil with no letters.
    static func hanShare(_ text: String) -> Double? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        let han = letters.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value)
        }
        return Double(han.count) / Double(letters.count)
    }

    /// A shape line reworded for the base-model document, which talks about the writer.
    static func thirdPerson(_ line: String) -> String {
        line.replacingOccurrences(of: "my name", with: "their name").replacingOccurrences(of: "I have", with: "they have")
    }

    /// A base model continues documents: lay one out so that the draft comes next.
    private func frameDocument(_ request: WriteRequest, budget: Int, counter: any TokenCounting) -> FramedPrompt {
        let input = Self.redacted(request.context)
        var layout: [LayoutItem] = [
            .fixed(PromptSegment(text: Self.documentHeader, kind: .control, stability: .stable)),
        ]
        if let about = cleaned(input.aboutWriter) {
            layout.append(.block(Block(prefix: "\n\nAbout the writer: ", content: about, suffix: "", priority: .writer,
                                       stability: .stable)))
        }
        if let notes = cleaned(input.globalInstructions) {
            layout.append(.block(Block(prefix: "\n\nHow they write: ", content: notes, suffix: "", priority: .writer,
                                       stability: .stable)))
        }
        if request.mode == .write, let screen = cleaned(input.screenContext) {
            layout.append(.block(Block(prefix: Self.documentWriteLead, content: screen, suffix: "", priority: .screen,
                                       stability: .perField, keep: .end)))
        }
        if request.mode == .transform {
            layout.append(.fixed(PromptSegment(text: Self.documentTransformText, kind: .control,
                                               stability: .perKeystroke)))
            layout.append(.fixed(PromptSegment(text: request.source, kind: .content, stability: .perKeystroke,
                                               label: "source")))
            layout.append(.fixed(PromptSegment(text: Self.documentTransformAsk + Self.transformInstruction(request),
                                               kind: .content, stability: .perKeystroke, label: "instruction")))
            layout.append(.fixed(PromptSegment(text: Self.documentTransformDone, kind: .control,
                                               stability: .perKeystroke)))
            let assembled = FrameAssembler.assembleNoted(layout: layout, caretText: "", budget: budget, counter: counter)
            return FramedPrompt(segments: assembled.segments.filter { !$0.text.isEmpty }, requiredPrefix: "",
                                framerID: Self.frameID, style: .document, budgetNotes: assembled.notes)
        }
        let prompt = request.shape == .aiPrompt
        // An edited AI-prompt wording replaces the built-in "Form:" line too.
        let promptForm = request.shapeText == nil ? Self.documentPromptForm
            : Self.shapeLine(for: request).map { "\n\nForm: " + Self.thirdPerson($0) } ?? ""
        var lead = switch (request.mode, prompt) {
        case (.write, false): Self.documentNotes
        case (.write, true): promptForm + Self.documentPromptNotes
        case (.polish, false): Self.documentRough
        case (.polish, true): Self.documentPromptRough
        case (.transform, _): ""  // framed above
        }
        if request.mode == .write, !prompt, let shape = Self.shapeLine(for: request) {
            lead = "\n\nForm: " + Self.thirdPerson(shape) + lead
        }
        layout.append(.fixed(PromptSegment(text: lead, kind: .control, stability: .perKeystroke)))
        layout.append(.fixed(PromptSegment(text: Self.source(request), kind: .content, stability: .perKeystroke,
                                           label: "source")))
        let follow = switch (request.mode, prompt) {
        case (.write, false): Self.documentWritten
        case (.write, true): Self.documentPromptWritten
        case (.polish, false): Self.documentPolished
        case (.polish, true): Self.documentPromptPolished
        case (.transform, _): ""  // framed above
        }
        layout.append(.fixed(PromptSegment(text: follow, kind: .control, stability: .perKeystroke)))
        let assembled = FrameAssembler.assembleNoted(layout: layout, caretText: "", budget: budget, counter: counter)
        return FramedPrompt(segments: assembled.segments.filter { !$0.text.isEmpty }, requiredPrefix: "",
                            framerID: Self.frameID, style: .document, budgetNotes: assembled.notes)
    }
}
