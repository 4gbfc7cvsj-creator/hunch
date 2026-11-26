import HunchCore

/// Keeps web addresses out of suggestions outside search fields. A completion that would make the
/// word being typed into an address ("goo" + "gle.com/search?q=...") is suppressed; an address
/// later in the completion cuts it just before the address.
public enum URLGuard {
    public enum Result: Equatable {
        case unchanged
        case cut(String)
        case url
    }

    public static func check(_ text: String, before: String) -> Result {
        // The word being typed: what follows the last whitespace in `before`.
        let tail = before.lastIndex(where: \.isWhitespace).map { before[before.index(after: $0)...] } ?? before[...]
        var index = text.startIndex
        var first = true
        while index < text.endIndex {
            guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let token = text[start..<end]
            // The first token continues the typed word when the completion does not start with a space.
            let joined = first && start == text.startIndex ? tail + token : token
            if URLShape.isURL(joined) {
                if first { return .url }
                let kept = String(text[..<start]).trimmingSuffixWhitespace()
                return kept.contains(where: { $0.isLetter || $0.isNumber }) ? .cut(kept) : .url
            }
            first = false
            index = end
        }
        return .unchanged
    }
}

private extension String {
    func trimmingSuffixWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
