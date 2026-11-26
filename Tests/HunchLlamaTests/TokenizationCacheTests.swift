import Foundation
import Testing
import HunchCore
@testable import HunchLlama

private func us(_ d: Duration) -> String {
    String(format: "%.0f µs", Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12)
}

private func key(_ s: String, special: Bool = false) -> TokenizationCache.Key {
    TokenizationCache.Key(bytes: Array(s.utf8), parseSpecial: special)
}

@Suite struct TokenizationCacheTests {
    @Test func hitReturnsStoredTokens() {
        var cache = TokenizationCache()
        #expect(cache.value(for: key("hello")) == nil)
        cache.store([1, 2, 3], for: key("hello"))
        #expect(cache.value(for: key("hello")) == [1, 2, 3])
        #expect(cache.count == 1 && cache.totalBytes == 5)
    }

    @Test func parseSpecialIsPartOfTheKey() {
        var cache = TokenizationCache()
        cache.store([7], for: key("<|turn>", special: true))
        #expect(cache.value(for: key("<|turn>", special: false)) == nil)
        cache.store([1, 2, 3], for: key("<|turn>", special: false))
        #expect(cache.value(for: key("<|turn>", special: true)) == [7])
        #expect(cache.value(for: key("<|turn>", special: false)) == [1, 2, 3])
    }

    @Test func contentAndPlainKeysAreSeparate() {
        var cache = TokenizationCache()
        let plain = key("<|channel>")
        var content = plain
        content.splitsMarkers = true
        cache.store([1], for: plain)
        cache.store([2, 3], for: content)
        #expect(cache.value(for: plain) == [1])
        #expect(cache.value(for: content) == [2, 3])
    }

    /// Canonically equal strings with different bytes may tokenize differently: never one entry.
    @Test func keyIsBytesNotCanonicalString() {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        var cache = TokenizationCache()
        cache.store([1], for: key(composed))
        #expect(cache.value(for: key(decomposed)) == nil)
    }

    @Test func evictsLeastRecentlyUsedByCount() {
        var cache = TokenizationCache(maxEntries: 3, maxBytes: 1_000)
        cache.store([1], for: key("a"))
        cache.store([2], for: key("b"))
        cache.store([3], for: key("c"))
        _ = cache.value(for: key("a"))   // a is now most recent; b is least
        cache.store([4], for: key("d"))
        #expect(cache.value(for: key("b")) == nil)
        #expect(cache.count == 3)
        #expect(cache.keysByRecency == [key("d"), key("a"), key("c")])
        cache.store([5], for: key("e"))  // evicts c
        #expect(cache.keysByRecency == [key("e"), key("d"), key("a")])
    }

    @Test func restoringAnEntryRefreshesIt() {
        var cache = TokenizationCache(maxEntries: 2, maxBytes: 1_000)
        cache.store([1], for: key("a"))
        cache.store([2], for: key("b"))
        cache.store([9], for: key("a"))
        cache.store([3], for: key("c"))
        #expect(cache.value(for: key("a")) == [9])
        #expect(cache.value(for: key("b")) == nil)
        #expect(cache.totalBytes == 2)
    }

    @Test func evictsUntilByteCapHolds() {
        var cache = TokenizationCache(maxEntries: 100, maxBytes: 10)
        cache.store([1], for: key("aaaa"))
        cache.store([2], for: key("bbbb"))
        #expect(cache.totalBytes == 8)
        cache.store([3], for: key("cccccc"))   // 8 + 6 > 10: only the oldest goes
        #expect(cache.keysByRecency == [key("cccccc"), key("bbbb")])
        #expect(cache.totalBytes == 10)
        cache.store([4], for: key("ddddddddd")) // needs 9: both older entries go
        #expect(cache.keysByRecency == [key("ddddddddd")])
        #expect(cache.totalBytes == 9)
    }

    @Test func entryLargerThanByteCapIsNotStored() {
        var cache = TokenizationCache(maxEntries: 100, maxBytes: 4)
        cache.store([1], for: key("ab"))
        cache.store([2], for: key("abcde"))
        #expect(cache.value(for: key("abcde")) == nil)
        #expect(cache.keysByRecency == [key("ab")])
    }

