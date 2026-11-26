// kvcheck: append, trim and context-shift reuse must give the same next-token log-probs as a cold prefill.
import Foundation
import HunchCore
import HunchDecode
import HunchLlama

private struct KVReport: Sendable {
    var capability: ReuseCapability
    var appendDiff: Float
    var appendArgmaxSame: Bool
    var trimDiff: Float?
    var trimArgmaxSame: Bool?
    var backspaceDiff: Float
    var backspaceArgmaxSame: Bool
    var nontrivial: Bool
    var reusedAppend: Bool
    var slides: [SlideReport]
}

/// One slid-window case: the planner's choice, the sync it produced, and the shifted-vs-cold comparison.
private struct SlideReport: Sendable {
    var name: String
    var action: ReusePlan.Action
    var tokens: (cached: Int, next: Int)
    var reused: Int
    var decoded: Int
    /// Largest log-prob change among the cold prefill's 16 most likely tokens.
    var topDiff: Float
    /// KL(cold || shifted).
    var kl: Float
    /// Largest log-prob change over the whole vocabulary (dominated by negligible tokens; informational).
    var fullDiff: Float
    var argmaxSame: Bool
    var nontrivial: Bool
    var shiftMillis: Double
    var coldMillis: Double
}

/// Shifted cells carry K/V computed while the dropped tokens were still in front of them (the
/// K-shift only re-rotates their positions, in f16), so unlike append/trim, which reuse exactly,
/// the next-token distribution moves a little. Measured on the dev model with a ~600-token
/// window: top-16 max |dlogp| about 0.2 for a few-word slide, under 0.3 for a sentence; the argmax
/// must agree with the cold prefill.
private let slideTolerance: Float = 0.5

