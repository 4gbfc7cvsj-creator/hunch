import Foundation

// Suggested replies: in an empty field, a bubble above the caret offers up to three ways to answer
// the message on screen. The writing model writes them in one go, one per line; Tab moves the
// highlight, Return or a click inserts the highlighted one.

/// A suggested-replies job on the write path (`WriteRequest.replies`): the writers frame it with the
/// replies prompt instead of a draft prompt and give back the model's text as is.
public struct ReplyRequest: Sendable, Equatable {
    /// Words per reply, from the Length setting (`LengthPreset`).
    public var minWords: Int
    public var maxWords: Int
    /// Replies the user sent to messages like this one before (learned replies), best first: the
    /// prompt names them so the model offers them when they still fit.
    public var learned: [String] = []
    public init(minWords: Int, maxWords: Int) {
        self.minWords = minWords
        self.maxWords = max(minWords, maxWords)
    }

    public init(length: LengthPreset) {
        self.init(minWords: length.minWords, maxWords: length.maxWords)
    }

    /// Most replies offered.
    public static let maxReplies = 3
    /// What the model writes when there is nothing to reply to.
    public static let noneMarker = "NONE"
    /// Tokens a reply set may take: three replies of the longest length, with numbering, or CJK text.
    public var maxTokens: Int { min(400, 48 + maxWords * 3 * 4) }
}

/// Reads the model's reply list: one reply per line, numbered or bulleted or not. Quotes around a
/// reply, a heading line ("Replies:") and a marker for "nothing to reply to" are dropped.
public enum SuggestedReplies {
    /// Learned replies first (at most `learnedSlots`, so the model's own answers still get a place),
    /// then the model's, without repeats, at most `max`.
    public static func merge(learned: [String], model: [String], learnedSlots: Int = 2,
                             max: Int = ReplyRequest.maxReplies) -> [String] {
        func key(_ s: String) -> String {
            var t = s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            while let last = t.last, ".!,".contains(last) { t.removeLast() }
            return t
        }
        var out: [String] = []
        for r in learned.prefix(learnedSlots) + model where !out.contains(where: { key($0) == key(r) }) {
            out.append(r)
            if out.count == max { break }
        }
        return out
    }

    public static func parse(_ raw: String, max: Int = ReplyRequest.maxReplies) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            guard out.count < max, let reply = cleanLine(line) else { continue }
            let key = reply.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(reply)
        }
        return out
    }

    /// Whether two screen reads show the same conversation: the words of their newest part mostly
    /// match. Text recognition misreads a few words differently on each read, so an exact compare
    /// would see a change every time.
    public static func sameScreen(_ a: String, _ b: String?, tail: Int = 600, threshold: Double = 0.75) -> Bool {
        guard let b else { return false }
        return screenSimilarity(a, b, tail: tail) >= threshold
    }

    /// How much the newest parts of two screen reads share their words (0–1; both empty: 1).
    public static func screenSimilarity(_ a: String, _ b: String, tail: Int = 600) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(String(s.suffix(tail)).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let x = words(a), y = words(b)
        if x.isEmpty && y.isEmpty { return 1 }
        let union = x.union(y).count
        return union > 0 ? Double(x.intersection(y).count) / Double(union) : 0
    }

    /// One line as a reply, or nil for a blank line, a heading, a fence or the "none" marker.
    static func cleanLine(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("```") { return nil }
        text = text.replacingOccurrences(of: "**", with: "")
        text = stripListMarker(text)
        text = stripQuotes(text.trimmingCharacters(in: .whitespaces))
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: ".:!。：").union(.whitespaces))
        if bare.uppercased() == ReplyRequest.noneMarker || bare.lowercased() == "none" { return nil }
        // "Replies:", "Here are three replies:", "回覆：": a heading, not a reply.
        if text.hasSuffix(":") || text.hasSuffix("：") { return nil }
        return text
    }

    /// "1. ", "1) ", "(1) ", "- ", "* ", "• ", "１．" at the start of a line.
    static func stripListMarker(_ text: String) -> String {
        var s = Substring(text)
        if let first = s.first, "-*•·".contains(first) {
            s = s.dropFirst()
            return String(s).trimmingCharacters(in: .whitespaces)
        }
        var probe = s
        let open = probe.first == "("
        if open { probe = probe.dropFirst() }
        let digits = probe.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return text }
        probe = probe.dropFirst(digits.count)
        guard let mark = probe.first, ".)．、:".contains(mark) || (open && mark == ")") else { return text }
        probe = probe.dropFirst()
        if open, probe.first == ")" { probe = probe.dropFirst() }
        return String(probe).trimmingCharacters(in: .whitespaces)
    }

    static func stripQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』"), ("'", "'")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

