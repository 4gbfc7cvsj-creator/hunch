import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let fieldA = FieldID(pid: 200, elementHash: 1, generation: 1)
private let fieldB = FieldID(pid: 200, elementHash: 2, generation: 1)

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("style-\(UUID().uuidString).bin")
}

private func makeService(_ url: URL = tempURL(), keys: InMemoryKeyProvider = InMemoryKeyProvider(),
                         capture: Bool = true) async -> HistoryService {
    let s = HistoryService(store: EncryptedHistoryStore(url: url, keys: keys), saveDelay: .milliseconds(20))
    await s.setStyleCaptureEnabled(capture)
    return s
}

private func type(_ s: HistoryService, _ f: FieldID, _ text: String, app: String? = nil) async {
    await s.record(.textChanged(field: f, before: text, appKey: app), at: t0)
}

/// Simulates typing `text` one character at a time on top of `prefix` (already in the field).
private func typeChars(_ s: HistoryService, _ f: FieldID, _ text: String, after prefix: String = "",
                       app: String? = nil, at now: Date = t0) async {
    var cur = prefix
    for ch in text {
        cur.append(ch)
        await s.record(.textChanged(field: f, before: cur, appKey: app), at: now)
    }
}

private func leave(_ s: HistoryService, _ f: FieldID) async {
    await s.record(.focusLeft(field: f), at: t0)
}

private let good = "I will send the quarterly budget report tomorrow morning."

@Test func harvestsNewSentenceOnFocusLeave() async {
    let s = await makeService()
    await type(s, fieldA, "", app: "com.example.mail")
    await typeChars(s, fieldA, good, app: "com.example.mail")
    await leave(s, fieldA)
    let snips = await s.styleSnippets()
    #expect(snips.map(\.text) == [good])
    #expect(snips.first?.appKey == "com.example.mail")
}

@Test func baselineSentencesAreNotTaken() async {
    let s = await makeService()
    let old = "The meeting notes from last week are pasted below for reference."
    await type(s, fieldA, old + " ")
    await typeChars(s, fieldA, good, after: old + " ")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().map(\.text) == [good])
}

@Test func lengthFiltersApply() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "Too short here. " + Array(repeating: "word", count: 45).joined(separator: " ") + ".")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func chineseLengthRule() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "好的。我明天上午會把這份季度報告寄給你，請放心。")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().map(\.text) == ["我明天上午會把這份季度報告寄給你，請放心。"])
}

@Test func secretUrlEmailDigitsRejected() async {
    let s = await makeService()
    await type(s, fieldA, "")
    let bad = [
        "My password is hunter42x for the shared account.",
        "Please open https://example.com/page for the details.",
        "You can write to me at jane@example.com about it.",
        "The order number is 123456 and it shipped already.",
        "The token sk9aF3kd is what you should paste there.",
    ]
    await typeChars(s, fieldA, bad.joined(separator: " "))
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func unterminatedSentenceNeedsClear() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "This sentence has no closing punctuation at all")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func clearedBoxHarvestsFinalSentence() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "Sounds great to me, see you at the cafe soon")
    await type(s, fieldA, "")
    #expect(await s.styleSnippets().map(\.text) == ["Sounds great to me, see you at the cafe soon"])
}

@Test func clearedBoxStartsNewBaseline() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, good)
    await type(s, fieldA, "")
    await typeChars(s, fieldA, good)   // typed again: same text, deduped
    await leave(s, fieldA)
    #expect(await s.styleSnippets().count == 1)
}

@Test func editingDoesNotCountAsClear() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, good + " And")
    await type(s, fieldA, good + " An")   // backspace
    #expect(await s.styleSnippets().isEmpty)
}

