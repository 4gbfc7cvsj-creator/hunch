import Foundation
import HunchCore

/// One answer the user sent to a learned question. `mass` is "as of `asOf`" and decays with
/// `LearnedReplies.halfLife` when read; an answer added by hand never decays.
public struct LearnedAnswer: Codable, Sendable, Equatable {
    /// As last sent (the user's own casing and punctuation).
    public var text: String
    public var sends: Int
    public var mass: Float
    public var asOf: Date
    public var lastSent: Date
    /// Added (or edited) by the user in Settings.
    public var manual: Bool = false

    func weight(at now: Date) -> Float {
        if manual { return LearnedReplies.manualMass }
        let days = Float(max(0, now.timeIntervalSince(asOf)) / 86_400)
        return mass * Float(pow(0.5, Double(days / LearnedReplies.halfLifeDays)))
    }
}

/// A recurring question in one app (or site) and what the user sent back to it.
public struct LearnedQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// `AppKey`: the site's host in a browser, else the app's bundle ID.
    public var appKey: String
    /// The question sentences it was asked with (`ReplyQuestion.keySentences`), newest last.
    public var keys: [String]
    /// Times it was answered.
    public var seen: Int
    public var lastSeen: Date
    public var answers: [LearnedAnswer]
    /// The user never wants replies learned or offered for it.
    public var blocked: Bool = false
    /// Added by the user in Settings: never fades away.
    public var manual: Bool = false
}

/// What learned replies offer for a message (`LearnedReplies.suggestion`).
public struct LearnedSuggestion: Sendable, Equatable {
    public var questionID: String
    /// Best first: whole answers, and the start several answers share ("Done testing, ").
    public var replies: [String]
    /// Sends of the answers still remembered.
    public var cases: Int
    /// Share of those answers (by recent weight) the replies cover.
    public var coverage: Double
    /// How alike the message is to the learned question (0...1).
    public var similarity: Double
    /// The habit is clear: show the replies without asking the model.
    public var skipModel: Bool
}

/// Learned replies: per app, the questions that keep coming back (matched by their question
/// sentences, `ReplyQuestion`) and the answers the user sent to them. Only the message replies
/// answer is ever matched (`ReplyQuestion.theirNewest`). Saved encrypted inside the history file.
public struct LearnedReplies: Codable, Sendable, Equatable {
    public var questions: [LearnedQuestion] = []

    public init() {}

    /// Recent sends weigh more: an answer's weight halves every three weeks.
    static let halfLifeDays: Float = 21
    /// An answer not sent for this long is dropped; a question not seen for this long is forgotten.
    static let answerExpiry: TimeInterval = 60 * 86_400
    static let questionExpiry: TimeInterval = 90 * 86_400
    /// The weight of an answer added by hand (a clear habit on its own).
    static let manualMass: Float = 3
    /// Messages at least this alike count as the same question.
    public static let matchThreshold = 0.5
    /// Answers below this weight are not offered.
    static let minOffered: Float = 0.25
    /// The habit is clear after this many sends, with the replies covering this share of them.
    public static let casesToSkip = 3
    public static let coverageToSkip = 0.8
    static let maxQuestions = 300
    static let maxAnswers = 8
    static let maxKeys = 6
    /// Longer sends are not replies to learn; longer answers are only offered through a shared start.
    static let maxAnswerLength = 300
    static let maxOfferedLength = 120
    static let maxReplies = 3

    // MARK: Matching

    /// The question this message (its key sentences) asks in `appKey`, with how alike they are.
    func match(_ keys: [String], appKey: String) -> (index: Int, similarity: Double)? {
        guard !keys.isEmpty else { return nil }
        var best: (index: Int, similarity: Double)?
        for (i, q) in questions.enumerated() where q.appKey == appKey {
            let s = ReplyQuestion.similarity(keys, q.keys)
            guard s >= Self.matchThreshold else { continue }
            if let b = best, s < b.similarity || (s == b.similarity && q.seen <= questions[b.index].seen) { continue }
            best = (i, s)
        }
        return best
    }

