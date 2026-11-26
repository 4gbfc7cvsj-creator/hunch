import Foundation
import HunchCore
import Testing
@testable import HunchHistory

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let field = FieldID(pid: 300, elementHash: 1, generation: 1)

/// Synthetic, digit-free fixtures: the older shape heuristics (`looksLikeSecret`) let these
/// through, so only the shared sanitizer stops them.
private let openAIKey = "sk-" + "fakefakefakefakefakefake"
private let awsKey = "AKIA" + "FAKEFAKEFAKEFAKE"

private func makeService() async -> HistoryService {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).bin")
    let s = HistoryService(store: EncryptedHistoryStore(url: url, keys: InMemoryKeyProvider()),
                           saveDelay: .milliseconds(20))
    await s.setStyleCaptureEnabled(true)
    return s
}

@Test func secretSentencesAreNotHarvested() async {
    let s = await makeService()
    await s.record(.textChanged(field: field, before: "", appKey: nil), at: t0)
    let clean = "I will send the quarterly budget report tomorrow morning."
    let text = [
        "My password: correcthorsebattery is on the sticky note.",
        "Das Passwort: sommerregen steht auf dem Zettel dort.",
        "Paste \(openAIKey) into the settings box later today.",
        clean,
    ].joined(separator: " ")
    var current = ""
    for ch in text {
        current.append(ch)
        await s.record(.textChanged(field: field, before: current, appKey: nil), at: t0)
    }
    await s.record(.focusLeft(field: field), at: t0)
    #expect(await s.styleSnippets().map(\.text) == [clean])
}

@Test func keyLikeWordsAreNeverLearned() {
    var m = VocabularyModel()
    for (i, word) in [openAIKey, awsKey, "Kubernetes"].enumerated() {
        let f = FieldID(pid: 1, elementHash: i, generation: 1)
        m.apply(LearningEvent(field: f, kind: .confirmed(words: [WordScore(text: " " + word, logProb: -6)],
                                                         context: [])), now: t0)
        m.apply(LearningEvent(field: f, kind: .correctionSkipped(word: word)), now: t0)
    }
    #expect(m.entries[VocabularyModel.key(openAIKey)] == nil)
    #expect(m.entries[VocabularyModel.key(awsKey)] == nil)
    #expect(m.entries["kubernetes"] != nil)
}