@Test func captureOffStoresNothing() async {
    let s = await makeService(capture: false)
    await type(s, fieldA, "")
    await typeChars(s, fieldA, good)
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func libraryDedupesAndCaps() {
    var lib = StyleLibrary()
    let first = lib.add(text: "Hello   there friend", at: t0)
    let second = lib.add(text: "hello there  FRIEND", at: t0)
    #expect(first)
    #expect(!second)
    let cap = StyleLibrary.capacityPerCategory
    for i in 0..<(cap + 5) { lib.add(text: "unique sentence number \(i) here", at: t0) }
    #expect(lib.snippets.count == cap)
    #expect(lib.snippets.last?.text == "unique sentence number \(cap + 4) here")
    #expect(!lib.snippets.contains { $0.text == "Hello there friend" })
}

@Test func libraryCapsEachCategorySeparately() {
    let cats: [String: String] = ["claude.ai": "AI", "chatgpt.com": "ai", "com.apple.MobileSMS": "Chats"]
    let categoryOf = { (k: String) -> String? in cats[k] }
    let cap = StyleLibrary.capacityPerCategory
    var lib = StyleLibrary()
    lib.add(text: "See you at the station tomorrow.", at: t0, appKey: "com.apple.MobileSMS", categoryOf: categoryOf)
    lib.add(text: "Typed in an app with no category.", at: t0, appKey: "com.example.notes", categoryOf: categoryOf)
    // Twice the cap in AI, split across two sites whose category names differ only in case.
    for i in 0..<(2 * cap) {
        lib.add(text: "prompt number \(i) for the model", at: t0, appKey: i.isMultiple(of: 2) ? "claude.ai" : "chatgpt.com",
                categoryOf: categoryOf)
    }
    let ai = lib.snippets.filter { $0.appKey == "claude.ai" || $0.appKey == "chatgpt.com" }
    #expect(ai.count == cap)
    #expect(ai.first?.text == "prompt number \(cap) for the model")   // oldest AI ones dropped
    #expect(lib.snippets.contains { $0.text == "See you at the station tomorrow." })
    #expect(lib.snippets.contains { $0.text == "Typed in an app with no category." })
    #expect(lib.snippets.count == cap + 2)
    // A dropped sentence can be saved again (its duplicate key was released).
    let readded = lib.add(text: "prompt number 0 for the model", at: t0, appKey: "claude.ai", categoryOf: categoryOf)
    #expect(readded)
}

private func seeded() async -> HistoryService {
    let s = await makeService()
    await type(s, fieldB, "", app: "app.a")
    await typeChars(s, fieldB, "The quarterly budget report is attached for your review. We loved the new garden design today. Cats sleep on warm windowsills all afternoon.", app: "app.a")
    await leave(s, fieldB)
    return s
}

@Test func selectsByOverlap() async {
    let s = await seeded()
    let r = await s.styleExamples(for: "Here is the budget", field: fieldA, appKey: "app.a")
    #expect(r == ["The quarterly budget report is attached for your review."])
}

@Test func zeroOverlapReturnsNothing() async {
    let s = await seeded()
    #expect(await s.styleExamples(for: "Completely unrelated rocket science", field: fieldA, appKey: "app.a").isEmpty)
}

@Test func selfEchoExcluded() async {
    let s = await seeded()
    let r = await s.styleExamples(for: "The quarterly budget report is attached for your review. Next budget", field: fieldA, appKey: "app.a")
    #expect(r.isEmpty)
}

@Test func higherOverlapThenNewestWins() async {
    let s = await seeded()
    // "garden" matches one snippet; "cats windowsills" matches another with two words.
    let r = await s.styleExamples(for: "garden cats windowsills", field: fieldA, appKey: "app.a", k: 1)
    #expect(r == ["Cats sleep on warm windowsills all afternoon."])
}

@Test func pinningHoldsUntilFocusLeaves() async {
    let s = await seeded()
    let first = await s.styleExamples(for: "the budget", field: fieldA, appKey: "app.a", k: 1)
    #expect(first.count == 1)
    let again = await s.styleExamples(for: "garden design", field: fieldA, appKey: "app.a", k: 1)
    #expect(again == first)
    await leave(s, fieldA)
    let after = await s.styleExamples(for: "garden design", field: fieldA, appKey: "app.a", k: 1)
    #expect(after == ["We loved the new garden design today."])
}

@Test func emptyPickIsNotPinned() async {
    let s = await seeded()
    #expect(await s.styleExamples(for: "zzz", field: fieldA, appKey: "app.a").isEmpty)
    #expect(await s.styleExamples(for: "the budget", field: fieldA, appKey: "app.a", k: 1).count == 1)
}

@Test func clearedFieldResetsPin() async {
    let s = await seeded()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "the budget please send it over now")
    let first = await s.styleExamples(for: "the budget", field: fieldA, appKey: "app.a", k: 1)
    await type(s, fieldA, "")
    let after = await s.styleExamples(for: "garden design", field: fieldA, appKey: "app.a", k: 1)
    #expect(!first.isEmpty)
    #expect(after == ["We loved the new garden design today."])
}

