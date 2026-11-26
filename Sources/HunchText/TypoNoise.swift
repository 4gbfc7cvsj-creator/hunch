// Realistic fast-typing slips for the autocorrect eval: puts typos into clean text the way a fast
// typist makes them, and scores a corrected text against the clean one. Pure and seeded.
// The mix of slips follows real fast-typing samples (docs/features/autocorrect-ambiguous-words.md).
import Foundation

/// One typing slip in a noisy text.
public struct TypoSlip: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        /// Two neighbouring letters typed in the wrong order, mostly the last two ("foudn").
        case swap
        /// A letter left out, often one of a double ("setings").
        case omit
        /// A letter typed twice ("stilll", "tthe").
        case double
        /// A neighbouring key hit as well ("riught").
        case extraKey
        /// A neighbouring key hit instead ("autocmreect").
        case wrongKey
        /// The space between two words left out ("canfix").
        case joinWords
        /// The space typed one key early or late ("ye spklease").
        case spaceMoved
        /// A space typed inside a word ("a s").
        case spaceInside
        /// A bottom-row letter hit instead of the space ("thebcat").
        case spaceAsLetter
        /// The apostrophe left out ("dont").
        case apostropheDropped
        /// Shift let go early on a symbol ("(off0").
        case shiftMissed
        /// A number-row key hit by a top-row letter ("s3with").
        case numberRow
        /// A punctuation key hit instead of a nearby letter or apostrophe ("co,e", "don;t").
        case punctAsLetter
        /// A real word typed for a commonly confused one ("their" for "there"). Never seeded by
        /// `TypoNoise`; only in hand-written eval sets.
        case confusedWord
        /// A short word left out ("I going"), a word typed twice or stray ("the the"), or a small
        /// grammar slip ("he go"). Never seeded; only in hand-written eval sets (whole-field rewrite).
        case missingWord, extraWord, grammar

        /// Kinds `TypoNoise` never seeds.
        public static let handWrittenOnly: Set<Kind> = [.confusedWord, .missingWord, .extraWord, .grammar]
    }

    public var kind: Kind
    /// The clean words it touches (indices into the clean text's whitespace-separated words).
    public var words: Range<Int>

    public init(kind: Kind, words: Range<Int>) {
        self.kind = kind
        self.words = words
    }

    /// Kinds that touch the space between words (case 2 of the fast-typing task).
    public var isSpacing: Bool { [.joinWords, .spaceMoved, .spaceInside, .spaceAsLetter].contains(kind) }
    /// Kinds that involve a symbol, digit or punctuation key (case 3).
    public var isSymbol: Bool { [.apostropheDropped, .shiftMissed, .numberRow, .punctAsLetter].contains(kind) }
}

/// A clean text with slips put in.
public struct NoisyText: Sendable, Equatable {
    public var clean: String
    public var typed: String
    public var slips: [TypoSlip]

    public init(clean: String, typed: String, slips: [TypoSlip]) {
        self.clean = clean
        self.typed = typed
        self.slips = slips
    }
}

