import Foundation

/// Snapshot of one learned (or manual, or blocked) word for the "Learned words" editor.
public struct LearnedWordInfo: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable { case learning, active, blocked }
    /// Stable key: the normalized (lowercased, whitespace-collapsed) text. Changes on rename.
    public let id: String
    public let text: String
    public let status: Status
    public let origin: VocabEntry.Origin
    public let positiveCount: Int
    public let negativeCount: Int
    public let lastSeen: Date
    /// Current decayed weight in 0...1 as the bias builder would use it (0 while blocked or not
    /// worth anything yet).
    public let strength: Float
    /// Apps (app keys: bundle IDs or site hosts) the word was confirmed in, with each one's share
    /// of its use, largest first. Empty for words learned before apps were recorded or added by hand.
    public let apps: [(key: String, share: Float)]
    /// The user kept this word over a spelling fix (typed past it, or rejected an automatic fix).
    public let keptOverFix: Bool
    /// A word the user often mistypes (kept automatic fixes of it, `SlipRecord`), not a learned word:
    /// it can only be deleted. Its id starts with `slipIDPrefix`; `positiveCount` is the kept fixes.
    public let oftenMistyped: Bool
    /// Blocked by Hunch as a likely typo of the user's (`VocabEntry.likelyTypo`), not by the user.
    public let likelyTypo: Bool

    public static let slipIDPrefix = "slip:"

    public static func == (a: LearnedWordInfo, b: LearnedWordInfo) -> Bool {
        a.id == b.id && a.text == b.text && a.status == b.status && a.origin == b.origin
            && a.positiveCount == b.positiveCount && a.negativeCount == b.negativeCount
            && a.lastSeen == b.lastSeen && a.strength == b.strength
            && a.keptOverFix == b.keptOverFix && a.oftenMistyped == b.oftenMistyped && a.likelyTypo == b.likelyTypo
            && a.apps.map(\.key) == b.apps.map(\.key) && a.apps.map(\.share) == b.apps.map(\.share)
    }

    public init(id: String, text: String, status: Status, origin: VocabEntry.Origin, positiveCount: Int,
                negativeCount: Int, lastSeen: Date, strength: Float, apps: [(key: String, share: Float)] = [],
                keptOverFix: Bool = false, oftenMistyped: Bool = false, likelyTypo: Bool = false) {
        self.oftenMistyped = oftenMistyped
        self.likelyTypo = likelyTypo
        self.apps = apps
        self.keptOverFix = keptOverFix
        self.id = id
        self.text = text
        self.status = status
        self.origin = origin
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.lastSeen = lastSeen
        self.strength = strength
    }
}

/// Why an edit to the learned words was refused. `errorDescription` is user-readable.
public enum LearnedWordError: Error, Equatable, LocalizedError {
    case empty
    case tooManyWords
    case tooLong
    case looksSensitive
    case notFound
    case readOnlyStore

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a word or short phrase."
        case .tooManyWords: "Use one to three words."
        case .tooLong: "That is too long for a word. Use shorter words."
        case .looksSensitive:
            "That looks like a password, key, address, or number, so Hunch will not store it."
        case .notFound: "That word is no longer in the list."
        case .readOnlyStore:
            "Your learned words could not be opened safely, so changes are disabled for this session."
        }
    }
}

extension VocabularyModel {
    static let maxEditWords = 3
    static let maxEditWordLength = 40

