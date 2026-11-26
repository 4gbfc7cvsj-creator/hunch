import Foundation
import HunchCore
import Testing
@testable import HunchText

/// A completion of a half-typed learned word must end as that word or a dictionary word.
@Suite struct LearnedWordFinishTests {
    // The app's checker treats learned words as spelled right and as known prefixes.
    let checker = FakeSpell(["micros", "the", "to", "group", "sarah", "microspikes"])

    func run(_ raw: String, before: String, learned: [String]) -> PostOutcome {
        var context = PostContext(before: before, after: "", requiredPrefix: "", allowNewlines: false, maxWords: 6)
        context.learnedWords = learned
        return DefaultPostProcessor(spellChecker: checker, prefaceTexts: []).process(raw, meanLogProb: nil, context: context)
    }

    @Test func mangledLearnedWordIsDropped() {
        #expect(run("eak to the group", before: "I lent my microsp", learned: ["microspikes"]) == .suppress(.likelyTypo))
    }

    @Test func theLearnedWordItselfIsKept() {
        #expect(run("ikes to Sarah", before: "I lent my microsp", learned: ["microspikes"]) == .show("ikes to Sarah"))
    }

    @Test func aDictionaryWordIsAllowed() {
        // "micros" is a word; the mid-word bias, not this check, is what keeps "microspikes" on track.
        #expect(run("os to Sarah", before: "I lent my micr", learned: ["microspikes"]) == .show("os to Sarah"))
    }

    @Test func onlyWhenALearnedWordIsInPlay() {
        // Same text without the learned word in play: the old rule (the typed part is a known prefix) keeps it.
        #expect(run("eak to the group", before: "I lent my microsp", learned: []) == .show("eak to the group"))
        // A learned word that doesn't extend the typed letters doesn't count.
        #expect(run("eak to the group", before: "I lent my microsp", learned: ["Priya"]) == .show("eak to the group"))
    }

    @Test func finishesMatchesCaseInsensitively() {
        #expect(TypoDetector.finishes("micr", into: "Microspikes", not: "micros"))
        #expect(!TypoDetector.finishes("microspikes", into: "microspikes", not: "microspikesx"))
        #expect(!TypoDetector.finishes("micr", into: " microspikes", not: "microspikes"))
    }
}
