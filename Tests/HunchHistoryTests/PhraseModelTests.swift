import Foundation
import HunchCore
import Testing
@testable import HunchHistory

@Suite struct PhraseModelTests {
    private let model = PhraseModel(sentences: [
        "Sounds good, see you tomorrow at the office.",
        "Ok see you tomorrow then!",
        "I will see you tomorrow morning before the standup.",
        "Alex Morgan will send the deck after lunch.",
    ])

    private func texts(_ before: String, in m: PhraseModel? = nil) -> [String] {
        (m ?? model).continuations(after: before).map(\.text)
    }

    @Test func continuesAPhraseSharedBySeveralSentences() throws {
        let top = try #require(model.continuations(after: "Great, see you").first)
        #expect(top.text == " tomorrow")
        #expect(top.support == 3)
        #expect(top.weight > 0.3)
    }

    @Test func spacingFollowsTheCaret() {
        #expect(texts("Great, see you ").first == "tomorrow")
        #expect(texts("Great, see you").first == " tomorrow")
        #expect(texts("Great, see you").allSatisfy { $0.hasPrefix(" tomorrow") })
        // Mid-word: the rest of the word, then the phrase.
        #expect(texts("Great, see you tom").first == "orrow")
        #expect(texts("Great, see you tomo").first == "rrow")
    }

    @Test func noMatchGivesNothing() {
        #expect(texts("The weather is").isEmpty)
        #expect(texts("").isEmpty)
        #expect(PhraseModel(sentences: []).continuations(after: "see you").isEmpty)
        // One word of context is not enough.
        #expect(texts("tomorrow").isEmpty)
    }

    @Test func longerContextWeighsMore() throws {
        let m = PhraseModel(sentences: [
            "please send the report by friday",
            "could you send the report by noon",
            "we send the invoice monthly",
            "they send the invoice weekly",
        ])
        let short = try #require(m.continuations(after: "I will send the").first { $0.text.hasPrefix(" report") })
        let long = try #require(m.continuations(after: "could you send the report").first)
        #expect(long.context > short.context)
        #expect(PhraseModel.backoff(2) < PhraseModel.backoff(3))
        #expect(PhraseModel.backoff(3) < PhraseModel.backoff(4))
        #expect(PhraseModel.backoff(6) == 1)
        #expect(long.weight > short.weight)
    }

    @Test func aOneOffSentenceIsScaledDownAndKeptShort() throws {
        let one = try #require(model.continuations(after: "Alex Morgan will").first)
        #expect(one.support == 1)
        #expect(one.weight <= PhraseModel.singleScale)
        // "will" ends at the caret, so it counts as the word being typed: 3 units = will, send, the.
        #expect(one.text == " send the")
        let m = PhraseModel(sentences: [
            "Alex Morgan will send the deck after lunch.",
            "Alex Morgan will send the deck tomorrow.",
        ])
        let two = try #require(m.continuations(after: "Alex Morgan will").first)
        #expect(two.support == 2)
        #expect(two.weight > one.weight)
        #expect(two.text == " send the deck")
    }

    @Test func sentenceStartMatches() {
        let m = PhraseModel(sentences: ["Thanks for the quick reply.", "Thanks for the update!",
                                        "No thanks for now."])
        #expect(texts("Hi Alex. Thanks for", in: m).first == " the")
        #expect(texts("Thanks", in: m).first == " for the")
    }

    @Test func chineseMatchesAcrossScriptsAndAnswersInTheWritersScript() throws {
        let m = PhraseModel(sentences: ["我們明天見面討論一下吧。", "那我们明天见面再说。", "好的，我們明天見面。"])
        let trad = try #require(m.continuations(after: "那我們明天").first)
        #expect(trad.text.hasPrefix("見面"))
        #expect(trad.support == 3)
        let simp = try #require(m.continuations(after: "那我们明天").first)
        #expect(simp.text.hasPrefix("见面"))
    }

    @Test func lookupIsFastOnALargeLibrary() {
        let words = ["alpha", "beta", "gamma", "delta", "see", "you", "the", "a", "report", "send"]
        var rng = SystemRandomNumberGenerator()
        let sentences = (0..<3000).map { _ in
            (0..<12).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
        }
        let m = PhraseModel(sentences: sentences)
        let start = Date()
        for _ in 0..<50 { _ = m.continuations(after: "please send the report to the") }
        #expect(Date().timeIntervalSince(start) / 50 < 0.05)
    }
}

