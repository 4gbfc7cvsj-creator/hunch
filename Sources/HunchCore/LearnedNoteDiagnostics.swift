import Foundation

/// What the diagnostic console shows about gated learned-word notes for one request. Filled by the app
/// only while the console is open; the engine adds what the framer did with them. Observation only.
public struct LearnedNoteDiagnostics: Sendable, Equatable {
    public struct Pick: Sendable, Equatable {
        public var word: String
        /// Why the gate let it through: `lead-in "tell"`, `topic {contract, renewal}`, plus the mid-word prefix.
        public var reason: String
        public init(word: String, reason: String) {
            self.word = word
            self.reason = reason
        }
    }
    /// The words that went into the prompt, in order.
    public var picks: [Pick]
    /// Every active learned word for this app or category (to label a learned word the notes didn't carry).
    public var learnedHere: [String]
    /// Set by the engine: the framer names learned words (instruct); the learned-word bias is then mid-word only.
    public var framerListsVocabulary: Bool?
    public init(picks: [Pick] = [], learnedHere: [String] = [], framerListsVocabulary: Bool? = nil) {
        self.picks = picks
        self.learnedHere = learnedHere
        self.framerListsVocabulary = framerListsVocabulary
    }
}

extension DiagnosticSections {
    /// Whether `word` appears as a whole word (any case) in `text`.
    static func mentions(_ text: String?, _ word: String) -> Bool {
        guard let text, !word.isEmpty else { return false }
        let w = NSRegularExpression.escapedPattern(for: word.trimmingCharacters(in: .whitespaces))
        return text.range(of: "(?<![\\p{L}\\p{N}'’])" + w + "(?![\\p{L}\\p{N}])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Where else the model could have got `word`: "on screen", "in the writing samples", both, or nil.
    static func elsewhere(_ word: String, input: PromptInput) -> String? {
        var places: [String] = []
        if mentions(input.screenContext, word) { places.append("on screen") }
        if input.styleExamples.contains(where: { mentions($0, word) }) { places.append("in the writing samples") }
        return places.isEmpty ? nil : places.joined(separator: " and ")
    }

    /// The gated-notes lines for the "Learned words and phrases" section.
    public static func noteItems(_ notes: LearnedNoteDiagnostics, input: PromptInput) -> [DiagnosticSection.Item] {
        if notes.framerListsVocabulary == false {
            return [.init("Learned-word notes", "not used: this model's framing doesn't name learned words (full learned-word bias instead)")]
        }
        guard !notes.picks.isEmpty else { return [.init("Learned-word notes (in the prompt)", "none")] }
        let lines = notes.picks.map { p in
            "\(p.word) ← \(p.reason); " + (elsewhere(p.word, input: input).map { "also \($0)" } ?? "not on screen or in the samples")
        }
        return [.init("Learned-word notes (in the prompt)", lines.joined(separator: "\n"))]
    }

    /// Learned words the shown suggestion adds (whole words that complete or follow the typed text), each
    /// labelled: from the notes, also on screen/samples, or not gated. Nil when it adds none.
    public static func learnedInSuggestion(before: String, shown: String, input: PromptInput,
                                           notes: LearnedNoteDiagnostics?, bias: LearnedBias) -> String? {
        let picked = Set((notes?.picks ?? []).map { $0.word.lowercased() })
        var words = (notes?.learnedHere ?? []) + (notes?.picks ?? []).map(\.word)
            + bias.entries.map { $0.text.trimmingCharacters(in: .whitespaces) }
        var seen = Set<String>()
        words = words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let full = before + shown
        var out: [String] = []
        for w in words {
            let pattern = "(?<![\\p{L}\\p{N}'’])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let hit = re.matches(in: full, range: NSRange(full.startIndex..., in: full)).contains {
                (Range($0.range, in: full).map { full.distance(from: full.startIndex, to: $0.upperBound) } ?? 0) > before.count
            }
            guard hit else { continue }
            let label: String
            if picked.contains(w.lowercased()) {
                label = elsewhere(w, input: input).map { "also \($0)" } ?? "from notes"
            } else {
                label = "not gated" + (elsewhere(w, input: input).map { " (\($0))" } ?? "")
            }
            out.append("\(w): \(label)")
        }
        return out.isEmpty ? nil : out.joined(separator: "; ")
    }

    /// The learned word a dropped suggestion finished wrongly ("microsp" + "eak" while "microspikes" is in
    /// play), as a console note; nil when that isn't what happened.
    public static func mangledLearnedWord(before: String, generated: String, learned: [String]) -> String? {
        let partial = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
        let chunk = String(generated.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard !partial.isEmpty, !chunk.isEmpty else { return nil }
        let finished = (partial + chunk).lowercased()
        guard let word = learned.first(where: {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return l.count > partial.count && l.hasPrefix(partial.lowercased()) && l != finished
        }) else { return nil }
        return "dropped \"\(partial)\" + \"\(chunk)\" = \"\(partial + chunk)\": not \(word.trimmingCharacters(in: .whitespaces)) and not a dictionary word"
    }
}
