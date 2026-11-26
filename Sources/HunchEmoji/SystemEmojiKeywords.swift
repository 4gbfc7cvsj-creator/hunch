import Foundation

/// The keyword index macOS ships for its emoji picker's search (CoreEmoji
/// `SearchModel-en/term_index.plist` + `document_index.plist`): search words like "yay",
/// "bonfire" or "hashtag" that are not in the emoji's name, each with a relevance weight.
/// English only. The index refers to emoji by CoreEmoji's token number, which only CoreEmoji
/// can turn into the emoji string (`CEMEmojiTokenCreateWithIndex`, looked up at runtime).
/// A missing file or function (older or future macOS) gives an empty table; name search is
/// unaffected.
public struct SystemEmojiKeywords: Sendable {
    /// Folded keyword (see `EmojiIndex.fold`, spaces as "_") -> (emoji key, weight), best first.
    public let terms: [String: [(key: String, weight: Int)]]

    public static let empty = SystemEmojiKeywords(terms: [:])

    public static let modelDirectory = SystemEmojiNames.resources.appendingPathComponent("SearchModel-en")

    public init(terms: [String: [(key: String, weight: Int)]]) {
        self.terms = terms
    }

    /// Loads the English index. `emojiForToken` maps CoreEmoji's token number to the emoji
    /// string; it defaults to CoreEmoji itself.
    public static func load(
        from dir: URL = modelDirectory,
        emojiForToken: ((Int) -> String?)? = nil
    ) -> SystemEmojiKeywords {
        guard let terms = plist(dir.appendingPathComponent("term_index.plist")) as? [String: [Int]],
              let docs = plist(dir.appendingPathComponent("document_index.plist")) as? [String: [String: Any]]
        else { return .empty }
        guard let lookup = emojiForToken ?? CoreEmojiTokens.make() else { return .empty }

        var emojiKey: [Int: String] = [:]
        func key(_ token: Int) -> String? {
            if let k = emojiKey[token] { return k.isEmpty ? nil : k }
            let k = lookup(token).map(SystemEmojiNames.key) ?? ""
            emojiKey[token] = k
            return k.isEmpty ? nil : k
        }

        var out: [String: [(key: String, weight: Int)]] = [:]
        out.reserveCapacity(terms.count)
        for (term, tokens) in terms {
            let t = EmojiIndex.fold(term).replacingOccurrences(of: " ", with: "_")
            guard !t.isEmpty else { continue }
            var hits = out[t] ?? []
            for token in tokens {
                guard let k = key(token) else { continue }
                let w = ((docs[String(token)]?[term] as? [String: Any])?["w"] as? Int) ?? 0
                if let i = hits.firstIndex(where: { $0.key == k }) {
                    hits[i].weight = max(hits[i].weight, w)
                } else {
                    hits.append((k, w))
                }
            }
            if !hits.isEmpty { out[t] = hits }
        }
        for (t, hits) in out { out[t] = hits.sorted { $0.weight > $1.weight } }
        return SystemEmojiKeywords(terms: out)
    }

    static func plist(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}

/// CoreEmoji's token-number -> emoji lookup, resolved with `dlsym` so a macOS without these
/// private functions just has no keywords.
enum CoreEmojiTokens {
    private typealias CreateLocaleData = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
    private typealias CreateToken = @convention(c) (CFIndex, CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias TokenString = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?

    static func make() -> ((Int) -> String?)? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/CoreEmoji.framework/CoreEmoji", RTLD_NOW | RTLD_LOCAL),
              let pLocale = dlsym(h, "CEMCreateEmojiLocaleData"),
              let pToken = dlsym(h, "CEMEmojiTokenCreateWithIndex"),
              let pString = dlsym(h, "CEMEmojiTokenGetString")
        else { return nil }
        let createLocale = unsafeBitCast(pLocale, to: CreateLocaleData.self)
        let createToken = unsafeBitCast(pToken, to: CreateToken.self)
        let tokenString = unsafeBitCast(pString, to: TokenString.self)
        guard let locale = createLocale("en" as CFString)?.takeRetainedValue() else { return nil }
        return { index in
            guard index > 0, let token = createToken(index, locale)?.takeRetainedValue() else { return nil }
            return tokenString(token)?.takeUnretainedValue() as String?
        }
    }
}
