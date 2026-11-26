import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let fieldA = FieldID(pid: 100, elementHash: 7, generation: 1)
private let fieldB = FieldID(pid: 100, elementHash: 8, generation: 1)

private func skip(_ m: inout VocabularyModel, _ f: FieldID, _ word: String, _ at: Date) {
    m.apply(LearningEvent(field: f, kind: .correctionSkipped(word: word)), now: at)
}

@Test func threeSkipsOneDayOneFieldNotActive() {
    var m = VocabularyModel()
    for i in 0..<3 { skip(&m, fieldA, "Zorblax", t0 + Double(i) * 60) }
    #expect(m.entries["zorblax"]?.positive == 3)
    #expect(m.entries["zorblax"]?.active == false)
}

@Test func threeSkipsAcrossDaysActive() {
    var m = VocabularyModel()
    skip(&m, fieldA, "Zorblax", t0)
    skip(&m, fieldA, "Zorblax", t0 + 60)
    skip(&m, fieldA, "Zorblax", t0 + 2 * day)
    #expect(m.entries["zorblax"]?.active == true)
}

@Test func threeSkipsAcrossFieldsActive() {
    var m = VocabularyModel()
    skip(&m, fieldA, "Zorblax", t0)
    skip(&m, fieldB, "Zorblax", t0 + 60)
    skip(&m, fieldB, "Zorblax", t0 + 120)
    #expect(m.entries["zorblax"]?.active == true)
}

@Test func acceptedFixAddsNegative() {
    var m = VocabularyModel()
    skip(&m, fieldA, "Zorblax", t0)
    skip(&m, fieldA, "Zorblax", t0 + 2 * day)
    skip(&m, fieldA, "Zorblax", t0 + 3 * day)
    #expect(m.entries["zorblax"]?.active == true)
    for i in 0..<4 {
        m.apply(LearningEvent(field: fieldA, kind: .correctionAccepted(word: "zorblax")), now: t0 + 4 * day + Double(i))
    }
    #expect(m.entries["zorblax"]?.negative == 4)
    // Unknown words stay unknown.
    m.apply(LearningEvent(field: fieldA, kind: .correctionAccepted(word: "nothere")), now: t0)
    #expect(m.entries["nothere"] == nil)
}

@Test func skipOfBlockedWordDoesNothing() throws {
    var m = VocabularyModel()
    _ = try m.block("Zorblax", now: t0)
    for i in 0..<3 { skip(&m, fieldA, "Zorblax", t0 + Double(i) * day) }
    #expect(m.entries["zorblax"]?.positive == 0)
    #expect(m.entries["zorblax"]?.active == false)
}

@Test func serviceRecordsCorrectionSkips() async {
    let svc = HistoryService(store: EncryptedHistoryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-skip-\(UUID().uuidString).bin"), keys: InMemoryKeyProvider()),
                             saveDelay: .seconds(60))
    await svc.record(.correctionSkipped(field: fieldA, word: "zorblax"), at: t0)
    await svc.record(.correctionSkipped(field: fieldB, word: "zorblax"), at: t0 + 1)
    await svc.record(.correctionSkipped(field: fieldB, word: "zorblax"), at: t0 + 2)
    #expect(await svc.entryCount == 1)
    #expect(await svc.activeWords().contains("zorblax"))
    await svc.record(.correctionAccepted(field: fieldA, word: "zorblax"), at: t0 + 3)
    #expect(await svc.entryCount == 1)
}
