import Foundation

/// A single suggestion candidate.
public struct EmojiMatch: Sendable, Equatable {
    /// The string to insert (preferences already applied).
    public let emoji: String
    /// Display name, e.g. "Fire".
    public let name: String
    /// Best shortcode alias, when one exists (no colons).
    public let shortcode: String?
}

public enum EmojiSearch {
    /// Case-insensitive search over aliases, English names, the user's other-language names
    /// and the OS picker's English keywords. Ranking: exact alias, alias prefix, name-word
    /// prefix, substring, then keywords (exact, then 3+ letter prefix) by the picker's weight.
    /// An exact keyword moves above name-word prefixes when no alias or whole name word
    /// matches (":lol" -> 🤣 before 🍭). Ties broken by neutral-before-gendered, popularity,
    /// shorter name, then index order.
    /// `limit` counts base emoji; skin-tone/gender variants of one base are adjacent.
    public static func query(
        _ term: String, limit: Int,
        preferences: EmojiPreferences = .default,
        index: EmojiIndex = .shared
    ) -> [EmojiMatch] {
        guard limit > 0 else { return [] }
        let q = EmojiIndex.fold(term).trimmingCharacters(in: CharacterSet(charactersIn: ":："))
            .replacingOccurrences(of: " ", with: "_")
        guard !q.isEmpty else { return [] }
        // Chinese/Japanese names have no spaces, so any part of the name can match.
        let cjk = q.unicodeScalars.contains(where: isCJK)

        var exactKeyword: [Int: Int] = [:]
        for h in index.keywords[q] ?? [] { exactKeyword[h.entry] = max(exactKeyword[h.entry] ?? 0, h.weight) }
        var prefixKeyword: [Int: Int] = [:]
        if q.count >= 3, !cjk {
            var lo = 0, hi = index.keywordTerms.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if index.keywordTerms[mid] < q { lo = mid + 1 } else { hi = mid }
            }
            while lo < index.keywordTerms.count, index.keywordTerms[lo].hasPrefix(q) {
                let t = index.keywordTerms[lo]
                lo += 1
                guard t != q else { continue }
                for h in index.keywords[t] ?? [] { prefixKeyword[h.entry] = max(prefixKeyword[h.entry] ?? 0, h.weight) }
            }
        }

        // Tiers: 0 exact alias, 2 alias prefix, 4 name prefix, 6 substring; 3 or 7 exact
        // keyword (see above), 8 keyword prefix.
        // (tier, aliasLength or -weight, genderVariant, popularity, nameLength, index)
        var hits: [(Int, Int, Int, Int, Int, Int)] = []
        var strongName = false
        var keywordHits: [(entry: Int, weight: Int, exact: Bool, nameTier: Int)] = []
        for (i, e) in index.entries.enumerated() {
            var tier = Int.max
            var aliasLen = 0
            for a in e.aliases {
                if a == q { tier = 0; break }
                if a.hasPrefix(q), tier > 2 || a.count < aliasLen { tier = 2; aliasLen = a.count }
            }
            if tier > 4 {
                if e.joinedName.hasPrefix(q) { tier = 4 }
                else if e.words.contains(where: { $0.hasPrefix(q) }) { tier = 4 }
            }
            if tier > 4 {
                for n in e.localNames {
                    if n.hasPrefix(q) { tier = 4; break }
                    if tier > 6, cjk || q.count >= 3, n.contains(q) { tier = 6 }
                }
                if tier > 4, e.localWords.contains(where: { $0.hasPrefix(q) }) { tier = 4 }
            }
            if tier > 6, q.count >= 3, e.joinedName.contains(q) { tier = 6 }
            if tier <= 2 || e.words.contains(q) || e.joinedName == q || e.joinedName.hasPrefix(q + "_")
                || e.localNames.contains(q) || e.localWords.contains(q) {
                strongName = true
            }
            // Exact keywords are placed once `strongName` is known; the better tier wins.
            if let w = exactKeyword[i], tier > 3 {
                keywordHits.append((i, w, true, tier))
            } else if tier != Int.max {
                hits.append((tier, tier == 2 ? aliasLen : 0, e.isGenderVariant ? 1 : 0, e.popularity, e.joinedName.count, i))
            } else if let w = prefixKeyword[i] {
                keywordHits.append((i, w, false, tier))
            }
        }
        for k in keywordHits {
            let e = index.entries[k.entry]
            let tier = k.exact ? (strongName ? 7 : 3) : 8
            if k.nameTier < tier {
                hits.append((k.nameTier, 0, e.isGenderVariant ? 1 : 0, e.popularity, e.joinedName.count, k.entry))
            } else {
                hits.append((tier, -k.weight, e.isGenderVariant ? 1 : 0, e.popularity, e.joinedName.count, k.entry))
            }
        }
        hits.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            if a.3 != b.3 { return a.3 < b.3 }
            if a.4 != b.4 { return a.4 < b.4 }
            return a.5 < b.5
        }

        var result: [EmojiMatch] = []
        var emitted: Set<String> = []
        var bases = 0
        for h in hits where bases < limit {
            let e = index.entries[h.5]
            let code = e.aliases.first(where: { $0.hasPrefix(q) }) ?? e.aliases.first
            // A gendered entry can repeat what a neutral entry already produced.
            let vs = EmojiVariants.variants(of: e.emoji, prefs: preferences, genderForms: index.genderForms)
                .filter { emitted.insert($0).inserted }
            guard !vs.isEmpty else { continue }
            bases += 1
            for v in vs { result.append(EmojiMatch(emoji: v, name: e.name, shortcode: code)) }
        }
        return result
    }

    /// Han, kana and Hangul scalars.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }
}
