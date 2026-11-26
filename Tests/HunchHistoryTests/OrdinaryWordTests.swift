import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let scorer = VocabularyScorer()

private func typed(_ m: inout VocabularyModel, _ word: String, times: Int = 3,
                   spelling: (@Sendable (String) -> Bool?)? = nil) {
    for i in 0..<times {
        m.apply(LearningEvent(field: FieldID(pid: 1, elementHash: i, generation: 1),
                              kind: .typedOver(context: [], suggested: "x", typed: word)),
                now: t0 + Double(i) * day, spelling: spelling)
    }
}

private func entry(_ text: String, positive: Int = 4, skips: Int = 0, active: Bool = false,
                   origin: VocabEntry.Origin = .learned, blocked: Bool = false) -> VocabEntry {
    var e = VocabEntry(text: text, now: t0)
    e.positive = positive; e.posMass = Float(positive); e.skips = skips; e.active = active
    e.origin = origin; e.blocked = blocked
    e.days = [1, 2]
    return e
}

@Test func frequentWordsAreFilteredButUncommonOnesAreNot() {
    for w in ["apps", "messages", "column", "forget", "dont"] {
        #expect(scorer.candidates(typed: w, context: []).isEmpty, "\(w)")
    }
    for w in ["kubernetes", "figma"] {
        #expect(scorer.candidates(typed: w, context: []).map(\.text) == [w])
    }
}

@Test func phraseNeedsAnUncommonWordAndDampsTheCommonOnes() {
    let allCommon = [WordScore(text: " forget", logProb: -9), WordScore(text: " messages", logProb: -9)]
    #expect(scorer.candidates(words: allCommon, context: []).isEmpty)
    let mixed = [WordScore(text: " forget", logProb: -9), WordScore(text: " kubernetes", logProb: -9)]
    let c = scorer.candidates(words: mixed, context: [])
    #expect(c.map(\.text).sorted() == ["forget kubernetes", "kubernetes"])
    #expect(c.first { $0.text == "kubernetes" }?.credit == 1)
    #expect(c.first { $0.text == "forget kubernetes" }?.credit == 1)   // max over the words
}

@Test func misspelledAndUnknownWordsAreNotLearnedFromTyping() {
    var m = VocabularyModel()
    typed(&m, "zorblax", spelling: { _ in true })
    typed(&m, "quuxify", spelling: { _ in nil })
    typed(&m, "frobnitz", spelling: { _ in false })
    #expect(m.entries["zorblax"] == nil)
    #expect(m.entries["quuxify"] == nil)
    #expect(m.entries["frobnitz"]?.positive == 3)
    // A phrase is dropped when any of its words is misspelled.
    var p = VocabularyModel()
    let words = [WordScore(text: " frobnitz", logProb: -9), WordScore(text: " zorblax", logProb: -9)]
    p.apply(LearningEvent(field: FieldID(pid: 1, elementHash: 1, generation: 1),
                          kind: .confirmed(words: words, context: [])), now: t0,
            spelling: { $0 == "zorblax" ? true : false })
    #expect(p.entries.keys.sorted() == ["frobnitz"])
}

@Test func skippedCorrectionIsLearnedDespiteMisspellingAndCounted() {
    var m = VocabularyModel()
    for i in 0..<2 {
        m.apply(LearningEvent(field: FieldID(pid: 1, elementHash: 1, generation: 1),
                              kind: .correctionSkipped(word: "Forget")), now: t0 + Double(i), spelling: { _ in true })
    }
    #expect(m.entries["forget"]?.positive == 2)
    #expect(m.entries["forget"]?.skips == 2)
}

@Test func consolidateDropsAccidentalEntriesOnly() {
    var m = VocabularyModel()
    m.entries["forget"] = entry("forget", active: true)
    m.entries["apps"] = entry("apps")
    m.entries["forget messages"] = entry("forget messages")
    m.entries["dnot"] = entry("dnot", active: true)
    m.entries["kubernetes"] = entry("kubernetes")
    m.entries["skipped"] = entry("skipped", skips: 1)
    m.entries["column"] = entry("column", skips: 2)
    m.entries["added"] = entry("added", origin: .manual)
    m.entries["blockedword"] = entry("blockedword", blocked: true)
    m.entries["messages"] = entry("messages", origin: .manual)
    m.consolidate(now: t0 + day) { w in
        switch w { case "dnot", "skipped", "added", "blockedword": true; default: false }
    }
    #expect(Set(m.entries.keys) == ["kubernetes", "skipped", "column", "added", "blockedword", "messages"])
}

@Test func consolidateKeepsWordsWhenSpellingIsUnknown() {
    var m = VocabularyModel()
    m.entries["unsure"] = entry("unsure")
    m.consolidate(now: t0 + day) { _ in nil }
    #expect(Set(m.entries.keys) == ["unsure"])
}

@Test func oldEntriesDecodeWithZeroSkips() throws {
    let json = #"{"text":"Zed","lastSeen":0}"#
    let e = try JSONDecoder().decode(VocabEntry.self, from: Data(json.utf8))
    #expect(e.skips == 0)
    var withSkips = e
    withSkips.skips = 3
    let back = try JSONDecoder().decode(VocabEntry.self, from: JSONEncoder().encode(withSkips))
    #expect(back.skips == 3)
}

@Test func serviceSkipsMisspelledTypingButNotSkippedCorrections() async throws {
    let svc = HistoryService(store: EncryptedHistoryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-\(UUID().uuidString).bin"), keys: InMemoryKeyProvider()),
                             saveDelay: .seconds(3600))
    await svc.setSpelling { _ in true }
    let f = FieldID(pid: 1, elementHash: 1, generation: 1)
    await svc.record(.correctionSkipped(field: f, word: "zorblax"), at: t0)
    #expect(await svc.totalMass(of: "zorblax") > 0)
}
