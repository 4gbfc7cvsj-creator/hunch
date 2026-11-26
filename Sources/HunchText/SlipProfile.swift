import Foundation

/// The user's personal slips ("Fix automatically"): words they often mistype, each in whatever way
/// (learned from automatic fixes they kept, `HunchHistory.TroubleWord`). A slip to a trouble word costs
/// less than the plain keyboard prior (`SlipCost`), a typed form fixed to it before costs least, and
/// a trouble word within reach is always a candidate for a misspelled word. Never used for a word the
/// dictionary accepts: a clean word is never pulled toward a trouble word. Pure.
public struct SlipProfile: Sendable, Equatable {
    /// Lowercased trouble word → lowercased typed forms the user kept a fix of more than once.
    public private(set) var words: [String: Set<String>]

    public init(words: [String: Set<String>]) {
        var w: [String: Set<String>] = [:]
        for (k, v) in words {
            let key = k.lowercased()
            guard !key.isEmpty else { continue }
            w[key, default: []].formUnion(v.map { $0.lowercased() })
        }
        self.words = w
    }

    public var isEmpty: Bool { words.isEmpty }

    /// `SlipCost` to a trouble word is scaled by this.
    static let troubleScale: Float = 0.7
    /// … and by this for a typed form already fixed to it more than once.
    static let exactScale: Float = 0.4
    /// Shortest typed word (letters) a trouble word is offered for.
    public static let minLetters = 4
    /// `SlipCost` budget per typed letter for offering a trouble word (after scaling), like the
    /// dictionary search (`CorrectionFinder.fuzzyBudgetPerLetter`).
    static let budgetPerLetter: Float = 0.45

    /// The multiplier on the slip cost from `typed` to `candidate` (1: not a trouble word).
    public func scale(typed: String, candidate: String) -> Float {
        guard let forms = words[candidate.lowercased()] else { return 1 }
        return forms.contains(typed.lowercased()) ? Self.exactScale : Self.troubleScale
    }

    public func isExact(typed: String, candidate: String) -> Bool {
        words[candidate.lowercased()]?.contains(typed.lowercased()) == true
    }

    /// `SlipCost.cost`, scaled for trouble words.
    public func cost(typed: String, candidate: String, timing: KeyTiming? = nil) -> Float {
        SlipCost.cost(typed: typed, candidate: candidate, timing: timing) * scale(typed: typed, candidate: candidate)
    }

    /// Trouble words a misspelled `typed` word may be, cheapest first (lowercase), with whether the
    /// typed form was fixed to it before. Within reach: the scaled slip cost within the budget, at
    /// most 3 letters shorter or longer, and the trouble word has most of the typed letters (fast
    /// typing adds stray keys, so a third may be extra: "stuioill" → still).
    public func candidates(for typed: String, limit: Int = 3) -> [(word: String, exact: Bool)] {
        let w = typed.lowercased()
        let letters = w.filter(\.isLetter).count
        guard letters >= Self.minLetters, !words.isEmpty else { return [] }
        let budget = Float(letters) * Self.budgetPerLetter + 0.01
        var hits: [(word: String, exact: Bool, cost: Float)] = []
        for (word, forms) in words where word != w && abs(word.count - w.count) <= 3 {
            let exact = forms.contains(w)
            if !exact {
                guard CorrectionFinder.lettersMissing(from: word, typed: w) <= (w.count + 2) / 3 else { continue }
            }
            let c = cost(typed: w, candidate: word)
            guard exact || c <= budget else { continue }
            hits.append((word, exact, c))
        }
        hits.sort { $0.exact != $1.exact ? $0.exact : ($0.cost != $1.cost ? $0.cost < $1.cost : $0.word < $1.word) }
        return hits.prefix(limit).map { ($0.word, $0.exact) }
    }
}
