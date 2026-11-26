import Foundation
import HunchCore
import Testing
@testable import HunchHistory

// Clean rejections of an automatic fix (`fixRejected`): two make the word active, so it is exempt
// from the typo check in every field and app; deleting it from Learned words brings the fix back.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let mailField = FieldID(pid: 100, elementHash: 7, generation: 1)
private let chatField = FieldID(pid: 200, elementHash: 3, generation: 1)

private func reject(_ m: inout VocabularyModel, _ f: FieldID, _ word: String, _ at: Date) {
    m.apply(LearningEvent(field: f, kind: .fixRejected(word: word)), now: at)
}

private func service() -> HistoryService {
    HistoryService(store: EncryptedHistoryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-reject-\(UUID().uuidString).bin"), keys: InMemoryKeyProvider()),
                   saveDelay: .seconds(60))
}

@Test func oneCleanRejectionIsNotEnough() {
    var m = VocabularyModel()
    reject(&m, mailField, "csv", t0)
    #expect(m.entries["csv"]?.rejections == 1)
    #expect(m.entries["csv"]?.skips == 1)
    #expect(m.entries["csv"]?.active == false)
}

@Test func twoCleanRejectionsLearnTheWord() {
    var m = VocabularyModel()
    reject(&m, mailField, "csv", t0)
    reject(&m, chatField, "csv", t0 + 30)
    #expect(m.entries["csv"]?.active == true)
}

@Test func twoRejectionsSameFieldSameDayAlsoLearn() {
    // Unlike plain skips (3 over 2 days or 2 fields): a clean rejection is deliberate.
    var m = VocabularyModel()
    reject(&m, mailField, "coworking", t0)
    reject(&m, mailField, "coworking", t0 + 30)
    #expect(m.entries["coworking"]?.active == true)
}

@Test func rejectionsAndSkipsAddUp() {
    var m = VocabularyModel()
    m.apply(LearningEvent(field: mailField, kind: .correctionSkipped(word: "webhook")), now: t0)
    m.apply(LearningEvent(field: chatField, kind: .correctionSkipped(word: "webhook")), now: t0 + 1)
    reject(&m, chatField, "webhook", t0 + 2)
    #expect(m.entries["webhook"]?.rejections == 1)
    #expect(m.entries["webhook"]?.active == true)  // 3 over 2 fields
}

@Test func rejectionOfBlockedWordDoesNothing() throws {
    var m = VocabularyModel()
    _ = try m.block("csv", now: t0)
    reject(&m, mailField, "csv", t0)
    reject(&m, chatField, "csv", t0 + 1)
    #expect(m.entries["csv"]?.rejections == 0)
    #expect(m.entries["csv"]?.active == false)
}

@Test func oneRejectionIsSavedAndRoundTrips() throws {
    var m = VocabularyModel()
    reject(&m, mailField, "csv", t0)
    let decoded = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
    #expect(decoded.entries["csv"]?.rejections == 1)
}

@Test func serviceLearnsAcrossAppsAndDeleteBringsTheFixBack() async throws {
    let svc = service()
    await svc.record(.textChanged(field: mailField, before: "Send me the ", appKey: "com.example.mail"), at: t0)
    await svc.record(.fixRejected(field: mailField, word: "csv"), at: t0 + 1)
    #expect(await !svc.activeWords().contains("csv"))
    await svc.record(.textChanged(field: chatField, before: "the ", appKey: "com.example.chat"), at: t0 + 2)
    await svc.record(.fixRejected(field: chatField, word: "csv"), at: t0 + 3)
    #expect(await svc.activeWords().contains("csv"))
    let info = try #require(await svc.entries(now: t0 + 4).first { $0.id == "csv" })
    #expect(info.status == .active)
    #expect(info.keptOverFix)
    try await svc.delete(id: "csv")
    #expect(await !svc.activeWords().contains("csv"))
}
