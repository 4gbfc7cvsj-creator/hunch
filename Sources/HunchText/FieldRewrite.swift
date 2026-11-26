// Whole-field rewrite (autocorrect's Top strength): at a pause the model rereads the paragraph being
// typed and answers with a corrected copy. This file is the pure part: which text a pass sends
// (`RewriteTarget`), and which of the model's changes may go in (`FieldRewrite.edits`). The model
// may fix misspellings, real-word slips, small grammar slips, and add or drop a few short words; a
// change that rewords (a different content word, a reordering) is thrown out here, whatever the
// model says. Words the never-touch guard protects and words the caller locks are never changed.
import Foundation
import HunchCore

/// The text one pass works on: whole sentences of the caret's paragraph that the last pass did not
/// already check, up to the caret.
public struct RewriteTarget: Sendable, Equatable {
    /// The text the model may change.
    public var text: String
    /// UTF-16 offset of `text` in the field's text before the caret.
    public var start: Int
    /// Field text before `text` (reference for the model).
    public var before: String
    /// UTF-16 length at the end of `text` that is an unfinished word (the caret is in it): shown to
    /// the model, never changed.
    public var heldTail: Int

    /// Longest target, in characters; a longer stretch starts at a sentence inside the last part.
    public static let maxCharacters = 600

    /// The target for the field's text before the caret, or nil when there is nothing new to check.
    /// - Parameters:
    ///   - checked: the field's text before the caret as the last pass left it (nil: none yet).
    ///     Sentences of the paragraph that are still exactly as they were then are not sent again.
    ///   - finished: the text is complete (sent, or the field left): the last word counts as typed.
    public static func find(before: String, checked: String? = nil, finished: Bool = false) -> RewriteTarget? {
        let ns = before as NSString
        // The paragraph: back to the last line break.
        let lineBreak = ns.rangeOfCharacter(from: .newlines, options: .backwards)
        var start = lineBreak.location == NSNotFound ? 0 : lineBreak.location + lineBreak.length
        // Skip what the last pass checked: whole sentences still the same.
        if let checked {
            let common = commonPrefixUTF16(before, checked)
            let ends = sentenceEnds(in: ns, from: start).filter { $0 <= common }
            if let last = ends.last { start = max(start, last) }
        }
        if ns.length - start > maxCharacters {
            let floor = ns.length - maxCharacters
            start = sentenceEnds(in: ns, from: floor).first ?? floor
            // Mid-word cut: start at the next word.
            while start < ns.length, !isSpace(ns.character(at: start - 1)) { start += 1 }
        }
        // Leading whitespace belongs to the reference.
        while start < ns.length, isSpace(ns.character(at: start)) { start += 1 }
        guard start < ns.length else { return nil }
        let text = ns.substring(from: start)
        guard text.contains(where: \.isLetter), isMostlyLatin(text) else { return nil }
        var held = 0
        if !finished, let last = text.last, !last.isWhitespace, !".!?,;:)".contains(last) {
            held = NeverTouch.lastChunk(of: text).utf16.count
        }
        // A target that is only the unfinished word has nothing to fix yet.
        guard held < text.utf16.count else { return nil }
        return RewriteTarget(text: text, start: start, before: ns.substring(to: start), heldTail: held)
    }

    /// UTF-16 offsets where each sentence after the first starts (after ". " "! " "? " and spaces).
    public static func sentenceEndsPublic(in text: String) -> [Int] { sentenceEnds(in: text as NSString, from: 0) }

    /// UTF-16 offsets just after each sentence end (". " "! " "? ") at or after `from`.
    static func sentenceEnds(in ns: NSString, from: Int) -> [Int] {
        var out: [Int] = []
        var i = max(from, 1)
        while i < ns.length {
            let c = ns.character(at: i - 1)
            if (c == 0x2E || c == 0x21 || c == 0x3F), isSpace(ns.character(at: i)) {
                var j = i
                while j < ns.length, isSpace(ns.character(at: j)) { j += 1 }
                out.append(j)
                i = j
            }
            i += 1
        }
        return out
    }

    static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 }

    static func commonPrefixUTF16(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a.utf16, b.utf16) {
            guard x == y else { break }
            n += 1
        }
        return n
    }

    /// English only for now: at least 85 % of the letters are Latin.
    static func isMostlyLatin(_ text: String) -> Bool {
        var letters = 0, latin = 0
        for s in text.unicodeScalars where CharacterSet.letters.contains(s) {
            letters += 1
            if s.value < 0x250 { latin += 1 }
        }
        return letters > 0 && Double(latin) >= 0.85 * Double(letters)
    }
}

/// One change a pass makes: `original` (at `range` in the field's text before the caret, UTF-16)
/// becomes `replacement`. An added word has an empty range; a dropped word an empty replacement.
public struct RewriteEdit: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A misspelled or garbled word, or a real word typed for another.
        case word
        /// Words run together or split apart.
        case spacing
        /// A short word added, or one dropped (typed twice, or stray).
        case added, dropped
        /// Only capitals changed.
        case capital
        /// Only punctuation or apostrophes changed.
        case punctuation
    }
    public var range: Range<Int>
    public var original: String
    public var replacement: String
    public var kind: Kind

    public init(range: Range<Int>, original: String, replacement: String, kind: Kind) {
        self.range = range
        self.original = original
        self.replacement = replacement
        self.kind = kind
    }
}

/// A change the model made that may not go in, and why (eval and diagnostics).
public struct RejectedRewrite: Sendable, Equatable {
    public enum Reason: String, Sendable, CaseIterable {
        case protected, locked, heldTail, reworded, shorthand, capitals, punctuation, tooManyWords, rephrased
        /// Inside quotes: a word quoted as typed ("recieve" written about) stays.
        case quoted
    }
    public var original: String
    public var replacement: String
    public var reason: Reason
}

public struct RewriteOptions: Sendable, Equatable {
    public var fixesCapitals = true
    public var fixesPunctuation = true
    /// Chat shorthand ("idk", "rn") is kept.
    public var leavesShorthand = false
    /// Most words added or dropped per sentence; more and none of that sentence's go in.
    public var maxAddedOrDropped = 2
    /// When the words in changes that may not go in exceed this share of the target's words, the
    /// model reworded the text: nothing from the pass goes in.
    public var maxRejectedShare = 0.25
    /// Words never changed (lowercased): words on screen (names, terms) and words the user put back
    /// in this field.
    public var keptWords: Set<String> = []
    /// Whether a word is spelled right (the spell checker with the user's learned words). With it, a
    /// typed word that is not a real word may become a real word a few keyboard slips away
    /// (`SlipCost`), not just one or two letters away, and two real words typed apart are never
    /// joined. Nil: plain edit distance only. Not compared by `==`.
    public var isKnownWord: (@Sendable (String) -> Bool)?
    /// The writer types "i" lowercase on its own (set from the text): an added "I" goes in as "i".
    var writesLowercaseI = false

