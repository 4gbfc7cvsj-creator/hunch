import Foundation
import HunchCore

/// One continuation of the text at the caret, drawn from the user's own sentences.
public struct PhraseContinuation: Sendable, Equatable {
    /// What would follow the typed text directly: " tomorrow at 5" after "see you", "tomorrow"
    /// after "see you ", "orrow" after "see you tom", "見面" after "明天".
    public var text: String
    /// 0...1: the share of matching places that continue this way, times the strength of the
    /// matched context (longer = stronger), scaled down when only one sentence supports it.
    public var weight: Float
    /// Distinct sentences that continue this way.
    public var support: Int
    /// Matched context length in word units (a CJK character or punctuation mark counts half).
    public var context: Float
}

/// Personal phrase model ("learned phrases", experimental): an n-gram index over the user's saved
/// sentences. Given the text before the caret, it finds the places in those sentences whose
/// preceding words match the end of that text (longest match per place, up to `maxContext` units)
/// and returns how they continue.
///
/// Units: Latin-script words (lowercased for matching), single CJK characters (matched in the
/// simplified script, so traditional and simplified text match each other), and punctuation
/// marks. Each sentence starts with a sentence-start unit, so "Thanks for" at the start of a
/// sentence matches the starts of saved sentences.
///
/// Weighting:
/// - Back-off: a place matched on 2 units counts 0.4, 3 units 0.7, 4 or more 1.0. CJK characters
///   and punctuation count half a unit; fewer than 2 units never match.
/// - A continuation's weight is its share of the matched places (weighted by back-off) times the
///   best back-off among the places that support it.
/// - One-off sentences don't dominate: a continuation needs two distinct sentences for full
///   weight; one supported by a single sentence is scaled by `singleScale` and cut to 3 units.
///
/// Built once per change of the saved sentences; a lookup scans the places that share the last
/// context unit (a few hundred at most) and is well under a millisecond.
public struct PhraseModel: Sendable {
    public static let maxContext = 6
    public static let maxContinuation = 6
    public static let singleScale: Float = 0.35
    public static let minWeight: Float = 0.12
    public static let maxResults = 6

    enum Kind: UInt8, Sendable { case start, word, cjk, punct }

    struct Unit: Sendable, Equatable {
        var key: String
        var surface: String
        /// Whitespace came before it in the sentence.
        var space: Bool
        var kind: Kind
        var size: Float { kind == .word || kind == .start ? 1 : 0.5 }
    }

    private let sentences: [[Unit]]
    /// Unit key → (sentence, index of the unit) for every unit that has something after it.
    private let index: [String: [(sentence: Int32, unit: Int32)]]

    public var sentenceCount: Int { sentences.count }

    public init(sentences texts: [String]) {
        var seen = Set<String>()
        var sentences: [[Unit]] = []
        var index: [String: [(Int32, Int32)]] = [:]
        for text in texts {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            let units = [Unit(key: "\u{2}", surface: "", space: false, kind: .start)] + Self.units(t)
            guard units.count > 2 else { continue }
            let s = Int32(sentences.count)
            sentences.append(units)
            for u in 0..<(units.count - 1) { index[units[u].key, default: []].append((s, Int32(u))) }
        }
        self.sentences = sentences
        self.index = index.mapValues { $0.map { (sentence: $0.0, unit: $0.1) } }
    }

    public var isEmpty: Bool { sentences.isEmpty }

    // MARK: Lookup

