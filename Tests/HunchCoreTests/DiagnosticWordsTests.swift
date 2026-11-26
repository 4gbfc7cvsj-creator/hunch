import Foundation
import Testing
@testable import HunchCore

private func lp(_ p: Double) -> Float { Float(Foundation.log(p)) }

private func tokens(_ pairs: [(String, Float)]) -> (text: String, tokens: [DiagnosticToken]) {
    (pairs.map(\.0).joined(), pairs.map { DiagnosticToken(byteCount: $0.0.utf8.count, logProb: $0.1) })
}

@Suite struct DiagnosticWordsTests {
    @Test func wordRangesIncludeLeadingSpaceAndSkipTrailing() {
        let text = " see you  tomorrow \n"
        let words = DiagnosticWords.ranges(of: text).map { String(decoding: Array(text.utf8)[$0], as: UTF8.self) }
        #expect(words == [" see", " you", "  tomorrow"])
    }

    @Test func oneTokenOneWordIsExpOfItsLogProb() {
        let (text, toks) = tokens([(" the", lp(0.9)), (" cat", lp(0.25))])
        let words = DiagnosticWords.group(text: text, tokens: toks)
        #expect(words.count == 2)
        #expect(abs((words[0].probability ?? 0) - 0.9) < 0.001)
        #expect(abs((words[1].probability ?? 0) - 0.25) < 0.001)
    }

    @Test func aWordSplitIntoTokensUsesTheMeanLogProb() throws {
        // " won" + "der" + "ful": mean of the three log-probs, not their sum or the product's root of one.
        let (text, toks) = tokens([(" it", lp(0.8)), (" won", lp(0.5)), ("der", lp(0.5)), ("ful", lp(0.125))])
        let words = DiagnosticWords.group(text: text, tokens: toks)
        #expect(words.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["it", "wonderful"])
        let expected: Float = exp((lp(0.5) + lp(0.5) + lp(0.125)) / 3)
        #expect(abs(try #require(words[1].probability) - expected) < 0.001)
        #expect(words[1].tokenCount == 3)
    }

    @Test func punctuationJoinsTheWordBeforeIt() throws {
        let (text, toks) = tokens([(" fine", lp(0.8)), (",", lp(0.2)), (" thanks", lp(0.9))])
        let words = DiagnosticWords.group(text: text, tokens: toks)
        #expect(words.count == 2)
        #expect(words[0].text == " fine,")
        let expected: Float = exp((lp(0.8) + lp(0.2)) / 2)
        #expect(abs(try #require(words[0].probability) - expected) < 0.001)
    }

    @Test func aTokenSpanningTwoWordsCountsForBoth() throws {
        let (text, toks) = tokens([(" so", lp(0.9)), (" much more", lp(0.4))])
        let words = DiagnosticWords.group(text: text, tokens: toks)
        #expect(words.count == 3)
        #expect(abs(try #require(words[1].probability) - 0.4) < 0.001)
        #expect(abs(try #require(words[2].probability) - 0.4) < 0.001)
    }

    @Test func whitespaceOnlyTokensScoreNoWord() {
        let (text, toks) = tokens([(" end", lp(0.9)), ("\n\n", lp(0.01)), ("next", lp(0.5))])
        let words = DiagnosticWords.group(text: text, tokens: toks)
        #expect(words.count == 2)
        #expect(words[0].tokenCount == 1)
    }

    @Test func chineseCharactersAreOneWordEach() {
        let (text, toks) = tokens([("你好", lp(0.7)), ("，", lp(0.5)), ("世界", lp(0.9))])
        let words = DiagnosticWords.group(text: text, tokens: toks)
        #expect(words.map(\.text) == ["你", "好，", "世", "界"])
        // "你" and "好" share the first token, so both carry its probability.
        #expect(abs((words[0].probability ?? 0) - 0.7) < 0.001)
        #expect(abs((words[1].probability ?? 0) - exp((lp(0.7) + lp(0.5)) / 2)) < 0.001)
    }

    @Test func wordsNoTokenCoversHaveNoProbability() {
        let words = DiagnosticWords.group(text: " one two", tokens: [DiagnosticToken(byteCount: 4, logProb: lp(0.5))])
        #expect(words[0].probability != nil)
        #expect(words[1].probability == nil)
    }

    // MARK: Where the text was cut

    private let facts = ConfidenceTrimFacts(dropText: "and", windowedMean: lp(0.02), limit: lp(0.22), window: 1,
                                            atClauseEnd: true)

    @Test func aConfidenceTrimMarksTheCutAfterTheKeptWords() {
        let (text, toks) = tokens([(" booked", lp(0.9)), (" until", lp(0.9)), (" fall", lp(0.8)), (",", lp(0.7)),
                                   (" and", lp(0.02)), (" I", lp(0.3))])
        let output = DiagnosticWords.output(generated: text, tokens: toks, trim: (" booked until fall", facts), postCuts: [],
                                            shown: " booked until fall", stopText: nil, meanLogProb: nil)
        #expect(output.words.count == 5)
        #expect(output.cuts.count == 1)
        #expect(output.cuts[0].afterWords == 3)
        #expect(output.firstCutAfterWord == 3)
    }

    @Test func aPostProcessingCutComesEarlierThanTheTrim() {
        let (text, toks) = tokens([(" a", lp(0.9)), (" b", lp(0.9)), (" c", lp(0.9)), (" d", lp(0.9)), (" e", lp(0.1))])
        let output = DiagnosticWords.output(generated: text, tokens: toks, trim: (" a b c d", facts),
                                            postCuts: [.wordLimit(2)], shown: " a b", stopText: nil, meanLogProb: nil)
        #expect(output.cuts.map(\.afterWords) == [2, 4])
        #expect(output.cuts[0].reason == .postProcessing(.wordLimit(2)))
        #expect(output.firstCutAfterWord == 2)
    }

