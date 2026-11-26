import CryptoKit
import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gt-lw-\(UUID().uuidString)/history.bin")
}

private func learn(_ m: inout VocabularyModel, _ word: String, times: Int = 4, from start: Date = t0) {
    for i in 0..<times {
        m.apply(LearningEvent(field: FieldID(pid: 1, elementHash: i, generation: 1),
                              kind: .confirmed(words: [WordScore(text: word, logProb: -6)], context: [])),
                now: start + Double(i) * day)
    }
}

private func service(_ url: URL = tempURL(), keys: InMemoryKeyProvider = InMemoryKeyProvider()) -> HistoryService {
    HistoryService(store: EncryptedHistoryStore(url: url, keys: keys), saveDelay: .milliseconds(20))
}

private func seed(_ svc: HistoryService, _ word: String, times: Int = 4) async {
    let field = FieldID(pid: 9, elementHash: 1, generation: 1)
    for i in 0..<times {
        let now = t0 + Double(i) * day
        await svc.record(.suggestionShown(field: field, before: "We run", suggestion: " " + word,
                                          scores: [WordScore(text: " " + word, logProb: -7)]), at: now)
        await svc.record(.accepted(field: field, text: " " + word), at: now + 1)
        await svc.record(.focusLeft(field: field), at: now + 2)
    }
}

@Suite struct LearnedWordsModelTests {
    @Test func oldFormatEntriesDecodeWithDefaults() throws {
        var m = VocabularyModel()
        learn(&m, "Kubernetes")
        let data = try JSONEncoder().encode(m)
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(root["entries"] as? [String: [String: Any]])
        for k in entries.keys { entries[k]?["origin"] = nil; entries[k]?["blocked"] = nil }
        root["entries"] = entries
        let old = try JSONSerialization.data(withJSONObject: root)
        #expect(!String(decoding: old, as: UTF8.self).contains("origin"))
        let back = try JSONDecoder().decode(VocabularyModel.self, from: old)
        let e = try #require(back.entries["kubernetes"])
        #expect(e.origin == .learned)
        #expect(!e.blocked)
        #expect(e.active)
    }

    @Test func newFieldsRoundTrip() throws {
        var m = VocabularyModel()
        try m.addManual("Zorblax", now: t0)
        try m.block("Nope", now: t0)
        let back = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
        #expect(back.entries["zorblax"]?.origin == .manual)
        #expect(back.entries["nope"]?.blocked == true)   // persisted although it has no positives
    }

    @Test func dictationFixesArePinnedButNeverDemoteAddedWords() throws {
        var m = VocabularyModel()
        try m.addManual("Sinead", origin: .dictation, now: t0)
        #expect(m.entries["sinead"]?.origin == .dictation)
        #expect(m.entries["sinead"]?.active == true)
        #expect(m.entries["sinead"]?.isProtected == true)
        try m.addManual("Zorblax", now: t0)
        try m.addManual("Zorblax", origin: .dictation, now: t0)
        #expect(m.entries["zorblax"]?.origin == .manual)
        let back = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
        #expect(back.entries["sinead"]?.origin == .dictation)
    }

    @Test func validation() throws {
        var m = VocabularyModel()
        #expect(throws: LearnedWordError.empty) { try m.addManual("   ", now: t0) }
        #expect(throws: LearnedWordError.tooManyWords) { try m.addManual("one two three four", now: t0) }
        #expect(throws: LearnedWordError.looksSensitive) { try m.addManual("hunter42x", now: t0) }
        #expect(throws: LearnedWordError.looksSensitive) { try m.block("me@example.com", now: t0) }
        #expect(throws: LearnedWordError.tooLong) { try m.addManual(String(repeating: "a", count: 60), now: t0) }
        #expect(throws: LearnedWordError.notFound) { try m.delete(id: "ghost") }
        #expect(throws: LearnedWordError.notFound) { try m.rename(id: "ghost", to: "x y", now: t0) }
        #expect(m.entries.isEmpty)
        #expect(LearnedWordError.tooManyWords.errorDescription?.isEmpty == false)
        #expect(try m.addManual("  Foo   Bar ", now: t0) == "foo bar")
        #expect(m.entries["foo bar"]?.text == "Foo Bar")
    }

    @Test func renameMovesAndRespells() throws {
        var m = VocabularyModel()
        learn(&m, "Kubernets")
        let id = try m.rename(id: "kubernets", to: "Kubernetes", now: t0 + 10 * day)
        #expect(id == "kubernetes")
        #expect(m.entries["kubernets"] == nil)
        let e = try #require(m.entries["kubernetes"])
        #expect(e.text == "Kubernetes")
        #expect(e.positive == 4)
        #expect(e.active)
    }

