import Foundation
import HunchCore
import Testing
@testable import HunchDecode

private let v = FakeVocabulary.standard

private func cfg(minWords: Int = 1, maxWords: Int = 10, fanout: Int = 1) -> DecodeConfig {
    DecodeConfig(minWords: minWords, maxWords: maxWords, firstTokenFanout: fanout, minMeanLogProb: -10,
                 wordStartMinFirstLogProb: nil, midWordMinMeanLogProb: nil)
}

private func scored(_ session: FakeSession, required: String = "", config: DecodeConfig = cfg(),
                    bias: LearnedBias = LearnedBias()) throws -> [ScoredCandidate] {
    try GreedyConstrainedSearch().searchScored(in: session, requiredPrefix: Array(required.utf8), config: config,
                                               bias: bias) { _ in }
}

private func bias(_ pairs: [(String, Float)], strength: Float = 1) -> LearnedBias {
    LearnedBias(entries: pairs.map { .init(text: $0.0, weight: $0.1) }, strength: strength)
}

@Suite struct LearnedBiasSearchTests {
    private let nearTie = makeScript([
        "": [(" banana", -1.0), (" apple", -1.2)],
        " banana": [(" is", -0.2)],
        " banana is": [(" red", -0.3)],
        " apple": [(" is", -0.2)],
        " apple is": [(" red", -0.3)],
    ])

    @Test func biasSteersANearTie() throws {
        let plain = try #require(try scored(FakeSession(script: nearTie)).first)
        #expect(plain.candidate.text == " banana is red")
        let steered = try #require(try scored(FakeSession(script: nearTie), bias: bias([(" apple", 1)], strength: 0.5)).first)
        #expect(steered.candidate.text == " apple is red")
        // Statistics stay raw: -1.2 -0.2 -0.3, not including the bias.
        #expect(abs(steered.candidate.totalLogProb - (-1.7)) < 0.001)
    }

    @Test func biasTooWeakToOvercomeAClearGap() throws {
        let gap = makeScript(["": [(" banana", -0.1), (" apple", -3.0)]])
        let best = try #require(try scored(FakeSession(script: gap), bias: bias([(" apple", 1)], strength: 1)).first)
        #expect(best.candidate.text == " banana")
    }

    @Test func emptyOrZeroStrengthBiasIsIdentical() throws {
        let base = try scored(FakeSession(script: nearTie))
        let zero = try scored(FakeSession(script: nearTie), bias: bias([(" apple", 1)], strength: 0))
        let none = try scored(FakeSession(script: nearTie), bias: LearnedBias(entries: [], strength: 2))
        let zeroWeight = try scored(FakeSession(script: nearTie), bias: bias([(" apple", 0)], strength: 3))
        #expect(base == zero)
        #expect(base == none)
        #expect(base == zeroWeight)
        // And equal to the protocol entry point.
        let viaProtocol = try GreedyConstrainedSearch().search(in: FakeSession(script: nearTie), requiredPrefix: [],
                                                               config: cfg()) { _ in }
        #expect(viaProtocol == base.map(\.candidate))
    }

    @Test func unrelatedEntriesChangeNothing() throws {
        let base = try scored(FakeSession(script: nearTie))
        let other = try scored(FakeSession(script: nearTie), bias: bias([(" Smith", 1), (" engineer", 1)], strength: 3))
        #expect(base == other)
    }

    @Test func biasNeverViolatesTheRequiredPrefix() throws {
        let script = makeScript(["": [(" banana", -0.1), (" apple", -3.0), (" a", -4.0)]])
        let session = FakeSession(script: script)
        let best = try #require(try scored(session, required: " a", bias: bias([(" banana", 1)], strength: 3)).first)
        // " banana" does not start with " a": never chosen, however strong the bias.
        #expect(best.candidate.tokens.first == v.id(" apple"))
        #expect(best.candidate.text.hasPrefix("pple"))
    }