/// The bubble's state: the replies and which one Tab has highlighted (none until the first Tab, so
/// Return keeps its meaning until the user picks).
public struct ReplyPicker: Sendable, Equatable {
    public private(set) var replies: [String]
    public private(set) var highlighted: Int?

    public init(replies: [String]) {
        self.replies = replies
        highlighted = nil
    }

    /// Tab: the first reply, then the next, wrapping around.
    public mutating func next() {
        guard !replies.isEmpty else { return }
        highlighted = highlighted.map { ($0 + 1) % replies.count } ?? 0
    }

    /// An arrow key: the next or previous reply, stopping at the ends (only once one is highlighted).
    public mutating func step(forward: Bool) {
        guard let h = highlighted, !replies.isEmpty else { return }
        highlighted = min(max(h + (forward ? 1 : -1), 0), replies.count - 1)
    }

    /// The reply Return inserts, nil while none is highlighted.
    public var chosen: String? { highlighted.map { replies[$0] } }
}

/// When suggested replies may be asked for in a field: everything that must hold besides the pause.
public enum SuggestedRepliesGate {
    public static func mayOffer(featureOn: Bool, suggestionsOn: Bool, context: TextContext, policy: AppPolicy) -> Bool {
        guard featureOn, suggestionsOn, policy.enabled, policy.suggestedRepliesAllowed, !policy.secureExcluded,
              policy.screenContextAllowed else {
            return false
        }
        // A shell prompt, a selection or an input method's marked text: not a reply.
        guard context.metadata.surface != .shell, context.selectionLength == 0, !context.hasMarkedText else {
            return false
        }
        return isEmpty(context)
    }

    /// Why replies may not be offered (`mayOffer` is false), for perf.log: never the field's text,
    /// only which gate, and for a field that looks empty but holds characters, their code points
    /// when none is a letter or digit (an editor's invisible placeholder).
    public static func whyNot(featureOn: Bool, suggestionsOn: Bool, context: TextContext, policy: AppPolicy) -> String {
        if !featureOn { return "feature off" }
        if !suggestionsOn { return "suggestions off here" }
        if !policy.enabled { return "app off" }
        if !policy.suggestedRepliesAllowed { return "replies off for this app" }
        if policy.secureExcluded { return "secure field" }
        if !policy.screenContextAllowed { return "screen context not allowed here" }
        if context.metadata.surface == .shell { return "shell prompt" }
        if context.selectionLength > 0 { return "selection" }
        if context.hasMarkedText { return "marked text" }
        let text = context.before + context.after
        if text.contains(where: { $0.isLetter || $0.isNumber }) {
            let placeholder = context.metadata.placeholder == nil ? "no placeholder" : "placeholder differs"
            let label = context.metadata.label == nil ? "no label" : "label differs"
            return "field has text (\(text.count) characters, \(placeholder), \(label))"
        }
        let codes = text.unicodeScalars.prefix(8).map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        return "field holds \(text.unicodeScalars.count) non-letter characters: \(codes)"
    }

    /// Nothing typed (`TextContext.looksEmpty`: invisible characters, or the placeholder or label a
    /// web editor reports as its value).
    public static func isEmpty(_ context: TextContext) -> Bool { context.looksEmpty }
}

/// One token the writer chose for a reply list: its bytes, its log-probability, and the
/// log-probability the model gave to ending its turn instead at that step.
public struct ReplyStep: Sendable, Equatable {
    public var bytes: [UInt8]
    public var logProb: Float
    public var stopLogProb: Float
    public init(bytes: [UInt8], logProb: Float, stopLogProb: Float) {
        self.bytes = bytes
        self.logProb = logProb
        self.stopLogProb = stopLogProb
    }
}

