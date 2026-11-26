import CryptoKit
import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let scorer = VocabularyScorer()

@Test func scorerSkipsStopwordsAndShortWords() {
    let words = [WordScore(text: " the", logProb: -9), WordScore(text: " and", logProb: -9),
                 WordScore(text: " ok", logProb: -9), WordScore(text: " Kubernetes", logProb: -9)]
    let c = scorer.candidates(words: words, context: [])
    #expect(c.map(\.text).contains("Kubernetes"))
    #expect(!c.map(\.text).contains("the"))
    #expect(!c.map(\.text).contains("ok"))
    #expect(scorer.candidates(typed: "I", context: []).isEmpty)
    #expect(scorer.candidates(typed: "2024", context: []).isEmpty)
    #expect(scorer.candidates(typed: "的", context: []).isEmpty)
    #expect(scorer.candidates(typed: "我们", context: []).isEmpty)
    #expect(scorer.candidates(typed: "机器", context: []).count == 1)
}

@Test func scorerSurpriseWeighting() {
    #expect(scorer.credit(logProb: -0.2) == 0)
    #expect(scorer.credit(logProb: -1.0) == 0)
    #expect(scorer.credit(logProb: -2.5) > 0.4)
    #expect(scorer.credit(logProb: -2.5) < 0.6)
    #expect(scorer.credit(logProb: -8) == 1)
    #expect(scorer.credit(logProb: nil) == 1)
    #expect(scorer.candidates(words: [WordScore(text: " probably", logProb: -0.3)], context: []).isEmpty)
}

@Test func scorerRejectsSecretsAndURLs() {
    #expect(VocabularyScorer.looksLikeSecret("sk9aF3kd8Xz1Qw7Rt5Yu2Io"))
    #expect(!VocabularyScorer.looksLikeSecret("Kubernetes"))
    #expect(scorer.candidates(typed: "sk9aF3kd8Xz1Qw7Rt5Yu2Io", context: []).isEmpty)
    #expect(scorer.candidates(typed: "me@example.com", context: []).isEmpty)
    #expect(scorer.candidates(typed: "https://example.com", context: []).isEmpty)
}

@Test func phrasesNeedAContentWord() {
    let stop = [WordScore(text: " in", logProb: -9), WordScore(text: " the", logProb: -9),
                WordScore(text: " and", logProb: -9)]
    #expect(scorer.candidates(words: stop, context: []).isEmpty)
    let mixed = [WordScore(text: " in", logProb: -5), WordScore(text: " kubernetes", logProb: -5)]
    let c = scorer.candidates(words: mixed, context: ["deploy"])
    #expect(c.map(\.text).sorted() == ["in kubernetes", "kubernetes"])
    #expect(c.first { $0.text == "in kubernetes" }?.context == ["deploy"])
    #expect(c.first { $0.text == "kubernetes" }?.context == ["deploy", "in"])
}

private func confirm(_ m: inout VocabularyModel, _ word: String, field: Int, at date: Date,
                     context: [String] = []) {
    let f = FieldID(pid: 1, elementHash: field, generation: 1)
    m.apply(LearningEvent(field: f, kind: .confirmed(words: [WordScore(text: word, logProb: -6)],
                                                     context: context)), now: date)
}

@Test func activationNeedsThreeAcrossDaysOrFields() {
    var m = VocabularyModel()
    // Three confirmations, same day, same field: not active.
    for i in 0..<3 { confirm(&m, "Kubernetes", field: 1, at: t0.addingTimeInterval(Double(i))) }
    #expect(m.entries["kubernetes"]?.active == false)
    // Two confirmations on two days: not enough count.
    var m2 = VocabularyModel()
    confirm(&m2, "Kubernetes", field: 1, at: t0)
    confirm(&m2, "Kubernetes", field: 1, at: t0 + day)
    #expect(m2.entries["kubernetes"]?.active == false)
    // Third on another day: active.
    confirm(&m2, "Kubernetes", field: 1, at: t0 + 2 * day)
    #expect(m2.entries["kubernetes"]?.active == true)
    // Same day but two fields: active.
    var m3 = VocabularyModel()
    confirm(&m3, "Kubernetes", field: 1, at: t0)
    confirm(&m3, "kubernetes", field: 2, at: t0.addingTimeInterval(1))
    confirm(&m3, "Kubernetes", field: 2, at: t0.addingTimeInterval(2))
    #expect(m3.entries["kubernetes"]?.active == true)
    #expect(m3.entries.count == 1)
    #expect(m3.entries["kubernetes"]?.text == "Kubernetes")   // latest casing
}