    @Test func biasAppliesInsideTheAdmissibleSet() throws {
        let script = makeScript(["": [(" an", -1.0), (" apple", -1.3), (" a", -5.0)]])
        let plain = try #require(try scored(FakeSession(script: script), required: " a").first)
        let steered = try #require(try scored(FakeSession(script: script), required: " a",
                                              bias: bias([(" apple", 1)], strength: 0.6)).first)
        #expect(plain.candidate.tokens.first == v.id(" an"))
        #expect(steered.candidate.tokens.first == v.id(" apple"))
    }

    @Test func phraseBiasCarriesAcrossAWordBoundary() throws {
        let script = makeScript([
            "": [(" Thanks", -1.0), (" Mr", -1.3)],
            " Mr": [(" Sam", -0.5), (" Smith", -0.8)],
            " Thanks": [(" Sam", -0.5), (" Smith", -0.8)],
        ])
        let plain = try #require(try scored(FakeSession(script: script), config: cfg(maxWords: 2)).first)
        #expect(plain.candidate.text == " Thanks Sam")
        let phrase = bias([(" Mr Smith", 1)], strength: 2)
        let steered = try #require(try scored(FakeSession(script: script), config: cfg(maxWords: 2), bias: phrase).first)
        #expect(steered.candidate.text == " Mr Smith")
        // " Smith" alone (not preceded by " Mr") gets nothing: the phrase state is what matters.
        let wrongStart = try #require(try scored(FakeSession(script: makeScript([
            "": [(" Thanks", -0.1)], " Thanks": [(" Sam", -0.5), (" Smith", -0.8)],
        ])), config: cfg(maxWords: 2), bias: phrase).first)
        #expect(wrongStart.candidate.text == " Thanks Sam")
    }

    @Test func tokenThatOnlyStartsAnEntryEarnsOnlyAShare() throws {
        // " hea" is the first half of the entry " hearing" (4 of 8 bytes): its bonus is half of
        // weight * strength, not the full amount, so a 1.5 nat gap survives strength 2 (bonus 1)
        // and falls at strength 4 (bonus 2).
        let script = makeScript(["": [(" red", -1.0), (" hea", -2.5)], " red": [(" is", -0.2)],
                                 " hea": [("ring", -0.1)]])
        let entry = [(" hearing", Float(1))]
        let weak = try #require(try scored(FakeSession(script: script), bias: bias(entry, strength: 2)).first)
        #expect(weak.candidate.tokens.first == v.id(" red"))
        let strong = try #require(try scored(FakeSession(script: script), bias: bias(entry, strength: 4)).first)
        #expect(strong.candidate.text == " hearing")
        // Completing the entry earns the rest: the whole-word token gets the full amount.
        let whole = makeScript(["": [(" red", -1.0), (" hearing", -2.5)]])
        let full = try #require(try scored(FakeSession(script: whole), bias: bias(entry, strength: 2)).first)
        #expect(full.candidate.tokens.first == v.id(" hearing"))
    }

    @Test func divergingFromAnEntryStartIsNotRewardedFurther() throws {
        // The entry start wins at strength 4, but "aring" is not the entry's continuation ("ring"):
        // it earns nothing, so the model's own choice decides the rest.
        let script = makeScript(["": [(" red", -1.0), (" hea", -2.5)], " hea": [("aring", -0.2), ("ring", -3.0)]])
        let best = try #require(try scored(FakeSession(script: script), bias: bias([(" hearing", 1)], strength: 4)).first)
        #expect(best.candidate.tokens == [v.id(" hea"), v.id("aring")])
    }

    @Test func unrelatedChoicesAreUnaffectedAtAnyStrength() throws {
        // Entry " engineer": " e" (1 of 9 bytes) and " an" share nothing useful. Choices stay the same
        // however strong the strength.
        let base = try scored(FakeSession(script: nearTie))
        for strength: Float in [1, 6, 20] {
            let other = try scored(FakeSession(script: nearTie), bias: bias([(" engineer", 1), (" another", 1)], strength: strength))
            #expect(other.map(\.candidate.text) == base.map(\.candidate.text))
        }
    }

    @Test func aFinishedEntryEarnsNoSecondBonus() throws {
        let script = makeScript([
            "": [(" banana", -1.0), (" apple", -1.2)],
            " banana": [(" banana", -1.5), (" is", -1.2)],
            " banana is": [(" red", -0.3)],
        ])
        let best = try #require(try scored(FakeSession(script: script), bias: bias([(" banana", 1)], strength: 1)).first)
        #expect(best.candidate.text == " banana is red")
    }

    @Test func fanoutRanksByTheBiasedPathButReportsRawStatistics() throws {
        let session = FakeSession(script: nearTie)
        let results = try scored(session, config: cfg(fanout: 2), bias: bias([(" apple", 1)], strength: 0.5))
        let best = try #require(results.first)
        #expect(best.candidate.text == " apple is red")
        #expect(abs(best.candidate.totalLogProb - (-1.7)) < 0.001)
        #expect(results.count == 2)
    }
}