private func millis(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Largest log-prob change among the cold prefill's `k` most likely tokens, and KL(cold || shifted).
private func slideDistance(_ shifted: [Float], _ ref: [Float], k: Int = 16) -> (top: Float, kl: Float) {
    let top = ref.indices.sorted { ref[$0] > ref[$1] }.prefix(k)
    let topDiff = top.reduce(Float(0)) { max($0, abs(shifted[$1] - ref[$1])) }
    var kl: Float = 0
    for i in ref.indices where ref[i] > -30 { kl += exp(ref[i]) * (ref[i] - shifted[i]) }
    return (topDiff, kl)
}

/// Stable blocks in front of the before-caret window.
private let stableText = "Notes from the island, written up for the family newsletter.\n\n"

/// Varied prose for a ~600-token before-caret window.
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

The fourth day we hired bicycles and rode inland to the salt pans. The road is flat but the wind comes \
straight off the sea, so the way out took twice as long as the way back. The pans are divided by low \
stone walls into shallow squares, pink in places from the algae, and flamingos stand in the far ones \
where nobody goes. A man raking salt into cones let Nora try, and gave her a small bag of the coarse \
grey crystals to take home. We ate bread and tomatoes in the shade of the only tree for a mile and \
argued, pleasantly, about whether the sea was warmer than last year.

The fifth day was for the caves on the north shore. You go by boat, in groups of eight, with a guide \
who switches the engine off inside so you can hear the water moving in the dark. The light comes in \
from below and turns the whole chamber blue; everyone goes quiet, even the children. Afterwards we \
swam from the rocks outside and dried off on the warm stone while the guide told us about the storm \
two winters ago that closed the caves for a month.

On our last evening we walked to the point to watch the sunset. The wind had dropped and the water was \
so still that the lighthouse made a perfect reflection. A woman from the bakery was there with her dog, \
and she told us the best time to come back is late September, when the figs are ripe and the summer \
visitors have gone. We agreed that
"""

/// `text` with its first `words` words removed, cut the way `Budget.tail` cuts (after the whitespace).
private func slid(_ text: String, words: Int) -> String {
    var rest = Substring(text)
    for _ in 0..<words {
        guard let space = rest.firstIndex(of: " ") else { break }
        rest = rest[rest.index(after: space)...]
    }
    return String(rest)
}

private func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

private func argmax(_ v: [Float]) -> Int {
    var best = 0
    for i in v.indices where v[i] > v[best] { best = i }
    return best
}

private func seg(_ text: String) -> PromptSegment {
    PromptSegment(text: text, kind: .content, stability: .perKeystroke)
}

func runKVCheck(_ args: [String]) async -> Int32 {
    guard let path = args.first else {
        printErr("usage: hunch-eval kvcheck <model.gguf>")
        return ExitCode.usage
    }
    guard FileManager.default.fileExists(atPath: path) else {
        printErr("model file not found: \(path)")
        return ExitCode.failure
    }
    let entry = makeEntry(path: path)
    guard entry.validity == .valid else {
        printErr("not a usable model (\(describe(entry.validity))): \(path)")
        return ExitCode.failure
    }
    let host = LlamaModelHost()
    await host.load(entry, options: evalRuntimeOptions)
    guard case .ready(_, let profile) = await host.state() else {
        printErr("load failed: \(await host.state())")
        return ExitCode.failure
    }
    let addBOS = profile.addsBOS
    let counter = RequestCounter()
    let name = entry.url.lastPathComponent
    do {
        let report = try await host.withSession(counter.next()) { s -> KVReport in
            let prefix = [seg("Dear Sam, thanks for the photos from the trip. The lake looked")]
            let tailB = seg(" beautiful in the evening light and I")
            let tailC = seg(" cold but the mountains were")
            let tA = try s.tokenize(prefix, addBOS: addBOS)
            let tAB = try s.tokenize(prefix + [tailB], addBOS: addBOS)
            let tAC = try s.tokenize(prefix + [tailC], addBOS: addBOS)
            let cold = ReusePlan(action: .coldPrefill, tokensToDecode: 0)

            var afterA: [Float] = [], warm: [Float] = [], ref: [Float] = []
            _ = try s.syncPrompt(tA, plan: cold)
            try s.logProbs(.primary, into: &afterA)
            let r1 = try s.syncPrompt(tAB, plan: ReusePlan(action: .appendOnly(keep: tA.count),
                                                          tokensToDecode: tAB.count - tA.count))
            try s.logProbs(.primary, into: &warm)
            _ = try s.syncPrompt(tAB, plan: cold)
            try s.logProbs(.primary, into: &ref)
            let appendDiff = maxAbsDiff(warm, ref)
            let appendSame = argmax(warm) == argmax(ref)
            let nontrivial = maxAbsDiff(afterA, ref) > 0.1

            var trimDiff: Float?
            var trimSame: Bool?
            if s.reuseCapability.canTrim {
                _ = try s.syncPrompt(tA, plan: cold)
                _ = try s.syncPrompt(tAB, plan: ReusePlan(action: .appendOnly(keep: tA.count),
                                                         tokensToDecode: tAB.count - tA.count))
                _ = try s.syncPrompt(tAC, plan: ReusePlan(action: .trimAndAppend(keep: tA.count),
                                                         tokensToDecode: tAC.count - tA.count))
                try s.logProbs(.primary, into: &warm)
                _ = try s.syncPrompt(tAC, plan: cold)
                try s.logProbs(.primary, into: &ref)
                trimDiff = maxAbsDiff(warm, ref)
                trimSame = argmax(warm) == argmax(ref)
            }

            // Pure backspace: shrink to the shorter prompt, compare with its cold log-probs.
            _ = try s.syncPrompt(tAB, plan: cold)
            _ = try s.syncPrompt(tA, plan: ReusePlan(action: .trimAndAppend(keep: tA.count), tokensToDecode: 0))
            try s.logProbs(.primary, into: &warm)
            let backDiff = maxAbsDiff(warm, afterA)
            let backSame = argmax(warm) == argmax(afterA)

            // Slid window: stable blocks, a ~600-token before-caret window that moves past a few
            // words (every keystroke or two at the budget) or a sentence, a word typed at the end.
            // The window is one text cut after a space, as `Budget.tail` cuts, so its first token is
            // re-tokenized and skipped; the run after it is moved instead of re-decoded.
            var slides: [SlideReport] = []
            // Checkpoint caches run the same cases: back to a checkpoint, then re-read (exact).
            if s.reuseCapability == .trimAndShift || s.reuseCapability == .checkpoint {
                let planner = DefaultReusePlanner()
                let clock = ContinuousClock()
                let cached = try s.tokenize([seg(stableText), seg(passage)], addBOS: addBOS)
                for words in [3, 25] {
                    let next = try s.tokenize([seg(stableText), seg(slid(passage, words: words) + " the")], addBOS: addBOS)
                    var shifted: [Float] = [], coldRef: [Float] = [], before: [Float] = []
                    s.discard([.primary])
                    _ = try s.syncPrompt(cached, plan: cold)
                    try s.logProbs(.primary, into: &before)
                    let plan = planner.plan(cached: cached, next: next, capability: s.reuseCapability)
                    let t0 = clock.now
                    let r = try s.syncPrompt(next, plan: plan)
                    try s.logProbs(.primary, into: &shifted)
                    let shiftTime = clock.now - t0
                    s.discard([.primary]) // a sync of the same tokens would otherwise be a no-op
                    let t1 = clock.now
                    _ = try s.syncPrompt(next, plan: cold)
                    try s.logProbs(.primary, into: &coldRef)
                    let coldTime = clock.now - t1
                    let distance = slideDistance(shifted, coldRef)
                    slides.append(SlideReport(name: "slide \(words) words", action: plan.action,
                                              tokens: (cached.count, next.count), reused: r.reusedTokens,
                                              decoded: r.decodedTokens, topDiff: distance.top, kl: distance.kl,
                                              fullDiff: maxAbsDiff(shifted, coldRef),
                                              argmaxSame: argmax(shifted) == argmax(coldRef),
                                              nontrivial: maxAbsDiff(before, coldRef) > 0.1,
                                              shiftMillis: millis(shiftTime), coldMillis: millis(coldTime)))
                }
            }
            return KVReport(capability: s.reuseCapability, appendDiff: appendDiff, appendArgmaxSame: appendSame,
                            trimDiff: trimDiff, trimArgmaxSame: trimSame, backspaceDiff: backDiff,
                            backspaceArgmaxSame: backSame, nontrivial: nontrivial,
                            reusedAppend: r1.reusedTokens == tA.count, slides: slides)
        }
        let tol: Float = 1e-2
        var pass = report.appendArgmaxSame && report.appendDiff < tol && report.nontrivial && report.reusedAppend
        // Backspace re-decodes one token in a different batch shape than the cold prefill, so allow a
        // little more float noise there (argmax must still match).
        pass = pass && report.backspaceArgmaxSame && report.backspaceDiff < 5e-2
        if let d = report.trimDiff, let same = report.trimArgmaxSame { pass = pass && same && d < tol }
        for slide in report.slides {
            switch slide.action {
            case .removeAndShift:
                pass = pass && slide.argmaxSame && slide.topDiff < slideTolerance && slide.nontrivial
            case .trimAndAppend where report.capability == .checkpoint:
                pass = pass && slide.argmaxSame && slide.fullDiff < tol && slide.nontrivial
            default:
                pass = false
            }
        }
        printOut("kvcheck \(name): capability=\(report.capability)  addBOS=\(addBOS)")
        printOut(String(format: "  append: max|dlogp|=%.5f argmax-same=%@ reused-all-prefix=%@", report.appendDiff,
                        "\(report.appendArgmaxSame)", "\(report.reusedAppend)"))
        if let d = report.trimDiff {
            printOut(String(format: "  trim+append: max|dlogp|=%.5f argmax-same=%@", d, "\(report.trimArgmaxSame ?? false)"))
        } else {
            printOut("  trim+append: n/a (capability \(report.capability); cold fallback is exact by construction)")
        }
        printOut(String(format: "  backspace-trim: max|dlogp|=%.5f argmax-same=%@", report.backspaceDiff,
                        "\(report.backspaceArgmaxSame)"))
        printOut("  comparison non-trivial (prefix vs extended log-probs differ): \(report.nontrivial)")
        if report.slides.isEmpty {
            printOut("  slide: n/a (capability \(report.capability); cold fallback is exact by construction)")
        }
        for slide in report.slides {
            printOut(String(format: "  %@ (%d->%d tokens): plan=%@ reused=%d decoded=%d argmax-same=%@ top16 max|dlogp|=%.5f "
                            + "KL=%.5f full-vocab max|dlogp|=%.3f non-trivial=%@ reuse %.1f ms vs cold %.1f ms",
                            slide.name, slide.tokens.cached, slide.tokens.next, "\(slide.action)", slide.reused,
                            slide.decoded, "\(slide.argmaxSame)", slide.topDiff, slide.kl, slide.fullDiff,
                            "\(slide.nontrivial)", slide.shiftMillis, slide.coldMillis))
        }
        printOut("  verdict: \(pass ? "PASS" : "FAIL") (tolerance \(tol); backspace 0.05; slide top-16 \(slideTolerance))")
        await host.unload()
        return pass ? ExitCode.ok : ExitCode.failure
    } catch {
        printErr("kvcheck error: \(error)")
        await host.unload()
        return ExitCode.failure
    }
}