    @Test func noCutWhenNothingWasShortened() {
        let (text, toks) = tokens([(" a", lp(0.9)), (" b", lp(0.9))])
        let output = DiagnosticWords.output(generated: text, tokens: toks, trim: nil, postCuts: [.wordLimit(5)],
                                            shown: " a b", stopText: nil, meanLogProb: nil)
        #expect(output.cuts.isEmpty)
        #expect(output.firstCutAfterWord == nil)
    }

    @Test func aSuppressedResultStillShowsItsTrim() {
        let (text, toks) = tokens([(" a", lp(0.9)), (" b", lp(0.9)), (" c", lp(0.02))])
        let output = DiagnosticWords.output(generated: text, tokens: toks, trim: (" a b", facts), postCuts: [],
                                            shown: nil, stopText: nil, meanLogProb: nil)
        #expect(output.cuts.map(\.afterWords) == [2])
    }

    @Test func unscoredTextHasNoWordsButStillCounts() {
        let output = DiagnosticWords.output(generated: "Hello there world", tokens: [], trim: nil, postCuts: [],
                                            shown: nil, stopText: "x", meanLogProb: nil)
        #expect(!output.hasScores)
        #expect(output.words.isEmpty)
    }
}

@Suite struct CutReasonTextTests {
    @Test func aConfidenceTrimNamesTheTokenTheAverageTheLimitAndWhereItCut() {
        let clause = CutReason.confidenceTrim(ConfidenceTrimFacts(
            dropText: "and", windowedMean: lp(0.05), limit: -1.5, window: 1, atClauseEnd: true)).text
        #expect(clause.contains("“and”"))
        #expect(clause.contains("5.0%"))
        #expect(clause.contains("below the limit of 22%"))
        #expect(clause.contains("log \u{2212}1.50"))
        #expect(clause.contains("last clause end"))
        let word = CutReason.confidenceTrim(ConfidenceTrimFacts(
            dropText: "fo", windowedMean: -3, limit: -1.5, window: 3, atClauseEnd: false)).text
        #expect(word.contains("average confidence over the 3 tokens from “fo”"))
        #expect(word.contains("last whole word"))
    }

    @Test func postProcessingCutsNameTheirGuard() {
        #expect(CutReason.postProcessing(.scriptGuard).text.contains("ScriptGuard"))
        #expect(CutReason.postProcessing(.urlGuard).text.contains("URLGuard"))
        #expect(CutReason.postProcessing(.wordLimit(1)).text == "Word limit: suggestions are held to 1 word.")
        #expect(CutReason.postProcessing(.wordLimit(4)).text.contains("4 words"))
        #expect(CutReason.postProcessing(.lineBreak).text.contains("line break"))
    }

    @Test func everySuppressReasonAndStopReasonHasWords() {
        for reason in [SuppressReason.empty, .punctuationOnly, .aiVoice, .metaReply, .echoesBefore, .echoesAfter,
                       .repetitionLoop, .lowConfidence, .likelyTypo, .markupLeak, .tooShort, .copiesStyleExample,
                       .foreignScript, .webAddress, .copiesScreen] {
            #expect(!reason.plainWords.isEmpty && !reason.shortWords.isEmpty)
        }
        #expect(SuppressReason.metaReply.plainWords.contains("PrefaceEcho"))
        #expect(SuppressReason.foreignScript.plainWords.contains("ScriptGuard"))
        #expect(SuppressReason.webAddress.plainWords.contains("URLGuard"))
        #expect(StopReason.wordBudget.plainWords.contains("word limit"))
    }

    @Test func theShownLineSaysWhyNothingWasShown() {
        #expect(DiagnosticFate.shown(" hi there").text == "“hi there”")
        #expect(DiagnosticFate.suppressed(.lowConfidence, detail: "average −3.0").text
            == "nothing: below the confidence floor (average −3.0)")
        #expect(DiagnosticFate.cancelled.text.contains("kept typing"))
        #expect(DiagnosticFate.suppressed(.likelyTypo, detail: nil).text.contains("typo"))
    }

    @Test func plainTextCopyHasTheMainParts() {
        let output = DiagnosticWords.output(
            generated: " see you", tokens: [DiagnosticToken(byteCount: 4, logProb: lp(0.9)), DiagnosticToken(byteCount: 4, logProb: lp(0.5))],
            trim: nil, postCuts: [], shown: " see you", stopText: "The model stopped because it ended the sentence.",
            meanLogProb: nil)
        let record = DiagnosticRecord(kind: .suggestion, appName: "Notes",
                                      sections: [DiagnosticSection("Clipboard", [])],
                                      prompt: DiagnosticPrompt(framerID: "document-v1", requiredPrefix: "", segments: [
                                          DiagnosticPromptSegment(text: "Hello", label: "text", isControl: false)], promptTokens: 1),
                                      output: output, fate: .shown(" see you"))
        let text = record.plainText()
        #expect(text.contains("== What went in =="))
        #expect(text.contains("[Clipboard]\n(none)"))
        #expect(text.contains("Full prompt, exactly as the model received it"))
        #expect(text.contains("see[90%] you[50%]"))
        #expect(text.contains("Shown to you: “see you”"))
        #expect(DiagnosticPrompt(framerID: "chat-prefill-v1", requiredPrefix: "", segments: [], promptTokens: 0).framerName
            == "ChatPrefillFramer (chat-prefill-v1)")
    }
}
