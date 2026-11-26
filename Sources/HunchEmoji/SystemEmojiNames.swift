import Foundation

/// Emoji names macOS ships for its own emoji picker: one `AppleName.strings` per
/// language, keyed by the untoned emoji string, including ZWJ sequences (families,
/// professions, couples, gendered people) and tag flags. Read-only and local; only
/// emoji the installed OS can draw are listed. A missing folder or file (older or
/// future macOS) gives empty tables and the index falls back to Unicode names.
public struct SystemEmojiNames: Sendable {
    /// Lookup key (see `key(_:)`) -> (emoji as the OS writes it, English name).
    public let english: [String: (emoji: String, name: String)]
    /// Lookup key -> names in the user's other languages, most preferred first.
    public let localized: [String: [String]]
    /// The `.lproj` folders the localized names came from, e.g. ["zh_TW"].
    public let languages: [String]

    public static let resources = URL(
        fileURLWithPath: "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources")

    public static let empty = SystemEmojiNames(english: [:], localized: [:], languages: [])

    public init(english: [String: (emoji: String, name: String)], localized: [String: [String]], languages: [String]) {
        self.english = english
        self.localized = localized
        self.languages = languages
    }

    /// Loads English plus up to `maxExtra` of the user's other languages.
    public static func load(
        preferredLanguages: [String] = Locale.preferredLanguages,
        from dir: URL = resources,
        maxExtra: Int = 3
    ) -> SystemEmojiNames {
        let en = table(dir.appendingPathComponent("en.lproj/AppleName.strings"))
        guard !en.isEmpty else { return .empty }
        var english: [String: (String, String)] = [:]
        for (e, n) in en { english[key(e)] = (e, n) }

        let available = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) })
        let langs = Array(lprojNames(for: preferredLanguages, available: available).prefix(maxExtra))
        var localized: [String: [String]] = [:]
        var used: [String] = []
        for l in langs {
            let t = table(dir.appendingPathComponent("\(l).lproj/AppleName.strings"))
            guard !t.isEmpty else { continue }
            used.append(l)
            for (e, n) in t { localized[key(e), default: []].append(n) }
        }
        return SystemEmojiNames(english: english, localized: localized, languages: used)
    }

    static func table(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [:] }
        return obj as? [String: String] ?? [:]
    }

    /// Emoji strings differ only in where U+FE0F sits (the OS writes "⬛️", Unicode data "⬛");
    /// keys drop it.
    public static func key(_ emoji: String) -> String {
        var v = String.UnicodeScalarView()
        for s in emoji.unicodeScalars where s.value != 0xFE0F { v.append(s) }
        return String(v)
    }

    /// Maps BCP-47 preferred languages ("zh-Hant-US", "de-DE", "pt-BR") to the OS's
    /// `.lproj` names, skipping English (always loaded) and duplicates.
    static func lprojNames(for preferred: [String], available: Set<String>) -> [String] {
        var out: [String] = []
        for id in preferred {
            let loc = Locale(identifier: id)
            guard let lang = loc.language.languageCode?.identifier, lang != "en" else { continue }
            let region = loc.region?.identifier
            let script = loc.language.script?.identifier
            var tries: [String] = []
            if lang == "zh" {
                let hant = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
                if hant { tries = ["HK", "MO"].contains(region ?? "") ? ["zh_HK", "zh_TW"] : ["zh_TW", "zh_HK"] }
                else { tries = ["zh_CN"] }
            } else {
                if let region { tries.append("\(lang)_\(region)") }
                tries.append(lang)
                tries.append(contentsOf: available.filter { $0.hasPrefix(lang + "_") }.sorted())
            }
            if let hit = tries.first(where: { available.contains($0) }), !out.contains(hit) { out.append(hit) }
        }
        return out
    }
}