    @Test func renameMergesIntoExistingEntry() throws {
        var m = VocabularyModel()
        learn(&m, "Kubernets", times: 2)
        learn(&m, "Kubernetes", times: 3, from: t0 + 5 * day)
        let a = try #require(m.entries["kubernets"]), b = try #require(m.entries["kubernetes"])
        let id = try m.rename(id: "kubernets", to: "Kubernetes", now: t0 + 9 * day)
        #expect(id == "kubernetes")
        #expect(m.entries.count == 1)
        let e = try #require(m.entries["kubernetes"])
        #expect(e.positive == a.positive + b.positive)
        #expect(e.days.count == Set(a.days + b.days).count)
        #expect(e.days.count <= VocabEntry.maxDays && e.fields.count <= VocabEntry.maxFields)
        #expect(e.posMass > b.posMass)
    }

    @Test func renameKeepsManualAndBlockedFlagsWhenMerging() throws {
        var m = VocabularyModel()
        try m.addManual("Alpha", now: t0)
        learn(&m, "Quuxify")
        try m.rename(id: "quuxify", to: "Alpha", now: t0)
        #expect(m.entries.count == 1)
        #expect(m.entries["alpha"]?.origin == .manual)
        try m.block("Gamma", now: t0)
        try m.rename(id: "alpha", to: "Gamma", now: t0)
        #expect(m.entries["gamma"]?.blocked == true)
        #expect(m.entries["gamma"]?.active == false)
    }

    @Test func deleteRemovesEntry() throws {
        var m = VocabularyModel()
        learn(&m, "Kubernetes")
        try m.delete(id: "kubernetes")
        #expect(m.entries.isEmpty)
    }

    @Test func manualEntriesAreActiveAtOnceAndSurviveMaintenance() throws {
        var m = VocabularyModel()
        m.capacity = 3
        try m.addManual("Zorblax", now: t0)
        let e = try #require(m.entries["zorblax"])
        #expect(e.active && e.origin == .manual && e.positive == 3)
        #expect(m.infos(now: t0).first?.status == .active)
        #expect((m.infos(now: t0).first?.strength ?? 0) > 0.5)
        // A year later, with many strong learned entries competing: still there, at the floor.
        for i in 0..<8 { learn(&m, "word\(i)x", from: t0 + 400 * day) }
        m.consolidate(now: t0 + 500 * day)
        let later = try #require(m.entries["zorblax"])
        #expect(later.active)
        let s = later.weight(at: t0 + 2000 * day)
        #expect(s > 0.2 && s < 0.35)
        #expect(m.entries.count <= max(3, 1 + 3))
    }

    @Test func blockedWordsAreNeverRelearnedOrReactivated() throws {
        var m = VocabularyModel()
        learn(&m, "Kubernetes")
        try m.setBlocked(id: "kubernetes", true, now: t0 + 5 * day)
        #expect(m.entries["kubernetes"]?.active == false)
        let before = try #require(m.entries["kubernetes"])
        learn(&m, "Kubernetes", times: 5, from: t0 + 10 * day)
        m.recordNegative(text: "Kubernetes", amount: 1, contextKey: nil, now: t0 + 11 * day)
        #expect(m.entries["kubernetes"] == before)
        m.consolidate(now: t0 + 20 * day)
        #expect(m.entries["kubernetes"]?.active == false)
        // A brand-new blocked word is not created by observations either.
        try m.block("Zork", now: t0)
        learn(&m, "Zork")
        #expect(m.entries["zork"]?.positive == 0)
        // Unblocking restores the learned history; a bare block marker disappears.
        try m.setBlocked(id: "kubernetes", false, now: t0 + 21 * day)
        #expect(m.entries["kubernetes"]?.active == true)
        try m.setBlocked(id: "zork", false, now: t0)
        #expect(m.entries["zork"] == nil)
    }

    @Test func protectedEntriesSurviveCapacityPruning() throws {
        var m = VocabularyModel()
        m.capacity = 2
        try m.addManual("Zorblax", now: t0)
        try m.block("Nope", now: t0)
        for i in 0..<5 { learn(&m, "learned\(i)x", times: 1, from: t0 + Double(i) * day) }
        m.prune(now: t0 + 6 * day)
        #expect(m.entries["zorblax"] != nil && m.entries["nope"] != nil)
    }

    @Test func infosIncludeOneOffsAsLearning() throws {
        var m = VocabularyModel()
        learn(&m, "Quuxlet", times: 1)
        learn(&m, "Kubernetes")
        let infos = m.infos(now: t0 + 5 * day)
        #expect(infos.first { $0.id == "quuxlet" }?.status == .learning)
        #expect(infos.first { $0.id == "kubernetes" }?.status == .active)
        #expect(infos.first?.id == "kubernetes")
    }
}