    /// Likely continuations of `before`, strongest first (at most `maxResults`).
    public func continuations(after before: String) -> [PhraseContinuation] {
        guard !sentences.isEmpty else { return [] }
        let (context, partial) = Self.lookupContext(before)
        guard let last = context.last, let places = index[last.key] else { return [] }
        let partialKey = partial.map { Self.normalize($0) }

        // Every place whose preceding units match the end of the context.
        struct Match { var sentence: Int; var next: Int; var context: Float; var backoff: Float }
        var matches: [Match] = []
        for place in places {
            let units = sentences[Int(place.sentence)]
            let next = Int(place.unit) + 1
            guard next < units.count else { continue }
            if let partialKey {
                // Mid-word: the next unit must be a word that starts with the typed part.
                guard units[next].kind == .word, units[next].key.hasPrefix(partialKey) else { continue }
            }
            var size: Float = 0
            var count = 0
            var i = Int(place.unit), j = context.count - 1
            while i >= 0, j >= 0, count < Self.maxContext, units[i].key == context[j].key {
                size += units[i].size
                count += 1
                if units[i].kind == .start { break }
                i -= 1
                j -= 1
            }
            if let partialKey { size += units[next].key == partialKey ? 1 : 0.5 }
            guard size >= 2 else { continue }
            matches.append(Match(sentence: Int(place.sentence), next: next, context: size,
                                 backoff: Self.backoff(size)))
        }
        guard !matches.isEmpty else { return [] }
        let total = matches.reduce(Float(0)) { $0 + $1.backoff }

        // A small trie over the continuations, by unit key.
        final class Node {
            var children: [String: Node] = [:]
            var order: [String] = []
            var surface: [Unit] = []
            var mass: Float = 0
            var best: Float = 0
            var bestContext: Float = 0
            var sentences = Set<Int>()
        }
        let root = Node()
        for m in matches {
            let units = sentences[m.sentence]
            var node = root
            var path: [Unit] = []
            for k in m.next..<min(units.count, m.next + Self.maxContinuation) {
                path.append(units[k])
                let key = units[k].key
                let child: Node
                if let c = node.children[key] { child = c } else {
                    child = Node()
                    child.surface = path
                    node.children[key] = child
                    node.order.append(key)
                }
                child.mass += m.backoff
                if m.backoff > child.best { child.best = m.backoff; child.bestContext = m.context }
                child.sentences.insert(m.sentence)
                node = child
                if units[k].kind == .punct, Self.sentenceEnds.contains(units[k].surface) { break }
            }
        }

        // Emit the continuations that two sentences share (each shared prefix and the longest shared
        // extension); a first word only one sentence continues with is emitted (at most 3 units,
        // scaled down).
        var out: [PhraseContinuation] = []
        func visit(_ node: Node) {
            for key in node.order {
                guard let child = node.children[key] else { continue }
                let support = child.sentences.count
                if support >= 2 {
                    let sharedBelow = child.children.values.contains { $0.sentences.count >= 2 }
                    // The shared prefix itself too: the decoder boosts it at its own (higher) share
                    // and pays nothing extra for the longer, less common extension.
                    emit(child, scale: 1)
                    if sharedBelow { visit(child) }
                } else if node === root {
                    // Only one sentence continues this way at all: keep it short.
                    var n = child
                    var depth = 1
                    while depth < 3, let k = n.order.first, let c = n.children[k] { n = c; depth += 1 }
                    emit(n, scale: Self.singleScale, share: child)
                }
            }
        }
        func emit(_ node: Node, scale: Float, share: Node? = nil) {
            let s = share ?? node
            let weight = min(1, s.mass / total) * s.best * scale
            guard weight >= Self.minWeight else { return }
            out.append(PhraseContinuation(text: "", weight: weight, support: s.sentences.count,
                                          context: s.bestContext))
            out[out.count - 1].text = Self.render(node.surface, before: before, partial: partial)
        }
        visit(root)
        out.removeAll { $0.text.isEmpty }
        // Strongest first; on a tie the longer phrase (its shorter prefix adds nothing in the decoder).
        out.sort {
            $0.weight != $1.weight ? $0.weight > $1.weight
                : $0.text.count != $1.text.count ? $0.text.count > $1.text.count : $0.text < $1.text
        }
        // Same text from different branches (casing): keep the strongest.
        var texts = Set<String>()
        out = out.filter { texts.insert($0.text).inserted }
        if HanScript.usesTraditional(before) {
            for i in out.indices { out[i].text = HanScript.traditional(out[i].text) }
        } else if HanScript.usesSimplified(before) {
            for i in out.indices { out[i].text = HanScript.simplified(out[i].text) }
        }
        return Array(out.prefix(Self.maxResults))
    }