    public init() {}

    public static func == (a: RewriteOptions, b: RewriteOptions) -> Bool {
        a.fixesCapitals == b.fixesCapitals && a.fixesPunctuation == b.fixesPunctuation
            && a.leavesShorthand == b.leavesShorthand && a.maxAddedOrDropped == b.maxAddedOrDropped
            && a.maxRejectedShare == b.maxRejectedShare && a.keptWords == b.keptWords
            && a.writesLowercaseI == b.writesLowercaseI
    }
}

public enum FieldRewrite {
    public struct Result: Sendable, Equatable {
        public var edits: [RewriteEdit]
        public var rejected: [RejectedRewrite]
    }

    /// The changes from `target.text` to the model's `revised` text that may go in. `locked`:
    /// ranges (UTF-16, in the field's text before the caret) the user set by hand, never changed.
    public static func edits(target: RewriteTarget, revised raw: String, options: RewriteOptions = .init(),
                             locked: [Range<Int>] = []) -> Result {
        guard let revised = cleanOutput(raw, target: target.text,
                                        maxRatio: options.leavesShorthand ? 2.2 : 1.5) else {
            return Result(edits: [], rejected: [RejectedRewrite(original: target.text, replacement: raw, reason: .rephrased)])
        }
        let a = Token.split(target.text), b = Token.split(revised)
        var options = options
        options.writesLowercaseI = a.contains { core($0.text) == "i" } && !a.contains { core($0.text) == "I" }
        // Alignment asks about the same words many times: each is looked up once per pass.
        if let known = options.isKnownWord {
            let cache = KnownWords(known)
            options.isKnownWord = { cache.contains($0) }
        }
        let heldFrom = target.text.utf16.count - target.heldTail
        var edits: [RewriteEdit] = []
        var rejected: [RejectedRewrite] = []
        var rejectedWords = 0
        // Differences the app's switches don't allow are not differences: the model's capitals or
        // punctuation never decide how the words line up.
        func key(_ t: Token) -> String {
            var k = options.fixesCapitals ? t.text : t.text.lowercased()
            if !options.fixesPunctuation { k = k.filter { $0.isLetter || $0.isNumber } }
            return k
        }
        let quoted = quotedTokens(a)
        // A word quoted anywhere in the pass's text or before it is written about: it stays as typed
        // everywhere ("recieve" quoted, then "typing recieve").
        let context = Token.split(target.before) + a
        let quotedWords = Set(quotedTokens(context).map { core(context[$0].text).lowercased() })
        let keys = a.map(key)
        // A word that keeps its whole stretch as typed: stretches are never joined across or around it.
        func holds(_ k: Int) -> Bool {
            let t = a[k], span = (t.range.lowerBound + target.start)..<(t.range.upperBound + target.start)
            return protects(t, in: target.text) || t.range.upperBound > heldFrom || locked.contains { $0.overlaps(span) }
                || options.keptWords.contains(core(t.text).lowercased())
        }
        for hunk in joinedAcrossOneWord(hunks(keys, b.map(key)), keys, holds: holds) {
            let orig = Array(a[hunk.a]), new = Array(b[hunk.b])
            let origText = orig.map(\.text).joined(separator: " "), newText = new.map(\.text).joined(separator: " ")
            func reject(_ reason: RejectedRewrite.Reason) {
                rejected.append(RejectedRewrite(original: origText, replacement: newText, reason: reason))
                if reason == .reworded || reason == .tooManyWords { rejectedWords += max(orig.count, new.count) }
            }
            if orig.contains(where: { protects($0, in: target.text) }) { reject(.protected); continue }
            // The unfinished word at the caret is shown, never changed (nor anything added after it).
            if orig.contains(where: { $0.range.upperBound > heldFrom })
                || (orig.isEmpty && hunk.a.lowerBound == a.count && target.heldTail > 0) {
                reject(.heldTail); continue
            }
            let span = orig.isEmpty ? nil : (orig.first!.range.lowerBound + target.start)..<(orig.last!.range.upperBound + target.start)
            if let span, locked.contains(where: { $0.overlaps(span) }) { reject(.locked); continue }
            if !options.keptWords.isEmpty, orig.contains(where: { options.keptWords.contains(core($0.text).lowercased()) }) {
                reject(.locked); continue
            }
            let longest = max(orig.count, new.count)
            // Past this, no run of slips: the model rewrote the text.
            guard longest <= maxStretch else { reject(.reworded); continue }
            let ops = match(orig.map(\.text), new.map(\.text), options: options)
            // A long stretch goes in piece by piece only when most of it lines up word for word
            // (a run of slips); a stretch the model mostly reworded stays as typed.
            if longest > 6 {
                let kept = ops.reduce(0) { n, op in
                    if case let .keep(ra, rb, .reworded) = op { n + max(ra.count, rb.count) } else { n }
                }
                if 3 * kept > longest { reject(.reworded); continue }
            }
            // Part of the stretch stays as typed: the model reworded it, so its added or dropped
            // words would only make a mix of the two.
            let reworded = ops.contains { if case .keep(_, _, let r) = $0 { r == .reworded || r == .shorthand } else { false } }
            // The model spelled out kept shorthand ("idk" → "I don't know"): the words it added for that
            // are not rewording, so they never cost the pass its other fixes.
            let shorthand = ops.contains { if case .keep(_, _, .shorthand) = $0 { true } else { false } }
            // The model dropped or added content words there: what it lined up around them is rewording.
            let droppedOrAddedKept = ops.contains { if case let .keep(ra, rb, .reworded) = $0 { ra.count != rb.count } else { false } }
            for op in ops {
                if reworded, case let .change(ra, rb, kind, _) = op, kind == .added || kind == .dropped {
                    rejected.append(RejectedRewrite(original: orig[ra].map(\.text).joined(separator: " "),
                                                    replacement: new[rb].map(\.text).joined(separator: " "), reason: .reworded))
                    continue
                }
                switch op {
                case let .change(ra, rb, kind, text):
                    let typed = orig[ra].map(\.text).joined(separator: " ")
                    // A word the stretch lines up unchanged (it joined two stretches) is no edit.
                    if kind != .added, kind != .dropped, text == typed { continue }
                    if ra.contains(where: { quoted.contains(hunk.a.lowerBound + $0)
                        || quotedWords.contains(core(orig[$0].text).lowercased()) }) {
                        rejected.append(RejectedRewrite(original: typed, replacement: new[rb].map(\.text).joined(separator: " "),
                                                        reason: .quoted))
                        continue
                    }
                    // Where the model dropped or added content words, only words that are no real word are
                    // fixed: a real word lined up with what is left ("into" → "its") is not a slip.
                    if droppedOrAddedKept, !shorthand, kind == .word, ra.count == 1, let known = options.isKnownWord,
                       isWordAsTyped(orig[ra.lowerBound].text, known) {
                        rejected.append(RejectedRewrite(original: typed, replacement: new[rb].map(\.text).joined(separator: " "),
                                                        reason: .reworded))
                        continue
                    }
                    edits.append(edit(for: op, a: a, hunk: hunk, new: new, target: target, options: options))
                case let .keep(ra, rb, reason):
                    rejected.append(RejectedRewrite(original: orig[ra].map(\.text).joined(separator: " "),
                                                    replacement: new[rb].map(\.text).joined(separator: " "), reason: reason))
                    if reason == .reworded, !shorthand { rejectedWords += max(ra.count, rb.count) }
                }
            }
        }
        // Too many words added or dropped in one sentence: the model rewrote it.
        var limited: [RewriteEdit] = []
        let sentences = Dictionary(grouping: edits) { sentenceIndex(of: $0.range.lowerBound - target.start, in: target.text) }
        for (_, group) in sentences {
            let count = group.filter { $0.kind == .added || $0.kind == .dropped }.count
            if count > options.maxAddedOrDropped {
                for e in group where e.kind == .added || e.kind == .dropped {
                    rejected.append(RejectedRewrite(original: e.original, replacement: e.replacement, reason: .tooManyWords))
                    rejectedWords += 1
                }
                limited += group.filter { $0.kind != .added && $0.kind != .dropped }
            } else {
                limited += group
            }
        }
        if Double(rejectedWords) > options.maxRejectedShare * Double(max(a.count, 1)) {
            return Result(edits: [], rejected: rejected + limited.map {
                RejectedRewrite(original: $0.original, replacement: $0.replacement, reason: .rephrased)
            })
        }
        return Result(edits: limited.sorted { $0.range.lowerBound < $1.range.lowerBound }, rejected: rejected)
    }

