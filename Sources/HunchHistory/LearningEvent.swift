import Foundation
import HunchCore

/// A learning signal derived from what the user did with a suggestion.
public struct LearningEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Accepted text survived the settle window (or focus left) unedited.
        /// `context` is the up-to-2 words before the first accepted word.
        /// An empty-text word is a break: its neighbors are not adjacent (a URL or email sat between).
        /// `boosted` holds normalized words the decoder was biased toward when it proposed them.
        case confirmed(words: [WordScore], context: [String], boosted: Set<String> = [])
        /// The user typed a different word than the ghost offered.
        case typedOver(context: [String], suggested: String, typed: String)
        /// Accepted word was edited into another word within the settle window.
        case correctedAfterAccept(context: [String], accepted: String, corrected: String)
        /// Escape on a visible suggestion (weak negative signal).
        case dismissed(context: [String], suggested: String)
        /// The user kept `word` as typed instead of the offered spelling fix.
        case correctionSkipped(word: String)
        /// The user cleanly rejected an automatic fix of `word` (undid or deleted it and kept the
        /// word; see `FixRejectionWatch`). A skip that counts more: two learn the word.
        case fixRejected(word: String)
        /// The user typed `word` and kept the automatic fix `fix` (typed on past it): teaches the
        /// personal slip list (`SlipRecord`).
        case fixKept(word: String, fix: String)
        /// An automatic fix to `fix` was cleanly rejected: counts against `fix` as a trouble word.
        case slipFixRejected(fix: String)
        /// The user applied the spelling fix for `word`.
        case correctionAccepted(word: String)
    }
    public var field: FieldID
    public var kind: Kind
    /// Words of this event written with a capital mid-sentence (`WordText.namesMidSentence`), as
    /// written. They are names, so they can be learned even when their lowercase form is ordinary.
    public var names: Set<String>
    public init(field: FieldID, kind: Kind, names: Set<String> = []) {
        self.field = field
        self.kind = kind
        self.names = names
    }
}
