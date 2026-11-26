import Foundation

/// A detected emoji trigger at the end of the text before the caret.
public struct EmojiTrigger: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case shortcode(query: String)
        case emoticon
    }

    public let kind: Kind
    /// The exact trailing text to replace (e.g. ":smi" or ":)").
    public let triggerText: String
    /// Length of `triggerText` in UTF-16 units (what AX ranges use).
    public var utf16Length: Int { triggerText.utf16.count }
    /// Candidates, best first. Never empty.
    public let candidates: [EmojiMatch]

    static let emoticons: [String: [String]] = {
        var m: [String: [String]] = [:]
        func add(_ keys: [String], _ v: [String]) { for k in keys { m[k] = v } }
        add([":)", ":-)", "=)"], ["🙂", "😊", "😀"])
        add([":(", ":-(", "=("], ["🙁", "😞", "😢"])
        add([":D", ":-D", "=D"], ["😃", "😄", "😁"])
        add([";)", ";-)"], ["😉", "😜"])
        add(["<3"], ["❤️", "💕", "💖"])
        add(["</3"], ["💔"])
        add([":P", ":-P", ":p", ":-p"], ["😛", "😜"])
        add([":O", ":-O", ":o", ":-o"], ["😮", "😲"])
        add([":'(", ":'-("], ["😢", "😭"])
        add(["XD", "xD", "XD"], ["😆", "😂"])
        add([":*", ":-*"], ["😘", "😚"])
        add([":/", ":-/"], ["😕"])
        add([":|", ":-|"], ["😐"])
        add(["^_^"], ["😊"])
        add(["-_-"], ["😑"])
        add([">:(", ">:-("], ["😠", "😡"])
        add(["T_T"], ["😭"])
        add([":3"], ["😺"])
        return m
    }()

    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "+" || c == "-"
    }

    /// Detects a trigger at the end of `before`. `limit` caps the base candidates.
    public static func detect(
        before: String, limit: Int = 5,
        preferences: EmojiPreferences = .default,
        index: EmojiIndex = .shared
    ) -> EmojiTrigger? {
        guard !before.isEmpty else { return nil }

        // Emoticon: the trailing whitespace-delimited token, which must start the text or follow whitespace.
        let tokenStart = before.lastIndex(where: { $0.isWhitespace }).map { before.index(after: $0) } ?? before.startIndex
        let token = String(before[tokenStart...])
        if token.count <= 4, let list = emoticons[token] {
            let cands = list.prefix(limit).flatMap { e in
                EmojiVariants.variants(of: e, prefs: preferences, genderForms: index.genderForms).map {
                    EmojiMatch(emoji: $0, name: "", shortcode: nil)
                }
            }
            return EmojiTrigger(kind: .emoticon, triggerText: token, candidates: cands)
        }

        // Shortcode: ":" (or the full-width "：" Chinese/Japanese input methods type) + >= 2
        // word characters at the very end; one is enough for Chinese/Japanese/Korean.
        var i = before.endIndex
        var count = 0
        while i > before.startIndex {
            let p = before.index(before: i)
            if isWordChar(before[p]) { i = p; count += 1 } else { break }
        }
        guard count >= 1, i > before.startIndex else { return nil }
        let colon = before.index(before: i)
        guard before[colon] == ":" || before[colon] == "：" else { return nil }
        guard count >= 2 || before[i...].unicodeScalars.contains(where: EmojiSearch.isCJK) else { return nil }
        if colon > before.startIndex {
            let prev = before[before.index(before: colon)]
            if prev.isLetter || prev.isNumber || prev == ":" || prev == "/" || prev == "\\" || prev == "_" { return nil }
        }
        let query = String(before[i...])
        guard query.contains(where: { $0.isLetter || $0 == "+" || $0 == "-" || query == "100" }) else { return nil }
        let cands = EmojiSearch.query(query, limit: limit, preferences: preferences, index: index)
        guard !cands.isEmpty else { return nil }
        return EmojiTrigger(kind: .shortcode(query: query), triggerText: String(before[colon...]), candidates: cands)
    }
}

extension EmojiTrigger.Kind {
    /// Whether this kind of trigger may show here: emoticons (":)") and ":" search are switched
    /// separately per app or site.
    public func isAllowed(emoticons: Bool, search: Bool) -> Bool {
        switch self {
        case .emoticon: emoticons
        case .shortcode: search
        }
    }
}
