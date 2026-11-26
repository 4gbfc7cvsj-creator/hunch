// Whole-field rewrite (Strong) over Hunch's own fixes: fix-as-you-type fixes words the moment
// they are typed, and some of those fixes are wrong real words ("quialty" → "quietly"). A pass that
// saw only the fixed text would keep such a word. So the pass sends the paragraph with the typed
// form of Hunch's own fixes put back, and the model's answer is mapped onto the field as it is:
// where the model wrote what the fix already says, nothing changes; where it wrote something else,
// its change replaces the fix (undo then gives back what the writer typed); where it kept the typed
// form, the fix stays (or, by policy, is taken back). Pure; the app and the eval wire it.
import Foundation

/// How sure fix-as-you-type was of a fix when it made it, recorded with the fix (`RecordedFix`,
/// `OwnFix`) so a later rewrite pass knows which fixes may give way.
public enum FixConfidence: String, Sendable, Codable, CaseIterable {
    case sure
    /// The fix put in a word that is neither an everyday word nor one of the writer's learned words
    /// ("gguf" → "gruff", "worktree" → "corktree", "mashuga" → "mashups"): the nearest dictionary
    /// word to what is most often a term the writer meant.
    case unsure

    /// The confidence of a fix of `typed` to `fixed`: unsure when a word it put in (not one typed, all
    /// letters) is neither `isEveryday` nor `isLearned` (both get the word lowercased).
    public static func of(typed: String, fixed: String, isEveryday: (String) -> Bool, isLearned: (String) -> Bool) -> FixConfidence {
        let typedWords = Set(RewriteOwnFixes.words(typed).map { $0.lowercased() })
        let added = RewriteOwnFixes.words(fixed).map { $0.lowercased() }
            .filter { !typedWords.contains($0) && !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        return added.contains { !isEveryday($0) && !isLearned($0) } ? .unsure : .sure
    }
}

/// A fix Hunch made in the field that is still there and not undone: `fixed` sits at `range`
/// (UTF-16, in the field's text before the caret); the writer typed `typed`.
public struct OwnFix: Sendable, Equatable {
    public var range: Range<Int>
    public var typed: String
    public var fixed: String
    /// The fix's entry in the field's fix history, when it has one.
    public var id: Int?
    /// How sure fix-as-you-type was of it (nil: not recorded, a rewrite pass's own fix).
    public var confidence: FixConfidence?

    public init(range: Range<Int>, typed: String, fixed: String, id: Int? = nil, confidence: FixConfidence? = nil) {
        self.range = range
        self.typed = typed
        self.fixed = fixed
        self.id = id
        self.confidence = confidence
    }

    /// Worth showing the model as typed: the letters differ (not a capital, apostrophe or other
    /// punctuation fix, which are the style switches' business), and the typed form stays in its line.
    public var changesLetters: Bool {
        func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return letters(typed) != letters(fixed) && !typed.contains(where: \.isNewline) && !fixed.isEmpty
    }
}

/// A word where the pass and Hunch's own fix disagree and a rule decided which goes in: the
/// model wrote another real word the own-fix rules blocked (or let in), or kept a typed form the
/// kept-typed rules decide about. A scorer may overrule the rule (`RewriteOwnFixes.arbitrate`).
public struct OwnFixDispute: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The model's change was blocked by `Rules.typedWordsStay`, `.sameWordCount`, `.noCostlier`.
        case typedWordsStay, sameWordCount, noCostlier
        /// The model's change went in.
        case accepted
        /// The model kept the typed form (the kept-typed rules decide).
        case keptTyped