@Test func oldFormatDecodesWithEmptyLibrary() throws {
    let json = #"{"entries":{}}"#
    let m = try JSONDecoder().decode(VocabularyModel.self, from: Data(json.utf8))
    #expect(m.style.isEmpty)
}

@Test func snippetsPersistWithoutVocabulary() async {
    let url = tempURL(), keys = InMemoryKeyProvider()
    let s = await seeded2(url, keys)
    await s.flush()
    let s2 = await makeService(url, keys: keys)
    #expect(await s2.styleSnippets().map(\.text) == [good])
    #expect(await s2.entryCount == 0)
}

private func seeded2(_ url: URL, _ keys: InMemoryKeyProvider) async -> HistoryService {
    let s = await makeService(url, keys: keys)
    await type(s, fieldA, "")
    await typeChars(s, fieldA, good)
    await leave(s, fieldA)
    return s
}

@Test func deletePaths() async throws {
    let s = await seeded()
    let snips = await s.styleSnippets()
    #expect(snips.count == 3)
    await s.deleteSnippet(id: snips[0].id)
    #expect(await s.styleSnippets().count == 2)
    await s.deleteAllSnippets()
    #expect(await s.styleSnippets().isEmpty)
}

@Test func deleteAllClearsSnippets() async throws {
    let url = tempURL(), keys = InMemoryKeyProvider()
    let s = await seeded2(url, keys)
    await s.flush()
    try await s.deleteAll()
    #expect(await s.styleSnippets().isEmpty)
    let s2 = await makeService(url, keys: keys)
    #expect(await s2.styleSnippets().isEmpty)
}

@Test func retrievalIsSameAppOnly() async {
    let s = await seeded()
    #expect(await s.styleExamples(for: "Here is the budget", field: fieldA, appKey: "app.b").isEmpty)
    #expect(await s.styleExamples(for: "Here is the budget", field: fieldA, appKey: nil).isEmpty)
    #expect(await s.styleExamples(for: "Here is the budget", field: fieldA, appKey: "app.a").count == 1)
}

@Test func retrievalSharedWithinCategory() async {
    let s = await seeded()
    await s.setAppCategories { AppCategories(apps: ["app.a": "Work", "app.b": "work"], sites: ["*.example.com": "Work"]) }
    #expect(await s.styleExamples(for: "Here is the budget", field: fieldA, appKey: "app.b").count == 1)
    #expect(await s.styleExamples(for: "Here is the budget", field: FieldID(pid: 201, elementHash: 2, generation: 1),
                                  appKey: "mail.example.com").count == 1)
    #expect(await s.styleExamples(for: "Here is the budget", field: FieldID(pid: 202, elementHash: 3, generation: 1),
                                  appKey: "app.c").isEmpty)
    // Taking the app out of the category stops sharing.
    await s.setAppCategories { AppCategories(apps: ["app.a": "Work"]) }
    #expect(await s.styleExamples(for: "Here is the budget", field: fieldA, appKey: "app.b").isEmpty)
}

