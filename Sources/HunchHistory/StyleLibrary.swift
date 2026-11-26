import Foundation
import HunchCore
import NaturalLanguage

/// One sentence the user wrote, kept as a style example for later prompts.
public struct StyleSnippet: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var createdAt: Date
    public var appBundleID: String?
    /// Where it was written: the site's host in a browser, else the app's bundle ID (see `AppKey`).
    /// Data saved before this existed falls back to `appBundleID`.
    public var appKey: String?

    public init(id: String = UUID().uuidString, text: String, createdAt: Date, appBundleID: String? = nil,
                appKey: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.appBundleID = appBundleID
        self.appKey = appKey ?? appBundleID
    }

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, appBundleID, appKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        appKey = try c.decodeIfPresent(String.self, forKey: .appKey) ?? appBundleID
    }
}

/// The user's saved sentences, newest last, capped per category, without duplicates.
public struct StyleLibrary: Codable, Sendable, Equatable {
    /// Sentences kept per app category (AI, Chats, ...), so the category typed in most can't crowd
    /// out the others. Apps and sites in no category share one more allowance of the same size.
    /// Learned phrases (`PhraseModel`) need a larger corpus than the prompt samples. Was one cap of
    /// 300 for everything before 2026-11-11; prompt samples still come from the newest `promptPoolSize`.
    public static let capacityPerCategory = 500
    /// Prompt samples are picked from this many newest sentences (unchanged behaviour).
    public static let promptPoolSize = 300

    public private(set) var snippets: [StyleSnippet] = []
    /// Normalized texts of `snippets` (duplicate check without rescanning every sentence).
    private var keys: [String: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case snippets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snippets = try c.decodeIfPresent([StyleSnippet].self, forKey: .snippets) ?? []
        for s in snippets { keys[VocabularyModel.key(s.text), default: 0] += 1 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(snippets, forKey: .snippets)
    }

    public static func == (a: StyleLibrary, b: StyleLibrary) -> Bool { a.snippets == b.snippets }

    public var isEmpty: Bool { snippets.isEmpty }

    /// Adds a snippet unless one with the same normalized text exists. Then drops the oldest
    /// sentences of the new one's category beyond `capacityPerCategory`. `categoryOf` maps an app
    /// key to its category name (nil = no category); categories are read at save time, so a
    /// category that grew past the cap after apps were moved is trimmed on its next save.
    /// Returns whether it was added.
    @discardableResult
    public mutating func add(text: String, at date: Date, appKey: String? = nil,
                             categoryOf: (String) -> String? = { _ in nil }) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = VocabularyModel.key(t)
        guard !k.isEmpty, keys[k] == nil else { return false }
        snippets.append(StyleSnippet(text: t, createdAt: date, appKey: appKey))
        keys[k] = 1
        let buckets = snippets.map { Self.bucket($0.appKey.flatMap(categoryOf)) }
        let mine = buckets[buckets.count - 1]
        let same = buckets.indices.filter { buckets[$0] == mine }
        if same.count > Self.capacityPerCategory {
            let drop = Set(same.prefix(same.count - Self.capacityPerCategory))
            for i in drop { forget(snippets[i]) }
            snippets = snippets.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        return true
    }

    /// Category names compared like `AppCategories.same` (case and accents ignored); "" = none.
    static func bucket(_ category: String?) -> String {
        (AppCategories.clean(category) ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return false }
        forget(snippets[i])
        snippets.remove(at: i)
        return true
    }

    public mutating func removeAll() {
        snippets = []
        keys = [:]
    }

    private mutating func forget(_ s: StyleSnippet) {
        let k = VocabularyModel.key(s.text)
        if let n = keys[k], n > 1 { keys[k] = n - 1 } else { keys[k] = nil }
    }
}

/// Pure logic for picking out sentences worth keeping and for choosing examples.
enum StyleText {
    static let window = 1500
    static let terminators: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{2026}"]
    static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{FF09}", "\u{300D}", "\u{300F}"]

    /// Sentences of `latest` written during this visit that are fit to keep.
    /// `cleared`: the last sentence counts even without closing punctuation (a sent chat message).
    static func harvest(latest: String, baseline: String, cleared: Bool) -> [String] {
        let truncated = latest.count > window
        let text = truncated ? String(latest.suffix(window)) : latest
        var sentences: [String] = []
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            sentences.append(String(text[r]))
            return true
        }
        if truncated, !sentences.isEmpty { sentences.removeFirst() }   // likely cut mid-sentence
        var out: [String] = []
        for (i, raw) in sentences.enumerated() {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, !baseline.contains(s) else { continue }
            let isFinal = i == sentences.count - 1
            guard endsSentence(s) || (cleared && isFinal) else { continue }
            guard isKeepable(s) else { continue }
            out.append(s)
        }
        return out
    }

    static func endsSentence(_ s: String) -> Bool {
        var chars = Substring(s)
        while let l = chars.last, closers.contains(l) { chars = chars.dropLast() }
        guard let l = chars.last else { return false }
        return terminators.contains(l)
    }

    static func isCJKDominant(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        return letters.filter { WordText.containsCJK(String($0)) }.count * 2 > letters.count
    }

