import Foundation

/// Preferred skin tone for emoji whose base scalar has the Emoji_Modifier_Base property.
public enum EmojiSkinTone: String, Sendable, CaseIterable, Codable {
    case none, light, mediumLight, medium, mediumDark, dark

    /// The Fitzpatrick modifier scalar (U+1F3FB...U+1F3FF), or nil for `.none`.
    public var modifier: Unicode.Scalar? {
        switch self {
        case .none: return nil
        case .light: return Unicode.Scalar(0x1F3FB)
        case .mediumLight: return Unicode.Scalar(0x1F3FC)
        case .medium: return Unicode.Scalar(0x1F3FD)
        case .mediumDark: return Unicode.Scalar(0x1F3FE)
        case .dark: return Unicode.Scalar(0x1F3FF)
        }
    }
}

public enum EmojiGender: String, Sendable, CaseIterable, Codable {
    case neutral, female, male
}

/// User preferences applied to search results.
public struct EmojiPreferences: Sendable, Equatable, Codable {
    public var skinTone: EmojiSkinTone
    /// When a skin tone is chosen, also offer the neutral (yellow) variant right after the toned one.
    public var includeNeutral: Bool
    public var gender: EmojiGender

    public init(skinTone: EmojiSkinTone = .none, includeNeutral: Bool = false, gender: EmojiGender = .neutral) {
        self.skinTone = skinTone
        self.includeNeutral = includeNeutral
        self.gender = gender
    }

    public static let `default` = EmojiPreferences()
}

enum EmojiVariants {
    static let fe0f = Unicode.Scalar(0xFE0F)!
    static let zwj = Unicode.Scalar(0x200D)!

    /// Person emoji for which "<base> [tone] ZWJ <female|male sign> FE0F" is a valid
    /// (RGI) sequence. Deliberately conservative; anything not listed is never gendered.
    static let genderable: Set<UInt32> = [
        0x1F647, 0x1F926, 0x1F937, 0x1F64B, 0x1F646, 0x1F645, 0x1F481, 0x1F64D, 0x1F64E,
        0x1F486, 0x1F487, 0x1F6B6, 0x1F3C3, 0x1F9CD, 0x1F9CE, 0x1F9D6, 0x1F9D7, 0x1F9D8,
        0x1F938, 0x1F93D, 0x1F93E, 0x1F939, 0x1F3C4, 0x1F3CA, 0x1F6A3, 0x1F6B4, 0x1F6B5,
        0x1F3CC, 0x1F3CB, 0x26F9, 0x1F575, 0x1F482, 0x1F477, 0x1F46E, 0x1F9B8, 0x1F9B9,
        0x1F9D9, 0x1F9DA, 0x1F9DB, 0x1F9DC, 0x1F9DD, 0x1F9DE, 0x1F9DF, 0x1F46F, 0x1F93C,
        0x1F471, 0x1F473, 0x1F9D4,
    ]

    /// Number of scalars in `emoji` that take a skin tone.
    static func modifierBaseCount(_ emoji: String) -> Int {
        emoji.unicodeScalars.filter { $0.properties.isEmojiModifierBase }.count
    }

    /// Expands one base emoji string into the variants dictated by `prefs`, best first.
    /// `genderForms` comes from the OS's emoji names (`EmojiIndex.genderForms`); when it is
    /// empty the conservative hand-written `genderable` list is used instead.
    static func variants(
        of base: String, prefs: EmojiPreferences,
        genderForms: [String: (female: String?, male: String?)] = [:]
    ) -> [String] {
        var gendered = base
        var genderOK = false
        if prefs.gender != .neutral {
            if !genderForms.isEmpty {
                if let f = genderForms[SystemEmojiNames.key(base)],
                   let g = prefs.gender == .female ? f.female : f.male {
                    gendered = g
                    genderOK = true
                }
            } else if let first = base.unicodeScalars.first, base.unicodeScalars.count <= 2,
                      genderable.contains(first.value) {
                var s = String.UnicodeScalarView(base.unicodeScalars)
                s.append(zwj)
                s.append(prefs.gender == .female ? Unicode.Scalar(0x2640)! : Unicode.Scalar(0x2642)!)
                s.append(fe0f)
                gendered = String(s)
                genderOK = true
            }
        }

        // A tone goes right after each person (replacing a FE0F that follows it). Sequences
        // with one person take it, and so do couples (❤), handshakes (🫱‍🫲) and people holding
        // hands (🧑‍🤝‍🧑, whose middle 🤝 stays untoned). Families stay untoned.
        let scalars = Array(gendered.unicodeScalars)
        let bases = modifierBaseCount(gendered)
        let pair = scalars.contains { $0.value == 0x2764 } || scalars.first?.value == 0x1FAF1
            || (scalars.count == 5 && scalars[2].value == 0x1F91D)
        let toneable = bases == 1 || (pair && bases >= 2)
        guard (toneable && prefs.skinTone != .none) || genderOK else { return [base] }
        guard toneable, let m = prefs.skinTone.modifier else { return [gendered] }

        var toned = String.UnicodeScalarView()
        var skipFE0F = false
        for (i, s) in scalars.enumerated() {
            if skipFE0F { skipFE0F = false; if s == fe0f { continue } }
            toned.append(s)
            let middleHandshake = s.value == 0x1F91D && i > 0 && i < scalars.count - 1
            if s.properties.isEmojiModifierBase, !middleHandshake { toned.append(m); skipFE0F = true }
        }
        return prefs.includeNeutral ? [String(toned), gendered] : [String(toned)]
    }
}
