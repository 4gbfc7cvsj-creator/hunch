// Result cache keys/LRU, cache hits in the engine, prewarm cancellation, prefix reuse, fail-fast load.
import Foundation
import HunchCore
import HunchDecode
import HunchLlama
import HunchPrompt
import Synchronization
import Testing
@testable import HunchEngine

private func key(_ before: String = "Hello", framer: String = "document-v1", decode: DecodeConfig = DecodeConfig(),
                  bias: LearnedBias = LearnedBias(), after: String = "") -> ResultCacheKey {
    ResultCacheKey(framerID: framer, addsBOS: true, promptTokenBudget: 1024, confidenceFloor: nil,
                   input: PromptInput(before: before, after: after, maxWords: 4), decode: decode, bias: bias)
}

private func completion(_ text: String) -> CachedCompletion {
    CachedCompletion(outcome: .show(text), alternatives: [], wordScores: [], partialText: text)
}

private final class Counter: Sendable {
    private let n = Mutex(0)
    func bump() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

@Suite struct ResultCacheKeyTests {
    @Test func equalInputsGiveEqualKeys() {
        #expect(key() == key())
        #expect(key().hashValue == key().hashValue)
    }

    @Test func framerDecodeAndTextChangeTheKey() {
        #expect(key() != key(framer: "chat-prefill-v1"))
        #expect(key() != key("Hello "))
        #expect(key() != key(after: "x"))
        var wide = DecodeConfig()
        wide.maxWords += 3
        #expect(key() != key(decode: wide))
    }

    @Test func biasChangesTheKeyButAnInertBiasDoesNot() {
        let active = LearnedBias(entries: [.init(text: " Kubernetes", weight: 1)], strength: 2)
        let stronger = LearnedBias(entries: [.init(text: " Kubernetes", weight: 1)], strength: 3)
        let otherWord = LearnedBias(entries: [.init(text: " Docker", weight: 1)], strength: 2)
        #expect(key() != key(bias: active))
        #expect(key(bias: active) != key(bias: stronger))
        #expect(key(bias: active) != key(bias: otherWord))
        // Strength 0 or no entries means the bias has no effect, so it must not split the cache.
        let off = LearnedBias(entries: [.init(text: " Kubernetes", weight: 1)], strength: 0)
        #expect(key() == key(bias: off))
    }

    @Test func forcedStraightQuotesChangeTheKey() {
        // Cached outcomes are post-processed; an app with smart quotes off must not reuse curly ones.
        var straight = PromptInput(before: "Hello", maxWords: 4)
        straight.quoteStyle = .straight
        let k = ResultCacheKey(framerID: "document-v1", addsBOS: true, promptTokenBudget: 1024, confidenceFloor: nil,
                               input: straight, decode: DecodeConfig(), bias: LearnedBias())
        #expect(key() != k)
    }

    @Test func lruEvictsLeastRecentlyUsed() {
        let cache = ResultCache(capacity: 2)
        cache.store(completion("a"), for: key("a"))
        cache.store(completion("b"), for: key("b"))
        #expect(cache.value(for: key("a")) != nil)   // touch a; b is now least recent
        cache.store(completion("c"), for: key("c"))
        #expect(cache.value(for: key("b")) == nil)
        #expect(cache.value(for: key("a")) != nil)
        #expect(cache.value(for: key("c")) != nil)
        #expect(cache.count == 2)
    }

    @Test func entriesExpireAndZeroCapacityDisables() {
        let cache = ResultCache(capacity: 4, timeToLive: .seconds(10))
        let t0 = ContinuousClock.now
        cache.store(completion("a"), for: key("a"), now: t0)
        #expect(cache.value(for: key("a"), now: t0 + .seconds(5)) != nil)
        #expect(cache.value(for: key("a"), now: t0 + .seconds(20)) == nil)
        let off = ResultCache(capacity: 0)
        off.store(completion("a"), for: key("a"))
        #expect(off.value(for: key("a")) == nil)
    }
}

@Suite struct EngineCacheTests {
    private func engine(host: FakeHost, counter: Counter, capacity: Int = 8) -> LocalCompletionEngine {
        LocalCompletionEngine(host: host,
                              search: { counter.bump(); return ScriptedSearch(text: " student at UCLA") },
                              resultCacheCapacity: capacity)
    }

    @Test func repeatedContextIsServedFromCache() async throws {
        let host = FakeHost(profile: baseProfile)
        let counter = Counter()
        let engine = engine(host: host, counter: counter)
        let first = try await engine.complete(makeRequest(1, before: "I am a")) { _ in }
        // Type one more character, then backspace to the earlier context.
        _ = try await engine.complete(makeRequest(2, before: "I am a ")) { _ in }
        let streamed = Collected()
        let again = try await engine.complete(makeRequest(3, before: "I am a")) { streamed.add($0) }
        #expect(counter.value == 2)
        #expect(again.path == .cache)
        #expect(again.outcome == first.outcome)
        #expect(!streamed.all.isEmpty)
        #expect(host.cancelledBelow == RequestID(3))
    }