/// How sure the model was of one reply: `confidence` is its words' average token probability
/// (geometric mean, 0–1), `stopChance` the chance it gave to ending its answer right before this
/// reply instead of writing it (nil for the first). A reply the model nearly didn't write, or wrote
/// unsurely, is a candidate to drop.
public struct ReplyScore: Sendable, Equatable {
    public var reply: String
    public var confidence: Double
    public var stopChance: Double?
    public init(reply: String, confidence: Double, stopChance: Double?) {
        self.reply = reply
        self.confidence = confidence
        self.stopChance = stopChance
    }
}

public enum ReplyScoring {
    /// A last (third) reply the model nearly didn't write: it gave at least this chance to ending
    /// its answer right before it.
    public static let dropStopChance = 0.2
    /// …or it was much less sure of it than of its first reply (its confidence below this share
    /// of the first's).
    public static let dropConfidenceShare = 0.55
    /// Never fewer than this many replies are kept by the drop.
    public static let keepAtLeast = 2

    /// The replies to show: `replies` minus a weak last one (see `dropStopChance`,
    /// `dropConfidenceShare`), and the score of the one dropped, if any. Without scores (an
    /// endpoint), everything is kept.
    public static func keep(_ replies: [String], scores: [ReplyScore]) -> (replies: [String], dropped: ReplyScore?) {
        guard replies.count > keepAtLeast, let last = replies.last,
              let score = scores.first(where: { $0.reply == last }),
              let first = scores.first(where: { $0.reply == replies[0] }) else { return (replies, nil) }
        let unsure = (score.stopChance ?? 0) >= dropStopChance
            || score.confidence < dropConfidenceShare * first.confidence
        return unsure ? (Array(replies.dropLast()), score) : (replies, nil)
    }

    /// "confidence 82%, 4% chance it stopped before this one", for the console and the eval.
    public static func describe(_ score: ReplyScore) -> String {
        let confidence = "confidence \(Int((score.confidence * 100).rounded()))%"
        guard let stop = score.stopChance else { return confidence }
        return confidence + ", \(Int((stop * 100).rounded()))% chance it stopped before this one"
    }

    /// The replies `SuggestedReplies.parse` would read from these steps, each with its score.
    public static func score(_ steps: [ReplyStep], max: Int = ReplyRequest.maxReplies) -> [ReplyScore] {
        struct Line { var bytes: [UInt8] = []; var logProbs: [Float] = []; var stopBefore: Float? }
        var lines: [Line] = [Line()]
        let newline = UInt8(ascii: "\n")
        for step in steps {
            guard let cut = step.bytes.firstIndex(of: newline) else {
                lines[lines.count - 1].bytes += step.bytes
                lines[lines.count - 1].logProbs.append(step.logProb)
                continue
            }
            // The token ends the line: what comes before the newline is the line's last piece, and
            // this step is where the model chose to go on rather than stop.
            let head = step.bytes[..<cut]
            if !head.isEmpty {
                lines[lines.count - 1].bytes += head
                lines[lines.count - 1].logProbs.append(step.logProb)
            }
            var next = Line()
            next.stopBefore = step.stopLogProb
            let tail = step.bytes[step.bytes.index(after: cut)...].filter { $0 != newline }
            if !tail.isEmpty {
                next.bytes = Array(tail)
                next.logProbs = [step.logProb]
            }
            lines.append(next)
        }
        var out: [ReplyScore] = []
        var seen = Set<String>()
        var sawReply = false
        for line in lines {
            guard out.count < max, let reply = SuggestedReplies.cleanLine(String(decoding: line.bytes, as: UTF8.self)),
                  seen.insert(reply.lowercased()).inserted else { continue }
            let mean = line.logProbs.isEmpty ? 0 : line.logProbs.reduce(0, +) / Float(line.logProbs.count)
            out.append(ReplyScore(reply: reply, confidence: Double(exp(mean)),
                                  stopChance: sawReply ? line.stopBefore.map { Double(exp($0)) } : nil))
            sawReply = true
        }
        return out
    }
}
