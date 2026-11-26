import Foundation

public enum SessionInput: Sendable {
    case context(TextContext)
    case suggestion(Suggestion)
    case acceptWord
    case acceptAll
    case dismiss
    case blocked(BlockReason)
}

public enum SessionEffect: Sendable, Equatable {
    case show(text: String)
    case hide
    case insert(String)
    case requestCompletion(TextContext, refill: Bool)
    case none
}

public protocol ResultCaching: Sendable {
    func lookup(prefixSignature: UInt64, framer: String, model: String) -> Suggestion?
    func store(_ suggestion: Suggestion, prefixSignature: UInt64, framer: String, model: String)
}