@Suite struct WordScoreTests {
    @Test func scoresAlignWithTheShownText() throws {
        let script = makeScript([
            "": [(" banana", -0.5)],
            " banana": [(" is", -0.25)],
            " banana is": [(" red", -1.5)],
        ])
        let best = try #require(try scored(FakeSession(script: script)).first)
        let words = WordScoring.scores(shown: best.candidate.text, for: best)
        #expect(words.map(\.text) == [" banana", " is", " red"])
        #expect(words.map(\.logProb) == [-0.5, -0.25, -1.5])
    }

    @Test func trimmedTailKeepsTheAlignedPrefixOnly() throws {
        let script = makeScript([
            "": [(" banana", -0.5)], " banana": [(" is", -0.25)], " banana is": [(" red", -1.5)],
        ])
        let best = try #require(try scored(FakeSession(script: script)).first)
        let trimmed = WordScoring.scores(shown: " banana is", for: best)
        #expect(trimmed.map(\.text) == [" banana", " is"])
        // Leading space trimmed by post-processing: the word is reported as shown.
        let noSpace = WordScoring.scores(shown: "banana is", for: best)
        #expect(noSpace.map(\.text) == ["banana", " is"])
        #expect(noSpace.map(\.logProb) == [-0.5, -0.25])
        // A word that no longer matches stops the alignment.
        let changed = WordScoring.scores(shown: " banana IS red", for: best)
        #expect(changed.map(\.text) == [" banana"])
        #expect(WordScoring.scores(shown: " grape", for: best).isEmpty)
    }

    @Test func healedFirstWordScoresOnlyTheVisibleCompletion() throws {
        let script = makeScript([
            "": [(" hearing", -0.3), (" hea", -3.0)],
            " hearing": [(" one", -0.2)],
            " hearing one": [(".", -0.1)],
        ])
        let best = try #require(try scored(FakeSession(script: script), required: " hea").first)
        #expect(best.candidate.text == "ring one.")
        let words = WordScoring.scores(shown: best.candidate.text, for: best)
        #expect(words.map(\.text) == ["ring", " one."])
        // The healed token is renormalized over tokens that start with " hea" (here " hearing"
        // and " hea"; the rest of the admissible set sits near -30).
        let conditional: Float = -0.3 - log(exp(-0.3) + exp(-3.0))
        #expect(abs(words[0].logProb - conditional) < 0.01)
        #expect(abs(words[1].logProb - (-0.2 - 0.1)) < 0.0001)
    }

    @Test func tokenSpanningWordsSplitsItsScoreByBytes() {
        let candidate = Candidate(text: " ab cd", tokens: [], meanLogProb: 0, totalLogProb: 0, stop: .tokenCap)
        let scored = ScoredCandidate(candidate: candidate, spans: [TokenSpan(byteCount: 6, logProb: -2)])
        let words = WordScoring.scores(shown: " ab cd", for: scored)
        #expect(words.map(\.logProb) == [-1, -1])
    }

    @Test func whitespaceOnlyTokenJoinsTheNextWord() {
        let candidate = Candidate(text: " hello", tokens: [], meanLogProb: 0, totalLogProb: 0, stop: .tokenCap)
        let scored = ScoredCandidate(candidate: candidate, spans: [TokenSpan(byteCount: 1, logProb: -2),
                                                                   TokenSpan(byteCount: 5, logProb: -1)])
        #expect(WordScoring.scores(shown: " hello", for: scored).map(\.logProb) == [-3])
    }

    @Test func scoresAreRawEvenWhenBiasChoseTheToken() throws {
        let script = makeScript([
            "": [(" banana", -1.0), (" apple", -1.2)], " apple": [(" is", -0.2)],
        ])
        let best = try #require(try scored(FakeSession(script: script),
                                           bias: bias([(" apple", 1)], strength: 2)).first)
        let words = WordScoring.scores(shown: best.candidate.text, for: best)
        #expect(words.map(\.text) == [" apple", " is"])
        #expect(words.map(\.logProb) == [-1.2, -0.2])
    }
}

