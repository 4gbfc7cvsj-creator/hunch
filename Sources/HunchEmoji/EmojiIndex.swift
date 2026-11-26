import Foundation

/// One searchable emoji. Value type; all search keys are precomputed lowercase.
public struct EmojiEntry: Sendable, Equatable {
    /// Neutral (un-toned, ungendered) emoji string; text-default scalars carry U+FE0F.
    public let emoji: String
    /// Title-cased English name, e.g. "Grinning Face With Smiling Eyes".
    public let name: String
    let words: [String]
    let joinedName: String
    let aliases: [String]
    /// Names in the user's other languages, folded (lowercase, no diacritics), with
    /// words joined by "_" like `joinedName`.
    let localNames: [String]
    /// The words of `localNames`, for word-prefix matching.
    let localWords: [String]
    /// Lower is more popular; `Int.max` when not on the popular list.
    let popularity: Int
    /// A woman/man form of another entry (ranked after the neutral one on ties).
    let isGenderVariant: Bool
}

/// The searchable emoji set, built once from the OS's Unicode data (Swift's
/// `Unicode.Scalar.Properties`), the OS's emoji picker names (`SystemEmojiNames`) and a
/// small hand-written alias table, plus the picker's English search keywords
/// (`SystemEmojiKeywords`).
///
/// Scope: single emoji scalars (text-default ones get U+FE0F), keycap sequences, flags for
/// ISO region codes, and every sequence the OS names (ZWJ families, professions, couples,
/// gendered people, tag flags). Skin-tone and gender variants are generated on demand
/// (`EmojiVariants`) from the neutral entry.
public struct EmojiIndex: Sendable {
    public static let shared = EmojiIndex()

    public let entries: [EmojiEntry]
    /// Neutral emoji key -> its woman / man forms, derived from the names the OS lists.
    /// Empty when the OS tables are missing (then `EmojiVariants.genderable` is used).
    let genderForms: [String: (female: String?, male: String?)]
    /// Languages of the localized names, as `.lproj` identifiers (e.g. "zh_TW").
    public let nameLanguages: [String]
    /// Folded search keyword -> (entry index, weight), best first.
    let keywords: [String: [(entry: Int, weight: Int)]]
    /// `keywords`' terms, sorted, for prefix lookup.
    let keywordTerms: [String]

    static let stopWords: Set<String> = ["with", "and", "of", "the", "for", "in", "on", "a", "at"]

