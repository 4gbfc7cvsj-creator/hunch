import Testing
@testable import HunchHistory

@Suite struct VocabularyGateTests {
    let emma = VocabularyGate.Candidate(text: "Emma", weight: 0.8, contexts: ["tell": 2])
    let riley = VocabularyGate.Candidate(text: "Riley", weight: 0.9, contexts: ["sync with": 2, "with": 2])
    let spikes = VocabularyGate.Candidate(text: "microspikes", weight: 0.5, contexts: ["bring": 2])
    let sentences = ["bring microspikes, it's icy up top", "trail report: snow above 5000 ft, bring microspikes",
                     "1:1 with Riley: wants more ownership of integrations, worried about on-call load",
                     "tell Emma I said hi"]

    func pick(_ before: String, screen: String? = nil, minOverlap: Int = 2) -> [String] {
        VocabularyGate.select([emma, riley, spikes], sentences: sentences, before: before, screen: screen,
                              minOverlap: minOverlap).map(\.text)
    }

    @Test func leadInPassesWithoutTopic() {
        #expect(pick("yes! tell ") == ["Emma"])
        #expect(pick("let me sync with ") == ["Riley"])
        #expect(pick("Did you remember to feed ").isEmpty)
        // "with" alone is a stopword: only the two-word lead-in counts.
        #expect(pick("I talked with ").isEmpty)
    }

    @Test func topicNeedsEnoughSharedWords() {
        let screen = "Kai: trail report says icy up top, snow above 5000 ft"
        #expect(pick("good call, I'll pack ", screen: screen) == ["microspikes"])
        #expect(pick("good call, I'll pack ", screen: "Kai: see you saturday").isEmpty)
        // One shared word ("integrations") passes only at overlap 1.
        #expect(pick("Agreed, I talked to ", screen: "the integrations folks are busy").isEmpty)
        #expect(pick("Agreed, I talked to ", screen: "the integrations folks are busy", minOverlap: 1) == ["Riley"])
    }

    @Test func midWordKeepsOnlyExtensionsOfTheTypedLetters() {
        #expect(pick("yes! tell Em") == ["Emma"])
        #expect(pick("yes! tell No").isEmpty)
        #expect(pick("yes! tell Emma").isEmpty)
    }

    @Test func limitAndOrder() {
        let screen = "trail report: icy above 5000 ft"
        let all = VocabularyGate.select([emma, riley, spikes], sentences: sentences, before: "tell ", screen: screen)
        #expect(all.map(\.text) == ["Emma", "microspikes"])
        #expect(all.first?.leadIn == true)
        #expect(VocabularyGate.select([emma, riley, spikes], sentences: sentences, before: "tell ", screen: screen, limit: 1).count == 1)
    }

    @Test func sentenceIsTheTextAfterTheLastStop() {
        #expect(VocabularyGate.currentSentence("Hi. Thanks for the note! I'll send the") == " I'll send the")
        #expect(VocabularyGate.currentSentence("line one\nline two") == "line two")
    }

    @Test func reasonsForTheConsole() {
        let lead = VocabularyGate.select([emma, riley, spikes], sentences: sentences, before: "yes! tell Em", screen: nil)
        #expect(lead.first?.reason == "lead-in \"tell\" + mid-word \"em\"")
        let topic = VocabularyGate.select([emma, riley, spikes], sentences: sentences, before: "good call, I'll pack ",
                                          screen: "Kai: trail report says icy up top, snow above 5000 ft")
        #expect(topic.first?.reason.hasPrefix("topic {") == true)
        #expect(topic.first?.sharedWords.contains("icy") == true)
    }
}
