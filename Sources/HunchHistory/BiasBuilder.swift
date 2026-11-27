import Foundation
import HunchCore

/// Builds a `LearnedBias` for the current text from the active entries of a `VocabularyModel`.
/// Construction indexes the model (do it after the model changes, not per request); `bias(for:)`
/// is a handful of dictionary lookups plus a short scan.
///
/// Text conventions: when the caret follows a word character or punctuation the entry text has a
/// leading space (" Kubernetes", the next word); after whitespace or at the start it has none.
/// Mid-word, entries that extend the typed partial word are listed first, as the full word
/// without a leading space.
public struct BiasBuilder: Sendable {
    public static let maxEntries = 64
    /// Context-free entries are scaled to this fraction of their weight; context matches and
    /// mid-word extensions of the typed partial word keep full weight.
    public static let globalScale: Float = 0.3

    private struct Item: Sendable {
        var text: String
        var lower: String
        var weight: Float
        var apps: [String: Float]
    }
    private struct Hit: Sendable {
        var index: Int
        var weight: Float
        var positive: Bool
    }

    private let items: [Item]                  // sorted by weight, descending
    private let byContext: [String: [Hit]]
    private let byFirstLetter: [Character: [Int]]
    private let scorer = VocabularyScorer()
    /// Blocked words as the user spelled them (sorted, capped).
    private let avoid: [String]
    public static let maxAvoid = 200

    public init(model: VocabularyModel, now: Date) {
        var actives = model.entries.values.filter { $0.active && !$0.blocked }
            .map { ($0, $0.weight(at: now)) }
            .filter { $0.1 > 0 }
        actives.sort { $0.1 > $1.1 }
        var items: [Item] = []
        var ctx: [String: [Hit]] = [:]
        // Hits a 2-word key lends to lookups by its last word alone. Kept apart and appended after
        // the exact 1-word hits, so an entry's own 1-word context wins (`hitMap` takes the first hit).
        var derived: [String: [Hit]] = [:]
        var letters: [Character: [Int]] = [:]
        for (i, (e, w)) in actives.enumerated() {
            items.append(Item(text: e.text, lower: VocabularyModel.key(e.text), weight: w, apps: e.apps))
            if let c = items[i].lower.first { letters[c, default: []].append(i) }
            // Sorted, so which derived hit comes first doesn't change from run to run.
            for key in Set(e.contexts.keys).union(e.negContexts.keys).sorted() {
                let hit = Hit(index: i, weight: e.weight(inContext: key, at: now),
                              positive: (e.contexts[key] ?? 0) > 0)
                ctx[key, default: []].append(hit)
                if let last = key.split(separator: " ").last, last.count != key.count {
                    derived[String(last), default: []].append(hit)
                }
            }
        }
        for (key, hits) in derived { ctx[key, default: []].append(contentsOf: hits) }
        self.avoid = Array(model.blockedTexts.prefix(Self.maxAvoid))
        self.items = items
        self.byContext = ctx
        self.byFirstLetter = letters
    }

    public var isEmpty: Bool { items.isEmpty && avoid.isEmpty }

    /// Scales an entry's weight by how much of its use was in `appKey` (or apps in its category):
    /// 1 when only there, 0 when only elsewhere (a word learned only in a chat app is not pushed in
    /// a mail app), between 1/3 and 1 when used in both, 1 without app data or without a key. Never
    /// above 1: the decoder caps entry weights at 1, so a boost would be cut off and only the
    /// penalty would remain.
    static func appFactor(apps: [String: Float], appKey: String?, categories: AppCategories = AppCategories()) -> Float {
        guard let appKey else { return 1 }
        let total = apps.values.reduce(0, +)
        guard total > 0 else { return 1 }
        let here = useHere(apps: apps, appKey: appKey, categories: categories)
        guard here > 0 else { return 0 }
        return (1 + 2 * here / total) / 3
    }

