import Foundation

// "Write for me": a shortcut turns a short instruction into a full draft (write), or tidies text
// the user already wrote (polish). Both show in a preview panel before anything is replaced.

/// What the model is asked to do with the text in the range.
public enum WriteMode: String, Codable, Sendable, CaseIterable {
    /// The text is an instruction ("agree to the new rate"): write the message it describes.
    case write
    /// The text is the message: fix wording, grammar and flow, keep every fact.
    case polish
    /// Do what `WriteRequest.instruction` says to the text ("make this shorter", "translate to
    /// Chinese"): the spoken instruction on a selection (voice instructions, experimental).
    case transform
}

/// The shape of a written draft. `adaptive` picks one from where the user is writing; the per-app
/// "Write for me" setting can fix it. Polish keeps the text's own shape and ignores this, except
/// for `aiPrompt`, where it also tightens the prompt for an AI reader.
public enum WriteShape: String, Codable, Sendable, CaseIterable {
    /// `aiPrompt`: a request sent to an AI chat or coding agent (Claude, ChatGPT, an editor's chat).
    case adaptive, email, message, paragraph, aiPrompt
}

/// A shape the user named and wrote themselves ("Team update"), picked per app like a preset.
/// Apps store only its `id`, so renaming it keeps every app that uses it.
public struct CustomWriteShape: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Sent to the model in place of a preset's shape line.
    public var text: String
    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// The user's saved shapes and their edits to the presets' wording, shared by every app.
public struct WriteShapeLibrary: Codable, Sendable, Equatable {
    /// Edited wording by preset (`WriteShape.rawValue`); a missing key means the built-in text.
    public var presetTexts: [String: String]
    public var custom: [CustomWriteShape]
    public init(presetTexts: [String: String] = [:], custom: [CustomWriteShape] = []) {
        self.presetTexts = presetTexts
        self.custom = custom
    }

    /// The presets offered in the per-app picker. Paragraph stays for Adaptive and dictation only.
    public static let presets: [WriteShape] = [.email, .message, .aiPrompt]

    public func custom(_ id: UUID?) -> CustomWriteShape? {
        guard let id else { return nil }
        return custom.first { $0.id == id }
    }

    /// The user's wording for a preset, or nil for the built-in one.
    public func editedText(_ shape: WriteShape) -> String? { presetTexts[shape.rawValue] }

    /// "Custom 1", "Custom 2"…: the first such name not taken yet.
    public func nextCustomName() -> String {
        let taken = Set(custom.map { $0.name.lowercased() })
        var n = 1
        while taken.contains("custom \(n)") { n += 1 }
        return "Custom \(n)"
    }
}

/// One write-for-me generation.
public struct WriteRequest: Sendable {
    public var id: RequestID
    public var mode: WriteMode
    /// The instruction (write) or the user's text (polish), exactly as it is in the field.
    public var source: String
    /// Resolved shape (never `adaptive`); polish only looks at it for `aiPrompt`.
    public var shape: WriteShape
    /// Wording that replaces the built-in shape line on a write: the user's edit of the preset,
    /// or a custom shape's text (then `shape` is `paragraph`). Empty means no shape line.
    public var shapeText: String?
    /// Follow-ups typed in the panel's refine box ("shorter", "more formal"), oldest first.
    public var refinements: [String]
    /// The draft the refinements apply to, when there is one.
    public var previousDraft: String?
    /// The writer, the place and the reference text, as for suggestions. `before` and `after` hold
    /// the field's text around the range (reference only).
    public var context: PromptInput
    /// Set for a dictation cleanup: the writers frame it with the dictation prompt instead
    /// (`source` then holds the transcript, `mode` is polish).
    public var dictation: DictationCleanup?
    /// What to do to `source` (`transform` only): the user's spoken instruction.
    public var instruction: String?
    /// Set for suggested replies: the writers frame it with the replies prompt instead and return the
    /// model's text uncleaned (`SuggestedReplies.parse` reads it). `source` is empty, `mode` is write.
    public var replies: ReplyRequest?
    public init(id: RequestID, mode: WriteMode, source: String, shape: WriteShape, refinements: [String] = [],
                previousDraft: String? = nil, context: PromptInput, dictation: DictationCleanup? = nil,
                shapeText: String? = nil, instruction: String? = nil) {
        self.instruction = instruction
        self.shapeText = shapeText
        self.dictation = dictation
        self.id = id
        self.mode = mode
        self.source = source
        self.shape = shape
        self.refinements = refinements
        self.previousDraft = previousDraft
        self.context = context
    }
}

/// Why a write could not run.
public enum WriteError: Error, Sendable, Equatable {
    /// No endpoint and no instruct model on disk.
    case noInstructModel
    case failed(String)
}

/// Generates write-for-me drafts. `partial` gets the whole draft so far (cleaned), repeatedly.
public protocol WriteGenerating: Sendable {
    func write(_ request: WriteRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String
    func cancelWrites()
}
