import Foundation

/// A word Hunch has fixed automatically for the user and they kept the fix: how often, and how
/// they typed it. Enough kept fixes make it a trouble word (`TroubleWord`). Counters and a few typed
/// forms only; mass decays with the vocabulary's 30-day half-life.
public struct SlipRecord: Codable, Sendable, Equatable {
    /// The fix as written (most recent casing).
    public var text: String
    public var kept: Int = 0
    /// Clean rejections of an automatic fix to this word (`FixRejectionWatch`).
    public var rejected: Int = 0
    /// Kept fixes, decayed from `asOf`.
    public var mass: Float = 0
    public var asOf: Date
    public var lastSeen: Date
    /// Lowercased typed form → times kept, at most `maxTyped`.
    public var typed: [String: Int] = [:]

    static let maxTyped = 8
    /// Kept fixes that make a trouble word.
    static let keptToLearn = 3
    /// Clean rejections of a fix to it that end a trouble word.
    static let rejectedToForget = 2
    /// Decayed kept mass below which it is no longer a trouble word (≈ 50 days after the third).
    static let minMass: Float = 1
    /// Times a typed form must have been kept to count as a known slip of it.
    static let exactRepeats = 2

    init(text: String, now: Date) {
        self.text = text
        asOf = now
        lastSeen = now
    }

    func decayedMass(at now: Date) -> Float {
        let days = now.timeIntervalSince(asOf) / 86_400
        guard days > 0 else { return mass }
        return mass * Float(pow(0.5, days / VocabEntry.halfLifeDays))
    }

    public func isTrouble(at now: Date) -> Bool {
        kept >= Self.keptToLearn && rejected < Self.rejectedToForget && decayedMass(at: now) >= Self.minMass
    }

    mutating func rebase(to now: Date) {
        mass = decayedMass(at: now)
        asOf = now
    }
}

/// A word the user often mistypes, for the autocorrect slip profile (`HunchText.SlipProfile`).
public struct TroubleWord: Sendable, Equatable {
    public var word: String
    /// Typed forms the user kept the fix of more than once (lowercased).
    public var knownSlips: Set<String>
}

extension VocabularyModel {
    static let maxSlipRecords = 400

    /// Key for a fix: a single word of letters (an apostrophe allowed), lowercased; nil otherwise.
    static func slipKey(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxEditWordLength,
              t.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        return t.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// The user typed `word` and kept the automatic fix `fix`.
    mutating func recordKeptFix(word: String, fix: String, now: Date) {
        guard let k = Self.slipKey(fix), let typed = Self.slipKey(word), typed != k,
              entries[Self.key(fix)]?.blocked != true else { return }
        var r = slips[k] ?? SlipRecord(text: fix, now: now)
        r.rebase(to: now)
        r.text = fix
        r.lastSeen = now
        r.kept += 1
        r.mass += 1
        r.typed[typed, default: 0] += 1
        while r.typed.count > SlipRecord.maxTyped,
              let low = r.typed.min(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key {
            r.typed[low] = nil
        }
        slips[k] = r
        if slips.count > Self.maxSlipRecords { pruneSlips(now: now) }
    }

    /// The user cleanly rejected an automatic fix to `fix`.
    mutating func recordRejectedFix(_ fix: String, now: Date) {
        guard let k = Self.slipKey(fix), var r = slips[k] else { return }
        r.rejected += 1
        r.lastSeen = now
        slips[k] = r
    }

    /// Trouble words now, with their known slips.
    func troubleWords(now: Date) -> [TroubleWord] {
        slips.compactMap { (k, r) in
            guard r.isTrouble(at: now), entries[Self.key(r.text)]?.blocked != true else { return nil }
            return TroubleWord(word: k, knownSlips: Set(r.typed.filter { $0.value >= SlipRecord.exactRepeats }.keys))
        }.sorted { $0.word < $1.word }
    }

    /// Drops dead records (decayed to nothing), then the weakest past capacity.
    mutating func pruneSlips(now: Date) {
        slips = slips.filter { $0.value.decayedMass(at: now) >= 0.05 }
        guard slips.count > Self.maxSlipRecords else { return }
        let doomed = slips.sorted { $0.value.decayedMass(at: now) < $1.value.decayedMass(at: now) }
            .prefix(slips.count - Self.maxSlipRecords)
        for (k, _) in doomed { slips[k] = nil }
    }
}