/// Seeded generator (SplitMix64): the same seed gives the same slips on every machine.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct TypoNoise: Sendable {
    /// Chance that a word gets a slip (the samples had about one in four).
    public var rate: Double
    /// Rate multiplier for the word right after a slipped one (slips come in bursts).
    public var burst: Double
    /// Chance that a slipped word gets a second slip inside it ("typhign").
    public var second: Double
    public var weights: [TypoSlip.Kind: Double]

    public static let sampleWeights: [TypoSlip.Kind: Double] = [
        .swap: 5, .omit: 4, .double: 2.5, .extraKey: 2, .wrongKey: 2,
        .joinWords: 1.5, .spaceMoved: 1, .spaceInside: 1, .spaceAsLetter: 1,
        .apostropheDropped: 1, .shiftMissed: 1, .numberRow: 1, .punctAsLetter: 1,
    ]

    public init(rate: Double = 0.25, burst: Double = 1.6, second: Double = 0.15,
                weights: [TypoSlip.Kind: Double] = TypoNoise.sampleWeights) {
        self.rate = rate
        self.burst = burst
        self.second = second
        self.weights = weights
    }

    /// Puts slips into `clean`. Only plain Latin words are touched (no URLs, mentions, digits, CJK).
    public func apply(to clean: String, seed: UInt64) -> NoisyText {
        var rng = SeededGenerator(seed: seed)
        var tokens = Self.tokenize(clean)
        let words = tokens.map(\.word)
        var slips: [TypoSlip] = []
        var lastSlipped = -2
        // Token `i` is clean word `i - extra`: a space typed inside a word adds a token.
        var extra = 0
        var i = 0
        while i < tokens.count {
            let c = i - extra
            let p = min(0.9, rate * (lastSlipped == c - 1 ? burst : 1))
            guard Self.eligible(tokens[i].word), Double.random(in: 0..<1, using: &rng) < p else { i += 1; continue }
            let pairOK = i + 1 < tokens.count && tokens[i].gap == " " && Self.eligible(tokens[i + 1].word)
                && !tokens[i].word.contains(where: { ".,;:!?)\"".contains($0) })
            let kinds = weights.filter { $0.value > 0 && Self.applies($0.key, word: tokens[i].word, pairOK: pairOK) }
                .sorted { $0.key.rawValue < $1.key.rawValue }
            guard let kind = Self.pick(kinds, using: &rng),
                  Self.mutate(kind, at: i, tokens: &tokens, using: &rng) else { i += 1; continue }
            let pair = Self.pairKinds.contains(kind)
            slips.append(TypoSlip(kind: kind, words: c..<(c + (pair ? 2 : 1))))
            if kind == .spaceInside {
                extra += 1
                i += 2
            } else if pair {
                i += 2
            } else {
                // A second slip inside the same word.
                if Double.random(in: 0..<1, using: &rng) < second {
                    let inner = weights.filter { Self.innerKinds.contains($0.key) && $0.value > 0
                        && Self.applies($0.key, word: tokens[i].word, pairOK: false) }
                        .sorted { $0.key.rawValue < $1.key.rawValue }
                    let once = tokens[i].word
                    if let k2 = Self.pick(inner, using: &rng), Self.mutate(k2, at: i, tokens: &tokens, using: &rng) {
                        if tokens[i].word == words[c] {
                            tokens[i].word = once  // the second slip undid the first ("ab" → "ba" → "ab")
                        } else {
                            slips.append(TypoSlip(kind: k2, words: c..<(c + 1)))
                        }
                    }
                }
                i += 1
            }
            lastSlipped = c + (pair ? 1 : 0)
        }
        return NoisyText(clean: clean, typed: tokens.map { $0.word + $0.gap }.joined(), slips: slips)
    }

    // MARK: Tokens

    /// A word and the whitespace after it. Pair slips edit `gap` (and may empty the next word's start).
    struct Token { var word: String; var gap: String }

    static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var word = "", gap = ""
        for c in text {
            if c.isWhitespace {
                gap.append(c)
            } else {
                if !gap.isEmpty { out.append(Token(word: word, gap: gap)); word = ""; gap = "" }
                word.append(c)
            }
        }
        if !word.isEmpty || !gap.isEmpty { out.append(Token(word: word, gap: gap)) }
        return out
    }

    /// The clean text's words as the scorer counts them.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func eligible(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 1, letters.allSatisfy({ $0.isASCII }) else { return false }
        return !word.contains(where: { $0.isNumber || "/@#_=<>{}[]`\\|~*+&%$".contains($0) })
    }

    static let pairKinds: Set<TypoSlip.Kind> = [.joinWords, .spaceMoved, .spaceAsLetter]
    static let innerKinds: Set<TypoSlip.Kind> = [.swap, .omit, .double, .extraKey, .wrongKey]

    static func applies(_ kind: TypoSlip.Kind, word: String, pairOK: Bool) -> Bool {
        let letters = word.filter(\.isLetter).count
        switch kind {
        case .swap: return letters >= 2
        case .omit: return letters >= 3
        case .double, .extraKey, .wrongKey: return letters >= 2
        case .joinWords, .spaceMoved, .spaceAsLetter: return pairOK && letters >= 1
        case .spaceInside: return letters >= 2
        case .apostropheDropped: return word.contains("'") || word.contains("\u{2019}")
        case .shiftMissed: return word.contains(where: { shifted[$0] != nil })
        case .numberRow: return word.lowercased().contains(where: { numberKeys[$0] != nil })
        case .punctAsLetter:
            return word.contains("'") || word.lowercased().contains(where: { punctKeys[$0] != nil })
        case .confusedWord, .missingWord, .extraWord, .grammar: return false
        }
    }

    static func pick(_ kinds: [(key: TypoSlip.Kind, value: Double)], using rng: inout SeededGenerator) -> TypoSlip.Kind? {
        let total = kinds.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }
        var r = Double.random(in: 0..<total, using: &rng)
        for (k, w) in kinds {
            if r < w { return k }
            r -= w
        }
        return kinds.last?.key
    }

    // MARK: Slips

    /// Indices of the letters in `chars`.
    private static func letterIndices(_ chars: [Character]) -> [Int] { chars.indices.filter { chars[$0].isLetter } }

    static func mutate(_ kind: TypoSlip.Kind, at i: Int, tokens: inout [Token], using rng: inout SeededGenerator) -> Bool {
        var chars = Array(tokens[i].word)
        let letters = letterIndices(chars)
        func keepCase(_ c: Character, like o: Character) -> Character {
            o.isUppercase ? Character(c.uppercased()) : c
        }
        switch kind {
        case .swap:
            // Adjacent letter pairs that differ; the last pair most often.
            let pairs = letters.indices.dropLast().map { (letters[$0], letters[$0 + 1]) }
                .filter { $0.1 == $0.0 + 1 && chars[$0.0].lowercased() != chars[$0.1].lowercased() }
            guard !pairs.isEmpty else { return false }
            let pair = Double.random(in: 0..<1, using: &rng) < 0.6 ? pairs.last! : pairs.randomElement(using: &rng)!
            chars.swapAt(pair.0, pair.1)
        case .omit:
            let doubles = letters.filter { $0 > 0 && chars[$0 - 1].lowercased() == chars[$0].lowercased() }
            let at = (!doubles.isEmpty && Double.random(in: 0..<1, using: &rng) < 0.5)
                ? doubles.randomElement(using: &rng)! : letters.dropFirst().randomElement(using: &rng)!
            chars.remove(at: at)
        case .double:
            let at = letters.randomElement(using: &rng)!
            chars.insert(Character(chars[at].lowercased()), at: at + 1)
        case .extraKey, .wrongKey:
            let options = letters.filter { neighbours[Character(chars[$0].lowercased())] != nil }
            guard let at = options.randomElement(using: &rng),
                  let key = neighbours[Character(chars[at].lowercased())]?.randomElement(using: &rng) else { return false }
            if kind == .wrongKey {
                chars[at] = keepCase(key, like: chars[at])
            } else {
                chars.insert(key, at: Bool.random(using: &rng) ? at + 1 : at)
            }
        case .spaceInside:
            guard letters.count >= 2 else { return false }
            let cut = letters[Int.random(in: 1..<letters.count, using: &rng)]
            tokens[i].word = String(chars[..<cut])
            tokens.insert(Token(word: String(chars[cut...]), gap: tokens[i].gap), at: i + 1)
            tokens[i].gap = " "
            // The extra token is merged back into one clean word by the scorer's alignment.
            return true
        case .joinWords:
            tokens[i].gap = ""
            return true
        case .spaceAsLetter:
            tokens[i].gap = String("bnvcm".randomElement(using: &rng)!)
            return true
        case .spaceMoved:
            var next = Array(tokens[i + 1].word)
            if Bool.random(using: &rng), chars.count >= 2, chars.last!.isLetter {
                // One key early: "yes please" → "ye splease".
                next.insert(chars.removeLast(), at: 0)
            } else if next.count >= 2, next.first!.isLetter {
                // One key late: "yes please" → "yesp lease".
                chars.append(next.removeFirst())
            } else {
                return false
            }
            tokens[i + 1].word = String(next)
        case .apostropheDropped:
            chars.removeAll { $0 == "'" || $0 == "\u{2019}" }
        case .shiftMissed:
            let at = chars.indices.filter { shifted[chars[$0]] != nil }.randomElement(using: &rng)!
            chars[at] = shifted[chars[at]]!
        case .numberRow:
            let options = chars.indices.filter { numberKeys[Character(chars[$0].lowercased())] != nil }
            let at = options.randomElement(using: &rng)!
            let key = numberKeys[Character(chars[at].lowercased())]!.randomElement(using: &rng)!
            if Bool.random(using: &rng) { chars[at] = key } else { chars.insert(key, at: Bool.random(using: &rng) ? at + 1 : at) }
        case .punctAsLetter:
            if let a = chars.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }), Bool.random(using: &rng) {
                chars[a] = ";"
            } else {
                let options = chars.indices.filter { punctKeys[Character(chars[$0].lowercased())] != nil }
                guard let at = options.randomElement(using: &rng) else {
                    guard let a = chars.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) else { return false }
                    chars[a] = ";"
                    break
                }
                chars[at] = punctKeys[Character(chars[at].lowercased())]!.randomElement(using: &rng)!
            }
        case .confusedWord, .missingWord, .extraWord, .grammar:
            return false
        }
        tokens[i].word = String(chars)
        return true
    }

    static let neighbours: [Character: [Character]] = {
        let rows: [Character: String] = [
            "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh", "u": "yihj", "i": "uojk",
            "o": "ipkl", "p": "ol", "a": "qwsz", "s": "adwezx", "d": "sferxc", "f": "dgrtcv", "g": "fhtyvb",
            "h": "gjyubn", "j": "hkuinm", "k": "jliom", "l": "kop", "z": "asx", "x": "zcsd", "c": "xvdf",
            "v": "cbfg", "b": "vngh", "n": "bmhj", "m": "njk",
        ]
        return rows.mapValues { Array($0) }
    }()

    /// Shifted symbol → the key's own character when Shift is let go early.
    static let shifted: [Character: Character] = [
        ")": "0", "(": "9", "!": "1", "?": "/", ":": ";", "\"": "'", "@": "2", "&": "7", "%": "5",
    ]

    /// Top-row letters → the number keys right above them.
    static let numberKeys: [Character: [Character]] = [
        "q": ["1", "2"], "w": ["2", "3"], "e": ["3", "4"], "r": ["4", "5"], "t": ["5", "6"],
        "y": ["6", "7"], "u": ["7", "8"], "i": ["8", "9"], "o": ["9", "0"], "p": ["0", "-"],
    ]

    /// Letters next to a punctuation key → that key.
    static let punctKeys: [Character: [Character]] = [
        "m": [","], "k": [","], "l": [".", ";"], "p": [";"],
    ]
}

