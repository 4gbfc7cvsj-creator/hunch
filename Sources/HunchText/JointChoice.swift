import Foundation

/// How likely a typed word is a keyboard slip of a candidate, as a cost in rough "edit" units
/// (lower = likelier): a neighbouring key costs less than any other key, a doubled or neighbouring
/// extra key less than any other extra key, a moved or missing space or apostrophe little.
/// Weighted optimal string alignment, case-insensitive. Pure.
public enum SlipCost {
    static let neighbourKey: Float = 0.6
    static let otherKey: Float = 1.2
    static let swap: Float = 0.7
    /// An extra key next to (or the same as) a key beside it ("riught", "sammple").
    static let extraNearKey: Float = 0.5
    static let extraKey: Float = 0.9
    static let missingKey: Float = 0.8
    static let space: Float = 0.5
    static let apostrophe: Float = 0.3

    /// A swap of two keys pressed almost together (`KeyTiming.rolled`).
    static let swapRolled: Float = 0.35
    /// An extra letter that is the same key hit again too fast, or held until it repeated.
    static let extraDoubleHit: Float = 0.25

    /// The cost of having typed `typed` when `candidate` was meant.
    public static func cost(typed: String, candidate: String) -> Float {
        cost(typed: typed, candidate: candidate, timing: nil)
    }

    /// The same, with the word's key timing: a swap or doubled letter the timing backs costs less;
    /// nothing costs more.
    public static func cost(typed: String, candidate: String, timing: KeyTiming?) -> Float {
        align(typed: typed, candidate: candidate, timing: timing).cost
    }

    /// Whether every slip from `typed` to `candidate` is one the key timing backs (and there is at
    /// least one): the fix is then exactly what the keys say happened.
    public static func timingExplains(typed: String, candidate: String, timing: KeyTiming?) -> Bool {
        guard let timing, !timing.isEmpty else { return false }
        let a = align(typed: typed, candidate: candidate, timing: timing)
        return a.cost > 0 && a.unbacked == 0
    }

