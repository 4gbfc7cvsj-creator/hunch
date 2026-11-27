import Foundation
import HunchCore

// EXPERIMENTAL voice instructions for Write for me: a shortcut records speech (dictation's
// recorder and speech model), and the transcript becomes the instruction instead of text for the
// field. With a selection it is applied to the selection (`WriteMode.transform`); with none it
// describes what to write at the caret (`write`); with the panel open it is a refinement.
// The transcript is never inserted into the document. Pure logic only; the app wires it up.

/// Where a voice instruction goes, decided when the shortcut is pressed.
public enum VoiceInstructionTarget: Sendable, Equatable {
    /// The Write for me panel was open: the words refine its draft.
    case panel
    /// The focused text box: the selection to transform, or the caret to write at.
    case field
}

/// Why a voice instruction was refused. Every refusal beeps and says so in the pill.
public enum VoiceInstructionRefusal: String, Error, Sendable, Equatable {
    /// The experimental toggle or dictation is off.
    case off
    /// A dictation, a voice instruction or a Write for me (opening, inserting) is still running.
    case busy
    /// A password or secure field, or an app excluded as secure.
    case secureField
    /// No text box Hunch can read here (it is off in this app, or nothing editable is focused).
    case noField
    /// Spoken for the panel, but the panel was closed meanwhile.
    case panelClosed
    /// Spoken for the text box, but Write for me opened meanwhile (typed shortcut).
    case panelOpened
    /// The selection is longer than Write for me takes.
    case selectionTooLong
}

/// What happens to a transcript once it is ready.
public enum VoiceInstructionDelivery: Sendable, Equatable {
    /// Into the open panel's refine box, run at once.
    case refine
    /// The selection is the text, the words are the instruction (`WriteMode.transform`).
    case transformSelection
    /// No selection: the words describe what to write at the caret (`WriteMode.write`).
    case writeAtCaret
    case refuse(VoiceInstructionRefusal)
}

public enum VoiceInstructionRoute {
    /// What is going on when the shortcut is pressed.
    public struct PressState: Sendable, Equatable {
        public var featureOn: Bool
        public var dictationEnabled: Bool
        /// The Write for me panel is showing.
        public var panelOpen: Bool
        /// Write for me is reading the field to open, or inserting an accepted draft.
        public var writeBusy: Bool
        /// A dictation or voice instruction is recording or being transcribed / cleaned up.
        public var speechBusy: Bool
        /// Secure Event Input is on, or focus is blocked as a secure field.
        public var secureInput: Bool
        /// Hunch reads the focused text box (Write for me works here).
        public var readableField: Bool

        public init(featureOn: Bool, dictationEnabled: Bool, panelOpen: Bool, writeBusy: Bool, speechBusy: Bool,
                    secureInput: Bool, readableField: Bool) {
            self.featureOn = featureOn
            self.dictationEnabled = dictationEnabled
            self.panelOpen = panelOpen
            self.writeBusy = writeBusy
            self.speechBusy = speechBusy
            self.secureInput = secureInput
            self.readableField = readableField
        }
    }

    /// Whether to start recording, and for what. The model's state plays no part: an idle-released
    /// Language Model loads when the draft is requested, like a typed Write for me.
    public static func atPress(_ s: PressState) -> Result<VoiceInstructionTarget, VoiceInstructionRefusal> {
        guard s.featureOn, s.dictationEnabled else { return .failure(.off) }
        guard !s.speechBusy, !s.writeBusy else { return .failure(.busy) }
        // The panel is Hunch's own window: the field's state doesn't matter while it is open.
        if s.panelOpen { return .success(.panel) }
        guard !s.secureInput else { return .failure(.secureField) }
        guard s.readableField else { return .failure(.noField) }
        return .success(.field)
    }

    /// Where a finished transcript goes. `selectedText` is the field's selection as read when the
    /// transcript is ready (nil before the read, or for the panel).
    public static func atDelivery(target: VoiceInstructionTarget, panelOpenNow: Bool, writeBusyNow: Bool,
                                  selectedText: String?) -> VoiceInstructionDelivery {
        switch target {
        case .panel:
            return panelOpenNow ? .refine : .refuse(.panelClosed)
        case .field:
            if panelOpenNow { return .refuse(.panelOpened) }
            if writeBusyNow { return .refuse(.busy) }
            let selected = selectedText ?? ""
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .writeAtCaret }
            guard selected.count <= WriteRange.maxCharacters else { return .refuse(.selectionTooLong) }
            return .transformSelection
        }
    }
}