@Test func decayHalvesMassAfterHalfLife() {
    var m = VocabularyModel()
    for i in 0..<3 { confirm(&m, "Kubernetes", field: i, at: t0 + Double(i) * day) }
    let e = m.entries["kubernetes"]!
    let now = e.asOf
    let w0 = e.net(at: now)
    let w30 = e.net(at: now + 30 * day)
    #expect(abs(w30 - w0 / 2) < 0.01)
    #expect(e.weight(at: now + 400 * day) < 0.01)
    m.consolidate(now: now + 400 * day)
    #expect(m.entries.isEmpty)
}

@Test func negativesReduceWeight() {
    var m = VocabularyModel()
    for i in 0..<3 { confirm(&m, "Kubernetes", field: i, at: t0 + Double(i) * day, context: ["deploy", "to"]) }
    let now = t0 + 3 * day
    let before = m.entries["kubernetes"]!.weight(at: now)
    let beforeCtx = m.entries["kubernetes"]!.weight(inContext: "deploy to", at: now)
    let ev = LearningEvent(field: FieldID(pid: 1, elementHash: 1, generation: 1),
                           kind: .typedOver(context: ["deploy", "to"], suggested: "Kubernetes", typed: "Docker"))
    m.apply(ev, now: now)
    let e = m.entries["kubernetes"]!
    #expect(e.weight(at: now) < before)
    #expect(e.weight(at: now) > before * 0.7)                    // global effect is small
    #expect(e.weight(inContext: "deploy to", at: now) < beforeCtx * 0.8)
    #expect(m.entries["docker"]?.positive == 1)                  // the typed word is learned
}

@Test func pruningRespectsCapacityAndKeepsStrongest() {
    var m = VocabularyModel()
    m.capacity = 50
    for i in 0..<200 {
        let f = FieldID(pid: 1, elementHash: i, generation: 1)
        m.apply(LearningEvent(field: f, kind: .confirmed(words: [WordScore(text: "word" + String(UnicodeScalar(UInt8(97 + i % 26))) + String(UnicodeScalar(UInt8(97 + i / 26))) + "x", logProb: -6)],
                                                         context: [])), now: t0)
    }
    #expect(m.entries.count <= 55)
    // A strong entry survives.
    for i in 0..<5 { confirm(&m, "Zebracorn", field: i, at: t0 + Double(i) * day) }
    m.capacity = 10
    m.consolidate(now: t0 + 5 * day)
    #expect(m.entries.count <= 10)
    #expect(m.entries["zebracorn"] != nil)
}

@Test func consolidateMergesCaseVariants() {
    var m = VocabularyModel()
    var a = VocabEntry(text: "Foobar", now: t0); a.positive = 2; a.posMass = 2
    var b = VocabEntry(text: "foobar ", now: t0); b.positive = 2; b.posMass = 2
    m.entries["foobar"] = a
    m.entries["foobar "] = b
    m.consolidate(now: t0)
    #expect(m.entries.count == 1)
    #expect(m.entries["foobar"]?.positive == 4)
}

private func activeModel() -> VocabularyModel {
    var m = VocabularyModel()
    let words = ["Kubernetes", "Terraform", "Postgres", "Grafana", "Prometheus"]
    for (n, w) in words.enumerated() {
        for i in 0..<(3 + n) {
            confirm(&m, w, field: i, at: t0 + Double(i) * day, context: n == 0 ? ["deploy", "to"] : ["other"])
        }
    }
    return m
}

@Test func biasContextFirstThenGlobalWithLeadingSpace() {
    let m = activeModel()
    let now = t0 + 6 * day
    let b = BiasBuilder(model: m, now: now).bias(for: "We deploy to", strength: 2)
    #expect(b.strength == 2)
    #expect(b.entries.first?.text == " Kubernetes")
    #expect(b.entries.count == 5)
    #expect(b.entries.allSatisfy { $0.text.hasPrefix(" ") && $0.weight > 0 && $0.weight <= 1 })
    // Strongest global entry (Prometheus) outranks weaker ones after the context match.
    #expect(b.entries[1].text == " Prometheus")
    let afterSpace = BiasBuilder(model: m, now: now).bias(for: "We deploy to ", strength: 1)
    #expect(afterSpace.entries.first?.text == "Kubernetes")
}

@Test func biasMidWordPrefersContinuations() {
    let m = activeModel()
    let b = BiasBuilder(model: m, now: t0 + 6 * day).bias(for: "Metrics via Pro", strength: 1)
    #expect(b.entries.first?.text == "Prometheus")
}

@Test func biasOffAndSizeCap() {
    let m = activeModel()
    let builder = BiasBuilder(model: m, now: t0 + 6 * day)
    #expect(builder.bias(for: "x ", strength: 0).isEmpty)

    var big = VocabularyModel()
    for i in 0..<300 {
        var e = VocabEntry(text: "term\(i)abc", now: t0)
        e.positive = 5; e.posMass = 3; e.days = [1, 2]; e.fields = [1]; e.active = true
        big.entries["term\(i)abc"] = e
    }
    let out = BiasBuilder(model: big, now: t0).bias(for: "hello ", strength: 1)
    #expect(out.entries.count == 64)
}

