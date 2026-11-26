import Foundation
import HunchCore

/// One learned word or short phrase. Holds counters and tiny bounded context lists only; never
/// raw field text. Mass values are "as of `asOf`" and decay with a 30-day half-life when read.
public struct VocabEntry: Codable, Sendable, Equatable {
    /// The user's own casing (most recent).
    public var text: String
    /// Credited confirmations (words typed by the user count too).
    public var positive: Int = 0
    public var negative: Int = 0
    public var posMass: Float = 0
    public var negMass: Float = 0
    /// Distinct UTC day numbers (latest 10).
    public var days: [Int32] = []
    /// Distinct field hashes (latest 8).
    public var fields: [UInt32] = []
    public var lastSeen: Date
    public var asOf: Date
    /// Positive mass by context key (1-2 lowercased preceding words), at most 6 keys.
    public var contexts: [String: Float] = [:]
    /// Positive mass by app key (see `AppKey`), at most 6 keys.
    public var apps: [String: Float] = [:]
    /// Negative mass by context key, at most 4 keys.
    public var negContexts: [String: Float] = [:]
    public var active: Bool = false
    /// Where the entry came from: observed while typing, or added by the user.
    public var origin: Origin = .learned
    /// The user never wants this word suggested: never learned, boosted, or activated, and the
    /// decoder steers away from it.
    public var blocked: Bool = false
    /// Times the user kept this word when offered a spelling fix: proof it is deliberate, so
    /// consolidation never drops it as a misspelling or an ordinary word.
    public var skips: Int = 0
    /// Clean rejections of an automatic fix (`LearningEvent.Kind.fixRejected`); also counted in
    /// `skips`. `rejectionsToLearn` of them make the word active on their own.
    public var rejections: Int = 0
    /// Blocked by Hunch, not the user: kept over fixes, but most likely the writer's own typo
    /// (`VocabularyModel.blockIfLikelyTypo`). Shown as "Blocked (potential typo)".
    public var likelyTypo: Bool = false
    /// The user unblocked (or added) a word Hunch had blocked as a likely typo: never blocked
    /// as one again.
    public var typoAllowed: Bool = false
    /// The likely-typo check said no for this word: consolidation doesn't ask again.
    public var typoChecked: Bool = false

    /// `dictation`: the user fixed it in dictated text; kept like a word added by hand.
    public enum Origin: String, Codable, Sendable { case learned, manual, dictation }

    /// Added by hand or from a dictation fix: active at once, never decays away or gets pruned.
    var isPinned: Bool { origin != .learned }

    private enum CodingKeys: String, CodingKey {
        case text, positive, negative, posMass, negMass, days, fields, lastSeen, asOf, contexts, negContexts, apps,
             active, origin, blocked, skips, rejections, likelyTypo, typoAllowed, typoChecked
    }