public enum VoiceInstruction {
    /// The transcript as an instruction: whitespace collapsed and trimmed, quotes around all of it
    /// and one closing period dropped. No cleanup pass (one model call saved; the instruction is
    /// read by the model, not by people). Nil when nothing was said.
    public static func clean(_ transcript: String) -> String? {
        var text = transcript.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("「", "」"), ("『", "』")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let last = text.last, last == "." || last == "。", !text.hasSuffix("..") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !DictationText.isEmptySpeech(text) else { return nil }
        return text
    }

    /// The pill's line for a refusal.
    public static func message(_ refusal: VoiceInstructionRefusal) -> String {
        switch refusal {
        case .off: "Voice instructions are off"
        case .busy: "Still busy with the last one"
        case .secureField: "Voice instructions are off in password fields"
        case .noField: "Click into a text box first"
        case .panelClosed: "Write for me was closed"
        case .panelOpened: "Write for me is already open: speak again to refine"
        case .selectionTooLong: "The selection is too long for Write for me"
        }
    }

    /// The pill's line once the words are in: what was heard, short enough for the pill.
    public static func heard(_ instruction: String, limit: Int = 60) -> String {
        let shown = instruction.count > limit ? String(instruction.prefix(limit - 1)) + "…" : instruction
        return "\u{201C}" + shown + "\u{201D}"
    }

    /// A voice draft in the script the user writes Chinese in: Traditional when the text it rewrites
    /// uses Traditional characters, or when that text has none and the user types Traditional (their
    /// keyboard or languages say so). Models often answer in Simplified; Simplified text stays as it is.
    public static func matchScript(_ draft: String, source: String, prefersTraditional: Bool) -> String {
        guard HanScript.usesSimplified(draft) else { return draft }
        let wantsTraditional = HanScript.usesTraditional(source)
            || (prefersTraditional && !HanScript.usesSimplified(source))
        return wantsTraditional ? HanScript.traditional(draft) : draft
    }

    /// What goes between the text before the caret and a draft written at the caret: nothing at
    /// the start of the box, after whitespace, next to Chinese or Japanese, or before punctuation;
    /// else one space.
    public static func separator(before: String, draft: String) -> String {
        guard let last = before.last, let first = draft.first else { return "" }
        if last.isWhitespace { return "" }
        if last.unicodeScalars.contains(where: isHanScalar) || first.unicodeScalars.contains(where: isHanScalar) {
            return ""
        }
        if ".,;:!?)]}…".contains(first) { return "" }
        return " "
    }
}

/// The instruction the user spoke last in a Write for me session, so it can be edited in the
/// panel and run again in its place (a misheard word fixed by typing).
public struct SpokenInstruction: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// What opened the panel: the transform's instruction, or the description to write from.
        case initial
        /// A refinement, with the refinements and draft from before it.
        case refinement(baseRefinements: [String], baseDraft: String?)
    }

    /// What the request becomes after an edit.
    public struct Rerun: Sendable, Equatable {
        /// The new initial instruction (nil for a refinement: the instruction stays).
        public var instruction: String?
        public var refinements: [String]
        public var previousDraft: String?
    }

    public var text: String
    public var kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    /// The request after replacing this instruction with `edited`; nil when the edit leaves nothing
    /// (or nothing changed, which still re-runs: the user pressed Return to try again).
    public func rerun(with edited: String) -> Rerun? {
        let text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch kind {
        case .initial:
            return Rerun(instruction: text, refinements: [], previousDraft: nil)
        case .refinement(let base, let draft):
            return Rerun(instruction: nil, refinements: base + [text], previousDraft: draft)
        }
    }
}

extension VoiceInstruction {
    /// Another Hunch shortcut that uses the same keys as the voice instruction shortcut, by its
    /// Settings name; nil when there is none. A clashing voice shortcut is not registered.
    public static func conflict(_ voice: KeyChord?, dictation: KeyChord?, bindings: AcceptBindings) -> String? {
        guard let voice else { return nil }
        let others: [(String, KeyChord?)] = [
            ("Dictation", dictation), ("Write for me", bindings.writeForMe),
            ("Accept next word", bindings.word), ("Accept whole suggestion", bindings.full),
            ("Next suggestion style", bindings.styleNext), ("Previous suggestion style", bindings.stylePrevious),
        ]
        return others.first { $0.1 == voice }?.0
    }
}
