import CryptoKit
import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let fld = FieldID(pid: 100, elementHash: 7, generation: 1)
private let scorer = VocabularyScorer()

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gt-fix-\(UUID().uuidString)/history.bin")
}

private func strongModel() -> VocabularyModel {
    var m = VocabularyModel()
    for i in 0..<4 {
        m.apply(LearningEvent(field: FieldID(pid: 1, elementHash: i, generation: 1),
                              kind: .confirmed(words: [WordScore(text: "Kubernetes", logProb: -6)], context: [])),
                now: t0 + Double(i) * day)
    }
    return m
}

private struct FlakyKeys: KeyProviding {
    struct Boom: Error {}
    func loadKey() throws -> SymmetricKey { throw Boom() }
    func createKey() throws -> SymmetricKey { throw Boom() }
    func deleteKey() throws { throw Boom() }
}

// MARK: 1. Load state and read-only

@Test func loadStateDistinguishesCases() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let keys = InMemoryKeyProvider()
    let store = EncryptedHistoryStore(url: url, keys: keys)
    #expect(store.loadResult().state == .noFile)
    try store.save(strongModel())
    #expect(store.loadResult().state == .loaded)
    try keys.deleteKey()
    #expect(store.loadResult().state == .discardedUnreadable)      // key gone: unreadable forever
    #expect(!store.loadResult().state.isReadOnly)
    try Data("HNH1junk-junk-junk".utf8).write(to: url)
    #expect(EncryptedHistoryStore(url: url, keys: InMemoryKeyProvider(key: SymmetricKey(size: .bits256)))
        .loadResult().state == .discardedUnreadable)
}

@Test func keychainErrorMakesStoreReadOnlyAndNeverOverwrites() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let good = InMemoryKeyProvider()
    try EncryptedHistoryStore(url: url, keys: good).save(strongModel())
    let original = try Data(contentsOf: url)

    let flaky = EncryptedHistoryStore(url: url, keys: FlakyKeys())
    let r = flaky.loadResult()
    #expect(r.state == .readOnlyKeyUnavailable)
    #expect(r.state.isReadOnly)
    #expect(r.model.entries.isEmpty)
    #expect(throws: FlakyKeys.Boom.self) { try flaky.save(VocabularyModel()) }   // save itself refuses too

    let svc = HistoryService(store: flaky, saveDelay: .milliseconds(20))
    for d in 0..<3 {
        let now = t0 + Double(d) * day
        await svc.record(.suggestionShown(field: fld, before: "We run", suggestion: " Terraform",
                                          scores: [WordScore(text: " Terraform", logProb: -7)]), at: now)
        await svc.record(.accepted(field: fld, text: " Terraform"), at: now + 1)
        await svc.record(.focusLeft(field: fld), at: now + 2)
    }
    #expect(await svc.loadState == .readOnlyKeyUnavailable)
    #expect(await svc.entryCount == 1)           // still learns in memory
    await svc.flush()
    try await Task.sleep(for: .milliseconds(100))
    #expect(try Data(contentsOf: url) == original)   // untouched
}

@Test func legacyFileWithoutAADLoadsAndIsUpgraded() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let keys = InMemoryKeyProvider()
    let key = try keys.createKey()
    let magic = Data("GTH1".utf8) // LEGACY_GHOSTTYPE: a header-only file from before the rename
    let plain = try JSONEncoder().encode(strongModel())
    let legacy = magic + (try AES.GCM.seal(plain, using: key).combined!)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacy.write(to: url)
    let store = EncryptedHistoryStore(url: url, keys: keys)
    let r = store.loadResult()
    #expect(r.state == .loadedLegacyFormat)
    #expect(r.model.entries.count == 1)

    let svc = HistoryService(store: store, saveDelay: .milliseconds(30))
    #expect(await svc.entryCount == 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(store.loadResult().state == .loaded)     // rewritten with AAD
    let blob = try Data(contentsOf: url)
    let current = Data("HNH1".utf8)
    #expect(blob.prefix(4) == current)                // the header from before the rename is replaced
    let box = try AES.GCM.SealedBox(combined: blob.dropFirst(4))
    #expect(throws: (any Error).self) { try AES.GCM.open(box, using: key) }   // AAD is required now
    #expect((try? AES.GCM.open(box, using: key, authenticating: current)) != nil)
}

