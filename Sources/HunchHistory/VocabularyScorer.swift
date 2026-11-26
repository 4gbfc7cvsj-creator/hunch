import Foundation
import HunchCore

/// Decides which words and short phrases are worth learning, and how much credit each earns.
public struct VocabularyScorer: Sendable {
    /// One thing to learn: a word or 2-3 word phrase, with surprise credit in (0, 1].
    public struct Candidate: Sendable, Equatable {
        public var text: String
        public var credit: Float
        /// Up to 2 words that preceded `text`, original casing.
        public var context: [String]
    }

    /// Credit below this is not recorded at all.
    public static let minCredit: Float = 0.1
    /// Words the model rated more likely than this (natural log) earn no credit.
    public static let likelyLogProb: Float = -1.0
    /// logProb at which credit saturates at 1.
    public static let surprisingLogProb: Float = -4.0

    public init() {}

    /// Surprise credit: 0 for words the model already expected, up to 1 for very unexpected ones.
    /// `nil` (the user typed it; the model never proposed it) counts as fully surprising.
    public func credit(logProb: Float?) -> Float {
        guard let lp = logProb else { return 1 }
        let span = Self.likelyLogProb - Self.surprisingLogProb
        return min(1, max(0, (Self.likelyLogProb - lp) / span))
    }

    /// Multiplier on credit for very common words (see `CommonWords`) and stopwords inside phrases.
    public static let commonFactor: Float = 0.1
    /// Multiplier on credit for words the decoder was biased toward (self-reinforcement guard).
    public static let boostedFactor: Float = 0.25

    /// Candidates from the accepted words of a confirmed suggestion. An empty-text word is a
    /// break (an opaque URL/email was removed there). `boosted` holds normalized words
    /// (lowercased, trimmed) the decoder was biased toward; they earn `boostedFactor` credit.
    /// `names` holds words as written that are names (capitalized mid-sentence): never ordinary.
    public func candidates(words: [WordScore], context: [String], boosted: Set<String> = [],
                           names: Set<String> = []) -> [Candidate] {
        candidates(scored: words.map { (Self.trim($0.text), Optional($0.logProb)) }, context: context,
                   boosted: boosted, names: names)
    }

    /// Candidates from a word the user typed themselves. `isName`: it was written with a capital
    /// mid-sentence, so it is never ordinary.
    public func candidates(typed: String, context: [String], isName: Bool = false) -> [Candidate] {
        let word = Self.trim(typed)
        return candidates(scored: [(word, nil)], context: context, names: isName ? [word] : [])
    }

    func candidates(scored: [(String, Float?)], context: [String], boosted: Set<String> = [],
                    names: Set<String> = []) -> [Candidate] {
        // Split at breaks so words on either side of a removed URL/email never form a phrase.
        var segments: [[(String, Float?)]] = [[]]
        for item in scored {
            if item.0.isEmpty { segments.append([]) } else { segments[segments.count - 1].append(item) }
        }
        var out: [Candidate] = []
        for (n, seg) in segments.enumerated() where !seg.isEmpty {
            out += segmentCandidates(seg, context: n == 0 ? context : [], boosted: boosted, names: names)
        }
        return out
    }

    private func segmentCandidates(_ scored: [(String, Float?)], context: [String],
                                   boosted: Set<String>, names: Set<String>) -> [Candidate] {
        var out: [Candidate] = []
        let words = scored.map(\.0)
        func ctx(before i: Int) -> [String] { Array((context + words[0..<i]).suffix(2)) }
        /// Credit after the surprise curve, before damping.
        func base(_ i: Int) -> Float { credit(logProb: scored[i].1) }
        /// Credit after damping for common, stopword, and decoder-boosted words (names aren't common).
        func damped(_ i: Int) -> Float {
            var c = base(i)
            let lower = words[i].lowercased()
            if !isName(words[i]), Self.isCommon(lower) { c *= Self.commonFactor }
            if boosted.contains(lower) { c *= Self.boostedFactor }
            return c
        }

        func isName(_ w: String) -> Bool { names.contains(w) && !Self.enStopwords.contains(w.lowercased()) }

        for i in scored.indices where isDistinctive(words[i], isName: isName(words[i])) {
            if base(i) >= Self.minCredit { out.append(Candidate(text: words[i], credit: damped(i), context: ctx(before: i))) }
        }
        for size in 2...3 where scored.count >= size {
            for i in 0...(scored.count - size) {
                let range = i..<(i + size)
                guard range.allSatisfy({ isPlausibleToken(words[$0]) }),
                      range.contains(where: { isDistinctive(words[$0], isName: isName(words[$0])) }) else { continue }
                guard (range.map { base($0) }.max() ?? 0) >= Self.minCredit else { continue }
                let c = range.map { damped($0) }.max() ?? 0
                out.append(Candidate(text: range.map { words[$0] }.joined(separator: " "), credit: c,
                                     context: ctx(before: i)))
            }
        }
        return out
    }