        public static let blocked: Set<Kind> = [.typedWordsStay, .sameWordCount, .noCostlier]
        /// What the app scores (measured 2026-11-16, `docs/features/autocorrect-rewrite.md`): the model's
        /// real word blocked by slip cost or a word count. Not `.typedWordsStay` or kept typed forms:
        /// scored on the pass's own prompt, the model favours what it just wrote, typed slips included.
        public static let app: Set<Kind> = [.noCostlier, .sameWordCount]
    }
    public var kind: Kind
    /// The span on the field as it is now: the key of a verdict.
    public var range: Range<Int>
    public var typed: String
    public var fixed: String
    /// The model's text (the typed form, for `.keptTyped`).
    public var model: String
    /// The readings to score, real words only, the rule's choice first.
    public var readings: [String]
    /// The pass's corrected copy of the target before the span, and the rest of its sentence after it.
    public var head: String
    public var tail: String

    /// What the model scores: `head` without its trailing spaces, and each reading after those spaces
    /// with the tail.
    public var scoring: (head: String, continuations: [String]) {
        let trimmed = String(head.reversed().drop(while: { $0 == " " }).reversed())
        let lead = String(head.dropFirst(trimmed.count))
        return (trimmed, readings.map { lead + $0 + tail })
    }

    /// Keyboard-slip cost from the typed keys to reading `i`, a space for each word added or dropped.
    public func slipCost(_ i: Int) -> Float {
        func keys(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let r = readings[i]
        let wordsAdded = abs(RewriteOwnFixes.words(r).count - RewriteOwnFixes.words(typed).count)
        return SlipCost.cost(typed: keys(typed), candidate: keys(r)) + Float(wordsAdded) * SlipCost.space
    }
}

/// A pass's target with Hunch's own fixes put back as typed.
public struct AsTypedTarget: Sendable, Equatable {
    public struct Placed: Sendable, Equatable {
        public var fix: OwnFix
        /// Where the typed form sits in the as-typed field text (`target.before + target.text`), UTF-16.
        public var typedRange: Range<Int>
    }
    /// What the model gets: the target text with the typed forms put back.
    public var target: RewriteTarget
    /// The target as the field holds it now.
    public var current: RewriteTarget
    /// The fixes put back, in text order.
    public var placed: [Placed]

    /// A target with nothing put back.
    public init(unchanged target: RewriteTarget) {
        self.target = target
        current = target
        placed = []
    }

    init(target: RewriteTarget, current: RewriteTarget, placed: [Placed]) {
        self.target = target
        self.current = current
        self.placed = placed
    }
}

/// One change of a pass on the field as it is now.
public struct OwnFixEdit: Sendable, Equatable {
    public var edit: RewriteEdit
    /// What the writer typed over `edit.range` when it covers Hunch's own fixes: undo puts this
    /// back. nil: `edit.original` was typed.
    public var typed: String?
    /// History ids of the own fixes this change replaces.
    public var replacesFixes: [Int]
    /// The change takes back an own fix (the model kept the typed form): no underline of its own.
    public var revertsFix: Bool

    public init(edit: RewriteEdit, typed: String? = nil, replacesFixes: [Int] = [], revertsFix: Bool = false) {
        self.edit = edit
        self.typed = typed
        self.replacesFixes = replacesFixes
        self.revertsFix = revertsFix
    }

    /// What undo puts back over `edit.range`.
    public var undoText: String { typed ?? edit.original }

    /// The change as the fix history records it, on `text` (the field before the caret, this change
    /// not in yet): an added or dropped word is recorded with a neighbouring word
    /// (`RewriteEdit.recordable`). `undo`: what the recorded change's undo puts back.
    public func recordable(in text: String) -> (edit: RewriteEdit, undo: String)? {
        guard let r = edit.recordable(in: text) else { return nil }
        let u = Array(text.utf16)
        let head = String(decoding: u[r.range.lowerBound..<edit.range.lowerBound], as: UTF16.self)
        let tail = String(decoding: u[edit.range.upperBound..<r.range.upperBound], as: UTF16.self)
        return (r, head + undoText + tail)
    }
}

public enum RewriteOwnFixes {
    /// What to do with an own fix whose typed form the model left as it was.
    public enum KeptTyped: String, Sendable, CaseIterable {
        /// The fix stays (the model may just have missed the slip).
        case keepFix
        /// The fix is taken back: the model read the typed word as meant (a term, a name).
        case revert
    }