    /// Files written before `origin`/`blocked` existed still decode (defaults apply).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        positive = try c.decodeIfPresent(Int.self, forKey: .positive) ?? 0
        negative = try c.decodeIfPresent(Int.self, forKey: .negative) ?? 0
        posMass = try c.decodeIfPresent(Float.self, forKey: .posMass) ?? 0
        negMass = try c.decodeIfPresent(Float.self, forKey: .negMass) ?? 0
        days = try c.decodeIfPresent([Int32].self, forKey: .days) ?? []
        fields = try c.decodeIfPresent([UInt32].self, forKey: .fields) ?? []
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        asOf = try c.decodeIfPresent(Date.self, forKey: .asOf) ?? lastSeen
        contexts = try c.decodeIfPresent([String: Float].self, forKey: .contexts) ?? [:]
        negContexts = try c.decodeIfPresent([String: Float].self, forKey: .negContexts) ?? [:]
        apps = try c.decodeIfPresent([String: Float].self, forKey: .apps) ?? [:]
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .learned
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        skips = try c.decodeIfPresent(Int.self, forKey: .skips) ?? 0
        rejections = try c.decodeIfPresent(Int.self, forKey: .rejections) ?? 0
        likelyTypo = try c.decodeIfPresent(Bool.self, forKey: .likelyTypo) ?? false
        typoAllowed = try c.decodeIfPresent(Bool.self, forKey: .typoAllowed) ?? false
        typoChecked = try c.decodeIfPresent(Bool.self, forKey: .typoChecked) ?? false
    }

    static let halfLifeDays: Double = 30
    static let maxDays = 10, maxFields = 8, maxContexts = 6, maxNegContexts = 4, maxApps = 6
    /// Net mass at which the weight reaches about 63%.
    static let saturation: Float = 2.5

    init(text: String, now: Date) {
        self.text = text
        lastSeen = now
        asOf = now
    }

    /// Multiplier for mass recorded at `asOf`, read at `now`.
    func decay(at now: Date) -> Float {
        let days = now.timeIntervalSince(asOf) / 86_400
        guard days > 0 else { return 1 }
        return Float(pow(0.5, days / Self.halfLifeDays))
    }

    /// Applies decay up to `now` so new mass can be added on a common baseline.
    mutating func rebase(to now: Date) {
        let f = decay(at: now)
        guard f < 1 else { return }
        posMass *= f
        negMass *= f
        for k in contexts.keys { contexts[k]! *= f }
        for k in negContexts.keys { negContexts[k]! *= f }
        for k in apps.keys { apps[k]! *= f }
        asOf = now
    }

    /// Net decayed mass; a negative global penalty is deliberately small.
    func net(at now: Date) -> Float {
        let n = (posMass - 0.25 * negMass) * decay(at: now)
        return isPinned ? max(n, Self.manualFloorMass) : n
    }

    /// Manual entries decay to this net mass (weight about 0.26) and stay there.
    static let manualFloorMass: Float = 0.75
    /// Mass given to a manually added word: as if confirmed 3 times with full credit.
    static let manualMass: Float = 3

    /// Manual and blocked entries are never auto-pruned or dropped as dead.
    var isProtected: Bool { isPinned || blocked }

    static func squash(_ net: Float) -> Float { net > 0 ? 1 - exp(-net / saturation) : 0 }

    /// Global weight in 0...1 (0 when net-negative).
    public func weight(at now: Date) -> Float { Self.squash(net(at: now)) }

    /// Weight within a context: positive history there boosts, negative history there suppresses.
    func weight(inContext key: String, at now: Date) -> Float {
        let n = net(at: now)
        guard n > 0 else { return 0 }
        let f = decay(at: now)
        let adj = n + 0.5 * (contexts[key] ?? 0) * f - 1.5 * (negContexts[key] ?? 0) * f
        return Self.squash(adj)
    }

    /// ≥3 confirmations across ≥2 days or ≥2 fields, and still worth something after decay.
    /// Also needs real credited mass (`minActiveMass`), so many tiny credits (common words, words
    /// the decoder was already biased toward) cannot make an entry active by count alone.
    func computeActive(at now: Date) -> Bool {
        if blocked { return false }
        if isPinned { return true }
        if rejections >= Self.rejectionsToLearn && net(at: now) > 0 { return true }
        return positive >= 3 && (days.count >= 2 || fields.count >= 2) && weight(at: now) >= 0.05
            && net(at: now) >= Self.minActiveMass
    }

    /// Clean rejections of an automatic fix that make a word active (never fixed again).
    static let rejectionsToLearn = 2
    /// Net decayed mass required for active status.
    static let minActiveMass: Float = 0.8
    /// Entries need at least this many positive confirmations to be written to disk.
    static let minPersistedPositive = 2

    /// Keeps the highest-valued keys when a dictionary exceeds `limit`.
    static func trim(_ d: inout [String: Float], to limit: Int) {
        while d.count > limit, let k = d.min(by: { $0.value < $1.value })?.key { d[k] = nil }
    }

    mutating func addDay(_ day: Int32) {
        guard !days.contains(day) else { return }
        days.append(day)
        if days.count > Self.maxDays { days.removeFirst(days.count - Self.maxDays) }
    }

    mutating func addField(_ f: UInt32) {
        guard !fields.contains(f) else { return }
        fields.append(f)
        if fields.count > Self.maxFields { fields.removeFirst(fields.count - Self.maxFields) }
    }

    /// Merges `other` (already rebased to the same instant) into self.
    mutating func merge(_ other: VocabEntry) {
        if other.lastSeen > lastSeen { text = other.text; lastSeen = other.lastSeen }
        // Added by hand outranks a dictation fix, which outranks learned.
        if other.origin == .manual || (other.origin == .dictation && origin == .learned) { origin = other.origin }
        // A block the user made themselves stays theirs: "potential typo" only when every blocked
        // side was Hunch's own.
        let userBlocked = (blocked && !likelyTypo) || (other.blocked && !other.likelyTypo)
        if other.blocked { blocked = true }
        if other.typoAllowed { typoAllowed = true }
        if other.typoChecked { typoChecked = true }
        likelyTypo = blocked && !typoAllowed && !userBlocked && (likelyTypo || other.likelyTypo)
        positive += other.positive
        skips += other.skips
        rejections += other.rejections
        negative += other.negative
        posMass += other.posMass
        negMass += other.negMass
        for d in other.days { addDay(d) }
        for f in other.fields { addField(f) }
        for (k, v) in other.contexts { contexts[k, default: 0] += v }
        for (k, v) in other.negContexts { negContexts[k, default: 0] += v }
        for (k, v) in other.apps { apps[k, default: 0] += v }
        Self.trim(&apps, to: Self.maxApps)
        Self.trim(&contexts, to: Self.maxContexts)
        Self.trim(&negContexts, to: Self.maxNegContexts)
    }
}