    /// What to offer for a message with these key sentences in `appKey`; nil when nothing is learned
    /// for it, or the question is blocked.
    public func suggestion(keys: [String], appKey: String, now: Date = Date()) -> LearnedSuggestion? {
        guard let (i, similarity) = match(keys, appKey: appKey) else { return nil }
        let q = questions[i]
        guard !q.blocked else { return nil }
        let live = q.answers.filter { $0.manual || now.timeIntervalSince($0.lastSent) < Self.answerExpiry }
        let picked = Self.offers(live, now: now)
        guard !picked.isEmpty else { return nil }
        let total = live.reduce(Float(0)) { $0 + $1.weight(at: now) }
        let covered = live.filter { a in picked.contains { Self.covers($0, a.text) } }
            .reduce(Float(0)) { $0 + $1.weight(at: now) }
        let coverage = total > 0 ? Double(covered / total) : 0
        let cases = live.reduce(0) { $0 + $1.sends }
        let skip = q.manual || live.contains(where: \.manual)
            || (cases >= Self.casesToSkip && coverage >= Self.coverageToSkip)
        return LearnedSuggestion(questionID: q.id, replies: picked, cases: cases, coverage: coverage,
                                 similarity: similarity, skipModel: skip)
    }

    /// Whether offering `reply` covers the answer `text`: it is that answer, or a start of it.
    static func covers(_ reply: String, _ text: String) -> Bool {
        let r = normalized(reply), t = normalized(text)
        return r == t || t.hasPrefix(r + " ") || (r.hasSuffix(",") && t.hasPrefix(r))
    }