    /// When a change the model made over an own fix may replace it (besides `isKnownWord`).
    public struct Rules: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Not when the model kept a typed word the fix changed.
        public static let typedWordsStay = Rules(rawValue: 1)
        /// Not when the model adds or drops a word the typed keys don't explain.
        public static let sameWordCount = Rules(rawValue: 2)
        /// Not when the model's text costs clearly more keyboard slips from the keys than the fix
        /// (`maxExtraSlipCost`): "3hen" stays "when", not "then"; "ws dome" stays "we come".
        public static let noCostlier = Rules(rawValue: 4)
        public static let all: Rules = [.typedWordsStay, .sameWordCount, .noCostlier]
    }

    /// Own fixes the model kept as typed that are also taken back under `.keepFix` (besides a fix
    /// that is no known word). The model siding with the typed form is one judge; these add a second.
    public struct KeptTypedRules: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The typed form is a known word itself (`isKnownWord`, with learned words): a real word
        /// swapped for another ("dock" → "rock"). Not a known confusion of the fix
        /// (`isKnownConfusion`: "form" → "from", "their" → "there"), unless `.anyRealWord`.
        public static let realWord = KeptTypedRules(rawValue: 1)
        /// With `.realWord`: no exemption for known confusions.
        public static let anyRealWord = KeptTypedRules(rawValue: 2)
        /// The typed form is the writer's term: it stands elsewhere in the field as typed (not fixed
        /// there), or is in `writerTerms` (on screen, learned).
        public static let term = KeptTypedRules(rawValue: 4)
        /// With `.realWord`: a fix that only puts back one dropped letter stays too ("gain" → "again",
        /// "th" → "the"): the commonest slip, and one the model often reads past.
        public static let droppedLetterStays = KeptTypedRules(rawValue: 8)
        /// A fix fix-as-you-type was unsure of (`FixConfidence.unsure`) is taken back when the model kept
        /// the typed form ("gguf" → "gruff").
        public static let unsureFix = KeptTypedRules(rawValue: 16)
        /// What the app uses (measured 2026-11-15, `docs/features/autocorrect-rewrite.md`).
        public static let app: KeptTypedRules = [.realWord, .droppedLetterStays]
    }

    /// `fixed` is `typed` with one letter put in (case aside).
    public static func putsBackOneLetter(typed: String, fixed: String) -> Bool {
        let a = Array(typed.lowercased()), b = Array(fixed.lowercased())
        guard b.count == a.count + 1 else { return false }
        return b.indices.contains { i in Array(b[..<i] + b[(i + 1)...]) == a }
    }

    /// A typed word and its fix that are a known confusion: rivals in `ConfusedWords`, or the same
    /// letters with two neighbours swapped ("form"/"from", "on"/"no"), the timed-swap slips.
    public static func isKnownConfusion(typed: String, fixed: String) -> Bool {
        let a = typed.lowercased(), b = fixed.lowercased()
        if ConfusedWords.rivals(of: a, trailing: ".").contains(b) || ConfusedWords.rivals(of: b, trailing: ".").contains(a) { return true }
        let x = Array(a), y = Array(b)
        guard x.count == y.count, x.count >= 2 else { return false }
        let diff = x.indices.filter { x[$0] != y[$0] }
        return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
    }

    /// Most `SlipCost` from the typed keys to a change over a fix that adds or drops a word.
    static let maxSplitSlipCost: Float = 1.6
    /// Most `SlipCost` a change over a fix may need from the typed keys beyond what the fix needs.
    static let maxExtraSlipCost: Float = 0.5

    /// `current` with the typed form of `fixes` put back: those inside the part the model may change
    /// (not the held tail), still showing their fixed text, that change letters. Overlapping fixes:
    /// the first one wins.
    public static func asTyped(_ current: RewriteTarget, fixes: [OwnFix]) -> AsTypedTarget {
        let base = current.start
        let units = Array(current.text.utf16)
        let editableEnd = base + units.count - current.heldTail
        var chosen: [OwnFix] = []
        for fix in fixes.sorted(by: { $0.range.lowerBound < $1.range.lowerBound })
        where fix.changesLetters && !fix.typed.isEmpty && fix.range.lowerBound >= base && fix.range.upperBound <= editableEnd
            && fix.range.count == fix.fixed.utf16.count {
            let lo = fix.range.lowerBound - base, hi = fix.range.upperBound - base
            guard String(decoding: units[lo..<hi], as: UTF16.self) == fix.fixed else { continue }
            if let last = chosen.last, last.range.upperBound > fix.range.lowerBound { continue }
            chosen.append(fix)
        }
        var out: [UInt16] = []
        var placed: [AsTypedTarget.Placed] = []
        var at = 0
        for fix in chosen {
            let lo = fix.range.lowerBound - base
            out += units[at..<lo]
            let start = base + out.count
            out += Array(fix.typed.utf16)
            placed.append(.init(fix: fix, typedRange: start..<(base + out.count)))
            at = fix.range.upperBound - base
        }
        out += units[at...]
        var target = current
        target.text = String(decoding: out, as: UTF16.self)
        return AsTypedTarget(target: target, current: current, placed: placed)
    }

    /// The pass's changes on the field as it is now. `result`: `FieldRewrite.edits` on `typed.target`
    /// with the model's `revised` copy. A change that covers own fixes covers them whole; when its
    /// text is what the field already holds (under the style switches), nothing changes. An own fix
    /// the model left as typed is handled by `kept`. `isKnownWord` (a spell checker): a change over an
    /// own fix goes in only when each new word in it is known (nil: no check); an own fix that is not
    /// a known word is taken back when the model kept the typed form. `isCommonWord` (lowercased): a
    /// fix that put in a rare word ("anthin" → "xanthin") may give way to a costlier change (nil: never).
    /// `keptRules`: more kept-typed fixes taken back under `.keepFix`; `writerTerms` (lowercased): the
    /// writer's words besides the field (screen words, learned words), for `.term`.
    public static func mapBack(_ result: FieldRewrite.Result, revised: String, on typed: AsTypedTarget,
                               options: RewriteOptions = .init(), kept: KeptTyped = .keepFix,
                               isKnownWord: ((String) -> Bool)? = nil, isCommonWord: ((String) -> Bool)? = nil,
                               rules: Rules = .all, keptRules: KeptTypedRules = [],
                               writerTerms: Set<String> = [], arbitrated: Set<OwnFixDispute.Kind> = [],
                               verdicts: [Range<Int>: String] = [:],
                               disputes: ((OwnFixDispute) -> Void)? = nil) -> [OwnFixEdit] {
        let base = typed.target.start
        let t = Array(typed.target.text.utf16), c = Array(typed.current.text.utf16)
        let placed = typed.placed
        func sub(_ u: [UInt16], _ a: Int, _ b: Int) -> String { String(decoding: u[(a - base)..<(b - base)], as: UTF16.self) }
        // A position in the as-typed text that is not inside a put-back word, on the field now.
        func toCurrent(_ p: Int) -> Int {
            p + placed.filter { $0.typedRange.upperBound <= p && !$0.typedRange.isEmpty }
                .reduce(0) { $0 + $1.fix.fixed.utf16.count - $1.typedRange.count }
        }
        func touches(_ e: RewriteEdit, _ p: AsTypedTarget.Placed) -> Bool {
            e.range.isEmpty ? (p.typedRange.lowerBound < e.range.lowerBound && e.range.lowerBound < p.typedRange.upperBound)
                : e.range.overlaps(p.typedRange)
        }
        // Each change grown over the own fixes it touches; changes that share a fix go together.
        struct Group { var lo: Int; var hi: Int; var edits: [RewriteEdit]; var fixes: [Int] }
        var groups: [Group] = []
        for e in result.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let hit = placed.indices.filter { touches(e, placed[$0]) }
            var g = Group(lo: e.range.lowerBound, hi: e.range.upperBound, edits: [e], fixes: hit)
            for i in hit {
                g.lo = min(g.lo, placed[i].typedRange.lowerBound)
                g.hi = max(g.hi, placed[i].typedRange.upperBound)
            }
            if var last = groups.last, !hit.isEmpty || !last.fixes.isEmpty,
               g.lo < last.hi || !Set(g.fixes).isDisjoint(with: last.fixes) {
                last.hi = max(last.hi, g.hi)
                last.edits += g.edits
                last.fixes += g.fixes.filter { !last.fixes.contains($0) }
                groups[groups.count - 1] = last
            } else {
                groups.append(g)
            }
        }
        // The pass's corrected copy around as-typed `lo..<hi` (the model's other changes in): before it,
        // and the rest of its sentence after it (up to `arbiterTailWords` words).
        func context(_ lo: Int, _ hi: Int) -> (head: String, tail: String) {
            let end = base + t.count
            let before = result.edits.filter { $0.range.upperBound <= lo && !($0.range.isEmpty && $0.range.lowerBound == lo) }
                .map { e -> RewriteEdit in var m = e; m.range = (e.range.lowerBound - base)..<(e.range.upperBound - base); return m }
            let after = result.edits.filter { $0.range.lowerBound >= hi && !($0.range.isEmpty && $0.range.lowerBound == hi) }
                .map { e -> RewriteEdit in var m = e; m.range = (e.range.lowerBound - hi)..<(e.range.upperBound - hi); return m }
            let head = FieldRewrite.apply(before, to: sub(t, base, lo))
            let rest = FieldRewrite.apply(after, to: sub(t, hi, end))
            return (head, sentenceTail(rest))
        }
        // Real-word readings only (a garble's many tokens score low whatever it means), the rule's
        // choice first; nil when fewer than two are left.
        func dispute(_ kind: OwnFixDispute.Kind, range: Range<Int>, typed typedText: String, fixed: String, model: String,
                     choice: String, lo: Int, hi: Int) -> OwnFixDispute? {
            func real(_ s: String) -> Bool {
                let w = words(s)
                guard !w.isEmpty else { return false }
                guard let isKnownWord else { return true }
                return w.allSatisfy { !$0.allSatisfy(\.isLetter) || isKnownWord($0) }
            }
            guard real(choice) else { return nil }
            var readings = [choice]
            for r in [typedText, fixed, model] where real(r) && !readings.contains(where: { same($0, r, options) }) {
                readings.append(r)
            }
            guard readings.count >= 2 else { return nil }
            let (head, tail) = context(lo, hi)
            return OwnFixDispute(kind: kind, range: range, typed: typedText, fixed: fixed, model: model,
                                 readings: readings, head: head, tail: tail)
        }
        var out: [OwnFixEdit] = []
        for g in groups {
            let lo = toCurrent(g.lo), hi = toCurrent(g.hi)
            guard !g.fixes.isEmpty else {
                var e = g.edits[0]
                e.range = lo..<hi
                out.append(OwnFixEdit(edit: e))
                continue
            }
            let typedText = sub(t, g.lo, g.hi)
            let moved = g.edits.map { e -> RewriteEdit in
                var m = e
                m.range = (e.range.lowerBound - g.lo)..<(e.range.upperBound - g.lo)
                return m
            }
            let newText = FieldRewrite.apply(moved, to: typedText)
            let now = sub(c, lo, hi)
            if same(newText, now, options) { continue }
            // The fix gives way only to real words: a word the model wrote that is neither in the fix
            // nor typed must be one the spell checker knows ("coudl" → "couldl" keeps "Could").
            if let isKnownWord {
                let seen = Set((words(now) + words(typedText)).map { $0.lowercased() })
                if words(newText).contains(where: { w in
                    !seen.contains(w.lowercased()) && w.allSatisfy(\.isLetter) && !isKnownWord(w)
                }) { continue }
            }
            // The rule that keeps the fix over the model's real-word change (nil: the change goes in).
            var blocked: OwnFixDispute.Kind?
            blockers: do {
            if rules.contains(.typedWordsStay) {
                // The model kept part of what was typed under a fix and changed the rest ("ye spklease"
                // → "ye please" for "Yes please"): it read the slip as meant there, and the fix knows
                // better. Keeping all of it (a name: "frieren" for "Frier") is not this.
                // The typed words a fix changed one for one (a fix that joined or split words: none).
                let slipWords = Set(g.fixes.flatMap { i -> [String] in
                    let a = words(placed[i].fix.typed).map { $0.lowercased() }
                    let b = words(placed[i].fix.fixed).map { $0.lowercased() }
                    return a.count == b.count ? zip(a, b).filter { $0 != $1 }.map(\.0) : []
                })
                let newWords = words(newText).map { $0.lowercased() }
                let typedWords = words(typedText).map { $0.lowercased() }
                if newWords != typedWords, newWords.contains(where: slipWords.contains) { blocked = .typedWordsStay; break blockers }
            }
            if rules.contains(.sameWordCount) {
                // A word added or dropped over a fix must come from the keys typed: the same first
                // letter and about one slip away with the spaces left out ("sendme" → "send me",
                // "foundva" → "found a"; not "siet" → "i set").
                func keys(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
                let k = keys(typedText), m = keys(newText)
                if words(newText).count != words(typedText).count,
                   k.first != m.first || SlipCost.cost(typed: k, candidate: m) > Self.maxSplitSlipCost {
                    blocked = .sameWordCount
                    break blockers
                }
            }
            // A fix that put in a rare word was a stretch: the model's reading may cost more slips.
            let rareFix = isCommonWord.map { common in
                let typedWords = Set(words(typedText).map { $0.lowercased() })
                return words(now).map { $0.lowercased() }.contains { !typedWords.contains($0) && !common($0) }
            } ?? false
            if rules.contains(.noCostlier), !rareFix {
                func keys(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
                let k = keys(typedText)
                let extra = SlipCost.cost(typed: k, candidate: keys(newText)) - SlipCost.cost(typed: k, candidate: keys(now))
                if extra > Self.maxExtraSlipCost { blocked = .noCostlier }
            }
            }
            let kind = g.edits.count == 1 ? g.edits[0].kind : .word
            let ids = g.fixes.compactMap { placed[$0].fix.id }
            let modelEdit = OwnFixEdit(edit: RewriteEdit(range: lo..<hi, original: now, replacement: newText, kind: kind),
                                       typed: typedText, replacesFixes: ids)
            // A disagreement a rule decided: a scorer may overrule it (`verdicts`).
            if arbitrated.contains(blocked ?? .accepted),
               let d = dispute(blocked ?? .accepted, range: lo..<hi, typed: typedText, fixed: now, model: newText,
                               choice: blocked == nil ? newText : now, lo: g.lo, hi: g.hi) {
                disputes?(d)
                if let v = verdicts[lo..<hi] {
                    if same(v, newText, options) {
                        out.append(modelEdit)
                    } else if same(v, typedText, options) {
                        out.append(OwnFixEdit(edit: RewriteEdit(range: lo..<hi, original: now, replacement: typedText, kind: .word),
                                              typed: typedText, replacesFixes: ids, revertsFix: true))
                    }
                    continue
                }
            }
            if blocked == nil { out.append(modelEdit) }
        }
        // Own fixes no change touched: did the model keep the typed form, or did the guard throw out
        // its change? Only the first is taken back: every such fix under `.revert`; under `.keepFix`
        // only a fix that is not a known word itself ("olmk" → "olmqk"), and those `keptRules` name.
        func notAWord(_ fix: OwnFix) -> Bool {
            guard let isKnownWord else { return false }
            let typedWords = Set(words(fix.typed).map { $0.lowercased() })
            return words(fix.fixed).contains { w in
                !typedWords.contains(w.lowercased()) && w.allSatisfy(\.isLetter) && !isKnownWord(w)
            }
        }
        // `.realWord`: the typed form is a real word too (and no known confusion of the fix).
        func typedRealWord(_ fix: OwnFix) -> Bool {
            guard keptRules.contains(.realWord), let isKnownWord else { return false }
            let a = words(fix.typed), b = words(fix.fixed)
            guard !a.isEmpty, a.allSatisfy({ $0.allSatisfy(\.isLetter) && isKnownWord($0) }) else { return false }
            if keptRules.contains(.droppedLetterStays), a.count == b.count,
               zip(a, b).contains(where: { putsBackOneLetter(typed: $0, fixed: $1) }) { return false }
            if keptRules.contains(.anyRealWord) { return true }
            return !(a.count == b.count && zip(a, b).contains { isKnownConfusion(typed: $0, fixed: $1) })
        }
        // `.term`: each typed word stands elsewhere in the field as typed, or is a writer's term.
        let fieldWords: Set<String> = keptRules.contains(.term)
            ? Set(words(typed.current.before + typed.current.text).map { $0.lowercased() }) : []
        func typedTerm(_ fix: OwnFix) -> Bool {
            guard keptRules.contains(.term) else { return false }
            let a = words(fix.typed).map { $0.lowercased() }
            return !a.isEmpty && a.allSatisfy { fieldWords.contains($0) || writerTerms.contains($0) }
        }
        func unsure(_ fix: OwnFix) -> Bool { keptRules.contains(.unsureFix) && fix.confidence == .unsure }
        func takeBack(_ fix: OwnFix) -> Bool {
            kept == .revert || notAWord(fix) || typedRealWord(fix) || typedTerm(fix) || unsure(fix)
        }
        guard arbitrated.contains(.keptTyped) || placed.contains(where: { takeBack($0.fix) }) else { return out }
        let covered = Set(groups.flatMap(\.fixes))
        let keptTyped = keptAsTyped(typed, revised: revised, options: options)
        for i in placed.indices where !covered.contains(i) && keptTyped.contains(i) {
            let p = placed[i]
            var back = takeBack(p.fix)
            if arbitrated.contains(.keptTyped),
               let d = dispute(.keptTyped, range: p.fix.range, typed: p.fix.typed, fixed: p.fix.fixed, model: p.fix.typed,
                               choice: back ? p.fix.typed : p.fix.fixed, lo: p.typedRange.lowerBound, hi: p.typedRange.upperBound) {
                disputes?(d)
                if let v = verdicts[p.fix.range] { back = same(v, p.fix.typed, options) }
            }
            guard back else { continue }
            out.append(OwnFixEdit(edit: RewriteEdit(range: p.fix.range, original: p.fix.fixed, replacement: p.fix.typed, kind: .word),
                                  typed: p.fix.typed, replacesFixes: p.fix.id.map { [$0] } ?? [], revertsFix: true))
        }
        return out.sorted { $0.edit.range.lowerBound < $1.edit.range.lowerBound }
    }

    /// Words of the sentence after a disputed word that go with each reading.
    static let arbiterTailWords = 8

    /// The start of `rest` up to the end of its sentence or `arbiterTailWords` words.
    static func sentenceTail(_ rest: String) -> String {
        var tail = ""
        var count = 0
        for ch in rest {
            if ch.isWhitespace, !tail.isEmpty, !(tail.last?.isWhitespace ?? true) {
                count += 1
                if count >= arbiterTailWords { break }
            }
            if ch.isNewline { break }
            tail.append(ch)
            if ".!?".contains(ch) { break }
        }
        return tail
    }

    /// Weight of the keyboard-slip cost from the typed keys against the model's log-probability.
    public static let arbiterSlipWeight: Float = 1.5
    /// How far the best reading must beat the rule's choice.
    public static let arbiterMargin: Float = 4.0

    /// The reading to take over the rule's choice (`d.readings[0]`), nil to keep it: the best by model
    /// score (`scores`, one per reading, of the reading plus `d.tail` after `d.head`) minus `slipWeight`
    /// × keyboard-slip cost from the typed keys, when it beats the rule's choice by `margin`.
    public static func arbitrate(_ d: OwnFixDispute, scores: [Float], margin: Float = arbiterMargin,
                                 slipWeight: Float = arbiterSlipWeight) -> String? {
        guard scores.count == d.readings.count, d.readings.count > 1, scores[0].isFinite else { return nil }
        let total = d.readings.indices.map { scores[$0] - slipWeight * d.slipCost($0) }
        guard let best = total.indices.max(by: { total[$0] < total[$1] }), best != 0,
              total[best] - total[0] >= margin else { return nil }
        return d.readings[best]
    }

    /// Indices of `typed.placed` whose words the model's copy has exactly as typed (under the switches).
    static func keptAsTyped(_ typed: AsTypedTarget, revised raw: String, options: RewriteOptions) -> Set<Int> {
        guard let revised = FieldRewrite.cleanOutput(raw, target: typed.target.text,
                                                     maxRatio: options.leavesShorthand ? 2.2 : 1.5) else { return [] }
        let a = FieldRewrite.Token.split(typed.target.text), b = FieldRewrite.Token.split(revised)
        let changed = FieldRewrite.hunks(a.map { key($0.text, options) }, b.map { key($0.text, options) })
            .flatMap { Array($0.a) }
        let base = typed.target.start
        var out = Set<Int>()
        for (i, p) in typed.placed.enumerated() {
            let r = (p.typedRange.lowerBound - base)..<(p.typedRange.upperBound - base)
            let tokens = a.indices.filter { a[$0].range.overlaps(r) }
            if !tokens.isEmpty, tokens.allSatisfy({ !changed.contains($0) }) { out.insert(i) }
        }
        return out
    }

    /// The own fixes after a pass's `edits` went into `before` (the field before the caret), in the
    /// order a fix history keeps them: the ones no change touched (moved along), then each change as
    /// a fix of what was typed (a taken-back fix is no fix any more). Newest `capacity` kept.
    public static func fixesAfter(_ fixes: [OwnFix], edits: [OwnFixEdit], in before: String,
                                  capacity: Int = FixHistory<Int>.capacity) -> [OwnFix] {
        let sorted = edits.sorted { $0.edit.range.lowerBound < $1.edit.range.lowerBound }
        func shift(before p: Int) -> Int {
            sorted.filter { $0.edit.range.upperBound <= p && !($0.edit.range.isEmpty && $0.edit.range.lowerBound == p) }
                .reduce(0) { $0 + $1.edit.replacement.utf16.count - $1.edit.range.count }
        }
        var out: [OwnFix] = []
        for f in fixes where !sorted.contains(where: { $0.edit.range.overlaps(f.range)
            || ($0.edit.range.isEmpty && f.range.lowerBound < $0.edit.range.lowerBound && $0.edit.range.lowerBound < f.range.upperBound) }) {
            let d = shift(before: f.range.lowerBound)
            var g = f
            g.range = (f.range.lowerBound + d)..<(f.range.upperBound + d)
            out.append(g)
        }
        for e in sorted where !e.revertsFix {
            guard let r = e.recordable(in: before) else { continue }
            let lo = r.edit.range.lowerBound + shift(before: r.edit.range.lowerBound)
            let fixed = r.edit.replacement
            guard !fixed.isEmpty, r.undo != fixed else { continue }
            out.append(OwnFix(range: lo..<(lo + fixed.utf16.count), typed: r.undo, fixed: fixed))
        }
        return Array(out.suffix(capacity))
    }

    static func key(_ s: String, _ options: RewriteOptions) -> String {
        var k = options.fixesCapitals ? s : s.lowercased()
        if !options.fixesPunctuation { k = k.filter { $0.isLetter || $0.isNumber || $0.isWhitespace } }
        return k
    }

    /// The words of `s`, without the punctuation around them (apostrophes inside kept).
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { FieldRewrite.core(String($0)) }.filter { !$0.isEmpty }
    }

    static func same(_ a: String, _ b: String, _ options: RewriteOptions) -> Bool {
        func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map { key(String($0), options) } }
        return words(a) == words(b)
    }
}
