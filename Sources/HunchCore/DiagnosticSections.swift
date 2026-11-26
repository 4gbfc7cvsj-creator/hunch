import Foundation

/// Builds the labelled "what went in" sections from a request's input. Pure. Text is redacted the
/// way the framers redact it before laying out the prompt, so the sections never show more than the
/// model got.
public enum DiagnosticSections {
    /// Longest stretch of text before the caret the sections quote in full.
    static let redactKeep = 200

    private static func item(_ label: String?, _ text: String?) -> DiagnosticSection.Item? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DiagnosticSection.Item(label, text)
    }

    /// For an inline suggestion (or the field text around a Write for me range, with other labels).
    /// - Parameters:
    ///   - beforeTitle / afterTitle: what the field text is called ("Text before the caret").
    public static func forInput(_ input: PromptInput, bias: LearnedBias? = nil, notes: LearnedNoteDiagnostics? = nil,
                                windowTitleSent: Bool = true,
                                beforeTitle: String = "Text before the caret",
                                afterTitle: String = "Text after the caret") -> [DiagnosticSection] {
        let surface = input.surface
        func r(_ text: String) -> String { SecretSanitizer.redact(text, surface: surface) }
        var sections: [DiagnosticSection] = []

        sections.append(DiagnosticSection("App, site and window", [
            item("App", input.appName.map(r)),
            item("Site", input.domain.map(r)),
            item("Window title", input.windowTitle.map(r)),
            item("Field", input.fieldLabel.map(r)),
            item("Kind of text", input.surface == .unknown ? nil : input.surface.rawValue),
        ].compactMap { $0 }))

        sections.append(DiagnosticSection(beforeTitle, [item(nil,
            SecretSanitizer.redact(input.before, keepingLast: redactKeep, surface: surface))].compactMap { $0 }))
        sections.append(DiagnosticSection(afterTitle, [item(nil, r(input.after))].compactMap { $0 }))
        sections.append(DiagnosticSection("Screen context", [
            item(nil, input.screenContext.map(r)),
            input.screenContext != nil && input.screenInterfaceDropped > 0
                ? item("Left out", "\(input.screenInterfaceDropped) interface line\(input.screenInterfaceDropped == 1 ? "" : "s") "
                       + "next to the field (status boxes, toolbars)") : nil,
        ].compactMap { $0 }))
        sections.append(DiagnosticSection("Clipboard", [item(nil, input.clipboard.map(r))].compactMap { $0 }))

        var learned: [DiagnosticSection.Item] = []
        if let bias {
            func weights(_ entries: [LearnedBias.Entry]) -> String {
                entries.sorted { $0.weight > $1.weight }
                    .map { "\($0.text.trimmingCharacters(in: .whitespaces)) (\(String(format: "%.2f", Double($0.weight))))" }
                    .joined(separator: ", ")
            }
            let midWord = notes?.framerListsVocabulary == true
            if !bias.entries.isEmpty {
                let what = midWord ? "Mid-word boost" : "Learned words"
                learned.append(.init(bias.strength > 0 ? "\(what) (strength \(String(format: "%.2g", Double(bias.strength))))"
                                     : "\(what) (strength 0: not used)", weights(bias.entries)))
            } else if midWord, bias.strength > 0 {
                learned.append(.init("Mid-word boost", "none here (only fires while a learned word is half typed)"))
            }
            if !bias.phrases.isEmpty {
                learned.append(.init(bias.phraseStrength > 0
                                     ? "Learned phrases (strength \(String(format: "%.2g", Double(bias.phraseStrength))))"
                                     : "Learned phrases (strength 0: not used)", weights(bias.phrases)))
            }
            if !bias.avoid.isEmpty { learned.append(.init("Blocked words and phrases", bias.avoid.joined(separator: ", "))) }
        }
        if let notes { learned.insert(contentsOf: noteItems(notes, input: input), at: 0) }
        sections.append(DiagnosticSection("Learned words and phrases", learned))

        var style: [DiagnosticSection.Item] = []
        if !input.preferredLanguages.isEmpty { style.append(.init("Languages", input.preferredLanguages.joined(separator: ", "))) }
        if let scripts = input.allowedScripts, !scripts.isEmpty {
            style.append(.init("Scripts you can type", scripts.sorted().joined(separator: ", ")))
        }
        if let han = input.preferredHanScript { style.append(.init("Chinese characters", han.rawValue)) }
        if input.quoteStyle == .straight { style.append(.init("Quotes", "always straight")) }
        if let text = item("How I write", input.globalInstructions) { style.append(text) }
        if let text = item("Notes for this app", input.appInstructions) { style.append(text) }
        if let text = item("About me", input.aboutWriter) { style.append(text) }
        for (index, example) in input.styleExamples.enumerated() {
            style.append(.init("Earlier sentence \(index + 1)", r(example)))
        }
        sections.append(DiagnosticSection("Languages and style hints", style))
        return sections
    }

    /// For a dictation cleanup.
    public static func forDictation(_ cleanup: DictationCleanup) -> [DiagnosticSection] {
        let context = cleanup.context
        let surface = context.surface ?? .unknown
        func r(_ text: String) -> String { SecretSanitizer.redact(text, surface: surface) }
        var sections: [DiagnosticSection] = []
        sections.append(DiagnosticSection("Dictation", [
            .init("Transcript (what speech to text heard)", r(cleanup.transcript)),
            .init("Cleanup", cleanup.preset.rawValue),
            .init("Written for", cleanup.shape.rawValue),
        ]))
        sections.append(DiagnosticSection("App, site and window", [
            item("App", context.appName.map(r)),
            item("Kind of text", context.surface.map(\.rawValue)),
            item("Names from the window title", context.titleNames.isEmpty ? nil : context.titleNames.joined(separator: ", ")),
        ].compactMap { $0 }))
        sections.append(DiagnosticSection("Text before the caret",
                                          [item(nil, context.textBefore.map(r))].compactMap { $0 }))
        sections.append(DiagnosticSection("Screen context",
                                          [item("Names from the screen", context.screenNames.isEmpty ? nil : context.screenNames.joined(separator: ", "))]
                                              .compactMap { $0 }))
        sections.append(DiagnosticSection("Learned words and phrases",
                                          [item("Spellings", context.spellings.isEmpty ? nil : context.spellings.joined(separator: ", "))]
                                              .compactMap { $0 }))
        var style: [DiagnosticSection.Item] = []
        if !context.languages.isEmpty { style.append(.init("Languages", context.languages.joined(separator: ", "))) }
        if context.traditionalChinese { style.append(.init("Chinese characters", "traditional")) }
        if let about = item("About me", context.aboutMe) { style.append(about) }
        sections.append(DiagnosticSection("Languages and style hints", style))
        return sections
    }

    /// For a Write for me request: what was asked, then the same context sections as a suggestion.
    public static func forWrite(_ request: WriteRequest) -> [DiagnosticSection] {
        var asked: [DiagnosticSection.Item] = [.init("Mode", request.mode.rawValue), .init("Shape", request.shape.rawValue)]
        if let text = item("Shape wording", request.shapeText) { asked.append(text) }
        let surface = request.context.surface
        asked.append(.init(request.mode == .write ? "Your instruction" : "Your text",
                           SecretSanitizer.redact(request.source, surface: surface)))
        if let instruction = item("Spoken instruction", request.instruction) { asked.append(instruction) }
        if let previous = item("Previous draft", request.previousDraft) { asked.append(previous) }
        for (index, change) in request.refinements.enumerated() { asked.append(.init("Change asked \(index + 1)", change)) }
        return [DiagnosticSection("Request", asked)]
            + forInput(request.context, beforeTitle: "Field text before the range", afterTitle: "Field text after the range")
    }

    /// A suggested-replies request: the length asked, the screen-text limit, then the context; and
    /// the replies the app read from the model's text (`SuggestedReplies.parse`).
    public static func forReplies(_ request: WriteRequest, replies: ReplyRequest, raw: String,
                                  scores: [ReplyScore] = []) -> [DiagnosticSection] {
        var asked: [DiagnosticSection.Item] = [
            .init("Words per reply", replies.minWords == replies.maxWords ? "\(replies.maxWords)"
                  : "\(replies.minWords)–\(replies.maxWords)"),
        ]
        if let limit = request.context.screenTokenLimit { asked.append(.init("Screen text limit", "\(limit) tokens")) }
        let parsed = SuggestedReplies.parse(raw)
        let read: [DiagnosticSection.Item] = parsed.isEmpty
            ? [.init(nil, "None: the model said nothing is waiting for a reply (or wrote nothing usable), so no bubble.")]
            : parsed.enumerated().map { index, reply in
                guard let score = scores.first(where: { $0.reply == reply }) else { return .init("Reply \(index + 1)", reply) }
                return .init("Reply \(index + 1)", "\(reply)  (\(ReplyScoring.describe(score)))")
            }
        return [DiagnosticSection("Request", asked)]
            + forInput(request.context, beforeTitle: "Field text before the caret", afterTitle: "Field text after the caret")
            + [DiagnosticSection("Replies read from the model's text", read)]
    }

    /// The "left out by the budget" section from the framer's notes.
    public static func budget(_ prompt: DiagnosticPrompt?) -> DiagnosticSection {
        var items: [DiagnosticSection.Item] = []
        if let prompt {
            items = prompt.notes.map { .init($0.name, $0.kind == .dropped ? "left out: \($0.detail)" : "shortened: \($0.detail)") }
            if items.isEmpty {
                let budget = prompt.budget.map { " of a budget of \($0)" } ?? ""
                items = [.init(nil, "Nothing was left out: the prompt used \(prompt.promptTokens) tokens\(budget).")]
            }
        }
        return DiagnosticSection("Left out by the token budget", items)
    }
}