@Test func oldSnippetsFallBackToBundleID() throws {
    let json = #"{"id":"1","text":"Hello there my friend.","createdAt":0,"appBundleID":"com.old.app"}"#
    let snip = try JSONDecoder().decode(StyleSnippet.self, from: Data(json.utf8))
    #expect(snip.appKey == "com.old.app")
    let none = try JSONDecoder().decode(StyleSnippet.self, from: Data(#"{"id":"1","text":"x","createdAt":0}"#.utf8))
    #expect(none.appKey == nil)
}

@Test func captureStoresSiteKey() async {
    let s = await makeService()
    let key = AppKey.make(bundleID: "com.apple.Safari", urlHost: "www.Discord.com")
    await type(s, fieldA, "", app: key)
    await typeChars(s, fieldA, good, app: key)
    await leave(s, fieldA)
    #expect(await s.styleSnippets().first?.appKey == "discord.com")
}

// MARK: Only typed text is harvestable

private let titles = (1..<8).map { "Amazing video number \($0) you will not believe this happened today!" }
    .joined(separator: " ")

@Test func pageTextAppearingInBulkIsNeverHarvested() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "Does hunch work here with this video page?")
    let typed = "Does hunch work here with this video page?"
    await type(s, fieldA, typed + " " + titles)   // page content shows up in the field text
    await leave(s, fieldA)
    #expect(await s.styleSnippets().map(\.text) == [typed])
}

@Test func pageTextWithNothingTypedSavesNothing() async {
    let s = await makeService()
    await type(s, fieldA, "Short")
    await type(s, fieldA, "Short " + titles)
    await type(s, fieldA, "")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func pastedParagraphIsNotHarvested() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await type(s, fieldA, good + " " + good.replacingOccurrences(of: "quarterly", with: "annual"))
    await type(s, fieldA, "")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func acceptedSuggestionCountsAsTyped() async {
    let s = await makeService()
    let head = "I will send the quarterly "
    let accepted = "budget report tomorrow morning."
    await type(s, fieldA, "")
    await typeChars(s, fieldA, head)
    await s.record(.accepted(field: fieldA, text: accepted), at: t0)
    await type(s, fieldA, head + accepted)
    await leave(s, fieldA)
    #expect(await s.styleSnippets().map(\.text) == [good])
}

@Test func acceptedTextOutsideWindowIsNotTyped() async {
    let s = await makeService()
    let head = "I will send the quarterly "
    let accepted = "budget report tomorrow morning."
    await type(s, fieldA, "")
    await typeChars(s, fieldA, head)
    await s.record(.accepted(field: fieldA, text: accepted), at: t0)
    await s.record(.textChanged(field: fieldA, before: head + accepted, appKey: nil), at: t0.addingTimeInterval(60))
    await leave(s, fieldA)
    #expect(await s.styleSnippets().isEmpty)
}

@Test func cjkImeCommitCountsAsTyped() async {
    let s = await makeService()
    await type(s, fieldA, "")
    var cur = ""
    for chunk in ["我明天上午", "會把這份季度", "報告寄給你，", "請放心。"] {   // IME commits of 4 to 6 characters
        cur += chunk
        await type(s, fieldA, cur)
    }
    await leave(s, fieldA)
    #expect(await s.styleSnippets().map(\.text) == [cur])
}

@Test func backspaceThenRetypeIsFine() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, "I will send the quarterly budgat")
    await type(s, fieldA, "I will send the quarterly budg")
    await typeChars(s, fieldA, "et report tomorrow morning.", after: "I will send the quarterly budg")
    await leave(s, fieldA)
    #expect(await s.styleSnippets().map(\.text) == [good])
}

@Test func typedSentenceSurvivesLaterBulkAndSend() async {
    let s = await makeService()
    await type(s, fieldA, "")
    await typeChars(s, fieldA, good)
    await type(s, fieldA, good + " " + titles)
    await type(s, fieldA, "")   // sent
    #expect(await s.styleSnippets().map(\.text) == [good])
}

// MARK: Learned phrases stay within an app or category

private func save(_ s: HistoryService, _ text: String, app: String) async {
    let f = FieldID(pid: 300, elementHash: Int.random(in: 1...Int.max), generation: 1)
    await type(s, f, "", app: app)
    await typeChars(s, f, text, app: app)
    await leave(s, f)
}

