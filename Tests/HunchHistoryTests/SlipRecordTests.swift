import Foundation
import HunchCore
import Testing
@testable import HunchHistory

// The personal slip list: three kept automatic fixes to a word make it a word the user often
// mistypes; typed forms kept twice are known slips; two clean rejections of a fix to it end it.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let field = FieldID(pid: 100, elementHash: 7, generation: 1)

private func keep(_ m: inout VocabularyModel, _ word: String, _ fix: String, _ at: Date) {
    m.apply(LearningEvent(field: field, kind: .fixKept(word: word, fix: fix)), now: at)
}

private func service() -> HistoryService {
    HistoryService(store: EncryptedHistoryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-slips-\(UUID().uuidString).bin"), keys: InMemoryKeyProvider()),
                   saveDelay: .seconds(60))
}

@Test func threeKeptFixesInAnyShapeMakeATroubleWord() {
    var m = VocabularyModel()
    keep(&m, "strenght", "strength", t0)
    keep(&m, "strentght", "strength", t0 + 60)
    #expect(m.troubleWords(now: t0 + 120).isEmpty)
    keep(&m, "strenght", "strength", t0 + 120)
    let words = m.troubleWords(now: t0 + 180)
    #expect(words == [TroubleWord(word: "strength", knownSlips: ["strenght"])])
    // The fix is not a learned word: it changes nothing else.
    #expect(m.entries.isEmpty)
}

@Test func onlyOneWordFixesAreKept() {
    var m = VocabularyModel()
    keep(&m, "therea res", "there are", t0)
    keep(&m, "stage2", "stage", t0)
    keep(&m, "same", "same", t0)
    #expect(m.slips.isEmpty)
}

@Test func twoCleanRejectionsEndATroubleWord() {
    var m = VocabularyModel()
    for i in 0..<3 { keep(&m, "stil", "still", t0 + Double(i)) }
    #expect(m.troubleWords(now: t0 + 10).map(\.word) == ["still"])
    m.apply(LearningEvent(field: field, kind: .slipFixRejected(fix: "still")), now: t0 + 20)
    #expect(m.troubleWords(now: t0 + 30).map(\.word) == ["still"])
    m.apply(LearningEvent(field: field, kind: .slipFixRejected(fix: "Still")), now: t0 + 40)
    #expect(m.troubleWords(now: t0 + 50).isEmpty)
}

@Test func aTroubleWordFadesWhenNoLongerMistyped() {
    var m = VocabularyModel()
    for i in 0..<3 { keep(&m, "aobut", "about", t0 + Double(i)) }
    #expect(!m.troubleWords(now: t0 + 30 * 86_400).isEmpty)
    #expect(m.troubleWords(now: t0 + 60 * 86_400).isEmpty)
    m.consolidate(now: t0 + 200 * 86_400)
    #expect(m.slips.isEmpty)
}

@Test func typedFormsStayBounded() {
    var m = VocabularyModel()
    for i in 0..<20 { keep(&m, "strength" + String(repeating: "x", count: i + 1), "strength", t0) }
    #expect(m.slips["strength"]?.typed.count == SlipRecord.maxTyped)
}

@Test func aBlockedWordIsNeverATroubleWord() throws {
    var m = VocabularyModel()
    _ = try m.block("still", now: t0)
    for i in 0..<3 { keep(&m, "stil", "still", t0 + Double(i)) }
    #expect(m.troubleWords(now: t0 + 10).isEmpty)
}

@Test func slipsRoundTripAndOldFilesStillDecode() throws {
    var m = VocabularyModel()
    for i in 0..<3 { keep(&m, "mroe", "more", t0 + Double(i)) }
    let decoded = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
    #expect(decoded.slips == m.slips)
    let old = try JSONDecoder().decode(VocabularyModel.self, from: Data(#"{"entries":{}}"#.utf8))
    #expect(old.slips.isEmpty)
}

@Test func serviceListsTroubleWordsAndDeleteForgetsThem() async throws {
    let svc = service()
    for i in 0..<3 { await svc.record(.fixKept(field: field, word: "tsage", fix: "stage"), at: t0 + Double(i)) }
    #expect(await svc.troubleWords(now: t0 + 10).map(\.word) == ["stage"])
    let info = try #require(await svc.entries(now: t0 + 10).first { $0.oftenMistyped })
    #expect(info.text == "stage")
    #expect(info.id == LearnedWordInfo.slipIDPrefix + "stage")
    #expect(info.positiveCount == 3)
    #expect(await svc.activeWords().isEmpty)  // never exempt from the typo check
    try await svc.delete(id: info.id)
    #expect(await svc.troubleWords(now: t0 + 20).isEmpty)
    try await svc.deleteAll()
    #expect(await svc.troubleWords(now: t0 + 20).isEmpty)
}