    /// The replies to offer, best first: whole answers sent more than once and short enough to send as
    /// they are, and the start (two or more words) that several different answers share, weighed by
    /// all of them.
    static func offers(_ answers: [LearnedAnswer], now: Date) -> [String] {
        var scored: [(text: String, score: Float, recent: Date)] = []
        // Whole answers sent more than once (or added by hand): one send is not yet a habit.
        for a in answers where a.text.count <= maxOfferedLength && (a.sends >= 2 || a.manual) {
            scored.append((a.text, a.weight(at: now), a.lastSent))
        }
        for start in sharedStarts(answers) {
            let covered = answers.filter { covers(start, $0.text) }
            let score = covered.reduce(Float(0)) { $0 + $1.weight(at: now) }
            let recent = covered.map(\.lastSent).max() ?? .distantPast
            // The same words as a whole answer: that answer already stands for it.
            if scored.contains(where: { normalized($0.text) == normalized(start).trimmingCharacters(in: [","]) }) {
                continue
            }
            scored.append((start, score, recent))
        }
        let ranked = scored.filter { $0.score >= minOffered }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.recent > $1.recent }
        var out: [String] = []
        for c in ranked where !out.contains(where: { normalized($0) == normalized(c.text) }) {
            out.append(c.text)
            if out.count == maxReplies { break }
        }
        return out
    }

    /// Word starts (at least two words) shared by two or more different answers, each the longest
    /// such start of its pair, in the newest answer's spelling, followed by a space so the reply reads
    /// as a beginning to finish ("Done testing, ", "Done testing, found a bug with "). A comma right
    /// after the shared words stays.
    static func sharedStarts(_ answers: [LearnedAnswer]) -> [String] {
        let newestFirst = answers.sorted { $0.lastSent > $1.lastSent }
        var starts: [String] = []
        for (i, a) in newestFirst.enumerated() {
            let wa = a.text.split(separator: " ")
            for b in newestFirst[(i + 1)...] {
                let wb = b.text.split(separator: " ")
                var n = 0
                while n < min(wa.count, wb.count), wordKey(wa[n]) == wordKey(wb[n]), !wordKey(wa[n]).isEmpty { n += 1 }
                // The last shared word may differ only in a trailing comma ("testing," vs "testing").
                guard n >= 2, n < wa.count || n < wb.count else { continue }
                var start = wa[..<n].joined(separator: " ")
                let comma = (wa[n - 1].last == "," || wb[n - 1].last == ",")
                if comma && !start.hasSuffix(",") { start += "," }
                if !comma { start = start.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:")) }
                // Always a beginning to finish: a space after it, ready for the next word.
                start += " "
                if !starts.contains(where: { normalized($0) == normalized(start) }) { starts.append(start) }
            }
        }
        return starts
    }

    static func wordKey(_ w: Substring) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Lowercased, single spaces, no closing ".", "!" or space: "Done testing." and "done testing" match.
    static func normalized(_ text: String) -> String {
        var t = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let last = t.last, ".!".contains(last) { t.removeLast() }
        return t
    }

    // MARK: Learning

    /// The user sent `answer` to the message with key sentences `keys` in `appKey`. Ignored when the
    /// question is blocked, or the answer is empty, too long or looks like a secret. Returns whether
    /// anything was learned.
    @discardableResult
    public mutating func record(keys rawKeys: [String], answer raw: String, appKey: String, now: Date = Date()) -> Bool {
        let answer = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !answer.isEmpty, answer.count <= Self.maxAnswerLength, Self.isSafe(answer) else { return false }
        let keys = rawKeys.map { SecretSanitizer.redact($0) }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return false }
        if let (i, _) = match(keys, appKey: appKey) {
            guard !questions[i].blocked else { return false }
            var q = questions[i]
            for k in keys where !q.keys.contains(where: { ReplyQuestion.similarity($0, k) >= 0.9 }) { q.keys.append(k) }
            q.keys = Array(q.keys.suffix(Self.maxKeys))
            q.seen += 1
            q.lastSeen = now
            Self.add(answer, to: &q, now: now)
            questions[i] = q
        } else {
            var q = LearnedQuestion(id: UUID().uuidString, appKey: appKey, keys: Array(keys.suffix(Self.maxKeys)),
                                    seen: 1, lastSeen: now, answers: [])
            Self.add(answer, to: &q, now: now)
            questions.append(q)
        }
        prune(now: now)
        return true
    }

    static func add(_ answer: String, to q: inout LearnedQuestion, now: Date) {
        if let j = q.answers.firstIndex(where: { normalized($0.text) == normalized(answer) }) {
            var a = q.answers[j]
            a.mass = a.weight(at: now) + 1
            a.asOf = now
            a.sends += 1
            a.lastSent = now
            if !a.manual { a.text = answer }
            q.answers[j] = a
        } else {
            q.answers.append(LearnedAnswer(text: answer, sends: 1, mass: 1, asOf: now, lastSent: now))
        }
        if q.answers.count > maxAnswers {
            // Hand-added answers stay; the weakest learned one goes.
            if let weakest = q.answers.indices.filter({ !q.answers[$0].manual })
                .min(by: { q.answers[$0].weight(at: now) < q.answers[$1].weight(at: now) }) {
                q.answers.remove(at: weakest)
            }
        }
    }

    /// No secret-looking text (keys, tokens, ids, addresses): sent text is kept only when it is plainly words.
    static func isSafe(_ text: String) -> Bool {
        if SecretSanitizer.containsSecret(text) { return false }
        for w in text.split(whereSeparator: { $0.isWhitespace }) {
            let t = w.trimmingCharacters(in: .punctuationCharacters)
            if t.contains("://") || t.contains("@") || VocabularyScorer.looksLikeSecret(t) { return false }
        }
        return true
    }

    /// Drops answers not sent for `answerExpiry`, questions not seen for `questionExpiry` (or left
    /// with no answers), and the oldest questions beyond `maxQuestions`. Hand-added ones and blocked
    /// questions stay.
    public mutating func prune(now: Date = Date()) {
        for i in questions.indices {
            questions[i].answers.removeAll { !$0.manual && now.timeIntervalSince($0.lastSent) >= Self.answerExpiry }
        }
        questions.removeAll { q in
            guard !q.manual, !q.blocked else { return false }
            return q.answers.isEmpty || now.timeIntervalSince(q.lastSeen) >= Self.questionExpiry
        }
        if questions.count > Self.maxQuestions {
            let keep = questions.enumerated().sorted { a, b in
                (a.element.manual || a.element.blocked) != (b.element.manual || b.element.blocked)
                    ? (a.element.manual || a.element.blocked) : a.element.lastSeen > b.element.lastSeen
            }.prefix(Self.maxQuestions).map(\.offset)
            let kept = Set(keep)
            questions = questions.enumerated().filter { kept.contains($0.offset) }.map(\.element)
        }
    }

    // MARK: Editing (Settings → Learned data)

    public mutating func deleteQuestion(id: String) throws {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { throw LearnedReplyError.notFound }
        questions.remove(at: i)
    }

    /// Blocks (or unblocks) a question: blocked, its answers are forgotten and none are learned again.
    public mutating func setBlocked(id: String, _ blocked: Bool) throws {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { throw LearnedReplyError.notFound }
        questions[i].blocked = blocked
        if blocked { questions[i].answers.removeAll() }
    }

    public mutating func deleteAnswer(questionID: String, text: String) throws {
        guard let i = questions.firstIndex(where: { $0.id == questionID }),
              let j = questions[i].answers.firstIndex(where: { $0.text == text }) else { throw LearnedReplyError.notFound }
        questions[i].answers.remove(at: j)
    }

    /// Changes an answer's words; it then counts as added by hand (kept, never fades).
    public mutating func renameAnswer(questionID: String, from old: String, to new: String, now: Date = Date()) throws {
        let text = try Self.validatedAnswer(new)
        guard let i = questions.firstIndex(where: { $0.id == questionID }),
              let j = questions[i].answers.firstIndex(where: { $0.text == old }) else { throw LearnedReplyError.notFound }
        if let dup = questions[i].answers.firstIndex(where: { Self.normalized($0.text) == Self.normalized(text) }), dup != j {
            questions[i].answers.remove(at: j)
            questions[i].answers[dup > j ? dup - 1 : dup].manual = true
            return
        }
        questions[i].answers[j].text = text
        questions[i].answers[j].manual = true
        questions[i].answers[j].lastSent = now
    }

    /// Adds answers to a question, or a new question typed by hand (its question sentences are read
    /// from `question` like a message's), in `appKey`. Returns the question's id.
    @discardableResult
    public mutating func addManual(question: String?, questionID: String? = nil, answers rawAnswers: [String],
                                   appKey: String, now: Date = Date()) throws -> String {
        let answers = try rawAnswers.map(Self.validatedAnswer)
        guard !answers.isEmpty else { throw LearnedReplyError.emptyAnswer }
        var index: Int
        if let questionID {
            guard let i = questions.firstIndex(where: { $0.id == questionID }) else { throw LearnedReplyError.notFound }
            index = i
        } else {
            let text = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LearnedReplyError.emptyQuestion }
            guard !SecretSanitizer.containsSecret(text) else { throw LearnedReplyError.looksSensitive }
            let keys = ReplyQuestion.keySentences(text.components(separatedBy: .newlines).filter { !$0.isEmpty })
            guard !keys.isEmpty else { throw LearnedReplyError.emptyQuestion }
            questions.append(LearnedQuestion(id: UUID().uuidString, appKey: appKey, keys: keys, seen: 0,
                                             lastSeen: now, answers: [], manual: true))
            index = questions.count - 1
        }
        questions[index].blocked = false
        for a in answers {
            if let j = questions[index].answers.firstIndex(where: { Self.normalized($0.text) == Self.normalized(a) }) {
                questions[index].answers[j].manual = true
            } else {
                questions[index].answers.append(LearnedAnswer(text: a, sends: 0, mass: Self.manualMass, asOf: now,
                                                              lastSent: now, manual: true))
            }
        }
        return questions[index].id
    }

    static func validatedAnswer(_ raw: String) throws -> String {
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { throw LearnedReplyError.emptyAnswer }
        guard text.count <= maxOfferedLength else { throw LearnedReplyError.tooLong }
        guard isSafe(text) else { throw LearnedReplyError.looksSensitive }
        return text
    }
}