    /// Trimmed text with single spaces, or the reason it cannot be stored.
    static func validatedEditText(_ raw: String) throws -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { throw LearnedWordError.empty }
        guard words.count <= maxEditWords else { throw LearnedWordError.tooManyWords }
        let scorer = VocabularyScorer()
        for w in words {
            guard w.count <= maxEditWordLength else { throw LearnedWordError.tooLong }
            guard scorer.isPlausibleToken(w) else { throw LearnedWordError.looksSensitive }
        }
        return words.joined(separator: " ")
    }

    /// Snapshot for the editor: every entry, in-memory one-offs included (as learning).
    func infos(now: Date) -> [LearnedWordInfo] {
        let list = entries.map { (k, e) -> LearnedWordInfo in
            let status: LearnedWordInfo.Status = e.blocked ? .blocked : (e.active ? .active : .learning)
            return LearnedWordInfo(id: k, text: e.text, status: status, origin: e.origin,
                                   positiveCount: e.positive, negativeCount: e.negative, lastSeen: e.lastSeen,
                                   strength: e.blocked ? 0 : e.weight(at: now), apps: Self.appShares(e.apps), keptOverFix: e.skips > 0,
                                   likelyTypo: e.blocked && e.likelyTypo)
        } + slips.compactMap { (k, r) -> LearnedWordInfo? in
            guard r.isTrouble(at: now), entries[Self.key(r.text)]?.blocked != true else { return nil }
            return LearnedWordInfo(id: LearnedWordInfo.slipIDPrefix + k, text: r.text, status: .active, origin: .learned,
                                   positiveCount: r.kept, negativeCount: r.rejected, lastSeen: r.lastSeen,
                                   strength: min(1, r.decayedMass(at: now) / Float(SlipRecord.keptToLearn)),
                                   oftenMistyped: true)
        }
        func rank(_ s: LearnedWordInfo.Status) -> Int { s == .active ? 0 : (s == .learning ? 1 : 2) }
        return list.sorted {
            if rank($0.status) != rank($1.status) { return rank($0.status) < rank($1.status) }
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            return $0.id < $1.id
        }
    }

    static func appShares(_ apps: [String: Float]) -> [(key: String, share: Float)] {
        let total = apps.values.reduce(0, +)
        guard total > 0 else { return [] }
        return apps.filter { $0.value > 0 }.map { (key: $0.key, share: $0.value / total) }
            .sorted { $0.share != $1.share ? $0.share > $1.share : $0.key < $1.key }
    }

    /// Blocked words as shown, sorted for stable cache keys.
    var blockedTexts: [String] {
        entries.values.filter(\.blocked).map(\.text).sorted()
    }

    /// Adds (or upgrades) a manual entry: active at once with the weight of three full confirmations
    /// on two days; never pruned. A blocked entry with the same text is unblocked.
    @discardableResult
    mutating func addManual(_ raw: String, origin: VocabEntry.Origin = .manual, now: Date) throws -> String {
        let text = try Self.validatedEditText(raw)
        let k = Self.key(text)
        var e = entries[k] ?? VocabEntry(text: text, now: now)
        e.rebase(to: now)
        e.text = text
        e.lastSeen = now
        // A dictation fix never demotes a word added by hand.
        if e.origin != .manual { e.origin = origin == .learned ? .manual : origin }
        if e.likelyTypo { e.likelyTypo = false; e.typoAllowed = true }
        e.blocked = false
        e.positive = max(e.positive, 3)
        e.posMass = max(e.posMass, VocabEntry.manualMass)
        e.addDay(Self.day(now) - 1)
        e.addDay(Self.day(now))
        e.active = e.computeActive(at: now)
        entries[k] = e
        return k
    }

    /// Renames (re-spells) an entry, merging into an existing entry with the new text.
    @discardableResult
    mutating func rename(id: String, to raw: String, now: Date) throws -> String {
        guard var source = entries[id] else { throw LearnedWordError.notFound }
        let text = try Self.validatedEditText(raw)
        let k = Self.key(text)
        source.rebase(to: now)
        entries[id] = nil
        if k != id, var target = entries[k] {
            target.rebase(to: now)
            target.merge(source)
            target.text = text
            target.active = target.computeActive(at: now)
            entries[k] = target
        } else {
            source.text = text
            source.active = source.computeActive(at: now)
            entries[k] = source
        }
        return k
    }

    mutating func delete(id: String) throws {
        if id.hasPrefix(LearnedWordInfo.slipIDPrefix) {
            guard slips.removeValue(forKey: String(id.dropFirst(LearnedWordInfo.slipIDPrefix.count))) != nil else {
                throw LearnedWordError.notFound
            }
            return
        }
        guard entries.removeValue(forKey: id) != nil else { throw LearnedWordError.notFound }
    }

    mutating func setBlocked(id: String, _ blocked: Bool, now: Date) throws {
        guard var e = entries[id] else { throw LearnedWordError.notFound }
        if !blocked, e.likelyTypo { e.likelyTypo = false; e.typoAllowed = true }
        e.blocked = blocked
        if blocked {
            e.active = false
        } else if e.origin == .learned, e.posMass <= 0 {
            entries[id] = nil   // a bare block marker with no history left
            return
        } else {
            e.rebase(to: now)
            e.active = e.computeActive(at: now)
        }
        entries[id] = e
    }

    /// Blocks a word that may not be in the list yet.
    @discardableResult
    mutating func block(_ raw: String, now: Date) throws -> String {
        let text = try Self.validatedEditText(raw)
        let k = Self.key(text)
        if entries[k] == nil { entries[k] = VocabEntry(text: text, now: now) }
        try setBlocked(id: k, true, now: now)
        return k
    }
}
