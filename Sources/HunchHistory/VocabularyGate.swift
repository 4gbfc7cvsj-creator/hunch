import Foundation

/// Picks the few learned words worth naming to an instruct model right now, as notes in the prompt
/// (the 2026-11-19 study found an always-on list makes the model use the words where they don't fit).
/// A word passes when either
/// - **lead-in**: the two words before the caret, or the last one when it isn't a stopword, are a
///   context the word was learned after ("tell" → Emma, "sync with" → Riley; not "in" → Lisbon), or
/// - **topic**: the writer's own past sentences with the word share at least `minOverlap` content
///   words with the screen near the field or the sentence being typed.
/// Mid-word, a word that doesn't extend the typed letters is left out. Pure: the caller supplies
/// entries already filtered to this app or category, and the sentences from the same place.
public enum VocabularyGate {
    public struct Candidate: Sendable {
        public var text: String
        public var weight: Float
        /// Learned lead-in contexts ("tell", "sync with"), as `VocabEntry.contexts` keys, with credit.
        public var contexts: [String: Float]
        public init(text: String, weight: Float, contexts: [String: Float]) {
            self.text = text
            self.weight = weight
            self.contexts = contexts
        }
    }

    public struct Pick: Sendable, Equatable {
        public var text: String
        public var leadIn: Bool
        public var overlap: Int
        /// The matched lead-in context, the shared topic words, and the typed letters it extends (diagnostics).
        public var leadInContext: String? = nil
        public var sharedWords: [String] = []
        public var midWordPrefix: String? = nil

        /// For the diagnostic console: `lead-in "tell"`, `topic {contract, renewal}`, `mid-word "mi"`.
        public var reason: String {
            var parts: [String] = []
            if let c = leadInContext { parts.append("lead-in \"\(c)\"") }
            if !sharedWords.isEmpty {
                parts.append("topic {\(sharedWords.joined(separator: ", "))}")
            }
            if let p = midWordPrefix { parts.append("mid-word \"\(p)\"") }
            return parts.joined(separator: " + ")
        }
    }

    /// Screen words nearest the field that count for the topic match.
    public static let screenWords = 80

    public static func select(_ candidates: [Candidate], sentences: [String], before: String, screen: String?,
                              limit: Int = 4, minOverlap: Int = 2) -> [Pick] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        let tail = String(before.suffix(300))
        let toks = WordText.tokens(in: tail).filter { !$0.opaque }
        let chars = Array(tail)
        let midWord = (chars.last.map(WordText.isWordChar) ?? false) && toks.last?.end == chars.count
        let partial = midWord ? (toks.last?.text.lowercased() ?? "") : ""
        let prior = midWord ? Array(toks.dropLast()) : toks
        let lead = prior.suffix(2).map { $0.text.lowercased() }
        var keys: Set<String> = []
        if lead.count == 2 { keys.insert(lead.joined(separator: " ")) }
        // A one-word lead-in counts only when it says something ("tell", "grab"); "in" or "the" alone
        // precede too many words.
        if let last = lead.last, !VocabularyScorer.enStopwords.contains(last) { keys.insert(last) }

        // The clue: the sentence being typed plus the screen lines nearest the field.
        let sentence = currentSentence(before)
        var clue = StyleText.contentWords(sentence)
        if let screen, !screen.isEmpty { clue.formUnion(StyleText.contentWords(StyleText.lastWords(screen, screenWords))) }

        var picks: [(Pick, Float)] = []
        for c in candidates {
            let lower = VocabularyModel.key(c.text)
            guard !lower.isEmpty else { continue }
            if midWord, !(lower.hasPrefix(partial) && lower != partial) { continue }
            let leadInContext = c.contexts.filter { keys.contains($0.key) && $0.value > 0 }
                .map(\.key).max { $0.count < $1.count }
            let leadIn = leadInContext != nil
            var overlap = 0
            var shared: [String] = []
            if !clue.isEmpty {
                let own = StyleText.contentWords(c.text)
                let pattern = try? NSRegularExpression(pattern: "(?<![\\w'])" + NSRegularExpression.escapedPattern(for: lower) + "(?![\\w'])",
                                                       options: [.caseInsensitive])
                var words = Set<String>()
                for s in sentences where pattern?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    words.formUnion(StyleText.contentWords(s))
                }
                shared = words.subtracting(own).intersection(clue).sorted()
                overlap = shared.count
            }
            guard leadIn || overlap >= minOverlap else { continue }
            picks.append((Pick(text: c.text, leadIn: leadIn, overlap: overlap, leadInContext: leadInContext,
                               sharedWords: overlap >= minOverlap ? shared : [], midWordPrefix: midWord ? partial : nil), c.weight))
        }
        picks.sort { a, b in
            if a.0.leadIn != b.0.leadIn { return a.0.leadIn }
            if a.0.overlap != b.0.overlap { return a.0.overlap > b.0.overlap }
            return a.1 > b.1
        }
        return picks.prefix(limit).map(\.0)
    }

    /// The text after the last sentence end (or line break) before the caret.
    static func currentSentence(_ before: String) -> String {
        let tail = String(before.suffix(400))
        guard let i = tail.lastIndex(where: { ".!?。！？\n".contains($0) }) else { return tail }
        return String(tail[tail.index(after: i)...])
    }
}