@Suite struct NestedBiasEntryTests {
    private func total(_ entries: [LearnedBias.Entry], pieces: [String], strength: Float) throws -> Float {
        let classes = TokenClassCache.shared.classes(for: v)
        let compiled = try #require(CompiledBias.make(vocabulary: v, classes: classes, entries: entries))
        var state = BiasState()
        var sum: Float = 0
        for piece in pieces {
            sum += compiled.map(state, strength: strength)[v.id(piece)] ?? 0
            compiled.advance(&state, Array(piece.utf8)[...])
        }
        return sum
    }

    @Test func nestedEntriesNeverPayMoreThanTheBestEntry() throws {
        let nested: [LearnedBias.Entry] = [.init(text: " Mr", weight: 0.3), .init(text: " Mr Smith", weight: 1)]
        let both = try total(nested, pieces: [" Mr", " Smith"], strength: 2)
        #expect(both <= 2 + 1e-4)
        #expect(both > 1.5)  // the heavy entry is still rewarded once completed
        // Only the light entry matched (the path stops after " Mr" and goes elsewhere): at most its own share.
        let stopped = try total(nested, pieces: [" Mr", " is"], strength: 2)
        #expect(stopped <= 2 + 1e-4)
        // Same text without the nested prefix entry: the total is the same ceiling.
        let alone = try total([.init(text: " Mr Smith", weight: 1)], pieces: [" Mr", " Smith"], strength: 2)
        #expect(abs(alone - 2) < 1e-4)
        #expect(both <= alone + 1e-4)
    }

    @Test func heavyWeightIsNotPairedWithALighterEntrysCloseness() throws {
        // " an" completes the light entry at once; the heavy entry " avid" must not lend it its weight.
        let entries: [LearnedBias.Entry] = [.init(text: " an", weight: 0.1), .init(text: " apple", weight: 1)]
        let classes = TokenClassCache.shared.classes(for: v)
        let compiled = try #require(CompiledBias.make(vocabulary: v, classes: classes, entries: entries))
        let map = compiled.map(BiasState(), strength: 1)
        #expect((map[v.id(" an")] ?? 0) <= 0.35)
        #expect(abs((map[v.id(" apple")] ?? 0) - 1) < 1e-4)
    }

    @Test func traditionalShownTextStillGetsWordScores() throws {
        let simplifiedVocabulary = makeScript(["": [("我", -0.5)], "我": [("们", -0.25)]])
        let best = try #require(try scored(FakeSession(script: simplifiedVocabulary)).first)
        let words = WordScoring.scores(shown: "我們", for: best)
        #expect(words.map(\.text) == ["我們"])
        #expect(!words.isEmpty)
    }
}

@Suite struct AvoidSearchTests {
    private let nearTie = makeScript([
        "": [(" banana", -1.0), (" apple", -1.2)],
        " banana": [(" is", -0.2)],
        " banana is": [(" red", -0.3)],
        " apple": [(" is", -0.2)],
        " apple is": [(" red", -0.3)],
    ])

    @Test func blockedWordLosesANearTieItWouldWin() throws {
        let plain = try #require(try scored(FakeSession(script: nearTie)).first)
        #expect(plain.candidate.text == " banana is red")
        // Strength is 0: blocking still applies.
        let blocked = LearnedBias(entries: [], strength: 0, avoid: ["banana"])
        let best = try #require(try scored(FakeSession(script: nearTie), bias: blocked).first)
        #expect(best.candidate.text == " apple is red")
        // Statistics stay raw.
        #expect(abs(best.candidate.totalLogProb - (-1.7)) < 0.001)
        // Capitalized spelling in the list still matches the lowercase continuation.
        let cap = LearnedBias(avoid: ["Banana"])
        #expect(try scored(FakeSession(script: nearTie), bias: cap).first?.candidate.text == " apple is red")
    }

