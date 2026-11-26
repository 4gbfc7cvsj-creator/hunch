import Foundation

/// Synthetic key timing for the autocorrect eval, whose texts carry none: when each key of `typed`
/// went down and up, typed at `cps` with jitter. A swap slip (found by aligning `typed` with
/// `clean`) usually comes with the two keys pressed together, an extra doubled letter usually with
/// a bounce; clean letter pairs are sometimes pressed together too (false evidence). Pure, seeded.
public struct KeyTimingModel: Sendable {
    /// Chance that a swapped pair went down together, that a doubled extra letter was a bounce,
    /// that a clean pair of different keys went down together, and that a meant double letter
    /// ("ll") came as fast as a bounce.
    public var swapRolled = 0.7
    public var doubleBounce = 0.6
    public var cleanRolled = 0.15
    public var cleanDoubleFast = 0.05

    public init() {}

    public func strokes(clean: String, typed: String, cps: Double, seed: UInt64) -> [KeyStroke] {
        var rng = SeededGenerator(seed: seed ^ 0x7417)
        let t = Array(typed)
        let (swaps, bounces) = Self.slipMarks(clean: Array(clean), typed: t)
        let interval = 1 / cps
        var out: [KeyStroke] = []
        var time = 1.0
        for (i, c) in t.enumerated() {
            if i > 0 {
                let prev = t[i - 1]
                let same = prev.lowercased() == c.lowercased()
                let r = Double.random(in: 0..<1, using: &rng)
                let gap: Double
                if same {
                    let fast = bounces.contains(i) ? r < doubleBounce : r < cleanDoubleFast
                    gap = fast ? Double.random(in: 0.02...0.055, using: &rng) : Self.normalGap(interval, &rng)
                } else if swaps.contains(i - 1) {
                    gap = r < swapRolled ? Double.random(in: 0.005...0.04, using: &rng) : Self.normalGap(interval, &rng)
                } else {
                    gap = r < cleanRolled ? Double.random(in: 0.015...0.044, using: &rng) : Self.normalGap(interval, &rng)
                }
                time += gap
            }
            let lower = Character(c.lowercased())
            let code = KeyTimingLog.keyCode(for: lower)?.code ?? KeyTimingLog.keyCode(for: c)?.code
                ?? UInt16(truncatingIfNeeded: 300 + Int(c.unicodeScalars.first?.value ?? 0) % 500)
            out.append(KeyStroke(keyCode: code, char: c, down: time,
                                 up: time + Double.random(in: 0.07...0.12, using: &rng)))
        }
        return out
    }

    /// An ordinary gap between two key downs: around the typing interval, never as fast as two
    /// keys pressed together.
    private static func normalGap(_ interval: Double, _ rng: inout SeededGenerator) -> Double {
        max(0.05, interval * Double.random(in: 0.6...1.5, using: &rng))
    }

    /// Positions in `typed` where pair (i, i+1) is a swap of `clean`'s letters, and extra letters
    /// that repeat the one before them ("stilll"), from a character alignment.
    static func slipMarks(clean c: [Character], typed t: [Character]) -> (swaps: Set<Int>, bounces: Set<Int>) {
        let n = t.count, m = c.count
        guard n > 0, m > 0, n * m <= 4_000_000 else { return ([], []) }
        let w = m + 1
        var d = [Int32](repeating: 0, count: (n + 1) * w)
        for i in 0...n { d[i * w] = Int32(i) }
        for j in 0...m { d[j] = Int32(j) }
        func eq(_ a: Character, _ b: Character) -> Bool { a == b || a.lowercased() == b.lowercased() }
        for i in 1...n {
            for j in 1...m {
                var best = min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1, d[(i - 1) * w + j - 1] + (eq(t[i - 1], c[j - 1]) ? 0 : 1))
                if i > 1, j > 1, eq(t[i - 1], c[j - 2]), eq(t[i - 2], c[j - 1]), !eq(t[i - 1], t[i - 2]) {
                    best = min(best, d[(i - 2) * w + j - 2] + 1)
                }
                d[i * w + j] = best
            }
        }
        var swaps = Set<Int>(), bounces = Set<Int>()
        var i = n, j = m
        while i > 0, j > 0 {
            let here = d[i * w + j]
            if i > 1, j > 1, eq(t[i - 1], c[j - 2]), eq(t[i - 2], c[j - 1]), !eq(t[i - 1], t[i - 2]),
               here == d[(i - 2) * w + j - 2] + 1 {
                swaps.insert(i - 2); i -= 2; j -= 2
            } else if here == d[(i - 1) * w + j - 1] + (eq(t[i - 1], c[j - 1]) ? 0 : 1) {
                i -= 1; j -= 1
            } else if here == d[(i - 1) * w + j] + 1 {
                // The extra letter and the same letter beside it: the later of the two is the bounce.
                if i < n, eq(t[i - 1], t[i]) { bounces.insert(i) } else if i > 1, eq(t[i - 1], t[i - 2]) { bounces.insert(i - 1) }
                i -= 1
            } else {
                j -= 1
            }
        }
        return (swaps, bounces)
    }
}