@Suite struct LearnedWordsServiceTests {
    @Test func entriesRenameDeleteThroughTheService() async throws {
        let svc = service()
        await seed(svc, "Terraform")
        let list = await svc.entries(now: t0 + 5 * day)
        let item = try #require(list.first)
        #expect(item.id == "terraform" && item.status == .active && item.origin == .learned)
        #expect(item.positiveCount >= 3 && item.strength > 0)
        let id = try await svc.rename(id: "terraform", to: "TerraForm", now: t0 + 6 * day)
        #expect(id == "terraform")
        #expect(await svc.entries(now: t0 + 6 * day).first?.text == "TerraForm")
        try await svc.delete(id: id)
        #expect(await svc.entries().isEmpty)
        await #expect(throws: LearnedWordError.notFound) { try await svc.delete(id: id) }
    }

    @Test func mutationsPersistOnFlush() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keys = InMemoryKeyProvider()
        let svc = HistoryService(store: EncryptedHistoryStore(url: url, keys: keys), saveDelay: .seconds(3600))
        try await svc.add(text: "Zorblax", now: t0)
        try await svc.block(text: "Quuxlet", now: t0)
        await svc.flush()
        let reopened = service(url, keys: keys)
        let list = await reopened.entries(now: t0)
        #expect(list.map(\.id).sorted() == ["quuxlet", "zorblax"])
        #expect(list.first { $0.id == "zorblax" }?.status == .active)
        #expect(list.first { $0.id == "quuxlet" }?.status == .blocked)
    }

    @Test func blockedWordsAreExcludedFromBiasAndActiveWordsButReturnedAsAvoid() async throws {
        let svc = service()
        await seed(svc, "Terraform")
        await seed(svc, "Kubernetes")
        let now = t0 + 5 * day
        #expect(await svc.activeWords().contains("terraform"))
        let withBoth = await svc.bias(for: "We run ", strength: 1, now: now)
        #expect(withBoth.entries.contains { $0.text.contains("Terraform") })
        #expect(withBoth.avoid.isEmpty)

        try await svc.setBlocked(id: "terraform", true, now: now)
        #expect(!(await svc.activeWords()).contains("terraform"))
        let after = await svc.bias(for: "We run ", strength: 1, now: now)
        #expect(!after.entries.contains { $0.text.contains("Terraform") })
        #expect(after.entries.contains { $0.text.contains("Kubernetes") })
        #expect(after.avoid == ["Terraform"])
        // Also when the personalization slider is off.
        let off = await svc.bias(for: "We run ", strength: 0, now: now)
        #expect(off.avoid == ["Terraform"] && off.entries.isEmpty && !off.isEmpty)

        // Further observations cannot bring it back.
        await seed(svc, "Terraform", times: 5)
        #expect(await svc.entries(now: now).first { $0.id == "terraform" }?.status == .blocked)
        #expect(!(await svc.bias(for: "We run ", strength: 1, now: now)).entries.contains { $0.text.contains("Terraform") })

        // Block a word that is not in the list yet.
        try await svc.block(text: "Quuxlet", now: now)
        #expect(await svc.bias(for: "x", strength: 0, now: now).avoid.sorted() == ["Quuxlet", "Terraform"])
        try await svc.setBlocked(id: "terraform", false, now: now)
        #expect(await svc.bias(for: "x", strength: 0, now: now + 1).avoid == ["Quuxlet"])
    }

    @Test func manualWordAppearsInBiasImmediately() async throws {
        let svc = service()
        try await svc.add(text: "Zorblax", now: t0)
        #expect(await svc.activeWords().contains("zorblax"))
        let b = await svc.bias(for: "We use ", strength: 1, now: t0)
        #expect(b.entries.contains { $0.text.contains("Zorblax") })
    }

    @Test func readOnlyStoreRefusesEdits() async throws {
        struct Boom: Error {}
        struct Flaky: KeyProviding {
            func loadKey() throws -> SymmetricKey { throw Boom() }
            func createKey() throws -> SymmetricKey { throw Boom() }
            func deleteKey() throws { throw Boom() }
        }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = VocabularyModel()
        learn(&m, "Kubernetes")
        try EncryptedHistoryStore(url: url, keys: InMemoryKeyProvider()).save(m)
        let svc = HistoryService(store: EncryptedHistoryStore(url: url, keys: Flaky()), saveDelay: .milliseconds(10))
        await #expect(throws: LearnedWordError.readOnlyStore) { try await svc.add(text: "Foo") }
        await #expect(throws: LearnedWordError.readOnlyStore) { try await svc.block(text: "Foo") }
        await #expect(throws: LearnedWordError.readOnlyStore) { try await svc.delete(id: "foo") }
        #expect(await svc.entries().isEmpty)
    }
}