    /// Longest stretch of differing words lined up word by word.
    static let maxStretch = 40

    /// A spell checker's answers for one pass (`edits` runs synchronously, on one thread).
    final class KnownWords: @unchecked Sendable {
        private let base: @Sendable (String) -> Bool
        private var seen: [String: Bool] = [:]

        init(_ base: @escaping @Sendable (String) -> Bool) { self.base = base }

        func contains(_ word: String) -> Bool {
            if let hit = seen[word] { return hit }
            let known = base(word)
            seen[word] = known
            return known
        }
    }

    /// `before` with `edits` applied (from the end, so earlier ranges stay valid).
    public static func apply(_ edits: [RewriteEdit], to before: String) -> String {
        var units = Array(before.utf16)
        // From the end; at one point, a replacement before an insertion there.
        for e in edits.sorted(by: { ($0.range.lowerBound, $0.range.count) > ($1.range.lowerBound, $1.range.count) }) {
            guard e.range.upperBound <= units.count else { continue }
            units.replaceSubrange(e.range, with: Array(e.replacement.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The edits that may still go in after the field changed from `original` to `fresh` while the
    /// model worked: those whose text, and the word after it, are still exactly where they were.
    public static func stillApplicable(_ edits: [RewriteEdit], original: String, fresh: String) -> [RewriteEdit] {
        let common = RewriteTarget.commonPrefixUTF16(original, fresh)
        let units = Array(original.utf16)
        return edits.filter { e in
            // The edit and the rest of its word's neighbourhood (up to the next space) must be unchanged.
            var end = e.range.upperBound
            while end < units.count, !RewriteTarget.isSpace(units[end]) { end += 1 }
            return end < common || (end == units.count && common == units.count)
        }
    }

    // MARK: Model output

    /// The model's text as a candidate copy of `target`, or nil when it is not one: empty, a note
    /// instead of the text, or far longer or shorter.
    /// `maxRatio`: longest copy against the target (kept shorthand the model spells out, "idk" →
    /// "I don't know", makes it longer; those words are thrown out word by word).
    static func cleanOutput(_ raw: String, target: String, maxRatio: Double = 1.5) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Corrected:", "Corrected text:", "My text:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if t.count >= 2, let f = t.first, let l = t.last, "\"“'".contains(f), "\"”'".contains(l),
           !(target.first.map { "\"“'".contains($0) } ?? false) {
            t = String(t.dropFirst().dropLast())
        }
        // A one-line target gets a one-line answer; anything after is a note.
        if !target.contains("\n"), let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        // Trailing whitespace the user typed is not the model's to keep or drop.
        guard !t.isEmpty else { return nil }
        let ratio = Double(t.count) / Double(max(target.trimmingCharacters(in: .whitespaces).count, 1))
        guard ratio > 0.6, ratio < maxRatio else { return nil }
        return t
    }

    // MARK: Alignment

    struct Token: Equatable {
        var text: String
        /// UTF-16 range in the text it came from.
        var range: Range<Int>

        static func split(_ s: String) -> [Token] {
            var out: [Token] = []
            var start: Int?
            var i = 0
            for u in s.utf16 {
                if RewriteTarget.isSpace(u) {
                    if let st = start { out.append(token(s, st, i)); start = nil }
                } else if start == nil { start = i }
                i += 1
            }
            if let st = start { out.append(token(s, st, i)) }
            return out
        }

        static func token(_ s: String, _ a: Int, _ b: Int) -> Token {
            let u = s.utf16
            let text = String(u[u.index(u.startIndex, offsetBy: a)..<u.index(u.startIndex, offsetBy: b)]) ?? ""
            return Token(text: text, range: a..<b)
        }
    }

    struct Hunk: Equatable { var a: Range<Int>; var b: Range<Int> }

    /// Runs of differing tokens between two token lists (longest common subsequence).
    static func hunks(_ a: [String], _ b: [String]) -> [Hunk] {
        let n = a.count, m = b.count
        var l = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    l[i][j] = a[i] == b[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
                }
            }
        }
        var out: [Hunk] = []
        var i = 0, j = 0, hi = 0, hj = 0
        func flush() { if hi < i || hj < j { out.append(Hunk(a: hi..<i, b: hj..<j)) } }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush(); i += 1; j += 1; hi = i; hj = j
            } else if j >= m || (i < n && l[i + 1][j] >= l[i][j + 1]) {
                i += 1
            } else {
                j += 1
            }
        }
        flush()
        return out
    }

    /// Two stretches one plain word apart, one of them only words dropped or only words added, as
    /// one stretch with that word in it: the word lined up with the wrong copy of itself ("you
    /// apizza adn a beer" → "you a pizza and a beer" pairs the typed "a" with the model's first one).
    /// `holds`: a typed word whose stretch must stay as typed (protected, locked, …): never joined.
    static func joinedAcrossOneWord(_ hunks: [Hunk], _ a: [String], holds: (Int) -> Bool = { _ in false }) -> [Hunk] {
        var out: [Hunk] = []
        for h in hunks {
            if let last = out.last, h.a.lowerBound == last.a.upperBound + 1, h.b.lowerBound == last.b.upperBound + 1,
               last.a.isEmpty || last.b.isEmpty || h.a.isEmpty || h.b.isEmpty,
               a[last.a.upperBound].allSatisfy(\.isLetter),
               !(last.a.lowerBound..<h.a.upperBound).contains(where: holds) {
                out[out.count - 1] = Hunk(a: last.a.lowerBound..<h.a.upperBound, b: last.b.lowerBound..<h.b.upperBound)
            } else {
                out.append(h)
            }
        }
        return out
    }

    /// Indexes of tokens inside quotes: a closed pair of double quotes around at most
    /// `maxQuotedWords` words, or one word in single quotes. A word quoted on its own is often
    /// written about as typed ("recieve" is not fixed).
    static func quotedTokens(_ tokens: [Token]) -> Set<Int> {
        let opens: Set<Character> = ["\"", "“"], closes: Set<Character> = ["\"", "”"]
        var out = Set<Int>()
        var start: Int?
        for (k, t) in tokens.enumerated() {
            let w = Array(t.text)
            if let s = start {
                if w.contains(where: closes.contains) {
                    if k - s < maxQuotedWords { out.formUnion(s...k) }
                    start = nil
                } else if k - s + 1 >= maxQuotedWords {
                    start = nil  // too long for a word quoted as typed
                }
                continue
            }
            guard let q = w.firstIndex(where: { !"([{".contains($0) }) else { continue }
            if opens.contains(w[q]) {
                // Closed in the same word ("recieve".) or in a later one.
                if w[(q + 1)...].contains(where: closes.contains) { out.insert(k) } else { start = k }
            } else if w[q] == "'" || w[q] == "‘", let e = w.lastIndex(where: { $0 == "'" || $0 == "’" }), e > q + 1,
                      w[(q + 1)..<e].allSatisfy(\.isLetter), w[(e + 1)...].allSatisfy(\.isPunctuation) {
                out.insert(k)  // 'recieve'
            }
        }
        return out
    }

    /// Most words a quote may hold and stay as typed: one. Longer quotes are mostly names of things
    /// ("leave chat shortand" for a setting) whose slips are slips.
    static let maxQuotedWords = 1

    // MARK: What may change

    enum Op: Equatable {
        /// Original tokens `a` (offsets within the hunk) become new tokens `b`.
        /// `text`: what goes in, in the writer's style where a switch keeps it (empty: dropped).
        case change(a: Range<Int>, b: Range<Int>, kind: RewriteEdit.Kind, text: String)
        /// The model's change of `a` into `b` may not go in: the original stays.
        case keep(a: Range<Int>, b: Range<Int>, reason: RejectedRewrite.Reason)
    }

    /// The hunk as operations: one-to-one fixes, joins, splits and short words added or dropped
    /// where allowed, and the rest kept as typed (with why). Prefers the fewest kept words, then the
    /// fewest added or dropped.
    static func match(_ a: [String], _ b: [String], options: RewriteOptions) -> [Op] {
        var memo: [Int: (cost: Int, ops: [Op])] = [:]
        func solve(_ i: Int, _ j: Int) -> (cost: Int, ops: [Op]) {
            if i == a.count, j == b.count { return (0, []) }
            let key = i * (b.count + 1) + j
            if let hit = memo[key] { return hit }
            var best: (cost: Int, ops: [Op])?
            func consider(_ di: Int, _ dj: Int, _ op: Op, cost: Int) {
                let rest = solve(i + di, j + dj)
                if best == nil || rest.cost + cost < best!.cost { best = (rest.cost + cost, [op] + rest.ops) }
            }
            func change(_ di: Int, _ dj: Int, _ kind: RewriteEdit.Kind, cost: Int) {
                let typed = Array(a[i..<(i + di)]), model = Array(b[j..<(j + dj)])
                var text = kind == .dropped ? "" : styled(model, typed: typed, options: options)
                // Words respaced with Fix punctuation off keep every mark the writer typed ("problems:i"
                // → "problems: i", never "problems i"), or stay as typed.
                if kind == .spacing, !options.fixesPunctuation, marks(text) != marks(typed.joined()) {
                    var withMarks = options
                    withMarks.fixesPunctuation = true
                    text = styled(model, typed: typed, options: withMarks)
                    guard marks(text) == marks(typed.joined()) else { return }
                }
                consider(di, dj, .change(a: i..<(i + di), b: j..<(j + dj), kind: kind, text: text), cost: cost)
            }
            func keep(_ di: Int, _ dj: Int, _ reason: RejectedRewrite.Reason) {
                consider(di, dj, .keep(a: i..<(i + di), b: j..<(j + dj), reason: reason), cost: 10 * max(di, dj))
            }
            if i < a.count, j < b.count, swallowsNeighbour(a, i, b[j]) {
                keep(1, 1, .reworded)
            } else if i < a.count, j < b.count {
                switch oneToOne(a[i], b[j], options: options) {
                case .success(let fix):
                    consider(1, 1, .change(a: i..<(i + 1), b: j..<(j + 1), kind: fix.kind, text: fix.text), cost: 0)
                case .failure(let e): keep(1, 1, e.reason)
                }
            }
            // Words run together or split apart: up to three typed words for up to three of the model's.
            for di in 1...3 where i + di <= a.count {
                for dj in 1...3 where j + dj <= b.count && di + dj > 2 {
                    if respaced(Array(a[i..<(i + di)]), Array(b[j..<(j + dj)]), options: options) {
                        change(di, dj, .spacing, cost: 0)
                    }
                }
            }
            if j < b.count {
                if isShortWord(b[j]) { change(0, 1, .added, cost: 1) } else { keep(0, 1, .reworded) }
            }
            if i < a.count {
                let doubled = (i > 0 && core(a[i - 1]).lowercased() == core(a[i]).lowercased())
                    || (i + 1 < a.count && core(a[i + 1]).lowercased() == core(a[i]).lowercased())
                if (isShortWord(a[i]) || doubled), !a[i].contains(where: \.isNumber), a[i].contains(where: \.isLetter) { change(1, 0, .dropped, cost: 1) } else { keep(1, 0, .reworded) }
            }
            let found = best ?? (0, [])
            memo[key] = found
            return found
        }
        return pairedUp(solve(0, 0).ops, a, b, options: options)
    }

    /// A word dropped right next to a word added is a one-word change in disguise ("I" dropped,
    /// "I'm" added): it is judged as that change instead.
    static func pairedUp(_ ops: [Op], _ a: [String], _ b: [String], options: RewriteOptions) -> [Op] {
        var out: [Op] = []
        var k = 0
        while k < ops.count {
            if k + 1 < ops.count, case let .change(ra1, rb1, k1, _) = ops[k], case let .change(ra2, rb2, k2, _) = ops[k + 1],
               Set([k1, k2]) == [.added, .dropped] {
                let ra = min(ra1.lowerBound, ra2.lowerBound)..<max(ra1.upperBound, ra2.upperBound)
                let rb = min(rb1.lowerBound, rb2.lowerBound)..<max(rb1.upperBound, rb2.upperBound)
                switch oneToOne(a[ra.lowerBound], b[rb.lowerBound], options: options) {
                case .success(let fix): out.append(.change(a: ra, b: rb, kind: fix.kind, text: fix.text))
                case .failure(let e): out.append(.keep(a: ra, b: rb, reason: e.reason))
                }
                k += 2
                continue
            }
            out.append(ops[k])
            k += 1
        }
        return out
    }

    struct ReasonError: Error { var reason: RejectedRewrite.Reason; init(_ r: RejectedRewrite.Reason) { reason = r } }

    /// A one-word change, its kind and the text that goes in, or why it may not go in. A change of
    /// only capitals or punctuation needs its switch; a spelling fix always goes in, put into the
    /// writer's style where a switch keeps it (`styled`): "teh" → "the" even when the model wrote
    /// "The" with capitals off.
    static func oneToOne(_ o: String, _ n: String, options: RewriteOptions)
        -> Swift.Result<(kind: RewriteEdit.Kind, text: String), ReasonError> {
        // A list number stuck to a word ("setting2.") is never removed or changed.
        guard listNumbers(o) == listNumbers(n) else { return .failure(.init(.reworded)) }
        let co = core(o), cn = core(n)
        if co.lowercased() == cn.lowercased() {
            let capsChanged = co != cn
            let punctChanged = strip(o) != strip(n)
            if capsChanged, !options.fixesCapitals { return .failure(.init(.capitals)) }
            if punctChanged, !options.fixesPunctuation { return .failure(.init(.punctuation)) }
            // Ending a sentence ("Alex" → "Alex.") is the writer's call: a sign-off, a list, a chat line.
            if punctChanged, n.hasPrefix(o), n.dropFirst(o.count).allSatisfy({ ".!?".contains($0) }) {
                return .failure(.init(.punctuation))
            }
            return .success((punctChanged ? .punctuation : .capital, n))
        }
        let lo = co.lowercased(), ln = cn.lowercased()
        // An apostrophe put in ("dont" → "don't") is punctuation.
        if lo == ln.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "") {
            return options.fixesPunctuation ? .success((.punctuation, n)) : .failure(.init(.punctuation))
        }
        // A contraction that adds a word ("I going" → "I'm going"): it needs an apostrophe.
        let ln2 = ln.replacingOccurrences(of: "’", with: "'")
        if ["'m", "'re", "'s", "'ll", "'ve", "'d"].contains(where: { ln2 == lo + $0 }) {
            // Without Fix punctuation, only when the writer typed the apostrophe ("I'," → "I'm").
            guard options.fixesPunctuation || o.contains("'") || o.contains("’") else { return .failure(.init(.punctuation)) }
            return .success((.added, styled([n], typed: [o], options: options)))
        }
        if options.leavesShorthand, ChatShorthand.contains(lo) { return .failure(.init(.shorthand)) }
        // What the word is, judged on letters alone.
        let ln3 = ln.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let lo3 = lo.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        var allowed = false
        if isShortWord(lo), isShortWord(ln) { allowed = true }  // a/an, is/are, to/too
        else if ConfusedWords.rivals(of: lo, trailing: "").contains(where: { $0.lowercased() == ln }) { allowed = true }
        else if editDistance(lo, ln) <= (lo.count <= 3 ? 1 : lo.count <= 6 ? 2 : 3)
                    || editDistance(lo3, ln3) <= (lo3.count <= 3 ? 1 : lo3.count <= 6 ? 2 : 3) { allowed = true }
        // Grammar: the same word with another ending ("go" → "goes", "try" → "tried").
        else if sameWordOtherEnding(lo, ln) || irregularForms.contains(where: { $0.contains(lo) && $0.contains(ln) }) {
            allowed = true
        }
        // Not a real word: any real word a few keyboard slips away ("fh" → "the", "capitlaizoain" →
        // "capitalization").
        else if slipFix(typed: co, model: cn, options: options) { allowed = true }
        guard allowed else { return .failure(.init(.reworded)) }
        // A word that is no real word becomes a real word, never another non-word ("oordash" → "ordash").
        if let known = options.isKnownWord, !isWordAsTyped(co, known), !known(cn) { return .failure(.init(.reworded)) }
        let text = styled([n], typed: [o], options: options)
        // In the writer's style the fix may be no change at all ("dont" kept for "don't").
        guard text != o else { return .failure(.init(options.fixesPunctuation ? .capitals : .punctuation)) }
        return .success((.word, text))
    }

    /// Whether `typed`, not a real word, may become the real word `model`: the keyboard-slip cost
    /// (`SlipCost`) within about one slip per three letters (at least 1.8, so a two- or three-letter
    /// garble like "fh" or "dha" can be fixed), and not much shorter or longer. Never for a word that
    /// looks like a name or term (digits, capitals inside, all capitals) or chat shorthand: those
    /// keep the strict rules. Needs `options.isKnownWord`.
    static func slipFix(typed: String, model: String, options: RewriteOptions) -> Bool {
        guard let known = options.isKnownWord else { return false }
        let x = typed.lowercased().filter(\.isLetter), y = model.lowercased().filter(\.isLetter)
        guard !x.isEmpty, !y.isEmpty, !typed.contains(where: \.isNumber), !ChatShorthand.contains(x) else { return false }
        switch casing([typed]) {
        case .lower, .title: break
        case .upper, .other: return false
        }
        guard abs(x.count - y.count) <= max(1, x.count / 4) else { return false }
        guard SlipCost.cost(typed: x, candidate: y) <= max(1.8, Float(x.count) / 3 + 0.8) else { return false }
        return !isWordAsTyped(typed, known) && known(model)
    }

    /// Punctuation marks of a text, in order (apostrophes included).
    static func marks(_ s: String) -> String { s.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace } }

    static func isQuoteMark(_ c: Character) -> Bool { "\"“”«»".contains(c) }

    /// The numbers in a word that end in "." or ")" ("setting2." → "2", "so:1." → "1"): a list's
    /// numbering, never a slip. A digit inside a word ("bet6er") is a number-row key hit for a letter.
    static func listNumbers(_ w: String) -> String {
        var out = "", run = ""
        for c in w {
            if c.isNumber { run.append(c); continue }
            if !run.isEmpty, c == "." || c == ")" { out += run + "|" }
            run = ""
        }
        return out
    }

    /// Whether the model's one word ends with the next typed word's letters too: "test ing" →
    /// "testing" is a join, never "test" → "testing" leaving "ing" (nor "ing" → "testing").
    static func swallowsNeighbour(_ a: [String], _ i: Int, _ model: String) -> Bool {
        func letters(_ w: String) -> String { w.lowercased().filter(\.isLetter) }
        let m = letters(model), w = letters(a[i])
        guard !w.isEmpty, m != w else { return false }
        if i + 1 < a.count, !letters(a[i + 1]).isEmpty, m == w + letters(a[i + 1]) { return true }
        if i > 0, !letters(a[i - 1]).isEmpty, m == letters(a[i - 1]) + w { return true }
        return false
    }

    /// Endings typed apart from their word ("test ing").
    static let detachedEndings: Set<String> = ["ing", "ed", "ly", "es", "er", "est", "ment", "ness", "tion", "able", "ful", "less"]

    /// A word and an ending typed apart, the model's word exactly their letters: a join even when the
    /// spell checker knows the ending as a word.
    static func isWordAndEnding(_ typed: [String], _ model: [String]) -> Bool {
        guard typed.count == 2, model.count == 1 else { return false }
        let x = typed.joined().lowercased().filter(\.isLetter), y = model[0].lowercased().filter(\.isLetter)
        return x == y && detachedEndings.contains(core(typed[1]).lowercased())
    }

    /// Two-letter words people type on purpose, besides the function words (`shortWords`). Other
    /// two-letter pieces the spell checker accepts (abbreviations: "ht", "la") are taken as slips.
    static let twoLetterWords: Set<String> = [
        "ok", "oh", "hi", "no", "go", "us", "ah", "ha", "uh", "um", "eh", "ex", "yo", "ya", "ma", "pa", "ox", "tv", "pc",
    ]

    /// Whether the writer meant `w` as typed: a word the spell checker knows (at two letters, only
    /// a function word or one of `twoLetterWords`).
    static func isWordAsTyped(_ w: String, _ known: (String) -> Bool) -> Bool {
        let c = core(w)
        if c.count == 2 { return isShortWord(c) || twoLetterWords.contains(c.lowercased()) }
        return known(c)
    }

    /// Whether a word counts as a real word for joins and splits: a number, "a" or "I", a two-letter
    /// function word ("in", "to"), or a longer word the spell checker knows. Other one- and two-letter
    /// pieces ("s", "ed") are slips.
    static func isRealWord(_ w: String, _ known: (String) -> Bool) -> Bool {
        let c = core(w)
        guard !c.isEmpty else { return false }
        if c.contains(where: \.isNumber) { return true }
        if c.count <= 2 { return isShortWord(c) }
        return known(c)
    }

    /// Whether the model's `model` words are `typed` with the spaces moved: the same letters (one
    /// slip, two past six letters). With `isKnownWord`, also up to three typed words for up to three
    /// of the model's when the spaces really move, every word the model wrote is a real word and the
    /// letters are a slip or two apart (one per six letters past nine; one slip when a real word
    /// typed there changes): "toose e" → "to see", never "teh cat" → "the cart". Words typed
    /// apart that are all real words are never run together ("well known" stays), except function
    /// words ("in to" → "into"). A run-together word with a capital inside ("GaryLeffler") never
    /// goes in, nor a sentence end the writer did not type.
    static func respaced(_ typed: [String], _ model: [String], options: RewriteOptions) -> Bool {
        if model.count == 1, typed.count > 1, core(model[0]).dropFirst().contains(where: \.isUppercase) { return false }
        if let m = model.last, let t = typed.last, let end = m.last, ".!?".contains(end),
           !t.contains(where: { ".!?".contains($0) }) { return false }
        guard typed.map(listNumbers).joined() == model.map(listNumbers).joined() else { return false }
        // A quote mark is never dropped or added by respacing (`like "` → `like` would leave a quote unmatched).
        guard typed.joined().filter(isQuoteMark).count == model.joined().filter(isQuoteMark).count else { return false }
        let oldShape = (typed.count == 2 && model.count == 1) || (typed.count == 1 && model.count == 2)
        let same = oldShape && sameLetters(typed.joined(), model.joined())
        guard let known = options.isKnownWord else { return same }
        func letters(_ w: String) -> String { w.lowercased().filter(\.isLetter) }
        let x = typed.map(letters).joined(), y = model.map(letters).joined()
        // The cheap tests first (the spell checker is asked last).
        var cost: Float = 0
        if !same {
            guard !x.isEmpty, !y.isEmpty else { return false }
            // As many words on each side: the spaces must move, or it is word-for-word fixes.
            if typed.count == model.count, typed.map({ letters($0).count }) == model.map({ letters($0).count }) { return false }
            cost = SlipCost.cost(typed: x, candidate: y)
            guard cost <= max(1.5, Float(x.count) / 6) else { return false }
        }
        if typed.count > 1, typed.allSatisfy({ isRealWord($0, known) }), !typed.allSatisfy(isShortWord),
           !isWordAndEnding(typed, model) { return false }
        // A join must make a real word; a split of one word keeps the old rule.
        if typed.count > 1, !model.allSatisfy({ isRealWord($0, known) }) { return false }
        if same { return true }
        guard model.allSatisfy({ isRealWord($0, known) }) else { return false }
        let modelWords = Set(model.map(letters))
        if typed.contains(where: { letters($0).count >= 3 && isRealWord($0, known) && !modelWords.contains(letters($0)) }) {
            return cost <= 1
        }
        return true
    }

    // MARK: The writer's style

    /// How a typed word is capitalized.
    enum Casing { case lower, title, upper, other }

    static func casing(_ words: [String]) -> Casing {
        let letters = words.map(core).joined().filter(\.isLetter)
        guard let first = letters.first else { return .other }
        if !letters.contains(where: \.isUppercase) { return .lower }
        if letters.count >= 2, !letters.contains(where: \.isLowercase) { return .upper }
        if first.isUppercase, !letters.dropFirst().contains(where: \.isUppercase) { return .title }
        return .other
    }

    /// The model's words, as they go in: with capitals off, cased like the typed words ("teh" →
    /// "the", "iphnoe" → "iphone"; an added word lowercase, "I" as the writer types it); with Fix
    /// punctuation off, the typed words' punctuation around them and no apostrophe the writer left out.
    /// `typed` empty: added words.
    static func styled(_ model: [String], typed: [String], options: RewriteOptions) -> String {
        var words = model
        if !options.fixesCapitals {
            switch typed.isEmpty ? (options.writesLowercaseI ? .lower : .other) : casing(typed) {
            case .lower:
                words = words.map { $0.lowercased() }
            case .title:
                words = words.enumerated().map { k, w in k == 0 ? capitalizedFirst(w.lowercased()) : w.lowercased() }
            case .upper:
                words = words.map { $0.uppercased() }
            case .other:
                // An added word: lowercase, except "I" (and its contractions) as the model wrote it.
                if typed.isEmpty {
                    words = words.map { w in core(w).lowercased().hasPrefix("i'") || core(w) == "I" ? w : w.lowercased() }
                }
            }
        }
        if !options.fixesPunctuation {
            let typedHasApostrophe = typed.contains { $0.contains("'") || $0.contains("’") }
            var cores = words.map { w -> String in
                let c = core(w)
                return typedHasApostrophe || typed.isEmpty ? c
                    : c.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            }
            if let first = typed.first, let last = typed.last, !cores.isEmpty {
                cores[0] = edge(leadingPunctuation(first)) + cores[0]
                var trail = edge(trailingPunctuation(last))
                // A punctuation key hit for a letter ("I'," for "I'm"): the model's word is one letter
                // longer than what was typed before the mark, so the mark was a slip, not punctuation.
                if model.count == 1, typed.count == 1, trail.count == 1, ",;./".contains(trail),
                   trailingPunctuation(model[0]).isEmpty,
                   wordPart(model[0]).count == wordPart(String(last.dropLast())).count + 1 {
                    trail = ""
                }
                cores[cores.count - 1] += trail
            }
            words = cores
        }
        return words.joined(separator: " ")
    }

    /// Edge punctuation without apostrophes (they belong to the word: "I'", "it'").
    static func edge(_ p: String) -> String { p.filter { $0 != "'" && $0 != "’" } }

    /// The word with apostrophes, without the punctuation around it.
    static func wordPart(_ w: String) -> String {
        w.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'’")))
    }

    static func capitalizedFirst(_ w: String) -> String {
        guard let i = w.firstIndex(where: \.isLetter) else { return w }
        return w.replacingCharacters(in: i...i, with: String(w[i]).uppercased())
    }

    /// The punctuation before and after a word's core ("(off," → "(" and ",").
    static func leadingPunctuation(_ w: String) -> String {
        let c = core(w)
        guard !c.isEmpty, let r = w.range(of: c) else { return "" }
        return String(w[..<r.lowerBound])
    }

    static func trailingPunctuation(_ w: String) -> String {
        let c = core(w)
        guard !c.isEmpty, let r = w.range(of: c, options: .backwards) else { return "" }
        return String(w[r.upperBound...])
    }

    /// Forms of one irregular verb ("see", "saw", "seen"): a tense or agreement slip, not a new word.
    static let irregularForms: [Set<String>] = [
        "be am is are was were been being", "have has had having", "do does did done doing", "go goes went gone",
        "see sees saw seen", "come comes came", "get gets got gotten", "make makes made", "take takes took taken",
        "give gives gave given", "know knows knew known", "think thinks thought", "say says said", "tell tells told",
        "find finds found", "send sends sent", "bring brings brought", "buy buys bought", "write writes wrote written",
        "begin begins began begun", "leave leaves left", "feel feels felt", "keep keeps kept", "run runs ran",
        "eat eats ate eaten", "fall falls fell fallen", "forget forgets forgot forgotten", "pay pays paid",
        "meet meets met", "sit sits sat", "speak speaks spoke spoken", "stand stands stood", "teach teaches taught",
        "catch catches caught", "choose chooses chose chosen", "break breaks broke broken", "drive drives drove driven",
        "lose loses lost", "hear hears heard", "hold holds held", "read reads", "put puts", "set sets",
    ].map { Set($0.split(separator: " ").map(String.init)) }

    /// The same word with another ending: "go"/"goes", "try"/"tried", "walk"/"walking".
    static func sameWordOtherEnding(_ a: String, _ b: String) -> Bool {
        let endings = ["", "s", "es", "ed", "d", "ing", "ies", "ied", "'s", "er", "est", "ly"]
        func stems(_ w: String) -> [String] {
            endings.compactMap { e in
                guard w.count > e.count, w.hasSuffix(e) else { return nil }
                let s = String(w.dropLast(e.count))
                return e.hasPrefix("i") && (e == "ies" || e == "ied") ? s + "y" : s
            }
        }
        let sa = Set(stems(a)), sb = Set(stems(b))
        return sa.contains { $0.count >= 2 && sb.contains($0) }
    }

    /// Function words the model may add or drop ("the", "to", "is", "I'm").
    static let shortWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "from", "with", "by", "as", "and", "or", "but", "so",
        "if", "is", "are", "was", "were", "be", "been", "am", "i", "i'm", "it", "it's", "its", "that", "this",
        "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should", "not", "too",
        "you", "we", "they", "he", "she", "me", "my", "up", "out", "just", "than", "then", "there", "their",
    ]

    static func isShortWord(_ s: String) -> Bool { shortWords.contains(core(s).lowercased().replacingOccurrences(of: "’", with: "'")) }

    /// The word without punctuation around it.
    static func core(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'’")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
    }

    static func strip(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    static func sameLetters(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().filter(\.isLetter), y = b.lowercased().filter(\.isLetter)
        return !x.isEmpty && (x == y || editDistance(x, y) <= (x.count > 6 ? 2 : 1))
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Optimal string alignment distance (adjacent swaps count as one edit).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }

    /// A token the never-touch guard protects: a link, path, identifier, code, etc.
    static func protects(_ token: Token, in text: String) -> Bool {
        let u = text.utf16
        let upTo = String(u[u.startIndex..<u.index(u.startIndex, offsetBy: token.range.upperBound)]) ?? ""
        if NeverTouch.insideCode(upTo) || token.text.contains("`") { return true }
        return NeverTouch.kind(of: token.text) != nil
    }

    // MARK: Building edits

    static func edit(for op: Op, a: [Token], hunk: Hunk, new: [Token], target: RewriteTarget,
                     options: RewriteOptions) -> RewriteEdit {
        guard case let .change(ra, _, kind, text) = op else { preconditionFailure("only changes become edits") }
        let orig = Array(a[(hunk.a.lowerBound + ra.lowerBound)..<(hunk.a.lowerBound + ra.upperBound)])
        var repl = text
        let base = target.start
        if let first = orig.first, let last = orig.last {
            if repl.isEmpty {
                let full = Array(target.text.utf16)
                var lo = first.range.lowerBound, hi = last.range.upperBound
                let after = trailingPunctuation(last.text)
                if !after.isEmpty, lo > 0, RewriteTarget.isSpace(full[lo - 1]) {
                    // Dropped before its punctuation ("the the." → "the."): the space before and the
                    // word go, the punctuation stays.
                    lo -= 1
                    hi -= after.utf16.count
                } else if hi < full.count, RewriteTarget.isSpace(full[hi]) {
                    hi += 1  // take the space after it
                } else if lo > 0, RewriteTarget.isSpace(full[lo - 1]) {
                    lo -= 1  // or before it, at the end
                }
                return RewriteEdit(range: (lo + base)..<(hi + base), original: substring(target.text, lo, hi),
                                   replacement: "", kind: kind)
            }
            // A fixed word that starts a sentence gets its capital when capitals are fixed.
            if options.fixesCapitals, kind == .word || kind == .spacing,
               isSentenceStart(tokenIndex: hunk.a.lowerBound + ra.lowerBound, tokens: a, text: target.text,
                               before: target.before),
               core(first.text).first?.isLowercase == true {
                repl = capitalizedFirst(repl)
            }
            return RewriteEdit(range: (first.range.lowerBound + base)..<(last.range.upperBound + base),
                               original: orig.map(\.text).joined(separator: " "), replacement: repl, kind: kind)
        }
        // Added: before the next original word, or after the previous one at the end (where the
        // operation is in the stretch, not where the stretch starts).
        let at = hunk.a.lowerBound + ra.lowerBound
        if at < a.count {
            let p = a[at].range.lowerBound + base
            return RewriteEdit(range: p..<p, original: "", replacement: repl + " ", kind: kind)
        }
        let p = (a.last?.range.upperBound ?? 0) + base
        return RewriteEdit(range: p..<p, original: "", replacement: " " + repl, kind: kind)
    }

    /// Whether token `k` of the target starts a sentence: the first one after a sentence end or a line
    /// break (or at the very start of the field).
    /// The token opens a sentence (`CapitalFix.startsSentence`: not after "Dr." "e.g." or an ellipsis).
    static func isSentenceStart(tokenIndex k: Int, tokens: [Token], text: String, before: String) -> Bool {
        CapitalFix.startsSentence(before: Substring(before + substring(text, 0, tokens[k].range.lowerBound)))
    }

    static func substring(_ s: String, _ lo: Int, _ hi: Int) -> String {
        let u = s.utf16
        return String(u[u.index(u.startIndex, offsetBy: lo)..<u.index(u.startIndex, offsetBy: hi)]) ?? ""
    }

    /// Which sentence of `text` an offset is in.
    static func sentenceIndex(of offset: Int, in text: String) -> Int {
        RewriteTarget.sentenceEnds(in: text as NSString, from: 0).filter { $0 <= offset }.count
    }
}