/// The learned vocabulary: normalized text to entry, with bounded size.
public struct VocabularyModel: Codable, Sendable, Equatable {
    public var entries: [String: VocabEntry] = [:]
    public var lastConsolidated: Date?
    /// Sentences kept as style examples; saved even when the vocabulary is empty.
    public var style = StyleLibrary()
    /// Automatic fixes the user kept, by fix (`SlipRecord`): the personal slip list.
    public var slips: [String: SlipRecord] = [:]
    /// Questions that keep coming back and the user's answers to them (suggested replies).
    public var replies = LearnedReplies()
    /// Maximum entries kept; not persisted.
    public var capacity = 5000

    private enum CodingKeys: String, CodingKey { case entries, lastConsolidated, style, slips, replies }

    /// One-offs stay in memory only: entries with fewer than `VocabEntry.minPersistedPositive`
    /// positive confirmations are left out of the encoded snapshot (so they never reach disk).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries.filter { $0.value.positive >= VocabEntry.minPersistedPositive || $0.value.isProtected
                                    || $0.value.rejections > 0 },
                     forKey: .entries)
        try c.encodeIfPresent(lastConsolidated, forKey: .lastConsolidated)
        if !style.isEmpty { try c.encode(style, forKey: .style) }
        if !slips.isEmpty { try c.encode(slips, forKey: .slips) }
        if !replies.questions.isEmpty { try c.encode(replies, forKey: .replies) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([String: VocabEntry].self, forKey: .entries)
        lastConsolidated = try c.decodeIfPresent(Date.self, forKey: .lastConsolidated)
        style = try c.decodeIfPresent(StyleLibrary.self, forKey: .style) ?? StyleLibrary()
        slips = try c.decodeIfPresent([String: SlipRecord].self, forKey: .slips) ?? [:]
        replies = try c.decodeIfPresent(LearnedReplies.self, forKey: .replies) ?? LearnedReplies()
    }

    public init() {}

    /// Capitalized like a name: uppercase first letter, not all caps ("Swift" yes; "OK", "I" no).
    /// Stopwords never count.
    static func isNameForm(_ word: String) -> Bool {
        guard let f = word.first, f.isUppercase, word.contains(where: { $0.isLowercase }) else { return false }
        return !VocabularyScorer.enStopwords.contains(word.lowercased())
    }

    /// Matching key: lowercased, whitespace collapsed.
    public static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func day(_ date: Date) -> Int32 { Int32(date.timeIntervalSince1970 / 86_400) }

    // MARK: Recording

    public mutating func apply(_ event: LearningEvent, now: Date, scorer: VocabularyScorer = VocabularyScorer(),
                          appKey: String? = nil, spelling: (@Sendable (String) -> Bool?)? = nil,
                          likelyTypo: (@Sendable (String) -> Bool?)? = nil) {
        let fk = FieldKey.hash(pid: Int32(event.field.pid), element: event.field.elementHash)
        func learn(_ cands: [VocabularyScorer.Candidate]) {
            for c in cands where Self.spelledOK(c.text, spelling) {
                recordPositive(text: c.text, credit: c.credit, contextKey: scorer.contextKey(c.context),
                               fieldKey: fk, now: now, appKey: appKey, likelyTypo: likelyTypo)
            }
        }
        switch event.kind {
        case let .confirmed(words, context, boosted):
            learn(scorer.candidates(words: words, context: context, boosted: boosted, names: event.names))
        case let .typedOver(context, suggested, typed):
            recordNegative(text: suggested, amount: 1, contextKey: scorer.contextKey(context), now: now)
            learn(scorer.candidates(typed: typed, context: context, isName: event.names.contains(typed)))
        case let .correctedAfterAccept(context, accepted, corrected):
            recordNegative(text: accepted, amount: 1, contextKey: scorer.contextKey(context), now: now)
            learn(scorer.candidates(typed: corrected, context: context, isName: event.names.contains(corrected)))
        case let .dismissed(context, suggested):
            recordNegative(text: suggested, amount: 0.3, contextKey: scorer.contextKey(context), now: now)
        case let .correctionSkipped(word):
            // Straight in: the scorer would drop it as misspelled-looking, which it is by definition.
            recordPositive(text: word, credit: 1, contextKey: nil, fieldKey: fk, now: now, appKey: appKey,
                           likelyTypo: likelyTypo)
            entries[Self.key(word)]?.skips += 1
        case let .fixRejected(word):
            let k = Self.key(word)
            let wasActive = entries[k]?.active ?? false
            recordPositive(text: word, credit: 1, contextKey: nil, fieldKey: fk, now: now, appKey: appKey)
            if var e = entries[k], !e.blocked {
                e.skips += 1
                e.rejections += 1
                e.active = e.computeActive(at: now)
                // Two rejections vouch for the word (exempt); one plus skips does not.
                if e.active, !wasActive, let likelyTypo { Self.blockIfLikelyTypo(&e, likelyTypo) }
                entries[k] = e
            } else if var e = entries[k], e.blocked, e.likelyTypo, !e.typoAllowed {
                // Fixes of a word blocked as a likely typo keep being rejected: that vouches for it,
                // as two rejections do before a block. Never lifts a block the user made.
                e.rejections += 1
                if e.rejections >= VocabEntry.rejectionsToLearn {
                    e.blocked = false
                    e.likelyTypo = false
                    e.typoAllowed = true
                    e.active = e.computeActive(at: now)
                }
                entries[k] = e
            }
        case let .correctionAccepted(word):
            recordNegative(text: word, amount: 1, contextKey: nil, now: now)
        case let .fixKept(word, fix):
            recordKeptFix(word: word, fix: fix, now: now)
        case let .slipFixRejected(fix):
            recordRejectedFix(fix, now: now)
        }
    }

    /// True when no spell check is wired, or every alphabetic word of `text` is known to be spelled
    /// not a typo. Typo and unknown (nil) answers both fail: ordinary typing only teaches words
    /// the checker is sure about. Chinese/Japanese/Korean words are not checked.
    static func spelledOK(_ text: String, _ spelling: (@Sendable (String) -> Bool?)?) -> Bool {
        guard let spelling else { return true }
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let w = String(raw).trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
            if w.isEmpty || WordText.containsCJK(w) { continue }
            if spelling(w) != false { return false }
        }
        return true
    }

    /// `likelyTypo`: checked when the entry is about to become active (`blockIfLikelyTypo`).
    public mutating func recordPositive(text: String, credit: Float, contextKey: String?, fieldKey: UInt32,
                                        now: Date, appKey: String? = nil,
                                        likelyTypo: (@Sendable (String) -> Bool?)? = nil) {
        let k = Self.key(text)
        guard !k.isEmpty else { return }
        if entries[k]?.blocked == true { return }   // blocked words are never re-learned
        if SecretSanitizer.containsSecret(text) { return }   // keys and tokens are never learned
        var e = entries[k] ?? VocabEntry(text: text, now: now)
        e.rebase(to: now)
        e.text = text
        e.lastSeen = now
        e.positive += 1
        e.posMass += credit
        e.addDay(Self.day(now))
        e.addField(fieldKey)
        if let a = appKey, !a.isEmpty {
            e.apps[a, default: 0] += credit
            VocabEntry.trim(&e.apps, to: VocabEntry.maxApps)
        }
        if let c = contextKey {
            e.contexts[c, default: 0] += credit
            VocabEntry.trim(&e.contexts, to: VocabEntry.maxContexts)
        }
        let wasActive = e.active
        e.active = e.computeActive(at: now)
        if e.active, !wasActive, let likelyTypo { _ = Self.blockIfLikelyTypo(&e, likelyTypo) }
        entries[k] = e
        if entries.count > capacity + max(capacity / 10, 1) { prune(now: now) }
    }

    /// Penalizes an entry that already exists; unknown words are ignored (nothing to suppress).
    public mutating func recordNegative(text: String, amount: Float, contextKey: String?, now: Date) {
        let k = Self.key(text)
        guard var e = entries[k], !e.blocked else { return }
        e.rebase(to: now)
        e.lastSeen = now
        e.negative += 1
        e.negMass += amount
        if let c = contextKey {
            e.negContexts[c, default: 0] += amount
            VocabEntry.trim(&e.negContexts, to: VocabEntry.maxNegContexts)
        }
        e.active = e.computeActive(at: now)
        entries[k] = e
    }

    // MARK: Maintenance

    /// Drops the lowest-value entries until at most `capacity` remain.
    public mutating func prune(now: Date) {
        guard entries.count > capacity else { return }
        func value(_ e: VocabEntry) -> Float { e.net(at: now) + (e.active ? 0.5 : 0) }
        let doomed = entries.filter { !$0.value.isProtected }.sorted { value($0.value) < value($1.value) }
            .prefix(entries.count - capacity)
        for (k, _) in doomed { entries[k] = nil }
    }

    /// Idle-time housekeeping: decay, merge case/whitespace duplicates, drop dead entries,
    /// prune to capacity, recompute active flags.
    ///
    /// Accidental entries are dropped (never manual, blocked, or ones with a correction-skip
    /// history, which the user chose): single English words that are ordinary (stopword, common, or
    /// frequent), active or not, since they could only have been learned by accident; phrases made
    /// only of ordinary words, unless active; and single words `spelling` says are misspelled
    /// (true only; unknown keeps the entry). The spell check stops for this pass at the first
    /// unknown answer. A word stored capitalized like a name ("Swift", "Mark") is not ordinary.
    ///
    /// `likelyTypo`: active words are checked first and blocked as likely typos
    /// (`blockIfLikelyTypo`), so they show in the list instead of being dropped as misspellings.
    public mutating func consolidate(now: Date, spelling: (@Sendable (String) -> Bool?)? = nil,
                                     likelyTypo: (@Sendable (String) -> Bool?)? = nil) {
        if let likelyTypo { blockLikelyTypos(now: now, likelyTypo) }
        var spellingAvailable = spelling != nil
        var merged: [String: VocabEntry] = [:]
        for (_, var e) in entries {
            e.rebase(to: now)
            e.asOf = now
            if e.posMass < 0.05 && !e.isProtected { continue }
            if !e.isProtected && e.skips == 0 {
                let written = e.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let words = written.map { $0.lowercased() }
                let english = !words.contains { WordText.containsCJK($0) }
                func ordinary(_ i: Int) -> Bool {
                    !Self.isNameForm(written[i]) && CommonWords.isOrdinaryEnglish(words[i])
                }
                if english, words.count == 1, ordinary(0) { continue }
                if english, words.count > 1, !e.active, words.indices.allSatisfy(ordinary) { continue }
                if english, words.count == 1, spellingAvailable, let spelling {
                    let w = words[0].trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
                    if !w.isEmpty {
                        let r = spelling(w)
                        if r == nil { spellingAvailable = false }
                        if r == true { continue }
                    }
                }
            }
            let k = Self.key(e.text)
            guard !k.isEmpty else { continue }
            if var existing = merged[k] {
                existing.merge(e)
                merged[k] = existing
            } else {
                merged[k] = e
            }
        }
        for k in merged.keys {
            merged[k]!.active = merged[k]!.computeActive(at: now)
        }
        entries = merged
        prune(now: now)
        pruneSlips(now: now)
        lastConsolidated = now
    }

    // MARK: Likely typos

    /// Blocks `e` as a likely typo (`VocabEntry.likelyTypo`) when `check` says its word is one.
    /// Returns `check`'s answer (nil: unknown, nothing changed), or false when `e` is not checked.
    @discardableResult
    static func blockIfLikelyTypo(_ e: inout VocabEntry, _ check: (String) -> Bool?) -> Bool? {
        guard mayBlockAsTypo(e) else { return false }
        let r = check(e.text.trimmingCharacters(in: .whitespaces))
        if r == true {
            e.blocked = true
            e.likelyTypo = true
            e.active = false
        } else if r == false {
            e.typoChecked = true
        }
        return r
    }

    /// Only learned single words the user has not vouched for: never words added by hand or from
    /// dictation, words with `rejectionsToLearn` rejected automatic fixes, or words the user
    /// unblocked. Chinese/Japanese/Korean words are not checked.
    static func mayBlockAsTypo(_ e: VocabEntry) -> Bool {
        let word = e.text.trimmingCharacters(in: .whitespaces)
        return !e.blocked && !e.isPinned && !e.typoAllowed && e.rejections < VocabEntry.rejectionsToLearn
            && !word.isEmpty && !word.contains(where: \.isWhitespace) && !WordText.containsCJK(word)
            && !isNameForm(word)  // "Jai": a name kept over "Jail", not a slip
    }

    /// Checks every active word (`blockIfLikelyTypo`): words learned before the check existed, or
    /// while it was unavailable. Stops at the first unknown answer, like consolidation's spell check.
    public mutating func blockLikelyTypos(now: Date, _ check: (String) -> Bool?) {
        for k in entries.keys.sorted() {
            guard var e = entries[k], !e.typoChecked, e.computeActive(at: now) else { continue }
            switch Self.blockIfLikelyTypo(&e, check) {
            case true?, false?: entries[k] = e
            case nil: return
            default: break
            }
        }
    }
}