    /// The part of an entry's use that was in `appKey` or an app in its category: what counts as
    /// "here" for learned words, in autocomplete (`appFactor`) and autocorrect (`LearnedWordPlaces`).
    static func useHere(apps: [String: Float], appKey: String, categories: AppCategories) -> Float {
        categories.isEmpty
            ? (apps[appKey] ?? 0)
            : apps.reduce(0) { $0 + (categories.sameCategory($1.key, appKey) ? $1.value : 0) }
    }

    /// The strongest active words for `appKey` (weight scaled by `appFactor`, words used only in other
    /// apps left out), up to `limit`, then sorted alphabetically so the list only changes when the set
    /// does: it is meant for a prompt block that should stay the same from keystroke to keystroke.
    public func topWords(appKey: String?, limit: Int, categories: AppCategories = AppCategories()) -> [String] {
        guard limit > 0 else { return [] }
        return items.indices
            .map { (items[$0].text, items[$0].weight * Self.appFactor(apps: items[$0].apps, appKey: appKey, categories: categories)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    /// `midWordOnly` keeps only step 1 below (entries that finish the half-typed word), for when the
    /// words reach the model another way (vocabulary notes in the prompt).
    public func bias(for before: String, strength: Float, appKey: String? = nil,
                     categories: AppCategories = AppCategories(), midWordOnly: Bool = false) -> LearnedBias {
        guard strength > 0, !items.isEmpty else { return LearnedBias(entries: [], strength: strength, avoid: avoid) }
        let tail = String(before.suffix(300))
        let toks = WordText.tokens(in: tail).filter { !$0.opaque }
        let chars = Array(tail)
        let endsWord = chars.last.map(WordText.isWordChar) ?? false
        let endsSpace = chars.last?.isWhitespace ?? true
        let lead = endsSpace ? "" : " "

        var out: [LearnedBias.Entry] = []
        var used = Set<Int>()
        func factor(_ i: Int) -> Float { Self.appFactor(apps: items[i].apps, appKey: appKey, categories: categories) }
        func add(_ i: Int, _ rawWeight: Float, prefix: String) {
            let w = rawWeight * factor(i)
            guard w > 0, out.count < Self.maxEntries, used.insert(i).inserted else { return }
            out.append(.init(text: prefix + items[i].text, weight: min(1, w)))
        }

        // 1. Mid-word: entries extending the partial word.
        if endsWord, let partialTok = toks.last, partialTok.end == chars.count, !partialTok.isCJK {
            let partial = partialTok.text.lowercased()
            let prior = Array(toks.dropLast())
            let hits = hitMap(words: prior)
            if let c = partial.first, let bucket = byFirstLetter[c] {
                for i in bucket where items[i].lower.hasPrefix(partial) && items[i].lower != partial {
                    add(i, hits[i]?.weight ?? items[i].weight, prefix: "")
                }
            }
        }

        if midWordOnly { return LearnedBias(entries: out, strength: strength, avoid: avoid) }

        // 2. Context matches, then 3. global strongest.
        let hits = hitMap(words: toks)
        let ctxHits = hits.values.filter { $0.positive && $0.weight > 0 }.sorted { $0.weight * factor($0.index) > $1.weight * factor($1.index) }
        for h in ctxHits { add(h.index, h.weight, prefix: lead) }
        for i in items.indices {
            if out.count >= Self.maxEntries { break }
            let w = (hits[i]?.weight ?? items[i].weight) * Self.globalScale
            add(i, w, prefix: lead)
        }
        return LearnedBias(entries: out, strength: strength, avoid: avoid)
    }

    /// Context hits for the words preceding the next word (2-word key preferred over 1-word).
    private func hitMap(words: [Token]) -> [Int: Hit] {
        let w = words.suffix(2).map { $0.text.lowercased() }
        var keys: [String] = []
        if w.count == 2 { keys.append(w.joined(separator: " ")) }
        if let last = w.last { keys.append(last) }
        var map: [Int: Hit] = [:]
        for k in keys {
            for h in byContext[k] ?? [] where map[h.index] == nil { map[h.index] = h }
        }
        return map
    }
}