extension RewriteEdit {
    /// The edit as a change of words the fix history can record (both sides non-empty): an added or
    /// dropped word joins the word before it ("link" → "link to", "the the" → "the"), or the word
    /// after it at the start of the text. `text`: the text the range is in. Nil when there is no
    /// word to join.
    public func recordable(in text: String) -> RewriteEdit? {
        guard original.isEmpty || replacement.isEmpty else { return self }
        let u = Array(text.utf16)
        func isSpace(_ i: Int) -> Bool { RewriteTarget.isSpace(u[i]) }
        func sub(_ a: Int, _ b: Int) -> String { String(decoding: u[a..<b], as: UTF16.self) }
        // Start of the word ending at or before `end` (spaces before `end` skipped).
        func previousWordStart(_ end: Int) -> Int? {
            var i = end
            while i > 0, isSpace(i - 1) { i -= 1 }
            guard i > 0 else { return nil }
            while i > 0, !isSpace(i - 1) { i -= 1 }
            return i
        }
        let at = range.lowerBound
        if let q = previousWordStart(at) {
            let head = sub(q, at)
            return RewriteEdit(range: q..<range.upperBound, original: head + original, replacement: head + replacement,
                               kind: kind)
        }
        // At the start: join the word after.
        var end = range.upperBound
        while end < u.count, isSpace(end) { end += 1 }
        while end < u.count, !isSpace(end) { end += 1 }
        guard end > range.upperBound else { return nil }
        let next = sub(range.upperBound, end)
        return RewriteEdit(range: range.lowerBound..<end, original: original + next, replacement: replacement + next,
                           kind: kind)
    }
}
