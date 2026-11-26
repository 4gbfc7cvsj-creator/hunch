// Context shift (removeAndShift) against the dev model. Skipped when the models drive is not mounted.
import Foundation
import Testing
import HunchCore
@testable import HunchLlama

/// Shifted cells keep K/V computed with the dropped tokens still in front of them (the K-shift only
/// re-rotates their positions, in f16), so the next-token distribution moves a little, unlike exact
/// reuse. Bound on the top-16 max |dlogp|; measured about 0.2 (3-word slide) and 0.3 (25 words).
private let slideTolerance: Float = 0.5

/// Stable blocks in front of the before-caret window.
private let stableText = "Notes from the island, written up for the family newsletter.\n\n"

/// Varied prose for a before-caret window (about 500 tokens; tests cut it to fit the context).
private let passage = """
On the first morning the ferry left late, so we bought coffee from the kiosk by the harbour and watched \
the fishing boats come in with their catch. Nora wanted to count the gulls; she gave up at forty. The \
crossing itself was calm, and from the upper deck you could see the lighthouse on the point and, further \
along, the white houses of the village stacked above the bay. Our room looked over a courtyard with a \
lemon tree and a tap that dripped all night, which I minded less than I expected.

We spent the second day walking the coastal path towards the old monastery. The trail climbs through \
pine woods and then follows the cliff edge, with wooden steps where the rock is steep. Halfway there is \
a chapel with a bell you are allowed to ring once, and a bench where an old man sells honey and figs \
from a cool box. The monastery itself is mostly ruins now, but the cloister still has its well and a \
fig tree growing out of the wall. We ate lunch there and read the plaque about the monks who kept bees \
and copied manuscripts.

The third day it rained, so we stayed in the village. There is a tiny museum of boatbuilding in a \
converted net shed, run by a retired carpenter who showed us how the planks are steamed and bent over \
a frame. In the afternoon Nora drew the harbour from the café window while I wrote postcards and tried \
to work out the bus timetable, which seemed to change depending on who you asked.

On our last evening we walked to the point to watch the sunset. The wind had dropped and the water was \
so still that the lighthouse made a perfect reflection. A woman from the bakery was there with her dog, \
and she told us the best time to come back is late September, when the figs are ripe and the summer \
visitors have gone. We agreed that
"""

/// How far the shifted distribution is from the cold one where it matters: the largest log-prob
/// change among the cold prefill's `k` most likely tokens, and the KL divergence cold || shifted.
/// (The max over the whole 262k vocabulary is dominated by tokens of negligible probability.)
func slideDistance(_ shifted: [Float], _ ref: [Float], k: Int = 16) -> (top: Float, kl: Float) {
    let top = ref.indices.sorted { ref[$0] > ref[$1] }.prefix(k)
    let topDiff = top.reduce(Float(0)) { max($0, abs(shifted[$1] - ref[$1])) }
    var kl: Float = 0
    for i in ref.indices where ref[i] > -30 { kl += exp(ref[i]) * (ref[i] - shifted[i]) }
    return (topDiff, kl)
}

/// What `DefaultReusePlanner` would choose (HunchLlamaTests does not link HunchDecode): the longest run
/// after the common prefix, over drop 0...512 and skip 0...2, leaving the last token to decode.
private func shiftPlan(cached: [TokenID], next: [TokenID]) -> ReusePlan? {
    let p = zip(cached, next).prefix { $0 == $1 }.count
    var best: (drop: Int, matched: Int, skip: Int)?
    for skip in 0...2 {
        for drop in 0...min(512, cached.count - p - 1) where drop + skip > 0 {
            let limit = min(cached.count - p - drop, next.count - p - skip - 1)
            var m = 0
            while m < limit, cached[p + drop + m] == next[p + skip + m] { m += 1 }
            if m > (best?.matched ?? 0) { best = (drop, m, skip) }
        }
    }
    guard let best else { return nil }
    return ReusePlan(action: .removeAndShift(keep: p, drop: best.drop, matched: best.matched, skip: best.skip),
                     tokensToDecode: next.count - p - best.matched)
}

/// The longest prefix of `passage`, cut after a space, whose tokens fit `budget` with the stable block.
private func window(_ s: any LanguageModelSession, budget: Int) throws -> String {
    var text = Substring(passage)
    while try s.tokenize([content(stableText), content(String(text))], addBOS: true).count > budget,
          let cut = text.lastIndex(of: " ") {
        text = text[..<cut]
    }
    return String(text)
}

/// `text` with its first `words` words removed, cut the way `Budget.tail` cuts (after the whitespace).
private func slid(_ text: String, words: Int) -> String {
    var rest = Substring(text)
    for _ in 0..<words {
        guard let space = rest.firstIndex(of: " ") else { break }
        rest = rest[rest.index(after: space)...]
    }
    return String(rest)
}