    /// Cheapest alignment; among equally cheap ones, the one with the fewest slips the timing doesn't back.
    private static func align(typed: String, candidate: String, timing: KeyTiming?) -> (cost: Float, unbacked: Int) {
        let s = Array(typed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
        let t = Array(candidate.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
        if s == t { return (0, 0) }
        // Timing is per character of the word as typed; any other length is not this word's.
        let timing = timing.flatMap { $0.rolled.count == s.count - 1 ? $0 : nil }
        typealias Cell = (cost: Float, unbacked: Int)
        func better(_ a: Cell, _ b: Cell) -> Cell {
            if abs(a.cost - b.cost) > 1e-4 { return a.cost < b.cost ? a : b }
            return a.unbacked <= b.unbacked ? a : b
        }
        func plus(_ a: Cell, _ c: Float, backed: Bool) -> Cell { (a.cost + c, a.unbacked + (backed ? 0 : 1)) }
        func extraCell(_ i: Int) -> (Float, Bool) {
            if let timing, isDoubleHit(s, at: i, timing) { return (extraDoubleHit, true) }
            return (extra(s, at: i), false)
        }
        var d = [[Cell]](repeating: [Cell](repeating: (0, 0), count: t.count + 1), count: s.count + 1)
        for i in 1...max(1, s.count) where i <= s.count {
            let (c, b) = extraCell(i - 1)
            d[i][0] = plus(d[i - 1][0], c, backed: b)
        }
        for j in 1...max(1, t.count) where j <= t.count { d[0][j] = plus(d[0][j - 1], missing(t[j - 1]), backed: false) }
        guard !s.isEmpty, !t.isEmpty else { return d[s.count][t.count] }
        for i in 1...s.count {
            for j in 1...t.count {
                let (ec, eb) = extraCell(i - 1)
                var best = plus(d[i - 1][j], ec, backed: eb)
                best = better(best, plus(d[i][j - 1], missing(t[j - 1]), backed: false))
                if s[i - 1] == t[j - 1] {
                    best = better(best, d[i - 1][j - 1])
                } else {
                    best = better(best, plus(d[i - 1][j - 1], substitution(typed: s[i - 1], meant: t[j - 1]), backed: false))
                }
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1], s[i - 1] != s[i - 2] {
                    // A space typed a letter early or late is a space slip.
                    if isSpace(s[i - 1]) || isSpace(s[i - 2]) {
                        best = better(best, plus(d[i - 2][j - 2], space, backed: false))
                    } else if let timing, timing.rolled[i - 2] {
                        best = better(best, plus(d[i - 2][j - 2], swapRolled, backed: true))
                    } else {
                        best = better(best, plus(d[i - 2][j - 2], swap, backed: false))
                    }
                }
                d[i][j] = best
            }
        }
        return d[s.count][t.count]
    }

    /// `s[i]` is the same key as the one before or after it, hit again too fast or by auto-repeat.
    private static func isDoubleHit(_ s: [Character], at i: Int, _ timing: KeyTiming) -> Bool {
        (i > 0 && s[i - 1] == s[i] && timing.doubleHit[i - 1])
            || (i + 1 < s.count && s[i + 1] == s[i] && timing.doubleHit[i])
    }

    private static func isSpace(_ c: Character) -> Bool { c == " " || c == "\u{00A0}" }

    private static func substitution(typed: Character, meant: Character) -> Float {
        if isSpace(meant), "bnmvc".contains(typed) { return neighbourKey }  // a key by the space bar
        if let row = CorrectionFinder.numberRowLetters[typed], row.contains(meant) { return neighbourKey }
        if CorrectionFinder.neighbours[meant]?.contains(typed) == true { return neighbourKey }
        return otherKey
    }

    /// `s[i]` typed but not meant.
    private static func extra(_ s: [Character], at i: Int) -> Float {
        let c = s[i]
        if isSpace(c) { return space }
        if c == "'" { return apostrophe }
        for j in [i - 1, i + 1] where j >= 0 && j < s.count {
            if s[j] == c || CorrectionFinder.neighbours[s[j]]?.contains(c) == true { return extraNearKey }
        }
        return extraKey
    }

    /// `c` meant but not typed.
    private static func missing(_ c: Character) -> Float {
        if isSpace(c) { return space }
        if c == "'" { return apostrophe }
        return missingKey
    }
}

/// The unsettled stretch to decide: one to `maxSlots` words in a row the system flagged (each with
/// its candidates), the text between them, and a finished word after the last one for context.
/// `before` = `head` + slot 0 + gaps[0] + slot 1 + … + gaps[n-1] + `tail`; `gaps.last` holds the
/// last slot's trailing text and the context word (scored), `tail` what follows (not scored).
public struct StretchTrigger: Sendable, Equatable {
    public var before: String
    public var head: String
    public var slots: [AmbiguousTypo]
    public var gaps: [String]
    public var tail: String

    public init(before: String, head: String, slots: [AmbiguousTypo], gaps: [String], tail: String) {
        self.before = before
        self.head = head
        self.slots = slots
        self.gaps = gaps
        self.tail = tail
    }

    /// The text after slot `s` to the caret: the later slots as typed, with their gaps.
    public func after(slot s: Int) -> String {
        var out = gaps[s]
        for t in (s + 1)..<max(s + 1, slots.count) { out += slots[t].misspelled + gaps[t] }
        return out + tail
    }

    /// The first slot (one-slot stretches are the usual case).
    public var typo: AmbiguousTypo { slots[0] }
}

/// The model's choice over a stretch: every combination of the slots' options (the word as typed
/// or a candidate) is scored as one continuation after `head`; each combination also carries a
/// keyboard-slip prior. Each slot is then decided on its own margin, like a single word was
/// (`TypoChoice`), from the best combination for each of its options. Pure.
public enum JointChoice {
    /// Most continuations scored for one word (≈ what a single word with 10 candidates took), and
    /// for two or three words (their continuations are longer; the model scores 3 at a time, in the app and the eval).
    public static let maxCombos = 12
    public static let maxJointCombos = 9
    /// Natural-log weight of one unit of `SlipCost` between a slot's candidates. The cheapest
    /// candidate costs nothing, so the word as typed against a fix is judged as before.
    public static let slipWeight: Float = 1.5
    /// The margin a fix needs is scaled by this when the key timing explains every slip in it
    /// (2.0 → 1.3, 3.0 → 1.95).
    public static let timedMarginScale: Float = 0.65

