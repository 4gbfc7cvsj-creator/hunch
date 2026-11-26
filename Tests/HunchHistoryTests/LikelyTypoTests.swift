import Foundation
import HunchCore
import Testing
@testable import HunchHistory

// Words kept over fixes that look like the user's own typos ("stil", "teh") are blocked as
// potential typos instead of learned; the user can unblock them.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let fieldA = FieldID(pid: 100, elementHash: 7, generation: 1)
private let fieldB = FieldID(pid: 100, elementHash: 8, generation: 1)
private let typos: Set<String> = ["stil", "teh", "doesn"]
private let check: @Sendable (String) -> Bool? = { typos.contains($0.lowercased()) }

private func skip(_ m: inout VocabularyModel, _ f: FieldID, _ word: String, _ at: Date) {
    m.apply(LearningEvent(field: f, kind: .correctionSkipped(word: word)), now: at, likelyTypo: check)
}

private func reject(_ m: inout VocabularyModel, _ f: FieldID, _ word: String, _ at: Date) {
    m.apply(LearningEvent(field: f, kind: .fixRejected(word: word)), now: at, likelyTypo: check)
}

/// Three skips over two fields: enough to become active.
private func threeSkips(_ m: inout VocabularyModel, _ word: String) {
    skip(&m, fieldA, word, t0)
    skip(&m, fieldB, word, t0 + 1)
    skip(&m, fieldB, word, t0 + 2)
}

@Test func skippedTypoIsBlockedInsteadOfActive() {
    var m = VocabularyModel()
    threeSkips(&m, "stil")
    let e = m.entries["stil"]
    #expect(e?.active == false)
    #expect(e?.blocked == true)
    #expect(e?.likelyTypo == true)
    #expect(!HistoryService.places(of: m).words.contains("stil"))
    // Blocked words are never learned further.
    skip(&m, fieldA, "stil", t0 + 3)
    #expect(m.entries["stil"]?.positive == 3)
}

@Test func skippedTermStillLearned() {
    var m = VocabularyModel()
    threeSkips(&m, "cyberware")
    #expect(m.entries["cyberware"]?.active == true)
    #expect(m.entries["cyberware"]?.likelyTypo == false)
}

@Test func unknownAnswerLeavesWordActive() {
    var m = VocabularyModel()
    for (i, f) in [fieldA, fieldB, fieldB].enumerated() {
        m.apply(LearningEvent(field: f, kind: .correctionSkipped(word: "stil")), now: t0 + Double(i),
                likelyTypo: { _ in nil })
    }
    #expect(m.entries["stil"]?.active == true)
    #expect(m.entries["stil"]?.blocked == false)
}

@Test func twoRejectionsVouchForTheWord() {
    var m = VocabularyModel()
    reject(&m, fieldA, "teh", t0)
    reject(&m, fieldB, "teh", t0 + 1)
    #expect(m.entries["teh"]?.active == true)
    #expect(m.entries["teh"]?.blocked == false)
}

@Test func oneRejectionPlusSkipsIsChecked() {
    var m = VocabularyModel()
    skip(&m, fieldA, "teh", t0)
    skip(&m, fieldB, "teh", t0 + 1)
    reject(&m, fieldB, "teh", t0 + 2)
    #expect(m.entries["teh"]?.active == false)
    #expect(m.entries["teh"]?.likelyTypo == true)
}

@Test func addedByHandIsNeverBlockedAsTypo() throws {
    var m = VocabularyModel()
    _ = try m.addManual("teh", now: t0)
    m.consolidate(now: t0 + day, likelyTypo: check)
    #expect(m.entries["teh"]?.active == true)
    #expect(m.entries["teh"]?.blocked == false)
}

@Test func tidyUpBlocksActiveTyposAndKeepsThem() {
    var m = VocabularyModel()
    // Learned before the check existed: active, typed often ("doesn" has no skips).
    for i in 0..<3 {
        m.recordPositive(text: "doesn", credit: 1, contextKey: nil, fieldKey: 1,
                         now: t0 + Double(i) * day)
        m.recordPositive(text: "wolvenkit", credit: 1, contextKey: nil, fieldKey: 1,
                         now: t0 + Double(i) * day)
    }
    #expect(m.entries["doesn"]?.active == true)
    // The spell check alone would drop "doesn" as a misspelling; the typo check keeps it, blocked.
    m.consolidate(now: t0 + 3 * day, spelling: { $0 == "doesn" ? true : false }, likelyTypo: check)
    #expect(m.entries["doesn"]?.blocked == true)
    #expect(m.entries["doesn"]?.likelyTypo == true)
    #expect(m.entries["wolvenkit"]?.active == true)
}

@Test func tidyUpStopsAtFirstUnknownAnswer() {
    var m = VocabularyModel()
    for w in ["aaa", "stil"] {
        m.apply(LearningEvent(field: fieldA, kind: .correctionSkipped(word: w)), now: t0)
        m.apply(LearningEvent(field: fieldB, kind: .correctionSkipped(word: w)), now: t0 + 1)
        m.apply(LearningEvent(field: fieldB, kind: .correctionSkipped(word: w)), now: t0 + 2)
    }
    m.blockLikelyTypos(now: t0 + 3) { $0 == "aaa" ? nil : typos.contains($0) }
    #expect(m.entries["stil"]?.blocked == false)   // "aaa" came first and had no answer
    m.blockLikelyTypos(now: t0 + 3, check)
    #expect(m.entries["stil"]?.blocked == true)
}