// Part of ModelIntegrationTests (same serialized suite): the tests share one host.
extension ModelIntegrationTests {
    /// The mechanism, isolated from the approximation: RoPE attention depends on relative positions
    /// only, so a prompt decoded at positions k... and the same prompt decoded at 0... then moved by
    /// +k with `seq_add` must give the same logits for the next token (f16 re-rotation aside).
    @Test func kShiftIsATranslation() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            guard s.reuseCapability == .trimAndShift else {
                Issue.record("backend cannot shift (capability \(s.reuseCapability))")
                return
            }
            let x = try s.tokenize([content(stableText), content(String(passage.prefix(600)))],
                                   addBOS: true)
            let t = try s.tokenize([content(" the")], addBOS: false)
            let k = 37
            var plain: [Float] = [], translated: [Float] = [], shifted: [Float] = [], back: [Float] = []
            s.discard([.primary])
            #expect(ls.decodeRaw(x, at: 0) == 0 && ls.decodeRaw(t, at: x.count) == 0)
            try s.logProbs(.primary, into: &plain)
            s.discard([.primary])
            #expect(ls.decodeRaw(x, at: k) == 0 && ls.decodeRaw(t, at: x.count + k) == 0)
            try s.logProbs(.primary, into: &translated)
            s.discard([.primary])
            #expect(ls.decodeRaw(x, at: 0) == 0)
            ls.shiftPositions(.primary, from: 0, by: k)
            #expect(ls.memoryPosMax(.primary) == Int32(x.count - 1 + k))
            #expect(ls.decodeRaw(t, at: x.count + k) == 0)
            try s.logProbs(.primary, into: &shifted)
            s.discard([.primary])
            #expect(ls.decodeRaw(x, at: k) == 0)
            ls.shiftPositions(.primary, from: 0, by: -k)
            #expect(ls.decodeRaw(t, at: x.count) == 0)
            try s.logProbs(.primary, into: &back)
            s.discard([.primary])
            print("[HunchLlama] K-shift translation (\(x.count) tokens, k=\(k)): plain vs translated max|dlogp|="
                  + "\(maxAbsDiff(plain, translated)) shifted(+k) vs translated=\(maxAbsDiff(shifted, translated)) "
                  + "shifted(-k) vs plain=\(maxAbsDiff(back, plain))")
            #expect(maxAbsDiff(plain, translated) < 5e-2)
            #expect(maxAbsDiff(shifted, translated) < 5e-2)
            #expect(maxAbsDiff(back, plain) < 5e-2)
            #expect(argmax(shifted) == argmax(plain) && argmax(back) == argmax(plain))
        }
    }

    /// Realistic slides: stable blocks, a window that fills the context, the window moving past a few
    /// words or a whole sentence, a word typed at the end. The run after the re-tokenized boundary is
    /// moved and only the boundary plus the typed tail is decoded; the result must give the cold
    /// prefill's argmax and stay within the slide tolerance.
    @Test func shiftedWindowMatchesColdPrefill() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            print("[HunchLlama] reuseCapability=\(s.reuseCapability)")
            guard s.reuseCapability == .trimAndShift else {
                Issue.record("backend cannot shift (capability \(s.reuseCapability)); the slide path is untested here")
                return
            }
            let full = try window(s, budget: 440)
            let cached = try s.tokenize([content(stableText), content(full)], addBOS: true)
            for words in [3, 25] {
                let next = try s.tokenize([content(stableText), content(slid(full, words: words) + " the")], addBOS: true)
                let plan = try #require(shiftPlan(cached: cached, next: next))
                guard case .removeAndShift(let keep, let drop, let matched, let skip) = plan.action else {
                    Issue.record("no shift plan for a slide of \(words) words")
                    continue
                }
                #expect(matched >= 64)

                var shifted: [Float] = [], ref: [Float] = [], before: [Float] = []
                s.discard([.primary])
                _ = try s.syncPrompt(cached, plan: cold)
                try s.logProbs(.primary, into: &before)
                let r = try s.syncPrompt(next, plan: plan)
                #expect(r.reusedTokens == keep + matched && r.decodedTokens == next.count - keep - matched)
                #expect(ls.cachedTokens(.primary) == next)
                #expect(ls.memoryPosMax(.primary) == Int32(next.count - 1))
                #expect(ls.memoryPosMax(SeqID(1)) == -1)
                try s.logProbs(.primary, into: &shifted)
                s.discard([.primary]) // a sync of the same tokens would otherwise be a no-op
                _ = try s.syncPrompt(next, plan: cold)
                try s.logProbs(.primary, into: &ref)
                let distance = slideDistance(shifted, ref)
                print("[HunchLlama] slide \(words) words (\(cached.count)->\(next.count) tokens): keep=\(keep) drop=\(drop) "
                      + "matched=\(matched) skip=\(skip) decoded=\(r.decodedTokens) argmax-same=\(argmax(shifted) == argmax(ref)) "
                      + "top16 max|dlogp|=\(distance.top) KL=\(distance.kl) full-vocab max|dlogp|=\(maxAbsDiff(shifted, ref))")
                #expect(maxAbsDiff(before, ref) > 0.1) // the comparison is not trivially equal
                #expect(argmax(shifted) == argmax(ref))
                #expect(distance.top < slideTolerance)
            }
        }
    }

    /// A decode that fails right after the shift metadata was applied (here: an invalid token id in
    /// the appended tail, which llama rejects before touching the cache) must drop sequence 0; a
    /// failure after the shift was applied keeps what the cache really holds. Either way the next
    /// request syncs correctly from the reported state and nothing leaks into later cold prefills.
    @Test func failedShiftLeavesTheSessionConsistent() async throws {
        let model = SharedModel.shared
        _ = try await model.ready()
        try await model.host.withSession(await model.nextID()) { s in
            let ls = try #require(s as? LlamaSession)
            guard s.reuseCapability == .trimAndShift else {
                Issue.record("backend cannot shift (capability \(s.reuseCapability)); the slide path is untested here")
                return
            }
            let invalid = TokenID(s.vocabulary.count + 5)
            let full = try window(s, budget: 300)
            let rest = slid(full, words: 5)
            let head = String(full.prefix(full.count - rest.count))
            // Segment-aligned (no boundary token: the failed decode is the one applying the shift)
            // and text-cut (the boundary decode applied the shift before the tail failed).
            let cases: [(String, [TokenID], [TokenID])] = [
                ("aligned", try s.tokenize([content(stableText), content(head), content(rest)], addBOS: true),
                 try s.tokenize([content(stableText), content(rest), content(" the")], addBOS: true)),
                ("cut", try s.tokenize([content(stableText), content(full)], addBOS: true),
                 try s.tokenize([content(stableText), content(rest + " the")], addBOS: true)),
            ]
            var ref: [Float] = [], again: [Float] = [], fresh: [Float] = [], viaShift: [Float] = []
            for (name, cached, next) in cases {
                let plan = try #require(shiftPlan(cached: cached, next: next))
                guard case .removeAndShift(let keep, _, let matched, let skip) = plan.action else { continue }
                if name == "aligned" { #expect(skip == 0) } else { #expect(skip >= 1) }
                s.discard([.primary])
                _ = try s.syncPrompt(next, plan: cold)
                try s.logProbs(.primary, into: &ref)
                // What a successful shift gives, for the recovered state to be compared with.
                s.discard([.primary])
                _ = try s.syncPrompt(cached, plan: cold)
                _ = try s.syncPrompt(next, plan: plan)
                try s.logProbs(.primary, into: &viaShift)

                s.discard([.primary])
                _ = try s.syncPrompt(cached, plan: cold)
                var broken = next
                broken[broken.count - 1] = invalid
                #expect(throws: LlamaError.self) { try s.syncPrompt(broken, plan: plan) }
                let retained = ls.retainedPromptTokens
                #expect(retained == ls.cachedTokens(.primary))
                #expect(ls.memoryPosMax(.primary) == Int32(retained.count - 1))
                #expect(ls.memoryPosMax(SeqID(1)) == -1)
                if skip == 0 {
                    // The failed decode was the one meant to apply the K-shift: nothing is trusted.
                    #expect(retained.isEmpty)
                } else {
                    // The boundary decode applied the shift; the moved run survived the failed tail.
                    #expect(retained == Array(next.prefix(keep + skip + matched)))
                }

                // Next request: reuse what was reported (the engine records retainedPromptTokens).
                let r = try s.syncPrompt(next, plan: ReusePlan(action: retained.isEmpty ? .coldPrefill
                                                                   : .appendOnly(keep: retained.count),
                                                               tokensToDecode: next.count - retained.count))
                #expect(r.reusedTokens == retained.count)
                #expect(ls.cachedTokens(.primary) == next)
                try s.logProbs(.primary, into: &again)
                s.discard([.primary])
                _ = try s.syncPrompt(next, plan: cold)
                try s.logProbs(.primary, into: &fresh)
                let expected = retained.isEmpty ? fresh : viaShift
                print("[HunchLlama] failed shift \(name): skip=\(skip) retained=\(retained.count) of \(next.count) "
                      + "cold-after vs cold-before max|dlogp|=\(maxAbsDiff(fresh, ref)) "
                      + "recovered vs \(retained.isEmpty ? "cold" : "successful shift")=\(maxAbsDiff(again, expected))")
                #expect(maxAbsDiff(fresh, ref) < 1e-2)
                #expect(argmax(again) == argmax(expected))
                #expect(maxAbsDiff(again, expected) < 5e-2)
            }
        }
    }
}