    /// A combination: per slot, 0 = the word as typed, i ≥ 1 = `candidates[i - 1]`.
    public typealias Combo = [Int]

    /// The combinations to score, at most `maxCombos`: each slot keeps the word as typed, its
    /// preferred fix and its cheapest candidates, as many as fit (earlier slots first).
    public static func combos(_ slots: [AmbiguousTypo], max: Int? = nil) -> [Combo] {
        guard !slots.isEmpty else { return [] }
        let limit = max ?? (slots.count == 1 ? maxCombos : maxJointCombos)
        let ranked = slots.map(rankedOptions)
        var keep = ranked.map { min($0.count, 2) }
        if slots.count == 1 { keep = [min(ranked[0].count, limit)] }
        var grew = true
        while grew {
            grew = false
            for s in keep.indices where keep[s] < ranked[s].count {
                var trial = keep
                trial[s] += 1
                if trial.reduce(1, *) <= limit { keep = trial; grew = true }
            }
        }
        while keep.reduce(1, *) > limit, let s = keep.indices.max(by: { keep[$0] < keep[$1] }), keep[s] > 1 { keep[s] -= 1 }
        var out: [Combo] = [[]]
        for s in slots.indices {
            out = out.flatMap { prefix in ranked[s].prefix(keep[s]).map { prefix + [$0] } }
        }
        return out
    }

    /// The text after `head` for a combination: the slots' picks with the gaps between them.
    public static func continuation(_ combo: Combo, _ trigger: StretchTrigger) -> String {
        var out = ""
        for (s, slot) in trigger.slots.enumerated() {
            out += option(slot, combo[s]) + trigger.gaps[s]
        }
        return out
    }

    /// Per slot: the typed word (index 0) first, then the preferred fix, then candidates by slip cost.
    static func rankedOptions(_ slot: AmbiguousTypo) -> [Int] {
        let costs = candidateCosts(slot)
        let preferred = slot.preferred.flatMap { p in slot.candidates.firstIndex(of: p) }
        let rest = slot.candidates.indices.filter { $0 != preferred }
            .sorted { costs[$0] != costs[$1] ? costs[$0] < costs[$1] : $0 < $1 }
        return [0] + (preferred.map { [$0 + 1] } ?? []) + rest.map { $0 + 1 }
    }

    static func option(_ slot: AmbiguousTypo, _ index: Int) -> String {
        index == 0 ? slot.misspelled : slot.candidates[index - 1]
    }

    /// Slip cost of each candidate, less the cheapest one's (the preferred fix costs no more than that).
    static func candidateCosts(_ slot: AmbiguousTypo) -> [Float] {
        // A confused word's rivals aren't keyboard slips: none is cheaper than another.
        if slot.confusable { return slot.candidates.map { _ in 0 } }
        var costs = slot.candidates.map {
            slot.personal?.cost(typed: slot.misspelled, candidate: $0, timing: slot.timing)
                ?? SlipCost.cost(typed: slot.misspelled, candidate: $0, timing: slot.timing)
        }
        guard let low = costs.min() else { return [] }
        costs = costs.map { $0 - low }
        if let p = slot.preferred, let i = slot.candidates.firstIndex(of: p) { costs[i] = 0 }
        return costs
    }

    /// Each slot's choice. `scores[k]` is the model's log-prob of `combos[k]`'s continuation.
    public static func decide(_ slots: [AmbiguousTypo], combos: [Combo], scores: [Float]) -> [TypoChoice] {
        guard scores.count == combos.count, !combos.isEmpty else { return slots.map { _ in .keep } }
        let costs = slots.map(candidateCosts)
        let totals = combos.indices.map { k -> Float in
            var t = scores[k]
            for (s, pick) in combos[k].enumerated() where pick > 0 { t -= slipWeight * costs[s][pick - 1] }
            return t
        }
        return slots.indices.map { s in
            // The best total with each option of this slot (-inf: not scored).
            var best = [Float](repeating: -.infinity, count: slots[s].candidates.count + 1)
            for (k, combo) in combos.enumerated() where totals[k].isFinite {
                best[combo[s]] = max(best[combo[s]], totals[k])
            }
            return choice(slots[s], best: best)
        }
    }

