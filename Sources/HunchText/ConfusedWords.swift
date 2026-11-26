// Commonly confused words ("Fix commonly confused words", a formal-apps fix): everyday words that
// are spelled right but often the wrong one of a set (their/there/they're, your/you're). The finder
// never questions an everyday word otherwise; for these it lets the model pick within the set, with
// the next word as context and a strict margin (`CorrectionFinder.confusedWordMargin`).
import Foundation

public enum ConfusedWords {
    /// The sets, lowercase with straight apostrophes. Each word's rivals are the others in its set.
    /// Kept small and precise: pairs that are swapped by sound, where the sentence decides
    /// which is meant. Left out: to/too (see `rivals`), were/where (often a slip, not a confusion),
    /// accept/except, a lot/alot (a misspelling, already fixed).
    static let sets: [[String]] = [
        ["their", "there", "they're"],
        ["your", "you're"],
        ["its", "it's"],
        ["then", "than"],
        ["whose", "who's"],
        ["lose", "loose"],
        ["affect", "effect"],
    ]

    static let rivalsByWord: [String: [String]] = {
        var out: [String: [String]] = [:]
        for set in sets { for w in set { out[w] = set.filter { $0 != w } } }
        return out
    }()

    /// The words `word` may have been confused with (lowercase, straight apostrophes), or none.
    /// "too" may be meant as "to"; "to" may be meant as "too" only right before punctuation ("me
    /// to.", "that is good to,"): elsewhere "to" is far too common to send to the model each time.
    public static func rivals(of word: String, trailing: String) -> [String] {
        let w = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if w == "too" { return ["to"] }
        if w == "to" { return trailing.contains(where: { ".,;:!?".contains($0) }) ? ["too"] : [] }
        return rivalsByWord[w] ?? []
    }

    /// Every word that is ever questioned (for tests and the eval).
    public static var allWords: [String] { sets.flatMap { $0 } + ["to", "too"] }

    /// `rival` written the way the user writes: their apostrophe (curly when the word or the field
    /// uses curly ones), cased like the typed word.
    static func styled(_ rival: String, typed token: String, before: String) -> String {
        var out = rival
        let curly = token.contains("\u{2019}") || (!token.contains("'") && QuoteStyle.detect(in: before) == .curly)
        if curly { out = out.replacingOccurrences(of: "'", with: "\u{2019}") }
        return CorrectionFinder.matchCase(out, to: token)
    }
}