@Test func fileFromBeforeTheRenameLoadsAndIsUpgraded() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let keys = InMemoryKeyProvider()
    let key = try keys.createKey()
    let old = Data("GTH1".utf8) // LEGACY_GHOSTTYPE: the header files had under the first name
    let plain = try JSONEncoder().encode(strongModel())
    let file = old + (try AES.GCM.seal(plain, using: key, authenticating: old).combined!)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try file.write(to: url)
    let store = EncryptedHistoryStore(url: url, keys: keys)
    let r = store.loadResult()
    #expect(r.state == .loadedLegacyFormat)
    #expect(r.model.entries.count == 1)

    let svc = HistoryService(store: store, saveDelay: .milliseconds(30))
    #expect(await svc.entryCount == 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(store.loadResult().state == .loaded)
    #expect(try Data(contentsOf: url).prefix(4) == Data("HNH1".utf8))
}

// MARK: 2. Reset

@Test func trackerResetDropsPendingAccepts() {
    var t = OutcomeTracker()
    _ = t.suggestionShown(field: fld, before: "Ship the", suggestion: " Kubernetes",
                          scores: [WordScore(text: " Kubernetes", logProb: -6)], at: t0)
    _ = t.accepted(field: fld, text: " Kubernetes", at: t0 + 1)
    t.reset()
    #expect(t.focusLeft(field: fld, at: t0 + 2).isEmpty)
    #expect(t.tick(at: t0 + 100).isEmpty)
    // Retained before-caret text is gone too: an accept with no anchor is ignored.
    #expect(t.accepted(field: fld, text: " more", at: t0 + 3).isEmpty)
    #expect(t.tick(at: t0 + 100).isEmpty)
}

@Test func serviceResetPreventsConfirmation() async {
    let svc = HistoryService(store: EncryptedHistoryStore(url: tempURL(), keys: InMemoryKeyProvider()),
                             saveDelay: .seconds(60))
    await svc.record(.suggestionShown(field: fld, before: "We run", suggestion: " Kubernetes",
                                      scores: [WordScore(text: " Kubernetes", logProb: -7)]), at: t0)
    await svc.record(.accepted(field: fld, text: " Kubernetes"), at: t0 + 1)
    await svc.reset()
    await svc.record(.focusLeft(field: fld), at: t0 + 2)
    await svc.record(.tick, at: t0 + 60)
    #expect(await svc.entryCount == 0)
}

// MARK: 3. Secret filter

@Test func secretFilterRules() {
    for s in ["hunter42x", "abc123", "sk9aF3kd8Xz1Qw7Rt5Yu2Io", "deadbeef0123456789", "aXkQ9pRtYz",
              "aBcDeFgHiJ", "QwErTyUiOp", "AKIAIOSFODNN7EXAMPLE1"] {
        #expect(VocabularyScorer.looksLikeSecret(s), "\(s)")
        #expect(scorer.candidates(typed: s, context: []).isEmpty, "\(s)")
    }
    for s in ["Figma", "iPhone", "JavaScript", "PostgreSQL", "Kubernetes", "McDonalds", "YouTube",
              "internationalization", "OpenAI", "macOS", "abc12"] {
        #expect(!VocabularyScorer.looksLikeSecret(s), "\(s)")
    }
    #expect(!scorer.candidates(typed: "Figma", context: []).isEmpty)
    #expect(!scorer.candidates(typed: "iPhone", context: []).isEmpty)
}

// MARK: 4. One-offs are not persisted

@Test func oneOffsStayInMemory() throws {
    var m = strongModel()
    m.apply(LearningEvent(field: fld, kind: .confirmed(words: [WordScore(text: "Zebracorn", logProb: -9)],
                                                       context: [])), now: t0)
    #expect(m.entries["zebracorn"]?.positive == 1)
    let decoded = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
    #expect(decoded.entries["zebracorn"] == nil)
    #expect(decoded.entries["kubernetes"] != nil)
    #expect(m.entries["zebracorn"] != nil)    // still live in memory
    m.apply(LearningEvent(field: fld, kind: .confirmed(words: [WordScore(text: "Zebracorn", logProb: -9)],
                                                       context: [])), now: t0 + 1)
    let again = try JSONDecoder().decode(VocabularyModel.self, from: JSONEncoder().encode(m))
    #expect(again.entries["zebracorn"] != nil)
}