    /// One slot's choice from the best total for each of its options (index 0 = as typed).
    static func choice(_ slot: AmbiguousTypo, best: [Float]) -> TypoChoice {
        let order = best.indices.sorted { best[$0] != best[$1] ? best[$0] > best[$1] : $0 < $1 }
        let winner = order[0]
        if slot.confusable {
            // A correct everyday word: changed only on a clear margin, never offered on a close call.
            let c = TypoChoice.decide(candidates: slot.candidates, scores: best, margin: slot.margin)
            if case .fix = c { return c }
            return .keep
        }
        guard let p = slot.preferred, let pi = slot.candidates.firstIndex(of: p).map({ $0 + 1 }) else {
            return TypoChoice.decide(candidates: slot.candidates, scores: best,
                                     margin: margin(slot.margin, slot, winner: winner))
        }
        // The system's confident fix stands unless the model clearly prefers something else.
        guard winner != pi, best[winner].isFinite, best[pi].isFinite else { return .fix(p) }
        let needed = winner == 0 ? CorrectionFinder.strictMargin : margin(slot.margin, slot, winner: winner)
        guard best[winner] - best[pi] >= needed else { return .fix(p) }
        return winner == 0 ? .keep : .fix(slot.candidates[winner - 1])
    }

    /// `base`, eased when the key timing explains every slip from the typed word to the winning fix.
    static func margin(_ base: Float, _ slot: AmbiguousTypo, winner: Int) -> Float {
        guard winner > 0, winner <= slot.candidates.count,
              SlipCost.timingExplains(typed: slot.misspelled, candidate: slot.candidates[winner - 1],
                                      timing: slot.timing) else { return base }
        return base * timedMarginScale
    }

    /// What to do with a stretch once the model has scored it (`scores` nil: no model, or too slow).
    public struct Resolution: Sendable, Equatable {
        /// The fixes, as one edit at the caret (nil: nothing to change).
        public var fix: SpanFix?
        /// A close call to offer to catch-up, when nothing was fixed: word and pick.
        public var offer: (word: String, pick: String, span: String)?
        public var choices: [TypoChoice]

        public static func == (a: Resolution, b: Resolution) -> Bool {
            a.fix == b.fix && a.choices == b.choices && a.offer?.word == b.offer?.word
                && a.offer?.pick == b.offer?.pick && a.offer?.span == b.offer?.span
        }
    }

    public static func resolve(_ trigger: StretchTrigger, combos: [Combo], scores: [Float]?) -> Resolution {
        let choices: [TypoChoice]
        if let scores {
            choices = decide(trigger.slots, combos: combos, scores: scores)
        } else {
            // No model: the system's confident fix goes in as it would have at once; a guess is offered.
            choices = trigger.slots.map { slot in
                if let p = slot.preferred { return .fix(p) }
                return slot.fallback.map { .unsure($0) } ?? .keep
            }
        }
        // The edit covers the first through the last fixed slot.
        let picks: [String?] = zip(trigger.slots, choices).map { slot, c in
            if case .fix(let p) = c { slot.cased(p) } else { nil }
        }
        if let first = picks.firstIndex(where: { $0 != nil }), let last = picks.lastIndex(where: { $0 != nil }) {
            var word = "", replacement = ""
            for s in first...last {
                word += trigger.slots[s].misspelled
                replacement += picks[s] ?? trigger.slots[s].misspelled
                if s < last { word += trigger.gaps[s]; replacement += trigger.gaps[s] }
            }
            let tail = trigger.after(slot: last)
            return Resolution(fix: SpanFix(before: trigger.before, word: word, replacement: replacement, tail: tail),
                              offer: nil, choices: choices)
        }
        if let s = choices.firstIndex(where: { if case .unsure = $0 { true } else { false } }),
           case .unsure(let picked) = choices[s] {
            let pick = trigger.slots[s].cased(picked)
            let span = trigger.slots[s].misspelled + trigger.after(slot: s)
            return Resolution(fix: nil, offer: (trigger.slots[s].misspelled, pick, span), choices: choices)
        }
        return Resolution(fix: nil, offer: nil, choices: choices)
    }
}