    @Test func differentBiasDoesNotHit() async throws {
        let host = FakeHost(profile: baseProfile)
        let counter = Counter()
        let engine = engine(host: host, counter: counter)
        var biased = makeRequest(1, before: "I am a")
        biased.bias = LearnedBias(entries: [.init(text: " student", weight: 1)], strength: 2)
        _ = try await engine.complete(biased) { _ in }
        _ = try await engine.complete(makeRequest(2, before: "I am a")) { _ in }
        #expect(counter.value == 2)
    }

    @Test func cacheIsOffByDefault() async throws {
        let host = FakeHost(profile: baseProfile)
        let counter = Counter()
        let engine = engine(host: host, counter: counter, capacity: 0)
        _ = try await engine.complete(makeRequest(1, before: "I am a")) { _ in }
        let second = try await engine.complete(makeRequest(2, before: "I am a")) { _ in }
        #expect(counter.value == 2)
        #expect(second.path != .cache)
    }

    @Test func prewarmNeverReadsOrWritesTheCache() async throws {
        let host = FakeHost(profile: baseProfile)
        let counter = Counter()
        let engine = engine(host: host, counter: counter)
        await engine.prewarm(makeRequest(1, before: "I am a", prewarm: true))
        #expect(counter.value == 0)
        let real = try await engine.complete(makeRequest(2, before: "I am a")) { _ in }
        #expect(counter.value == 1)
        #expect(real.path == .reuse)   // the prewarm left the prompt in the KV cache
        #expect(real.timings.decodedPromptTokens <= 1)
    }

    @Test func requestCancelsAQueuedPrewarm() async throws {
        let host = FakeHost(profile: baseProfile)
        let counter = Counter()
        let engine = engine(host: host, counter: counter)
        // The real request (id 5) is registered first; the older prewarm (id 4) then loses.
        engine.cancel(olderThan: RequestID(5))
        await engine.prewarm(makeRequest(4, before: "I am a", prewarm: true))
        #expect(host.session.syncCalls == 0)
        #expect(host.session.cached.isEmpty)
        let real = try await engine.complete(makeRequest(5, before: "I am a")) { _ in }
        #expect(real.path == .fresh)
        #expect(host.session.syncCalls == 1)
    }

    @Test func consecutiveKeystrokesReuseThePrefix() async throws {
        let host = FakeHost(profile: baseProfile)
        let counter = Counter()
        let engine = engine(host: host, counter: counter, capacity: 0)
        let base = "Hi Sarah, thanks for the update on the project. I"
        let first = try await engine.complete(makeRequest(1, before: base)) { _ in }
        #expect(first.path == .fresh)
        var typed = base
        var id: UInt64 = 1
        for ch in [" th", "in", "k"] {
            typed += ch
            id += 1
            let r = try await engine.complete(makeRequest(id, before: typed)) { _ in }
            #expect(r.path == .reuse)
            #expect(r.timings.decodedPromptTokens <= ch.utf8.count + 1)
        }
    }

    @Test func requestDuringLoadFailsFast() async {
        let host = FakeHost(profile: baseProfile)
        host.loadState = .loading(ModelEntryID(relativePath: "fake.gguf"), progress: 0.4)
        let engine = engine(host: host, counter: Counter())
        await #expect(throws: LlamaError.loading) {
            _ = try await engine.complete(makeRequest(1, before: "I am a")) { _ in }
        }
        #expect(host.session.syncCalls == 0)
    }
}

@Suite struct AvoidCacheKeyTests {
    @Test func blockedWordsChangeTheKeyEvenAtStrengthZero() {
        let none = LearnedBias()
        let blocked = LearnedBias(strength: 0, avoid: ["banana"])
        let other = LearnedBias(strength: 0, avoid: ["apple"])
        let harder = LearnedBias(strength: 0, avoid: ["banana"], avoidPenalty: 12)
        #expect(key(bias: none) != key(bias: blocked))
        #expect(key(bias: blocked) != key(bias: other))
        #expect(key(bias: blocked) != key(bias: harder))
        #expect(key(bias: blocked) == key(bias: LearnedBias(strength: 0, avoid: ["banana"])))
        // Order does not matter.
        #expect(key(bias: LearnedBias(avoid: ["a", "b"])) == key(bias: LearnedBias(avoid: ["b", "a"])))
    }
}

@Suite struct RawTextFieldTests {
    @Test func cachedCompletionKeepsWinnerRawText() {
        var cached = completion("shown")
        #expect(cached.rawText.isEmpty)
        cached.rawText = "raw winner"
        let store = ResultCache(capacity: 2)
        store.store(cached, for: key())
        #expect(store.value(for: key())?.rawText == "raw winner")
    }
}