// MARK: 5. Common words

@Test func commonWordListsAreSizedAndDisjointFromStopwords() {
    #expect((800...1500).contains(CommonWords.english.count))
    #expect((120...220).contains(CommonWords.chinese.count))
    #expect(CommonWords.english.allSatisfy { $0 == $0.lowercased() })
    #expect(CommonWords.isCommon("tomorrow"))
    #expect(CommonWords.isCommon("今天"))
    #expect(!CommonWords.isCommon("kubernetes"))
}

@Test func frequentSingleWordsAreNeverCandidates() {
    for w in ["tomorrow", "apps", "messages", "column", "forget", "the", "production"] {
        #expect(scorer.candidates(words: [WordScore(text: " \(w)", logProb: -8)], context: []).isEmpty, "\(w)")
        #expect(scorer.candidates(typed: w, context: []).isEmpty, "\(w)")
    }
    for w in ["Kubernetes", "figma"] {
        #expect(scorer.candidates(typed: w, context: []).first?.credit == 1)
    }
    let rare = scorer.candidates(words: [WordScore(text: " Kubernetes", logProb: -8)], context: [])
    #expect(rare.first?.credit == 1)
    // Casual use cannot make a common word appear at all...
    var m = VocabularyModel()
    for i in 0..<6 {
        m.apply(LearningEvent(field: FieldID(pid: 1, elementHash: i, generation: 1),
                              kind: .typedOver(context: [], suggested: "x", typed: "tomorrow")),
                now: t0 + Double(i) * day)
    }
    #expect(m.entries["tomorrow"] == nil)
    // ...while a distinctive word is active after three.
    var m2 = VocabularyModel()
    for i in 0..<3 {
        m2.apply(LearningEvent(field: FieldID(pid: 1, elementHash: i, generation: 1),
                               kind: .typedOver(context: [], suggested: "x", typed: "Kubernetes")),
                 now: t0 + Double(i) * day)
    }
    #expect(m2.entries["kubernetes"]?.active == true)
}

// MARK: 6. Bias builder global scale

@Test func globalBiasEntriesAreScaledContextAndMidWordAreNot() {
    var m = VocabularyModel()
    for i in 0..<6 {
        m.apply(LearningEvent(field: FieldID(pid: 1, elementHash: i, generation: 1),
                              kind: .confirmed(words: [WordScore(text: "Kubernetes", logProb: -6),
                                                       WordScore(text: "Terraform", logProb: -6)],
                                               context: ["deploy", "to"])),
                now: t0 + Double(i) * day)
    }
    let now = t0 + 6 * day
    let builder = BiasBuilder(model: m, now: now)
    let full = m.entries["terraform"]!.weight(at: now)
    let globalHit = builder.bias(for: "Hello there ", strength: 1).entries.first { $0.text == "Terraform" }!
    #expect(abs(globalHit.weight - full * 0.3) < 0.001)
    #expect(builder.bias(for: "Hello there ", strength: 1).entries.allSatisfy { $0.weight <= 0.3 + 1e-6 })
    let midWord = builder.bias(for: "Hello Terr", strength: 1).entries.first
    #expect(midWord?.text == "Terraform")
    #expect(abs((midWord?.weight ?? 0) - full) < 0.001)
    let ctx = builder.bias(for: "we deploy to ", strength: 1).entries.first { $0.text == "Kubernetes" }!
    #expect(ctx.weight > 0.3)
}

// MARK: 7. Boosted words

@Test func boostedWordsGetQuarterCredit() {
    let words = [WordScore(text: " Kubernetes", logProb: -8), WordScore(text: " Terraform", logProb: -8)]
    let c = scorer.candidates(words: words, context: [], boosted: ["kubernetes"])
    #expect(abs((c.first { $0.text == "Kubernetes" }?.credit ?? 0) - 0.25) < 0.0001)
    #expect(c.first { $0.text == "Terraform" }?.credit == 1)
}