@Test func unblockingAllowsTheWordForGood() throws {
    var m = VocabularyModel()
    threeSkips(&m, "stil")
    try m.setBlocked(id: "stil", false, now: t0 + 10)
    #expect(m.entries["stil"]?.active == true)
    #expect(m.entries["stil"]?.likelyTypo == false)
    #expect(m.entries["stil"]?.typoAllowed == true)
    m.consolidate(now: t0 + day, likelyTypo: check)
    #expect(m.entries["stil"]?.active == true)
    #expect(m.entries["stil"]?.blocked == false)
    // Blocking it by hand later is a plain block.
    try m.setBlocked(id: "stil", true, now: t0 + day + 1)
    #expect(m.entries["stil"]?.likelyTypo == false)
}

@Test func addingABlockedTypoByHandAllowsIt() throws {
    var m = VocabularyModel()
    threeSkips(&m, "teh")
    _ = try m.addManual("teh", now: t0 + 10)
    #expect(m.entries["teh"]?.active == true)
    #expect(m.entries["teh"]?.typoAllowed == true)
    #expect(m.entries["teh"]?.likelyTypo == false)
}

@Test func listShowsPotentialTyposAsBlocked() {
    var m = VocabularyModel()
    threeSkips(&m, "stil")
    threeSkips(&m, "gemma")
    let infos = m.infos(now: t0 + 10)
    let stil = infos.first { $0.id == "stil" }
    #expect(stil?.status == .blocked)
    #expect(stil?.likelyTypo == true)
    #expect(infos.first { $0.id == "gemma" }?.likelyTypo == false)
}

@Test func flagsSurviveSaving() throws {
    var m = VocabularyModel()
    threeSkips(&m, "stil")
    threeSkips(&m, "teh")
    try m.setBlocked(id: "teh", false, now: t0 + 10)
    let back = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
    #expect(back.entries["stil"]?.likelyTypo == true)
    #expect(back.entries["stil"]?.blocked == true)
    #expect(back.entries["teh"]?.typoAllowed == true)
}

@Test func serviceBlocksSkippedTypo() async {
    let svc = HistoryService(store: EncryptedHistoryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-typo-\(UUID().uuidString).bin"), keys: InMemoryKeyProvider()),
                             saveDelay: .seconds(60))
    await svc.setLikelyTypo(check)
    for (i, f) in [fieldA, fieldB, fieldB].enumerated() {
        await svc.record(.correctionSkipped(field: f, word: "teh"), at: t0 + Double(i))
        await svc.record(.correctionSkipped(field: f, word: "zorblax"), at: t0 + Double(i))
    }
    #expect(!(await svc.activeWords().contains("teh")))
    #expect(await svc.activeWords().contains("zorblax"))
    #expect(await svc.entries(now: t0 + 5).first { $0.id == "teh" }?.likelyTypo == true)
}

@Test func nameFormIsNeverBlockedAsTypo() {
    // "Stil" typed like a name: a name kept over a fix ("Jai" over "Jail") is not a slip.
    var m = VocabularyModel()
    threeSkips(&m, "Stil")
    #expect(m.entries["stil"]?.blocked == false)
    #expect(m.entries["stil"]?.active == true)
}

@Test func rejectedFixesLiftALikelyTypoBlock() {
    var m = VocabularyModel()
    threeSkips(&m, "stil")
    #expect(m.entries["stil"]?.likelyTypo == true)
    // The user keeps rejecting the fix: two rejections vouch for the word, as before a block.
    reject(&m, fieldA, "stil", t0 + 10)
    #expect(m.entries["stil"]?.blocked == true)
    reject(&m, fieldA, "stil", t0 + 11)
    let e = m.entries["stil"]
    #expect(e?.blocked == false)
    #expect(e?.likelyTypo == false)
    #expect(e?.typoAllowed == true)
}

@Test func rejectionsNeverLiftTheUsersOwnBlock() {
    var m = VocabularyModel()
    threeSkips(&m, "cyberware")
    m.entries["cyberware"]?.blocked = true
    for i in 0..<3 { reject(&m, fieldA, "cyberware", t0 + 10 + Double(i)) }
    #expect(m.entries["cyberware"]?.blocked == true)
}

@Test func mergeKeepsTheUsersBlockTheirs() {
    var mine = VocabEntry(text: "Stil", now: t0)
    mine.blocked = true
    var guessed = VocabEntry(text: "stil", now: t0)
    guessed.blocked = true
    guessed.likelyTypo = true
    mine.merge(guessed)
    #expect(mine.blocked == true)
    #expect(mine.likelyTypo == false)
}

@Test func consolidationAsksOncePerWord() {
    var m = VocabularyModel()
    threeSkips(&m, "cyberware")
    let calls = Counter()
    m.blockLikelyTypos(now: t0 + 5) { _ in calls.bump(); return false }
    m.blockLikelyTypos(now: t0 + 6) { _ in calls.bump(); return false }
    #expect(calls.value == 0 || calls.value == 1)
    #expect(m.entries["cyberware"]?.typoChecked == true)
}

private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}
