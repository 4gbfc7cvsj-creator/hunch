// Writing-system guardrail: never show suggestion letters the user cannot type. Pure.
import Foundation

/// Classifies letters into writing systems and cuts a completion at the first letter whose system the
/// writer has no way to type (see `PostContext.allowedScripts`). Digits, punctuation, symbols, emoji and
/// whitespace are never foreign.
public enum ScriptGuard {
    public enum Script: String, Sendable, CaseIterable {
        case latin, cyrillic, greek, han, bopomofo, kana, hangul, arabic, hebrew, thai, devanagari, other
    }

    public enum CutResult: Equatable, Sendable {
        case unchanged
        case cut(String)
        /// Nothing meaningful remains once the foreign part is removed.
        case foreign
    }

    /// The script of a letter scalar; nil for anything that is not a letter (always allowed).
    public static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: break
        default: return nil
        }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x250...0x2AF, 0x1E00...0x1EFF,
             0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: return .cyrillic
        case 0x590...0x5FF, 0xFB1D...0xFB4F: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x900...0x97F, 0xA8E0...0xA8FF: return .devanagari
        case 0xE00...0xE7F: return .thai
        case 0x3100...0x312F, 0x31A0...0x31BF: return .bopomofo
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF: return .hangul
        case 0x2E80...0x2FDF, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x323AF:
            return .han
        default: return .other
        }
    }

    /// Scripts of every letter in `text`.
    public static func scripts(in text: String) -> Set<Script> {
        var found = Set<Script>()
        for scalar in text.unicodeScalars { if let s = script(of: scalar) { found.insert(s) } }
        return found
    }

    /// Scripts a BCP-47 language (as macOS reports for an input source) is written in. Unknown
    /// languages yield an empty set.
    public static func scripts(forLanguage identifier: String) -> Set<String> {
        let language = Locale.Language(identifier: identifier)
        let maximal = language.maximalIdentifier
        let parts = maximal.split(whereSeparator: { $0 == "-" || $0 == "_" })
        let code = parts.first.map { $0.lowercased() } ?? ""
        let tag = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }.map { $0.capitalized } ?? ""
        var out = Set<Script>()
        switch tag {
        case "Latn": out = [.latin]
        case "Cyrl": out = [.cyrillic]
        case "Grek": out = [.greek]
        case "Hant": out = [.han, .bopomofo]
        case "Hans", "Hani": out = [.han]
        case "Jpan": out = [.han, .kana]
        case "Hira", "Kana": out = [.kana, .han]
        case "Kore": out = [.hangul, .han]
        case "Hang": out = [.hangul]
        case "Bopo": out = [.bopomofo, .han]
        case "Arab": out = [.arabic]
        case "Hebr": out = [.hebrew]
        case "Thai": out = [.thai]
        case "Deva": out = [.devanagari]
        default: break
        }
        if code == "ja" { out.formUnion([.han, .kana]) }
        return Set(out.map(\.rawValue))
    }

    /// Script names for a set of input-source languages.
    public static func scripts(forLanguages identifiers: [String]) -> Set<String> {
        identifiers.reduce(into: Set<String>()) { $0.formUnion(scripts(forLanguage: $1)) }
    }

    /// The allowed set for one request: keyboard scripts, Latin, and scripts already in the text.
    public static func permitted(_ allowed: Set<String>, before: String, after: String) -> Set<String> {
        var out = allowed
        out.insert(Script.latin.rawValue)
        for s in scripts(in: String(before.suffix(500))) { out.insert(s.rawValue) }
        for s in scripts(in: String(after.prefix(500))) { out.insert(s.rawValue) }
        return out
    }

    /// Cuts `text` at the first letter outside `allowed` and drops whitespace/punctuation left dangling.
    public static func cut(_ text: String, allowed: Set<String>) -> CutResult {
        var cutIndex: String.Index?
        for index in text.unicodeScalars.indices {
            if let s = script(of: text.unicodeScalars[index]), !allowed.contains(s.rawValue) {
                cutIndex = index
                break
            }
        }
        guard let cutIndex else { return .unchanged }
        var kept = String(text.unicodeScalars[..<cutIndex])
        while let last = kept.last, !(last.isLetter || last.isNumber) { kept.removeLast() }
        guard kept.contains(where: { $0.isLetter || $0.isNumber }) else { return .foreign }
        return .cut(kept)
    }
}