@Test func trackerCarriesBoostedThroughToConfirmation() {
    var t = OutcomeTracker()
    _ = t.suggestionShown(field: fld, before: "We run", suggestion: " Kubernetes",
                          scores: [WordScore(text: " Kubernetes", logProb: -6)], boosted: [" Kubernetes "],
                          at: t0)
    _ = t.accepted(field: fld, text: " Kubernetes", at: t0 + 1)
    let ev = t.focusLeft(field: fld, at: t0 + 2)
    if case let .confirmed(_, _, boosted)? = ev.first?.kind {
        #expect(boosted == ["kubernetes"])
    } else { Issue.record("expected confirmed") }
}

@Test func serviceDiscountsBoostedSuggestionsEndToEnd() async {
    func run(boosted: Set<String>) async -> Float {
        let svc = HistoryService(store: EncryptedHistoryStore(url: tempURL(), keys: InMemoryKeyProvider()),
                                 saveDelay: .seconds(60))
        await svc.record(.suggestionShown(field: fld, before: "We run", suggestion: " Kubernetes",
                                          scores: [WordScore(text: " Kubernetes", logProb: -8)],
                                          boosted: boosted), at: t0)
        await svc.record(.accepted(field: fld, text: " Kubernetes"), at: t0 + 1)
        await svc.record(.focusLeft(field: fld), at: t0 + 2)
        return await svc.totalMass(of: "kubernetes")
    }
    #expect(await run(boosted: []) == 1)
    #expect(abs(await run(boosted: ["kubernetes"]) - 0.25) < 0.0001)
}

// MARK: 8. Delete all

@Test func deleteAllRemovesTempFilesKeyAndMemory() async throws {
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keys = InMemoryKeyProvider()
    let store = EncryptedHistoryStore(url: url, keys: keys)
    try store.save(strongModel())
    let stray = dir.appendingPathComponent(".history-ABC.tmp")
    let other = dir.appendingPathComponent("keep.txt")
    try Data("x".utf8).write(to: stray)
    try Data("y".utf8).write(to: other)

    let svc = HistoryService(store: store, saveDelay: .seconds(60))
    #expect(await svc.entryCount == 1)
    try await svc.deleteAll()
    #expect(await svc.entryCount == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: stray.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
    #expect(throws: KeyProviderError.notFound) { try keys.loadKey() }
}

@Test func deleteAllPropagatesKeyErrors() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try EncryptedHistoryStore(url: url, keys: InMemoryKeyProvider()).save(strongModel())
    let svc = HistoryService(store: EncryptedHistoryStore(url: url, keys: FlakyKeys()))
    await #expect(throws: FlakyKeys.Boom.self) { try await svc.deleteAll() }
    #expect(!FileManager.default.fileExists(atPath: url.path))   // file removal still attempted
    #expect(await svc.entryCount == 0)
}

// MARK: Nits

@Test func phrasesDoNotSpanRemovedURLs() {
    var t = OutcomeTracker()
    _ = t.suggestionShown(field: fld, before: "Please see", suggestion: " zorblax https://x.com/a quuxify frobnitz",
                          scores: [], at: t0)
    _ = t.accepted(field: fld, text: " zorblax https://x.com/a quuxify frobnitz", at: t0 + 1)
    guard case let .confirmed(words, context, _)? = t.focusLeft(field: fld, at: t0 + 2).first?.kind else {
        Issue.record("expected confirmed"); return
    }
    #expect(words.map(\.text) == ["zorblax", "", "quuxify", "frobnitz"])
    let c = scorer.candidates(words: words, context: context).map(\.text)
    #expect(!c.contains("zorblax quuxify"))
    #expect(c.contains("quuxify frobnitz"))
    #expect(c.contains("zorblax"))
    // A numeric neighbor also breaks phrases.
    #expect(!scorer.candidates(words: [WordScore(text: "alpha", logProb: -9), WordScore(text: "2024", logProb: -9),
                                       WordScore(text: "beta", logProb: -9)], context: []).map(\.text)
        .contains("alpha 2024 beta"))
    // Context does not cross an opaque token.
    #expect(WordText.contextWords(of: "see http://x.com/a beta") == ["beta"])
}
