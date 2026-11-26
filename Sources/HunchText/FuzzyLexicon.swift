import Foundation

/// Words to search for a long garbled word that no checker guess or one/two-slip edit reaches
/// ("pucntioans" → punctuations, "capitlaizoain" → capitalization). Bucketed by first letter;
/// a cheap length and letter-count filter runs before the keyboard-slip cost (`SlipCost`). Pure.
public struct FuzzyLexicon: Sendable {
    private struct Entry: Sendable {
        var word: String
        var count: Int
        var letters: [UInt8]  // per-letter counts a…z
    }

    private let buckets: [Character: [Entry]]

    /// Lowercase a–z words of at least `minLength` letters; anything else is skipped.
    public init<S: Sequence>(words: S, minLength: Int = 4) where S.Element == String {
        var seen = Set<String>()
        var buckets: [Character: [Entry]] = [:]
        for w in words {
            guard w.count >= minLength, w.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }), seen.insert(w).inserted,
                  let first = w.first else { continue }
            buckets[first, default: []].append(Entry(word: w, count: w.count, letters: Self.letterCounts(w)))
        }
        self.buckets = buckets
    }

    public var count: Int { buckets.values.reduce(0) { $0 + $1.count } }

    /// Slip budget for a word: about one slip per 3 letters.
    public static func budget(for word: String) -> Float { Float(word.count) / 3 }

    /// The closest words (same first letter, length within ±3, `SlipCost` within the budget),
    /// cheapest first. A typed word ending in "s" is also matched against each word + "s"/"es".
    /// The `candidates` cheapest go through `isWord` (the spell checker: drops archaic entries).
    /// `maxMissing`: most typed letters (with repeats) a word may lack (default: a quarter).
    public func nearest(_ word: String, limit: Int = 4, budget: Float? = nil, candidates: Int = 16,
                        maxMissing: Int? = nil, isWord: (String) -> Bool = { _ in true }) -> [String] {
        let w = word.lowercased()
        guard let first = w.first, let bucket = buckets[first], w.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return [] }
        let budget = budget ?? Self.budget(for: w)
        let maxBag = Int((budget * 3.4).rounded(.up))
        let typedBytes = Array(w.utf8)
        let typed = Self.letterCounts(w)
        let plural = w.hasSuffix("s")
        let maxMissing = maxMissing ?? max(1, w.count / 4)
        var scratch: [Float] = []
        var hits: [(word: String, cost: Float)] = []
        func consider(_ form: () -> String, _ counts: [UInt8], length: Int) {
            guard abs(length - typedBytes.count) <= 3 else { return }
            var bag = 0, missing = 0
            for i in 0..<26 {
                let d = Int(typed[i]) - Int(counts[i])
                bag += abs(d)
                if d > 0 { missing += d }
                if bag > maxBag || missing > maxMissing { return }
            }
            let f = form()
            guard f != w else { return }
            let cost = Self.cost(typedBytes, Array(f.utf8), limit: budget, scratch: &scratch)
            if cost <= budget { hits.append((f, cost)) }
        }
        for e in bucket {
            consider({ e.word }, e.letters, length: e.count)
            if plural, !e.word.hasSuffix("s") {
                var s = e.letters; s[18] &+= 1
                consider({ e.word + "s" }, s, length: e.count + 1)
                var es = s; es[4] &+= 1
                consider({ e.word + "es" }, es, length: e.count + 2)
            }
        }
        hits.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.word < $1.word }
        var out: [String] = []
        for h in hits.prefix(candidates) where out.count < limit && !out.contains(h.word) && isWord(h.word) {
            out.append(h.word)
        }
        return out
    }

    /// `SlipCost.cost` for lowercase a–z bytes, stopping early once every alignment is over `limit`
    /// (then the answer is just some value over it).
    static func cost(_ s: [UInt8], _ t: [UInt8], limit: Float, scratch: inout [Float]) -> Float {
        let n = s.count, m = t.count, w = m + 1
        if scratch.count < (n + 1) * w { scratch = [Float](repeating: 0, count: (n + 1) * w) }
        func extra(_ i: Int) -> Float {
            let c = s[i]
            if i > 0, s[i - 1] == c || near[Int(s[i - 1] - 97)][Int(c - 97)] { return SlipCost.extraNearKey }
            if i + 1 < n, s[i + 1] == c || near[Int(s[i + 1] - 97)][Int(c - 97)] { return SlipCost.extraNearKey }
            return SlipCost.extraKey
        }
        return scratch.withUnsafeMutableBufferPointer { d -> Float in
            d[0] = 0
            for j in 1...max(1, m) where j <= m { d[j] = Float(j) * SlipCost.missingKey }
            for i in 1...max(1, n) where i <= n {
                let ex = extra(i - 1)
                d[i * w] = d[(i - 1) * w] + ex
                var rowMin = d[i * w]
                for j in 1...max(1, m) where j <= m {
                    let a = s[i - 1], b = t[j - 1]
                    let sub: Float = a == b ? 0 : (near[Int(b - 97)][Int(a - 97)] ? SlipCost.neighbourKey : SlipCost.otherKey)
                    var best = min(d[(i - 1) * w + j] + ex, d[i * w + j - 1] + SlipCost.missingKey, d[(i - 1) * w + j - 1] + sub)
                    if i > 1, j > 1, a == t[j - 2], s[i - 2] == b, a != s[i - 2] {
                        best = min(best, d[(i - 2) * w + j - 2] + SlipCost.swap)
                    }
                    d[i * w + j] = best
                    rowMin = min(rowMin, best)
                }
                if rowMin > limit { return rowMin }
            }
            return d[n * w + m]
        }
    }

    /// near[a][b]: key b is next to key a (a, b as 0…25).
    static let near: [[Bool]] = {
        var t = [[Bool]](repeating: [Bool](repeating: false, count: 26), count: 26)
        for (k, ns) in CorrectionFinder.neighbours {
            guard let a = k.asciiValue else { continue }
            for c in ns { if let b = c.asciiValue { t[Int(a - 97)][Int(b - 97)] = true } }
        }
        return t
    }()

    private static func letterCounts(_ w: String) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 26)
        for b in w.utf8 where b >= 97 && b <= 122 { c[Int(b - 97)] &+= 1 }
        return c
    }
}