    @Test func removeAllEmptiesAndStaysUsable() {
        var cache = TokenizationCache(maxEntries: 2, maxBytes: 100)
        cache.store([1], for: key("a"))
        cache.store([2], for: key("b"))
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalBytes == 0 && cache.keysByRecency.isEmpty)
        #expect(cache.value(for: key("a")) == nil)
        cache.store([3], for: key("c"))
        cache.store([4], for: key("d"))
        cache.store([5], for: key("e"))
        #expect(cache.keysByRecency == [key("e"), key("d")])
    }

    /// A long typing session: every keystroke adds new prefixes; both caps hold throughout.
    @Test func staysBoundedUnderChurn() {
        var cache = TokenizationCache(maxEntries: 512, maxBytes: 64 << 10)
        var text = ""
        for i in 0..<5_000 {
            text += "w\(i % 10) "
            let window = String(text.suffix(400 + i % 200))
            cache.store([Int32(i)], for: key(window))
            _ = cache.value(for: key(String(window.prefix(50))))
            #expect(cache.count <= 512 && cache.totalBytes <= 64 << 10)
        }
        #expect(cache.totalBytes == cache.keysByRecency.reduce(0) { $0 + $1.bytes.count })
    }

    @Test func defaultCaps() {
        let cache = TokenizationCache()
        #expect(cache.maxEntries == 512 && cache.maxBytes == 2 << 20)
    }
}

/// Model-gated: a repeated tokenize is a cache hit with the identical tokens, and how much it saves.
@Suite(.serialized, .enabled(if: DevModel.available, "dev model not mounted"))
final class TokenizationCacheModelTests {
    private let hold: ModelHold
    init() async { hold = await ModelHold() }

    private struct Measured: Sendable {
        var textCold: [Duration] = [], textWarm: [Duration] = []
        var contentCold: [Duration] = [], contentWarm: [Duration] = []
        var tokenCount = 0
        var identical = true, hits = true
        var markerIdentical = false, markerDistinct = false
    }

    /// ~4000 characters of prose behind a fresh nonce, so its first tokenize is a real miss.
    private static func prose() -> String {
        let paragraph = "The morning train was late again, so Maria walked along the river instead, counting the "
            + "boats that drifted past the old stone bridge. She thought about the letter she still had to write, "
            + "and about the garden her grandmother used to keep behind the yellow house near the market. "
        var text = "Note \(UUID().uuidString). "
        while text.count < 4_000 { text += paragraph }
        return String(text.prefix(4_000))
    }

    @Test func repeatedTokenizeIsAnIdenticalHit() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        let rounds = 5
        let texts = (0..<(2 * rounds)).map { _ in Self.prose() }

        let m = try await model.host.withSession(await model.nextID()) { s -> Measured in
            let ls = try #require(s as? LlamaSession)
            let clock = ContinuousClock()
            var m = Measured()
            _ = try ls.tokenizeText(Self.prose(), parseSpecial: false) // first-use warm-up, not measured

            func timed(_ body: () throws -> [TokenID]) rethrows -> ([TokenID], Duration) {
                let start = clock.now
                let out = try body()
                return (out, clock.now - start)
            }
            func isHit(_ body: () throws -> [TokenID]) rethrows -> ([TokenID], Duration, Bool) {
                let before = ls.profile
                let (out, d) = try timed(body)
                let after = ls.profile
                return (out, d, after.tokenizeHits == before.tokenizeHits + 1
                        && after.tokenizeCalls == before.tokenizeCalls + 1)
            }
            for r in 0..<rounds {
                let text = texts[2 * r], other = texts[2 * r + 1]
                let (cold, c1) = try timed { try ls.tokenizeText(text, parseSpecial: false) }
                let (warm, w1, hit1) = try isHit { try ls.tokenizeText(text, parseSpecial: false) }
                // The path `tokenize` takes for content segments (marker scan included).
                let (coldC, c2) = try timed { try ls.tokenizeContent(other) }
                let (warmC, w2, hit2) = try isHit { try ls.tokenizeContent(other) }
                m.textCold.append(c1); m.textWarm.append(w1)
                m.contentCold.append(c2); m.contentWarm.append(w2)
                m.identical = m.identical && cold == warm && coldC == warmC
                m.hits = m.hits && hit1 && hit2
                m.tokenCount = cold.count
            }

            // Marker text: the content result stays split on a hit, and a plain tokenize of the
            // same bytes is a separate entry.
            let marked = "see <|channel> here \(UUID().uuidString)"
            let raw = try ls.tokenizeText(marked, parseSpecial: false)
            let split1 = try ls.tokenizeContent(marked)
            let split2 = try ls.tokenizeContent(marked)
            m.markerIdentical = split1 == split2
            m.markerDistinct = split1 != raw
            return m
        }
        func median(_ d: [Duration]) -> String { us(d.sorted()[d.count / 2]) }
        print("[HunchLlama] tokenize 4000 chars (\(m.tokenCount) tokens), median of \(rounds): "
              + "tokenizeText cold \(median(m.textCold)) warm \(median(m.textWarm)); "
              + "tokenizeContent cold \(median(m.contentCold)) warm \(median(m.contentWarm))")
        #expect(m.identical)
        #expect(m.hits)
        #expect(m.markerIdentical)
        #expect(m.markerDistinct)
        #expect(m.tokenCount > 500)
    }
}
