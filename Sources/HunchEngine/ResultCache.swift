// Small LRU of finished completions, keyed by everything that can change the answer.
import Foundation
import HunchCore
import Synchronization

/// Identity of a completion request for caching. Two requests with equal keys produce the same
/// post-processed outcome (greedy decoding is deterministic for a fixed model and config), so the
/// engine may serve the stored result. The key includes the framer, the model-level knobs the
/// engine was built with, the complete prompt input, the decode config, and the learned bias.
struct ResultCacheKey: Hashable, Sendable {
    let framerID: String
    let addsBOS: Bool
    let promptTokenBudget: Int
    let confidenceFloor: Float?
    let before: String
    let after: String
    let surface: String
    let globalInstructions: String?
    let appInstructions: String?
    let styleInstructions: String?
    let aboutWriter: String?
    let preferredLanguages: [String]
    let maxWords: Int
    let allowNewlines: Bool
    let screenContext: String?
    let screenTokenLimit: Int?
    let clipboard: String?
    let decode: Data
    let bias: [BiasItem]
    let biasStrength: Float
    /// Blocked words (sorted; they act even at strength 0) and their penalty.
    let avoid: [String]
    let avoidPenalty: Float
    /// Learned phrases (experimental) and their strength; empty when off.
    let phrases: [BiasItem]
    let phraseStrength: Float
    /// The cached outcome is post-processed, so forced-straight quotes must not share it.
    let quoteStyle: QuotePreference

    struct BiasItem: Hashable, Sendable {
        let text: String
        let weight: Float
    }

    init(framerID: String, addsBOS: Bool, promptTokenBudget: Int, confidenceFloor: Float?,
         input: PromptInput, decode: DecodeConfig, bias: LearnedBias) {
        self.framerID = framerID
        self.addsBOS = addsBOS
        self.promptTokenBudget = promptTokenBudget
        self.confidenceFloor = confidenceFloor
        before = input.before
        after = input.after
        surface = String(describing: input.surface)
        globalInstructions = input.globalInstructions
        appInstructions = input.appInstructions
        styleInstructions = input.styleInstructions
        aboutWriter = input.aboutWriter
        preferredLanguages = input.preferredLanguages
        maxWords = input.maxWords
        allowNewlines = input.allowNewlines
        screenContext = input.screenContext
        screenTokenLimit = input.screenTokenLimit
        clipboard = input.clipboard
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.decode = (try? encoder.encode(decode)) ?? Data()
        // Boosted entries with strength 0 (or none) have no effect, whatever they say.
        if bias.entries.isEmpty || bias.strength <= 0 {
            self.bias = []
            biasStrength = 0
        } else {
            self.bias = bias.entries.map { BiasItem(text: $0.text, weight: $0.weight) }
            biasStrength = bias.strength
        }
        // Blocked words always matter (an explicit user choice), independent of strength.
        if bias.avoid.isEmpty {
            avoid = []
            avoidPenalty = 0
        } else {
            avoid = Array(Set(bias.avoid)).sorted()
            avoidPenalty = bias.avoidPenalty
        }
        if bias.phrases.isEmpty || bias.phraseStrength <= 0 {
            phrases = []
            phraseStrength = 0
        } else {
            phrases = bias.phrases.map { BiasItem(text: $0.text, weight: $0.weight) }
            phraseStrength = bias.phraseStrength
        }
        quoteStyle = input.quoteStyle
    }
}

/// What a cache hit replays.
struct CachedCompletion: Sendable {
    let outcome: PostOutcome
    let alternatives: [String]
    let wordScores: [WordScore]
    /// Last streamed partial text, replayed once so the UI sees the same stream end.
    let partialText: String?
    /// Raw text of the winning candidate (eval reporting).
    var rawText: String = ""
}

/// Thread-safe LRU with a time-to-live (the post-processor's spell checker and dictionaries can
/// change). Capacity 0 disables it. Holds completions in memory only.
final class ResultCache: Sendable {
    private struct Entry {
        let value: CachedCompletion
        let stored: ContinuousClock.Instant
    }
    private struct State {
        var entries: [ResultCacheKey: Entry] = [:]
        var order: [ResultCacheKey] = []   // least recently used first
    }

    let capacity: Int
    let timeToLive: Duration
    private let state = Mutex(State())

    init(capacity: Int, timeToLive: Duration = .seconds(300)) {
        self.capacity = max(0, capacity)
        self.timeToLive = timeToLive
    }

    func value(for key: ResultCacheKey, now: ContinuousClock.Instant = .now) -> CachedCompletion? {
        guard capacity > 0 else { return nil }
        return state.withLock { s in
            guard let entry = s.entries[key] else { return nil }
            if now - entry.stored > timeToLive {
                s.entries[key] = nil
                s.order.removeAll { $0 == key }
                return nil
            }
            s.order.removeAll { $0 == key }
            s.order.append(key)
            return entry.value
        }
    }

    func store(_ value: CachedCompletion, for key: ResultCacheKey, now: ContinuousClock.Instant = .now) {
        guard capacity > 0 else { return }
        state.withLock { s in
            s.order.removeAll { $0 == key }
            s.order.append(key)
            s.entries[key] = Entry(value: value, stored: now)
            while s.order.count > capacity {
                s.entries[s.order.removeFirst()] = nil
            }
        }
    }

    func removeAll() {
        state.withLock { s in
            s.entries.removeAll()
            s.order.removeAll()
        }
    }

    var count: Int { state.withLock { $0.entries.count } }
}
