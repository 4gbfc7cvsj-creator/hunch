import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func appKeyPrefersHostThenBundle() {
    #expect(AppKey.make(bundleID: "com.apple.Safari", urlHost: "www.Example.com") == "example.com")
    #expect(AppKey.make(bundleID: "com.apple.Safari", urlHost: "mail.google.com") == "mail.google.com")
    #expect(AppKey.make(bundleID: "com.apple.mail", urlHost: nil) == "com.apple.mail")
    #expect(AppKey.make(bundleID: "com.apple.mail", urlHost: "") == "com.apple.mail")
    #expect(AppKey.make(bundleID: nil, urlHost: nil) == nil)
    #expect(AppKey.make(bundleID: "", urlHost: nil) == nil)
}

private func record(_ m: inout VocabularyModel, _ word: String, app: String?, i: Int = 0, credit: Float = 1) {
    m.recordPositive(text: word, credit: credit, contextKey: nil, fieldKey: UInt32(i), now: t0 + Double(i) * day,
                     appKey: app)
}

@Test func oldModelDecodesWithoutApps() throws {
    let json = #"{"entries":{"foo":{"text":"Foo","positive":3,"lastSeen":0}}}"#
    let m = try JSONDecoder().decode(VocabularyModel.self, from: Data(json.utf8))
    #expect(m.entries["foo"]?.apps == [:])
}

@Test func recordPositiveAccumulatesPerAppAndTrims() {
    var m = VocabularyModel()
    record(&m, "Zorblax", app: "a", credit: 1)
    record(&m, "Zorblax", app: "a", credit: 1)
    record(&m, "Zorblax", app: "b", credit: 0.5)
    record(&m, "Zorblax", app: nil)
    #expect(m.entries["zorblax"]?.apps["a"] == 2)
    #expect(m.entries["zorblax"]?.apps["b"] == 0.5)
    #expect(m.entries["zorblax"]?.apps.count == 2)
    for n in 0..<10 { record(&m, "Zorblax", app: "x\(n)", credit: 0.1) }
    #expect(m.entries["zorblax"]!.apps.count == 6)
    #expect(m.entries["zorblax"]!.apps["a"] == 2)
}

@Test func appFactorCases() {
    #expect(BiasBuilder.appFactor(apps: ["d": 3], appKey: "d") == 1)
    #expect(BiasBuilder.appFactor(apps: ["d": 3], appKey: "m") == 0)
    #expect(BiasBuilder.appFactor(apps: [:], appKey: "m") == 1)
    #expect(BiasBuilder.appFactor(apps: ["d": 3], appKey: nil) == 1)
    #expect(abs(BiasBuilder.appFactor(apps: ["d": 1, "m": 1], appKey: "m") - 2.0 / 3) < 1e-6)
}

@Test func wordUsedOnlyInAnotherAppIsLeftOutOfBias() {
    var m = VocabularyModel()
    for i in 0..<5 { record(&m, "Zorblax", app: "discord", i: i) }
    let b = BiasBuilder(model: m, now: t0 + 5 * day)
    let here = b.bias(for: "hey ", strength: 1, appKey: "discord").entries.first!.weight
    let none = b.bias(for: "hey ", strength: 1, appKey: nil).entries.first!.weight
    #expect(here == none && here > 0)
    #expect(b.bias(for: "hey ", strength: 1, appKey: "mail").entries.isEmpty)
    // Mid-word too: a word learned only elsewhere does not finish the typed part.
    #expect(b.bias(for: "hey zor", strength: 1, appKey: "mail").entries.isEmpty)
}

@Test func wordUsedHereAndElsewhereWeighsLessThanOneUsedOnlyHere() {
    var m = VocabularyModel()
    for i in 0..<4 { record(&m, "Zorblax", app: "discord", i: i) }
    record(&m, "Zorblax", app: "mail", i: 4)
    let b = BiasBuilder(model: m, now: t0 + 5 * day)
    let discord = b.bias(for: "hey ", strength: 1, appKey: "discord").entries.first!.weight
    let mail = b.bias(for: "hey ", strength: 1, appKey: "mail").entries.first!.weight
    #expect(mail > 0 && mail < discord)
}

@Test func focusLeftConfirmationsCreditTheFieldApp() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString).bin")
    let svc = HistoryService(store: EncryptedHistoryStore(url: dir, keys: InMemoryKeyProvider()),
                             saveDelay: .seconds(60))
    let f = FieldID(pid: 5, elementHash: 1, generation: 1)
    let base = "We use "
    await svc.record(.textChanged(field: f, before: base, appKey: "discord"), at: t0)
    await svc.record(.suggestionShown(field: f, before: base, suggestion: "Zorblax",
                                      scores: [WordScore(text: "Zorblax", logProb: -8)]), at: t0 + 1)
    await svc.record(.accepted(field: f, text: "Zorblax"), at: t0 + 2)
    await svc.record(.focusLeft(field: f), at: t0 + 3)
    let apps = await svc.appsForTesting(of: "zorblax")
    #expect(apps["discord"] ?? 0 > 0)
    // A later event for the same field no longer has an app.
    await svc.record(.correctionSkipped(field: f, word: "Qwerty"), at: t0 + 4)
    #expect(await svc.appsForTesting(of: "qwerty").isEmpty)
}