/// Why an edit to the learned replies was refused. `errorDescription` is user-readable.
public enum LearnedReplyError: Error, Equatable, LocalizedError {
    case emptyQuestion
    case emptyAnswer
    case tooLong
    case looksSensitive
    case notFound
    case readOnlyStore

    public var errorDescription: String? {
        switch self {
        case .emptyQuestion: "Enter the question, as it appears on screen."
        case .emptyAnswer: "Enter at least one answer."
        case .tooLong: "Keep each answer under \(LearnedReplies.maxOfferedLength) characters."
        case .looksSensitive: "That looks like a password, key, address, or number, so Hunch will not store it."
        case .notFound: "That reply is no longer in the list."
        case .readOnlyStore: "Your learned data could not be opened safely, so changes are disabled for this session."
        }
    }
}

/// A reply the user picked from the bubble. Only a pick teaches learned replies: the message sent
/// from the same box soon after, when it is the pick itself or starts with it ("Done testing, the
/// labels look right"). Anything typed without a pick is never learned (it is usually a one-off).
public struct ReplyPick: Sendable, Equatable {
    public var text: String
    public var field: FieldID
    public var at: Date

    /// A pick not sent within this long is forgotten.
    public static let lifetime: TimeInterval = 600

    public init(text: String, field: FieldID, at: Date = Date()) {
        self.text = text
        self.field = field
        self.at = at
    }

    /// Whether `sent`, sent from `field` at `now`, is this pick (as it is, or with words added after it).
    public func isAnswered(by sent: String, field: FieldID, now: Date = Date()) -> Bool {
        guard field == self.field, now.timeIntervalSince(at) < Self.lifetime else { return false }
        let pick = LearnedReplies.normalized(text).trimmingCharacters(in: .whitespaces)
        let s = LearnedReplies.normalized(sent)
        guard !pick.isEmpty else { return false }
        if s == pick { return true }
        guard s.hasPrefix(pick) else { return false }
        // A picked start ("Done testing, ") goes on with anything; a whole reply only after a word break.
        if pick.last.map({ !($0.isLetter || $0.isNumber) }) == true { return true }
        let next = s[s.index(s.startIndex, offsetBy: pick.count)]
        return !(next.isLetter || next.isNumber)
    }
}