    static func isKeepable(_ s: String) -> Bool {
        guard s.contains(where: { $0.isLetter }) else { return false }
        if isCJKDominant(s) {
            let n = s.filter { !$0.isWhitespace }.count
            guard (8...80).contains(n) else { return false }
        } else {
            let words = s.split(whereSeparator: { $0.isWhitespace })
            guard (4...40).contains(words.count) else { return false }
        }
        let lower = s.lowercased()
        if lower.contains("://") || lower.contains("www.") || lower.contains("@") { return false }
        if hasDigitRun(s, atLeast: 5) { return false }
        for tok in s.split(whereSeparator: { $0.isWhitespace }) {
            let t = tok.trimmingCharacters(in: .punctuationCharacters)
            if !t.isEmpty, VocabularyScorer.looksLikeSecret(t) { return false }
        }
        return true
    }

    static func hasDigitRun(_ s: String, atLeast n: Int) -> Bool {
        var run = 0
        for c in s {
            if c.isNumber { run += 1; if run >= n { return true } } else { run = 0 }
        }
        return false
    }

    /// Lowercased word tokens that are not stopwords (traditional Chinese compared as simplified).
    static func contentWords(_ s: String) -> Set<String> {
        var out = Set<String>()
        let tok = NLTokenizer(unit: .word)
        tok.string = s
        tok.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in
            let w = String(s[r]).lowercased()
            guard w.contains(where: { $0.isLetter }) else { return true }
            let zh = HanScript.simplified(w)
            if VocabularyScorer.enStopwords.contains(w) || VocabularyScorer.zhStopwords.contains(zh) { return true }
            if w.count < 2 { return true }
            out.insert(w)
            return true
        }
        return out
    }

    /// The last `n` words of `s` (works on a bounded tail so tokenization stays cheap).
    static func lastWords(_ s: String, _ n: Int) -> String {
        let tail = String(s.suffix(2000))
        var starts: [String.Index] = []
        let tok = NLTokenizer(unit: .word)
        tok.string = tail
        tok.enumerateTokens(in: tail.startIndex..<tail.endIndex) { r, _ in starts.append(r.lowerBound); return true }
        guard starts.count > n else { return tail }
        return String(tail[starts[starts.count - n]...])
    }

    /// Top `k` snippets by content-word overlap with `before`, then newest. Overlap 0 never picks.
    static func pick(from snippets: [StyleSnippet], before: String, k: Int) -> [String] {
        guard k > 0, !snippets.isEmpty else { return [] }
        let ctx = contentWords(lastWords(before, 60))
        guard !ctx.isEmpty else { return [] }
        let beforeLower = before.lowercased()
        var scored: [(overlap: Int, index: Int, text: String)] = []
        for (i, s) in snippets.enumerated() {
            if beforeLower.contains(s.text.lowercased()) { continue }
            let o = contentWords(s.text).intersection(ctx).count
            if o > 0 { scored.append((o, i, s.text)) }
        }
        scored.sort { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : $0.index > $1.index }
        return scored.prefix(k).map { $0.text }
    }
}

/// What the service remembers per field to harvest sentences later.
/// Only text that arrived by typing (or an accepted suggestion) is harvestable: `typedTail` is the
/// contiguous typed run at the end of `latest`; `closedRuns` are earlier typed runs that were cut off
/// by a non-typed change (page text appearing, paste, caret jump). Neither ever contains untyped text.
struct StyleFieldState {
    var baseline: String
    var latest: String
    var appKey: String?
    var typedTail = ""
    var closedRuns: [String] = []

    static let typedChunkLimit = 8
    static let typedChunkLimitCJK = 12
    static let maxClosedRuns = 20

    init(baseline: String, latest: String, appKey: String?) {
        self.baseline = baseline
        self.latest = latest
        self.appKey = appKey
    }

    /// Folds in a new observed text. `accepted` is the not-yet-consumed rest of a just-accepted
    /// suggestion; the returned value is what remains of it.
    mutating func observe(_ text: String, accepted: String?) -> String? {
        var rest = accepted
        defer { latest = text }
        if text == latest { return rest }
        if text.hasPrefix(latest) {
            let delta = String(text.dropFirst(latest.count))
            let limit = StyleText.isCJKDominant(delta) ? Self.typedChunkLimitCJK : Self.typedChunkLimit
            if delta.count <= limit {
                typedTail += delta
                if let a = rest, a.hasPrefix(delta) { rest = String(a.dropFirst(delta.count)) }
                return rest
            }
            if let a = rest, a.hasPrefix(delta) || delta.hasPrefix(a) {
                typedTail += delta
                return a.hasPrefix(delta) ? String(a.dropFirst(delta.count)) : nil
            }
        } else if latest.hasPrefix(text) {
            let removed = latest.count - text.count
            typedTail = removed >= typedTail.count ? "" : String(typedTail.dropLast(removed))
            return rest
        }
        closeRun()
        return rest
    }

    mutating func closeRun() {
        if !typedTail.isEmpty {
            closedRuns.append(typedTail)
            if closedRuns.count > Self.maxClosedRuns { closedRuns.removeFirst() }
        }
        typedTail = ""
    }

    /// Sentences worth keeping, drawn from typed text only. `cleared`: the open tail's last
    /// sentence counts even without closing punctuation.
    func harvest(cleared: Bool) -> [String] {
        var out: [String] = []
        for run in closedRuns { out += StyleText.harvest(latest: run, baseline: baseline, cleared: false) }
        out += StyleText.harvest(latest: typedTail, baseline: baseline, cleared: cleared)
        return out
    }
}