    @Test func unrelatedChoicesAreUntouched() throws {
        let base = try scored(FakeSession(script: nearTie))
        let other = LearnedBias(avoid: ["zz", "something else"])
        #expect(try scored(FakeSession(script: nearTie), bias: other) == base)
        // Zero penalty disables it.
        let off = LearnedBias(avoid: ["banana"], avoidPenalty: 0)
        #expect(try scored(FakeSession(script: nearTie), bias: off) == base)
    }

    @Test func blockedWordStillWinsWhenTheAlternativeIsFarWorse() throws {
        // Not a hard ban: -0.1 vs -12 stays with the blocked word under an 8-logit penalty.
        let gap = makeScript(["": [(" banana", -0.1), (" apple", -12.0)]])
        let best = try #require(try scored(FakeSession(script: gap), bias: LearnedBias(avoid: ["banana"])).first)
        #expect(best.candidate.text == " banana")
    }

    @Test func requiredPrefixStaysAdmissible() throws {
        let script = makeScript(["": [(" apple", -1.0), (" an", -1.3), (" banana", -0.1)]])
        let blocked = LearnedBias(avoid: ["apple"])
        // The penalty reorders inside the admissible set (" a" allows " an" and " apple")...
        let plain = try #require(try scored(FakeSession(script: script), required: " a").first)
        let steered = try #require(try scored(FakeSession(script: script), required: " a", bias: blocked).first)
        #expect(plain.candidate.tokens.first == v.id(" apple"))
        #expect(steered.candidate.tokens.first == v.id(" an"))
        // ...but never admits a token outside it (" banana" is far better, still excluded).
        #expect(steered.candidate.tokens.first != v.id(" banana"))
        // When the blocked word is the only admissible continuation it stays possible.
        for fanout in [1, 3] {
            let only = try scored(FakeSession(script: script), required: " app", config: cfg(fanout: fanout),
                                  bias: blocked)
            let first = try #require(only.first)
            #expect(first.candidate.tokens.first == v.id(" apple"))
        }
    }

    @Test func penaltyTelescopesLikeTheBonus() throws {
        let classes = TokenClassCache.shared.classes(for: v)
        let compiled = try #require(CompiledBias.make(vocabulary: v, classes: classes,
                                                      entries: CompiledBias.avoidEntries(["apple"]), avoid: true))
        var state = AvoidState()
        var sum: Float = 0
        for piece in [" a", "pple"] {
            sum += compiled.map(state, strength: 8)[v.id(piece)] ?? 0
            compiled.advance(&state, Array(piece.utf8)[...])
        }
        #expect(abs(sum - 8) < 1e-3)
        // Starting a blocked word earns only a share of the penalty.
        let first = compiled.map(AvoidState(), strength: 8)[v.id(" a")] ?? 0
        #expect(first > 0 && first < 8)
    }
}

/// An entry may start after a whole character that ends a word, judged per character, not per
/// UTF-8 byte (CJK text, curly quotes and dashes are all non-ASCII).
@Suite struct BiasWordStartTests {
    private func bonus(_ entry: String, after pieces: [String], next: String) throws -> Float {
        let classes = TokenClassCache.shared.classes(for: v)
        let compiled = try #require(CompiledBias.make(vocabulary: v, classes: classes,
                                                      entries: [.init(text: entry, weight: 1)]))
        var state = BiasState()
        for piece in pieces { compiled.advance(&state, Array(piece.utf8)[...]) }
        return compiled.map(state, strength: 1)[v.id(next)] ?? 0
    }

    @Test func chineseEntryStartsAfterChineseText() throws {
        #expect(try bonus("今天", after: ["我", "们"], next: "今") > 0)
        #expect(try bonus("今天", after: ["好", "的"], next: "今") > 0)
    }

    @Test func chineseEntryKeepsGoingAfterItsFirstCharacter() throws {
        #expect(try bonus("今天", after: ["好", "今"], next: "天") > 0)
    }

    @Test func entryStartsAfterADash() throws {
        #expect(try bonus(" Sam", after: [" Thanks", "—"], next: "Sam") > 0)
    }

    @Test func entryDoesNotStartInsideALatinWord() throws {
        #expect(try bonus(" Sam", after: [" Thanks", "é"], next: "Sam") == 0)
        #expect(try bonus(" Sam", after: ["note"], next: "Sam") == 0)
        #expect(try bonus(" Sam", after: ["note"], next: " Sam") > 0)  // with its space it still starts
    }
}