private func phraseService() async -> HistoryService {
    let s = await makeService()
    await s.setAppCategories {
        AppCategories(apps: ["com.example.chat": "Chats"], sites: ["claude.ai": "AI", "chatgpt.com": "ai"])
    }
    await save(s, "See you at the station tomorrow after work.", app: "com.example.chat")
    await save(s, "Let's meet at the station tomorrow before lunch.", app: "com.example.chat")
    await save(s, "Please refactor the parser so it handles nested quotes.", app: "claude.ai")
    await save(s, "Can you refactor the parser so the errors are clearer?", app: "claude.ai")
    await save(s, "Remember to water the garden plants every evening.", app: "com.example.notes")
    await save(s, "I should water the garden plants before the trip.", app: "com.example.notes")
    return s
}

@Test func phrasesFromChatsNeverReachAnAIApp() async {
    let s = await phraseService()
    #expect(await s.styleSnippets().count == 6)
    #expect(!(await s.phrases(for: "Meet me at the station", appKey: "com.example.chat")).isEmpty)
    #expect(await s.phrases(for: "Meet me at the station", appKey: "claude.ai").isEmpty)
    #expect(await s.phrases(for: "Meet me at the station", appKey: nil).isEmpty)
}

@Test func phrasesSharedBetweenSitesInOneCategory() async {
    let s = await phraseService()
    #expect(!(await s.phrases(for: "Now refactor the", appKey: "claude.ai")).isEmpty)
    #expect(!(await s.phrases(for: "Now refactor the", appKey: "chatgpt.com")).isEmpty)
}

@Test func uncategorizedAppSeesOnlyItsOwnPhrases() async {
    let s = await phraseService()
    #expect(!(await s.phrases(for: "Did you water the", appKey: "com.example.notes")).isEmpty)
    #expect(await s.phrases(for: "Did you water the", appKey: "com.example.other").isEmpty)
    #expect(await s.phrases(for: "Did you water the", appKey: "claude.ai").isEmpty)
    #expect(await s.phrases(for: "Meet me at the station", appKey: "com.example.notes").isEmpty)
}

@Test func movingAnAppBetweenCategoriesRebuildsPhrases() async {
    let s = await phraseService()
    #expect(await s.phrases(for: "Meet me at the station", appKey: "claude.ai").isEmpty)
    // The chat app joins AI: its sentences now count there, and the cached AI index is not reused.
    await s.setAppCategories {
        AppCategories(apps: ["com.example.chat": "AI"], sites: ["claude.ai": "AI", "chatgpt.com": "ai"])
    }
    #expect(!(await s.phrases(for: "Meet me at the station", appKey: "claude.ai")).isEmpty)
    // Deleting its sentences takes them out again.
    for snip in await s.styleSnippets() where snip.appKey == "com.example.chat" { await s.deleteSnippet(id: snip.id) }
    #expect(await s.phrases(for: "Meet me at the station", appKey: "claude.ai").isEmpty)
}

@Test func phraseIndexIsBuiltRightAfterASave() async throws {
    let s = HistoryService(store: EncryptedHistoryStore(url: tempURL(), keys: InMemoryKeyProvider()),
                           saveDelay: .milliseconds(20), phraseWarmDelay: .milliseconds(10))
    await s.setStyleCaptureEnabled(true)
    await s.setAppCategories { AppCategories(sites: ["claude.ai": "AI", "chatgpt.com": "AI"]) }
    await save(s, "Please refactor the parser so it handles nested quotes.", app: "claude.ai")
    var ready = false
    for _ in 0..<100 where !ready {
        try await Task.sleep(for: .milliseconds(20))
        ready = await s.phrasesReady(for: "chatgpt.com")   // same category, same index
    }
    #expect(ready)
    #expect(!(await s.phrases(for: "Now refactor the", appKey: "claude.ai")).isEmpty)
    // Deleting the sentence drops the index with it.
    for snip in await s.styleSnippets() { await s.deleteSnippet(id: snip.id) }
    #expect(!(await s.phrasesReady(for: "claude.ai")))
}
