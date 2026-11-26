import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private let v = FakeVocabulary.standard

private func cfg(maxWords: Int = 10) -> DecodeConfig {
    DecodeConfig(minWords: 1, maxWords: maxWords, firstTokenFanout: 1, minMeanLogProb: -10)
}

private func run(_ script: [String: [TokenID: Float]], required: String = "",
                 phrases: [(String, Float)] = [], strength: Float = 1) throws -> ScoredCandidate? {
    let bias = LearnedBias(phrases: phrases.map { .init(text: $0.0, weight: $0.1) }, phraseStrength: strength)
    return try GreedyConstrainedSearch().searchScored(in: FakeSession(script: script), requiredPrefix: Array(required.utf8),
                                                      config: cfg(), bias: bias) { _ in }.first
}

@Suite struct LearnedPhraseSearchTests {
    private let nearTie = makeScript([
        "": [(" banana", -1.0), (" apple", -1.2)],
        " banana": [(" is", -0.2)],
        " banana is": [(" red", -0.3)],
        " apple": [(" is", -0.2)],
        " apple is": [(" red", -0.3)],
    ])

    @Test func aPhraseSteersANearTie() throws {
        #expect(try run(nearTie)?.candidate.text == " banana is red")
        let steered = try #require(try run(nearTie, phrases: [(" apple is", 1)], strength: 1))
        #expect(steered.candidate.text == " apple is red")
        // Scores stay the model's own.
        #expect(abs(steered.candidate.totalLogProb - (-1.7)) < 0.001)
    }

    @Test func noPhrasesOrZeroStrengthChangesNothing() throws {
        let base = try run(nearTie)
        #expect(try run(nearTie, phrases: [(" apple", 1)], strength: 0) == base)
        #expect(try run(nearTie, phrases: [], strength: 3) == base)
        #expect(try run(nearTie, phrases: [(" cherry pie", 1)], strength: 3) == base)
    }

    @Test func theBonusIsCappedSoAClearGapHolds() throws {
        let gap = makeScript(["": [(" banana", -0.1), (" apple", -2.5)]])
        #expect(try run(gap, phrases: [(" apple", 1)], strength: 2)?.candidate.text == " banana")
    }

    @Test func anImplausibleTokenGetsNoBonusAtAnyStrength() throws {
        // " apple" at -5 is below the floor (-4): even a huge strength can't pick it.
        let unlikely = makeScript(["": [(" banana", -0.01), (" apple", -5)]])
        #expect(try run(unlikely, phrases: [(" apple", 1)], strength: 50)?.candidate.text == " banana")
        // Just above the floor, a big enough strength would; the cap is what keeps it bounded.
        let plausible = makeScript(["": [(" banana", -0.01), (" apple", -3.5)]])
        #expect(try run(plausible, phrases: [(" apple", 1)], strength: 50)?.candidate.text == " apple")
    }

    @Test func phrasesOnlyApplyAtTheCaret() throws {
        // " apple" would win the second word if a phrase could start anywhere.
        let later = makeScript([
            "": [(" banana", -0.1)],
            " banana": [(" is", -1.0), (" apple", -1.2)],
            " banana is": [(" red", -0.3)],
        ])
        #expect(try run(later, phrases: [(" apple", 1)], strength: 1)?.candidate.text == " banana is red")
    }

    @Test func midWordTheFloorIsGivenTheTypedLetters() throws {
        // Typed " a": " apple" is unlikely overall (-6) but likely among words starting with "a".
        let script = makeScript(["": [(" banana", -0.01), (" an", -5.5), (" apple", -6.0), (" a", -9.0)]])
        let plain = try #require(try run(script, required: " a"))
        #expect(plain.candidate.tokens.first == v.id(" an"))
        let steered = try #require(try run(script, required: " a", phrases: [("pple", 1)], strength: 1))
        #expect(steered.candidate.tokens.first == v.id(" apple"))
    }

    @Test func phrasesFollowTheRequiredPrefix() throws {
        // Typed " a" (healed): the phrase text continues the typed word ("pple").
        let script = makeScript(["": [(" an", -1.0), (" apple", -1.3), (" a", -5.0)]])
        let plain = try #require(try run(script, required: " a"))
        #expect(plain.candidate.tokens.first == v.id(" an"))
        let steered = try #require(try run(script, required: " a", phrases: [("pple", 1)], strength: 1))
        #expect(steered.candidate.tokens.first == v.id(" apple"))
    }
}

@Suite struct TokenStartIndexTests {
    @Test func phraseTokensMatchTheFullScan() throws {
        // The anchored (indexed) trie offers the same tokens as the scanned one would accept.
        let classes = TokenClassCache.shared.classes(for: v)
        let entries: [LearnedBias.Entry] = [.init(text: " apple is red", weight: 1), .init(text: " a", weight: 0.5)]
        let anchored = try #require(CompiledBias.make(vocabulary: v, classes: classes, entries: entries, anchored: true))
        let scanned = try #require(CompiledBias.make(vocabulary: v, classes: classes, entries: entries))
        let a = anchored.map(PhraseState(), strength: 1)
        let s = scanned.map(PhraseState(), strength: 1)
        #expect(!a.isEmpty)
        #expect(Set(a.keys) == Set(s.keys))
        #expect(a[v.id(" apple")] != nil)
        #expect(a[v.id(" banana")] == nil)
    }
}

@Suite struct PhraseCurveTests {
    @Test func theFirstTokenEarnsMostOfThePhraseAndTheTotalStaysCapped() throws {
        let classes = TokenClassCache.shared.classes(for: v)
        let phrase = try #require(CompiledBias.make(vocabulary: v, classes: classes,
                                                    entries: [.init(text: " apple is red", weight: 1)], anchored: true))
        var state = PhraseState()
        let first = try #require(phrase.map(state, strength: 1)[v.id(" apple")])
        // " apple" is 6 of 13 bytes: sqrt(6/13) ≈ 0.68 (an even spread would give 0.46).
        #expect(abs(first - (6.0 / 13.0).squareRoot()) < 0.01)
        var total = first
        for word in [" apple", " is", " red"] {
            if word != " apple" { total += phrase.map(state, strength: 1)[v.id(word)] ?? 0 }
            phrase.advance(&state, Array(word.utf8)[...])
        }
        #expect(abs(total - 1) < 0.001)
    }
}

@Test func phraseStrengthFollowsThePersonalizeSlider() {
    #expect(LearnedBias.phraseStrength(personalize: 0) == 0)
    #expect(LearnedBias.phraseStrength(personalize: 1.5) == LearnedBias.defaultPhraseStrength)
    #expect(LearnedBias.phraseStrength(personalize: 0.75) == LearnedBias.defaultPhraseStrength / 2)
    #expect(LearnedBias.phraseStrength(personalize: 3) == LearnedBias.defaultPhraseStrength)
}