    /// Common words and stopwords: ordinary vocabulary that earns reduced credit.
    static func isCommon(_ lowercased: String) -> Bool {
        // Chinese lists are simplified; traditional input is compared in simplified form.
        let zh = HanScript.simplified(lowercased)
        return enStopwords.contains(lowercased) || zhStopwords.contains(zh) || CommonWords.isCommon(lowercased)
            || CommonWords.isCommon(zh)
    }

    /// Learnable and not an ordinary English word (stopword, common, or frequent). A name (written
    /// with a capital mid-sentence) is never ordinary. Chinese words keep the plain `isLearnable`
    /// rule (their common words are only damped).
    func isDistinctive(_ word: String, isName: Bool = false) -> Bool {
        guard isLearnable(word) else { return false }
        return isName || WordText.containsCJK(word) || !CommonWords.isOrdinaryEnglish(word.lowercased())
    }

    /// A word that can be learned on its own: plausible, not a stopword, long enough.
    public func isLearnable(_ word: String) -> Bool {
        guard isPlausibleToken(word) else { return false }
        let lower = word.lowercased()
        if WordText.containsCJK(word) {
            return word.count >= 2 && !Self.zhStopwords.contains(HanScript.simplified(lower))
        }
        return word.count >= 3 && !Self.enStopwords.contains(lower)
    }

    /// Has letters, is not numeric, URL-like, or secret-looking.
    func isPlausibleToken(_ word: String) -> Bool {
        guard !word.isEmpty, word.contains(where: { $0.isLetter }) else { return false }
        if word.contains("://") || word.contains("@") || word.lowercased().hasPrefix("www.") { return false }
        return !Self.looksLikeSecret(word)
    }

    /// Heuristic for passwords, API keys, tokens, and ids. A token is secret-looking when it
    ///  - mixes letters and digits and is 6+ characters (e.g. "hunter42x", "sk9aF3kd");
    ///  - is 8+ characters with 3+ uppercase letters mixed with lowercase and flips case between
    ///    adjacent letters 4+ times (random-looking "aXkQ9pRt"; but "Hunch", "iPhone",
    ///    "JavaScript", "PostgreSQL" have few flips and stay learnable);
    ///  - is a 12+ character hex run, or a 12+ character base64-alphabet run containing a digit
    ///    or one of + / =.
    public static func looksLikeSecret(_ s: String) -> Bool {
        let chars = Array(s)
        let hasLetter = chars.contains { $0.isLetter }
        let hasDigit = chars.contains { $0.isNumber }
        if chars.count >= 6, hasLetter, hasDigit { return true }
        if chars.count >= 12, chars.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return true }
        if chars.count >= 12, chars.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=_-".contains($0)) }),
           hasDigit || chars.contains(where: { "+/=".contains($0) }) { return true }
        if chars.count >= 8 {
            let upper = chars.filter { $0.isUppercase }.count
            let lower = chars.filter { $0.isLowercase }.count
            if upper >= 3, lower >= 1 {
                var flips = 0
                for (a, b) in zip(chars, chars.dropFirst()) where a.isLetter && b.isLetter
                    && a.isUppercase != b.isUppercase { flips += 1 }
                if flips >= 4 { return true }
            }
        }
        return false
    }

    /// Context key (up to 2 trailing storable words, lowercased, space-joined), or nil.
    func contextKey(_ words: [String]) -> String? {
        var kept: [String] = []
        for w in words.suffix(2).reversed() {
            let t = Self.trim(w).lowercased()
            guard isPlausibleToken(t), t.count <= 30 else { break }
            kept.insert(t, at: 0)
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Stopwords (hand-written)

    public static let enStopwords: Set<String> = Set("""
    a about above after again against all also am an and any are aren't as at be because been before being \
    below between both but by can can't cannot could couldn't did didn't do does doesn't doing don't down \
    during each even few for from further get gets got had hadn't has hasn't have haven't having he he'd he'll \
    he's her here here's hers herself him himself his how how's however i i'd i'll i'm i've if in into is isn't \
    it it's its itself just let let's like make many may me might more most much must my myself no nor not now of \
    off on once one only onto or other ought our ours ourselves out over own really same say says shall shan't \
    she she'd she'll she's should shouldn't so some such take than that that's the their theirs them \
    themselves then there there's these they they'd they'll they're they've thing things this those through \
    thus to too under until up upon us use used very want was wasn't we we'd we'll we're we've well were \
    weren't what what's when when's where where's whether which while who who's whom whose why why's will \
    with won't would wouldn't yes yet you you'd you'll you're you've your yours yourself yourselves \
    http https www com org net html
    """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init))

    public static let zhStopwords: Set<String> = Set("""
    的 了 是 在 我 有 和 就 不 人 都 一 个 上 也 很 到 说 要 去 你 会 着 没 看 好 自己 这 那 他 她 它 \
    我们 你们 他们 她们 它们 这个 那个 这些 那些 什么 怎么 为什么 可以 没有 不是 就是 还是 但是 因为 所以 如果 \
    已经 一个 一些 一样 这样 那样 然后 或者 而且 虽然 可能 应该 知道 觉得 现在 时候 非常 比较 还有 以及
    """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init))
}