@Test func biasExcludesNetNegativeAndInactive() {
    var m = activeModel()
    var dead = VocabEntry(text: "Doomed", now: t0)
    dead.positive = 5; dead.posMass = 1; dead.negMass = 8; dead.days = [1, 2]; dead.active = true
    m.entries["doomed"] = dead
    var inactive = VocabEntry(text: "Newbie", now: t0)
    inactive.positive = 1; inactive.posMass = 1
    m.entries["newbie"] = inactive
    let texts = BiasBuilder(model: m, now: t0).bias(for: "a ", strength: 1).entries.map(\.text)
    #expect(!texts.contains("Doomed"))
    #expect(!texts.contains("Newbie"))
}

@Test func biasIsFastAt5000Entries() {
    var m = VocabularyModel()
    for i in 0..<5000 {
        var e = VocabEntry(text: "term\(i)abc", now: t0)
        e.positive = 5; e.posMass = 1 + Float(i % 7); e.days = [1, 2]; e.active = true
        e.contexts = ["deploy to": 1, "to": 1]
        m.entries["term\(i)abc"] = e
    }
    let builder = BiasBuilder(model: m, now: t0)
    let start = ContinuousClock.now
    for _ in 0..<100 { _ = builder.bias(for: "We deploy to te", strength: 1) }
    let per = (ContinuousClock.now - start) / 100
    #expect(per < .milliseconds(5))   // generous bound for debug builds; target is < 1 ms in release
}

// MARK: Store and service

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gt-history-\(UUID().uuidString)/history.bin")
}

@Test func storeRoundTripAndPermissions() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let keys = InMemoryKeyProvider()
    let store = EncryptedHistoryStore(url: url, keys: keys)
    let m = activeModel()
    try store.save(m)
    try store.save(m)   // second save replaces atomically
    let loaded = store.load()
    #expect(loaded == m)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    // Not stored in the clear.
    let raw = try Data(contentsOf: url)
    #expect(raw.range(of: Data("Kubernetes".utf8)) == nil)
    try store.deleteAll()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(throws: KeyProviderError.notFound) { try keys.loadKey() }
}

@Test func corruptOrUndecryptableFileLoadsEmpty() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let keys = InMemoryKeyProvider()
    let store = EncryptedHistoryStore(url: url, keys: keys)
    #expect(store.load().entries.isEmpty)                       // missing file
    try store.save(activeModel())
    var blob = try Data(contentsOf: url)
    blob[blob.count / 2] ^= 0xFF
    try blob.write(to: url)
    #expect(store.load().entries.isEmpty)                       // tampered
    try Data("garbage".utf8).write(to: url)
    #expect(store.load().entries.isEmpty)                       // junk
    try store.save(activeModel())
    try keys.deleteKey()
    #expect(store.load().entries.isEmpty)                       // key lost
    try store.save(VocabularyModel())                           // recovers with a new key
    #expect(store.load().entries.isEmpty)
}

private func makeService(_ url: URL, _ keys: InMemoryKeyProvider) -> HistoryService {
    HistoryService(store: EncryptedHistoryStore(url: url, keys: keys), saveDelay: .milliseconds(50))
}

@Test func serviceLearnsSavesAndDeletes() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let keys = InMemoryKeyProvider()
    let svc = makeService(url, keys)
    let field = FieldID(pid: 9, elementHash: 3, generation: 1)
    for d in 0..<3 {
        let now = t0 + Double(d) * day
        await svc.record(.suggestionShown(field: field, before: "We run", suggestion: " Kubernetes",
                                          scores: [WordScore(text: " Kubernetes", logProb: -7)]), at: now)
        await svc.record(.accepted(field: field, text: " Kubernetes"), at: now + 1)
        await svc.record(.focusLeft(field: field), at: now + 2)
    }
    #expect(await svc.entryCount == 1)
    let bias = await svc.bias(for: "We run", strength: 2, now: t0 + 3 * day)
    #expect(bias.entries.map(\.text) == [" Kubernetes"])
    #expect(await svc.bias(for: "We run", strength: 0).isEmpty)

    #expect(!FileManager.default.fileExists(atPath: url.path))   // debounced, not yet written
    try await Task.sleep(for: .milliseconds(400))
    #expect(FileManager.default.fileExists(atPath: url.path))

    let reopened = makeService(url, keys)
    #expect(await reopened.entryCount == 1)

    #expect(await svc.consolidateIfDue(idle: true, now: t0 + 3 * day))
    #expect(await svc.consolidateIfDue(idle: true, now: t0 + 3 * day + 10) == false)
    #expect(await svc.consolidateIfDue(idle: false, now: t0 + 5 * day))

    try await svc.deleteAll()
    #expect(await svc.entryCount == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(throws: KeyProviderError.notFound) { try keys.loadKey() }
}