/// How a corrected text compares with the clean one.
public struct TypoScore: Sendable, Equatable {
    /// Per slip in `NoisyText.slips`: every clean word it touched is right in the output.
    public var fixed: [Bool]
    /// Clean words no slip touched that are wrong in the output (autocorrect broke them).
    public var damaged: Int
    /// Clean words no slip touched.
    public var untouched: Int
    /// Clean words wrong in the output, of `total`.
    public var wrong: Int
    public var total: Int
    public var exact: Bool

    /// Scores `output` against `noisy.clean`. A clean word is right when the word alignment matches
    /// it to an identical output word.
    public static func score(_ noisy: NoisyText, output: String) -> TypoScore {
        let clean = TypoNoise.words(noisy.clean)
        // A capital on the first word of a sentence is right (Auto-capitalization), though the corpus
        // text is lower case: it neither breaks a clean word nor hides a fixed slip.
        var starts = Set<Int>()
        for (i, w) in clean.enumerated() where i == 0 || ".!?".contains(clean[i - 1].last ?? " ") { starts.insert(i) }
        let right = alignedRight(clean, TypoNoise.words(output), sentenceStarts: starts)
        var touched = Set<Int>()
        for s in noisy.slips { touched.formUnion(s.words) }
        let fixed = noisy.slips.map { s in s.words.allSatisfy { $0 < right.count && right[$0] } }
        let untouched = clean.indices.filter { !touched.contains($0) }
        return TypoScore(fixed: fixed, damaged: untouched.filter { !right[$0] }.count, untouched: untouched.count,
                         wrong: right.filter { !$0 }.count, total: clean.count,
                         exact: output.split(whereSeparator: \.isWhitespace) == noisy.clean.split(whereSeparator: \.isWhitespace))
    }

    /// For each word of `a`, whether a longest common subsequence of the two word lists matches it
    /// to an equal word of `b` (as many words matched as possible).
    static func alignedRight(_ a: [String], _ b: [String], sentenceStarts: Set<Int> = []) -> [Bool] {
        func same(_ i: Int, _ j: Int) -> Bool {
            a[i] == b[j] || (sentenceStarts.contains(i) && a[i].prefix(1).uppercased() + a[i].dropFirst() == b[j])
        }
        let n = a.count, m = b.count
        var l = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    l[i][j] = same(i, j) ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
                }
            }
        }
        var right = [Bool](repeating: false, count: n)
        var i = 0, j = 0
        while i < n, j < m {
            if same(i, j), l[i][j] == l[i + 1][j + 1] + 1 {
                right[i] = true; i += 1; j += 1
            } else if l[i + 1][j] >= l[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return right
    }
}