// MARK: - App categories

@Test func categoriesFromPatches() {
    var mail = AppPolicyPatch(); mail.appCategory = " Work "
    var outlook = AppPolicyPatch(); outlook.appCategory = "Work"
    var site = AppPolicyPatch(); site.appCategory = "Work"
    var blank = AppPolicyPatch(); blank.appCategory = "  "
    let c = AppCategories(patches: [.app(bundleID: "com.apple.mail"): mail,
                                    .app(bundleID: "com.microsoft.Outlook"): outlook,
                                    .domain(pattern: "*.Google.com"): site,
                                    .app(bundleID: "x"): blank])
    #expect(c.names == ["Work"])
    #expect(c.category(of: "x") == nil)
    #expect(c.sameCategory("com.apple.mail", "com.microsoft.Outlook"))
    #expect(c.sameCategory("com.apple.mail", "mail.google.com"))
    #expect(!c.sameCategory("com.apple.mail", "google.com"))   // "*." is subdomains only
    #expect(!c.sameCategory("com.apple.mail", "x"))
    #expect(c.sameCategory("x", "x"))
}

@Test func appFactorCountsWholeCategory() {
    let cats = AppCategories(apps: ["mail": "Work", "outlook": "Work"])
    let apps: [String: Float] = ["mail": 1, "outlook": 1, "chat": 2]
    #expect(abs(BiasBuilder.appFactor(apps: apps, appKey: "mail") - (1 + 2 * 0.25) / 3) < 1e-6)
    #expect(abs(BiasBuilder.appFactor(apps: apps, appKey: "mail", categories: cats) - (1 + 2 * 0.5) / 3) < 1e-6)
    #expect(abs(BiasBuilder.appFactor(apps: apps, appKey: "chat", categories: cats) - (1 + 2 * 0.5) / 3) < 1e-6)
}

// MARK: - Learned words offered as fixes, per app

@Test func learnedWordPlacesHereUsesAnyUseInAppOrCategory() {
    let places = LearnedWordPlaces(apps: ["kubectl": ["term": 5], "lol": ["chat": 0.2, "term": 9],
                                          "zorblax": [:], "teams": ["work": 1]])
    #expect(places.here(appKey: nil) == nil)
    #expect(places.here(appKey: "chat") == ["lol", "zorblax"])
    #expect(places.here(appKey: "term") == ["kubectl", "lol", "zorblax"])
    #expect(places.here(appKey: "elsewhere") == ["zorblax"])
    let cats = AppCategories(apps: ["chat": "Chats", "work": "Chats"])
    #expect(places.here(appKey: "chat", categories: cats) == ["lol", "zorblax", "teams"])
}

@Test func placesOfModelMatchActiveWords() async throws {
    var m = VocabularyModel()
    for i in 0..<6 { record(&m, "Zorblax", app: "discord", i: i) }
    _ = try m.addManual("Kubernetes", origin: .manual, now: t0)
    let places = HistoryService.places(of: m)
    let active = Set(m.entries.values.filter { $0.active && !$0.blocked }.map { $0.text.lowercased() })
    #expect(places.words == active)
    #expect(places.apps["kubernetes"] == [:])
    #expect(places.here(appKey: "mail") == ["kubernetes"])
}

@Test func midWordOnlyKeepsJustTheExtensionOfTheTypedWord() {
    var m = VocabularyModel()
    for i in 0..<5 { record(&m, "Zorblax", app: "discord", i: i) }
    for i in 0..<5 { record(&m, "Quillon", app: "discord", i: i) }
    let b = BiasBuilder(model: m, now: t0 + 5 * day)
    #expect(b.bias(for: "hey ", strength: 1, appKey: "discord").entries.count == 2)
    #expect(b.bias(for: "hey ", strength: 1, appKey: "discord", midWordOnly: true).entries.isEmpty)
    let mid = b.bias(for: "hey zor", strength: 1, appKey: "discord", midWordOnly: true).entries
    #expect(mid.map(\.text) == ["Zorblax"])
}

@Test func topWordsAreForThisAppAndSortedAlphabetically() {
    var m = VocabularyModel()
    for i in 0..<5 { record(&m, "Zorblax", app: "discord", i: i) }
    for i in 0..<5 { record(&m, "Quillon", app: "discord", i: i) }
    for i in 0..<5 { record(&m, "Mailword", app: "mail", i: i) }
    let b = BiasBuilder(model: m, now: t0 + 5 * day)
    #expect(b.topWords(appKey: "discord", limit: 10) == ["Quillon", "Zorblax"])
    #expect(b.topWords(appKey: "mail", limit: 10) == ["Mailword"])
    #expect(b.topWords(appKey: nil, limit: 10).count == 3)
    #expect(b.topWords(appKey: "discord", limit: 1).count == 1)
    #expect(b.topWords(appKey: "discord", limit: 0).isEmpty)
}