    static func backoff(_ size: Float) -> Float {
        if size >= 4 { return 1 }
        if size >= 3 { return 0.7 + 0.3 * (size - 3) }
        return 0.4 + 0.3 * (size - 2)
    }

    /// The continuation as text to append at the caret.
    static func render(_ units: [Unit], before: String, partial: String?) -> String {
        var out = ""
        for (i, u) in units.enumerated() {
            if i == 0 {
                if let partial {
                    // Finish the typed word; the case of what was typed stays.
                    guard u.surface.count >= partial.count else { return "" }
                    out += u.surface.dropFirst(partial.count)
                    continue
                }
                let endsSpace = before.last?.isWhitespace ?? true
                if u.space, !endsSpace { out += " " }
            } else if u.space {
                out += " "
            }
            out += u.surface
        }
        return out
    }

    // MARK: Units

    static let sentenceEnds: Set<String> = [".", "!", "?", "。", "！", "？", "…"]

    static func normalize(_ s: String) -> String { HanScript.simplified(s.lowercased()) }

    /// Units of a sentence (no sentence-start unit).
    static func units(_ text: String) -> [Unit] {
        let chars = Array(text)
        // Simplify the whole text once; per-character alignment holds when the length is unchanged.
        let simple = Array(HanScript.simplified(text))
        let aligned = simple.count == chars.count
        var out: [Unit] = []
        var i = 0
        var space = false
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { space = true; i += 1; continue }
            if WordText.isCJK(c) {
                let key = aligned ? String(simple[i]) : HanScript.simplified(String(c))
                out.append(Unit(key: key, surface: String(c), space: space, kind: .cjk))
                i += 1
            } else if WordText.isWordChar(c) {
                var j = i + 1
                while j < chars.count {
                    let d = chars[j]
                    if WordText.isWordChar(d), !WordText.isCJK(d) {
                        j += 1
                    } else if d == "'" || d == "’" || d == "-", j + 1 < chars.count,
                              WordText.isWordChar(chars[j + 1]), !WordText.isCJK(chars[j + 1]) {
                        j += 1
                    } else {
                        break
                    }
                }
                let word = String(chars[i..<j])
                out.append(Unit(key: word.lowercased().replacingOccurrences(of: "’", with: "'"), surface: word,
                                space: space, kind: .word))
                i = j
            } else {
                let p = String(c)
                let key = p == "’" ? "'" : p
                out.append(Unit(key: key, surface: p, space: space, kind: .punct))
                i += 1
            }
            space = false
        }
        return out
    }

    static let boundaries: Set<Character> = [".", "!", "?", "。", "！", "？", "\n", "…"]

    /// The units of the current sentence before the caret (with the sentence-start unit when the
    /// sentence start is in view) and the partly typed word at the caret, if any. A word that
    /// ends at the caret counts as partly typed: its continuations must start with it.
    static func lookupContext(_ before: String) -> (context: [Unit], partial: String?) {
        let tail = Array(before.suffix(240))
        var start = tail.count
        while start > 0, !boundaries.contains(tail[start - 1]) { start -= 1 }
        // A terminator right before the caret ends the sentence: the next one starts fresh.
        let sentence = String(tail[start...])
        var units = units(sentence)
        let atStart = start > 0 || before.count <= tail.count
        if atStart { units.insert(Unit(key: "\u{2}", surface: "", space: false, kind: .start), at: 0) }
        var partial: String?
        if let last = units.last, last.kind == .word, let c = before.last, WordText.isWordChar(c), !WordText.isCJK(c) {
            partial = last.surface
            units.removeLast()
        }
        return (units, partial)
    }
}
