// Small shared helpers for hunch-eval: argument parsing, timing, percentiles, text matching.
import Foundation
import HunchCore
import HunchHistory
import HunchPolicy
import HunchText

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

func printErr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func printOut(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

struct EvalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Splits `--flag v1 v2 --other` style arguments. Positionals are collected separately.
struct ParsedArgs {
    var positionals: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ args: [String], valueOptions: Set<String>) {
        var current: String?
        for arg in args {
            if arg.hasPrefix("--") {
                current = nil
                if valueOptions.contains(arg) {
                    current = arg
                    options[arg, default: []] = options[arg] ?? []
                } else {
                    flags.insert(arg)
                }
            } else if let key = current {
                options[key, default: []].append(arg)
            } else {
                positionals.append(arg)
            }
        }
    }

    func values(_ key: String) -> [String] { options[key] ?? [] }
    func value(_ key: String) -> String? { options[key]?.first }
}

// MARK: - Timing

func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Nearest-rank percentile (p in 0...1). nil for an empty sample.
func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank - 1, 0), sorted.count - 1)]
}

func fmtMs(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
func fmtPct(_ num: Int, _ den: Int) -> String {
    den == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(num) / Double(den))
}

// MARK: - Text matching for the first-word metric

func isCJK(_ ch: Character) -> Bool {
    guard let v = ch.unicodeScalars.first?.value else { return false }
    return (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
        || (0x3040...0x30FF).contains(v)
}

/// The completed text a user would see after accepting `completion`, starting at the first
/// word: when the caret sat inside a Latin word and the completion continues it, the typed
/// fragment is joined back on, so "hea" + "ring" yields "hearing".
func wordStartText(before: String, completion: String) -> String {
    guard let first = completion.first, first.isLetter || first.isNumber, !isCJK(first) else {
        return String(completion.drop(while: { $0.isWhitespace }))
    }
    let fragment = String(before.reversed().prefix(while: { ($0.isLetter || $0.isNumber) && !isCJK($0) }).reversed())
    return fragment + completion
}

func firstWord(_ text: String) -> String {
    let trimmed = text.drop(while: { $0.isWhitespace })
    return String(trimmed.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" })).lowercased()
}

/// True when the completion starts with one of the expected first words. CJK expectations match
/// by prefix, Latin ones by whole first word.
func firstWordMatches(expect: [String], before: String, completion: String) -> Bool {
    let joined = wordStartText(before: before, completion: completion).lowercased()
    guard !joined.isEmpty else { return false }
    // Curly and straight apostrophes count as the same ("don’t" matches "don't").
    let word = firstWord(joined).replacingOccurrences(of: "\u{2019}", with: "'")
    for e in expect {
        let el = e.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard !el.isEmpty else { continue }
        if el.contains(where: isCJK) {
            if joined.hasPrefix(el) { return true }
        } else {
            let bare = String(el.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" }))
            if word == bare { return true }
        }
    }
    return false
}

// MARK: - Misc

func csvEscape(_ s: String) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    if flat.contains(",") || flat.contains("\"") { return "\"" + flat.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    return flat
}

func mdEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "|", with: "\\|")
}

/// Sendable collector for streamed partials.
final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    func set(_ s: String) { lock.withLock { last = s } }
    var value: String { lock.withLock { last } }
}

func timestampString() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

/// The user's learned words as the app's autocorrect gets them (`HistoryService.activeWordPlaces`):
/// active, not blocked, single words, lowercased, with the apps each was used in. Read from the
/// local encrypted history; personal, never written into reports.
/// Active words that look like the user's own typos are blocked first, as the app's next tidy-up
/// does (`VocabularyModel.blockLikelyTypos`).
func loadLearnedPlaces() -> LearnedWordPlaces {
    var (model, state) = EncryptedHistoryStore().loadResult()
    let before = Set(model.entries.filter { $0.value.blocked }.keys)
    model.blockLikelyTypos(now: Date(), systemLikelyTypoCheck)
    let typos = model.entries.filter { $0.value.likelyTypo && !before.contains($0.key) }.count
    printErr("learned words blocked as likely typos: \(typos)")
    let places = HistoryService.places(of: model)
    let withApps = places.apps.values.filter { !$0.isEmpty }.count
    printErr("learned words: \(places.words.count), \(withApps) with app data (history load: \(state))")
    return places
}

/// The user's app categories, as the app reads them (its per-app settings file).
func loadAppCategories() -> AppCategories {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hunch", isDirectory: true)
    let store = JSONPolicyStore(fileURL: support.appendingPathComponent("app-policies.json"))
    return AppCategories(patches: store.userPatches)
}

/// The app key (`AppKey`) of an eval case's app name (typing samples keep the name only); nil for
/// a name not listed. A browser case has no site host, so it gets the browser's own key.
func evalAppKey(_ name: String?) -> String? {
    switch name?.lowercased() {
    case "claude": "com.anthropic.claudefordesktop"
    case "messages": "com.apple.MobileSMS"
    case "discord": "com.hnc.Discord"
    case "safari": "com.apple.Safari"
    case "notes": "com.apple.Notes"
    case "mail": "com.apple.mail"
    case "slack": "com.tinyspeck.slackmacgap"
    default: nil
    }
}

/// A spell checker that counts learned words as spelled right (the app's `LearnedWordsSpellChecker`).
struct LearnedWordsChecker: SpellChecking {
    let base: any SpellChecking
    let words: Set<String>
    func isMisspelled(_ word: String, languages: [String]) -> Bool {
        words.contains(word.lowercased()) ? false : base.isMisspelled(word, languages: languages)
    }
    func isKnownPrefix(_ partial: String, languages: [String]) -> Bool {
        let lower = partial.lowercased()
        return words.contains { $0.hasPrefix(lower) } || base.isKnownPrefix(partial, languages: languages)
    }
}

/// The app's likely-typo check (`HistoryService.setLikelyTypo`): misspelled, and the system's fix is
/// an everyday word one edit away or a cut-off contraction (`TypoShape.isLikelyTypo`).
let systemLikelyTypoCheck: @Sendable (String) -> Bool? = { word in
    let languages = Locale.preferredLanguages
    guard let misspelled = SystemSpellChecker().lookupMisspelled(word, languages: languages) else { return nil }
    guard misspelled else { return false }
    guard let fix = SystemCorrectionSuggester().correction(for: word, context: word, languages: languages) else {
        return false
    }
    return TypoShape.isLikelyTypo(word, fixedTo: fix, isEveryday: CommonEnglish.isEveryday)
}