    public init(system: SystemEmojiNames = .load(), keywords: SystemEmojiKeywords = .load()) {
        var aliasByScalar: [UInt32: [String]] = [:]
        for (e, a) in EmojiAliases.rows {
            if let f = e.unicodeScalars.first { aliasByScalar[f.value, default: []].append(contentsOf: a) }
        }
        var popularity: [UInt32: Int] = [:]
        for (i, e) in EmojiAliases.popular.enumerated() {
            if let f = e.unicodeScalars.first, popularity[f.value] == nil { popularity[f.value] = i }
        }

        let genderForms = Self.genderForms(system)
        var variantKeys: Set<String> = []
        for (_, f) in genderForms {
            if let w = f.female { variantKeys.insert(SystemEmojiNames.key(w)) }
            if let m = f.male { variantKeys.insert(SystemEmojiNames.key(m)) }
        }

        var out: [EmojiEntry] = []
        out.reserveCapacity(2200)
        var seen: Set<String> = []

        func split(_ s: String) -> [String] {
            s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        }
        func make(_ emoji: String, _ rawName: String, extraWords: [String] = [], extraAliases: [String] = [], key: UInt32?) -> EmojiEntry {
            let k = SystemEmojiNames.key(emoji)
            let lower = rawName.lowercased()
            let words = lower.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            var kept = words.filter { !Self.stopWords.contains($0) } + extraWords
            // The OS picker's English name often differs from the Unicode name
            // ("person shrugging" vs "shrug"); its words are searchable too.
            if let apple = system.english[k]?.name.lowercased(), apple != lower {
                for w in split(apple) where !Self.stopWords.contains(w) && !kept.contains(w) { kept.append(w) }
            }
            var aliases = key.flatMap { aliasByScalar[$0] } ?? []
            aliases.append(contentsOf: extraAliases)
            let local = (system.localized[k] ?? []).map { n in
                split(Self.fold(n)).joined(separator: "_")
            }
            return EmojiEntry(
                emoji: emoji,
                name: rawName.capitalized,
                words: kept,
                joinedName: words.joined(separator: "_"),
                aliases: aliases,
                localNames: local,
                localWords: local.flatMap { $0.split(separator: "_").map(String.init) },
                popularity: key.flatMap { popularity[$0] } ?? Int.max,
                isGenderVariant: variantKeys.contains(k))
        }
        func add(_ e: EmojiEntry) {
            out.append(e)
            seen.insert(SystemEmojiNames.key(e.emoji))
        }

        let ranges: [ClosedRange<UInt32>] = [0x203C...0x3300, 0x1F000...0x1FAFF]
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v) else { continue }
                let p = s.properties
                guard p.isEmoji else { continue }
                if (0x1F1E6...0x1F1FF).contains(v) || (0x1F3FB...0x1F3FF).contains(v) { continue }
                guard p.isEmojiPresentation || v >= 0x2190 else { continue }
                guard let name = p.name, !name.isEmpty else { continue }
                var str = String(Character(s))
                if !p.isEmojiPresentation { str.unicodeScalars.append(EmojiVariants.fe0f) }
                add(make(str, name, key: v))
            }
        }

        // Keycaps: 0-9, #, *
        for ch in "0123456789#*" {
            let s = String(ch) + "\u{FE0F}\u{20E3}"
            let label = ch == "#" ? "number sign" : (ch == "*" ? "asterisk" : String(ch))
            add(make(s, "keycap \(label)", extraAliases: ["keycap_\(ch == "#" ? "hash" : (ch == "*" ? "star" : String(ch)))"], key: 0xFFFF_FF00 + (ch.unicodeScalars.first!.value & 0xFF)))
        }

        // Flags for ISO regions, named with the OS's English region names.
        let en = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            guard let country = en.localizedString(forRegionCode: code) else { continue }
            var str = ""
            for u in code.uppercased().unicodeScalars { str.unicodeScalars.append(Unicode.Scalar(0x1F1E6 + u.value - 65)!) }
            // Some ISO codes have no flag (EZ eurozone, QO outlying Oceania); the OS names
            // only flags it can draw.
            if !system.english.isEmpty, system.english[str] == nil { continue }
            add(make(str, "flag \(country)", extraAliases: ["flag_\(code.lowercased())"], key: 0xFFFF_0000))
        }

        // Everything else the OS names: ZWJ sequences and tag flags. Sorted for a stable order.
        // Skipped: the OS's per-market variants ("🇹🇼@CH-SKU") and region pairs no font draws
        // as a flag (🇪🇿, 🇶🇴); real region flags were added above.
        for k in system.english.keys.sorted() where !seen.contains(k) {
            if k.unicodeScalars.contains(where: { $0.isASCII }) { continue }
            if k.unicodeScalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) { continue }
            let (emoji, name) = system.english[k]!
            add(make(emoji, split(name).joined(separator: " "), key: nil))
        }

        var entryByKey: [String: Int] = [:]
        for (i, e) in out.enumerated() where entryByKey[SystemEmojiNames.key(e.emoji)] == nil {
            entryByKey[SystemEmojiNames.key(e.emoji)] = i
        }
        var kw: [String: [(entry: Int, weight: Int)]] = [:]
        for (term, hits) in keywords.terms {
            let mapped = hits.compactMap { h in entryByKey[h.key].map { (entry: $0, weight: h.weight) } }
            if !mapped.isEmpty { kw[term] = mapped }
        }

        entries = out
        self.genderForms = genderForms
        nameLanguages = system.languages
        self.keywords = kw
        keywordTerms = kw.keys.sorted()
    }

    /// Case- and diacritic-insensitive form used for localized names and queries.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Woman/man forms the OS names, for two patterns:
    /// "<person> ZWJ ♀/♂ FE0F" (🤷 -> 🤷‍♀️) and "🧑 ZWJ <thing>" -> "👩/👨 ZWJ <thing>" (🧑‍🚀 -> 👩‍🚀).
    static func genderForms(_ system: SystemEmojiNames) -> [String: (female: String?, male: String?)] {
        var out: [String: (female: String?, male: String?)] = [:]
        let names = system.english
        for (k, v) in names {
            let scalars = Array(k.unicodeScalars)
            // Sign style: the neutral is any named emoji; look up its +♀ / +♂ forms. A
            // directional sequence takes the sign before the arrow (🏃‍➡️ -> 🏃‍♀️‍➡️).
            if !scalars.contains(EmojiVariants.zwj) {
                let w = names[k + "\u{200D}\u{2640}"]?.emoji
                let m = names[k + "\u{200D}\u{2642}"]?.emoji
                if w != nil || m != nil { out[k] = (w, m) }
            } else if scalars.count >= 3, scalars[0].value != 0x1F9D1, scalars[1] == EmojiVariants.zwj {
                let head = String(scalars[0])
                let rest = String(String.UnicodeScalarView(scalars.dropFirst()))
                let w = names[head + "\u{200D}\u{2640}" + rest]?.emoji
                let m = names[head + "\u{200D}\u{2642}" + rest]?.emoji
                if w != nil || m != nil { out[k] = (w, m) }
            }
            // Prefix style: 🧑 ZWJ ... -> 👩 / 👨 ZWJ ...
            if scalars.count >= 3, scalars[0].value == 0x1F9D1, scalars[1] == EmojiVariants.zwj, out[k] == nil {
                let rest = String(String.UnicodeScalarView(scalars.dropFirst()))
                let w = names["\u{1F469}" + rest]?.emoji
                let m = names["\u{1F468}" + rest]?.emoji
                // Couples and families start with 🧑 too, but all people in them are adults
                // of any gender; only sequences with one person are gendered this way.
                if (w != nil || m != nil), EmojiVariants.modifierBaseCount(v.emoji) == 1 { out[k] = (w, m) }
            }
        }
        return out
    }
}
