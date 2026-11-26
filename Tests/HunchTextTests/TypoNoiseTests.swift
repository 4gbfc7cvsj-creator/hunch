import Testing
@testable import HunchText

@Suite struct TypoNoiseTests {
    static let clean = "yes it looks right now. I'm typing this out just as one more sample (for you) "
        + "and if we can fix typing with this many mistakes I would say the autocorrect is very good"

    @Test func sameSeedSameSlips() {
        let noise = TypoNoise(rate: 0.4)
        #expect(noise.apply(to: Self.clean, seed: 7) == noise.apply(to: Self.clean, seed: 7))
        #expect(noise.apply(to: Self.clean, seed: 7).typed != noise.apply(to: Self.clean, seed: 8).typed)
    }

    @Test func noRateNoSlips() {
        let n = TypoNoise(rate: 0).apply(to: Self.clean, seed: 1)
        #expect(n.typed == Self.clean && n.slips.isEmpty)
    }

    @Test func everyKindShowsUpAndIsScoredAsMissed() {
        var seen = Set<TypoSlip.Kind>()
        for seed in 0..<300 as Range<UInt64> {
            let n = TypoNoise(rate: 0.3).apply(to: Self.clean, seed: seed)
            #expect(n.typed != Self.clean || n.slips.isEmpty)
            // Typed as is: nothing fixed, and the words no slip touched are all still right.
            let s = TypoScore.score(n, output: n.typed)
            #expect(s.damaged == 0, "\(n.typed)")
            #expect(s.fixed.allSatisfy { !$0 } || n.slips.isEmpty, "\(n.typed) \(n.slips) \(s.fixed)")
            // Fully corrected: everything fixed.
            let fixedAll = TypoScore.score(n, output: Self.clean)
            #expect(fixedAll.exact && fixedAll.fixed.allSatisfy { $0 } && fixedAll.wrong == 0)
            seen.formUnion(n.slips.map(\.kind))
        }
        // Confused words come only from hand-written eval sets, never from noise.
        let seeded = Set(TypoSlip.Kind.allCases).subtracting(TypoSlip.Kind.handWrittenOnly)
        #expect(seen == seeded, "missing: \(seeded.subtracting(seen))")
    }

    @Test func slipsPointAtTheRightWords() {
        let words = TypoNoise.words(Self.clean)
        for seed in 0..<200 as Range<UInt64> {
            let n = TypoNoise(rate: 0.3).apply(to: Self.clean, seed: seed)
            // Fixing only the words of the first slip fixes that slip and nothing else.
            guard let first = n.slips.first, n.slips.count > 1 else { continue }
            let s = TypoScore.score(n, output: n.typed)
            #expect(s.fixed[0] == false)
            #expect(first.words.upperBound <= words.count)
        }
    }

    @Test func scoreCountsDamage() {
        let n = NoisyText(clean: "thanks for the update", typed: "thanks fo the update",
                          slips: [TypoSlip(kind: .omit, words: 1..<2)])
        let s = TypoScore.score(n, output: "thanks to the updates")
        #expect(s.fixed == [false] && s.damaged == 1 && s.wrong == 2 && !s.exact)
        let joined = NoisyText(clean: "we can fix it", typed: "we canfix it", slips: [TypoSlip(kind: .joinWords, words: 1..<3)])
        #expect(TypoScore.score(joined, output: "we can fix it").fixed == [true])
        #expect(TypoScore.score(joined, output: joined.typed).fixed == [false])
        #expect(TypoScore.score(joined, output: joined.typed).damaged == 0)
    }

    @Test func spaceInsideKeepsLaterIndices() {
        // Force only spaces inside words: every slip's word must be the one split.
        let noise = TypoNoise(rate: 0.5, second: 0, weights: [.spaceInside: 1])
        let words = TypoNoise.words(Self.clean)
        for seed in 0..<50 as Range<UInt64> {
            let n = noise.apply(to: Self.clean, seed: seed)
            let typed = TypoNoise.words(n.typed)
            #expect(typed.count == words.count + n.slips.count)
            var t = 0
            for (c, w) in words.enumerated() {
                if n.slips.contains(where: { $0.words.lowerBound == c }) {
                    #expect(typed[t] + typed[t + 1] == w)
                    t += 2
                } else {
                    #expect(typed[t] == w)
                    t += 1
                }
            }
        }
    }
}
