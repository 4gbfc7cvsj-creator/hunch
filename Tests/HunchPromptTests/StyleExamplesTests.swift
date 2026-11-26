import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct StyleExamplesTests {
    private func text(_ p: FramedPrompt) -> String { p.segments.map(\.text).joined() }
    private func framers() -> [(String, any PromptFramer, ModelProfile)] {
        [("doc1", DocumentFramer(), unknownBase), ("doc2", DocumentFramer(.v2), unknownBase),
         ("chat1", ChatPrefillFramer(), gemmaInstruct), ("chat2", ChatPrefillFramer(.v2), gemmaInstruct)]
    }
    private func frame(_ f: any PromptFramer, _ p: ModelProfile, _ input: PromptInput, budget: Int = 4096,
                       counter: any TokenCounting = ScalarCounter()) -> FramedPrompt {
        f.frame(input, profile: p, budget: budget, counter: counter)
    }

    @Test func presentWithPerFieldStabilityAndCaretLast() {
        let input = PromptInput(before: "Dear team, ", styleExamples: ["I booked the kiln for Friday.", "Glaze day is on."])
        for (name, f, p) in framers() {
            let prompt = frame(f, p, input)
            let t = text(prompt)
            #expect(t.contains("\u{201C}I booked the kiln for Friday.\u{201D} \u{201C}Glaze day is on.\u{201D}"), "\(name)")
            #expect(t.hasSuffix("Dear team,"), "\(name)")
            let seg = prompt.segments.first { $0.text.contains("kiln for Friday") }
            #expect(seg?.stability == .perField, "\(name)")
            #expect(prompt.segments.last?.stability == .perKeystroke, "\(name)")
        }
    }

    @Test func absentWhenEmptyOrBlank() {
        for (name, f, p) in framers() {
            let base = text(frame(f, p, PromptInput(before: "Hello")))
            #expect(text(frame(f, p, PromptInput(before: "Hello", styleExamples: []))) == base, "\(name)")
            #expect(text(frame(f, p, PromptInput(before: "Hello", styleExamples: ["", "  \n "]))) == base, "\(name)")
        }
    }

    @Test func orderedAfterInstructionsAndBeforeAfterCaretAndCaret() {
        let input = PromptInput(before: "Hi ", after: "bye now", globalInstructions: "casual", styleExamples: ["alpha beta gamma delta"])
        for (name, f, p) in framers() {
            let t = text(frame(f, p, input))
            let notes = t.range(of: "casual")!.lowerBound
            let style = t.range(of: "alpha beta")!.lowerBound
            let after = t.range(of: "bye now")!.lowerBound
            #expect(notes < style && style < after, "\(name)")
        }
    }

    @Test func eachExampleIsCappedAtWordBoundary() {
        let long = (0..<200).map { "w\($0)" }.joined(separator: " ")
        let got = styleBackground(PromptInput(before: "x", styleExamples: [long]), counter: WordCounter())!
        #expect(got.count <= styleExampleCharLimit + 4)
        #expect(got.hasPrefix("\u{201C}w0 w1"))
        #expect(!got.contains("w199"))
    }

    @Test func blockTokenCapAndCountCap() {
        let ex = Array(repeating: "one two three four five six seven eight nine ten", count: 10)
        let got = styleBackground(PromptInput(before: "x", styleExamples: ex), counter: WordCounter())!
        #expect(WordCounter().tokenCount(got) <= styleTokenLimit)
        #expect(got.components(separatedBy: "\u{201C}").count - 1 <= styleExampleMaxCount)
    }

    @Test func droppedUnderTightBudgetKeepingCaret() {
        let input = PromptInput(before: "Dear team, thanks ", styleExamples: ["I booked the kiln for Friday."])
        for (name, f, p) in framers() {
            let prompt = frame(f, p, input, budget: 70)
            #expect(!text(prompt).contains("kiln"), "\(name)")
            #expect(text(prompt).hasSuffix("thanks"), "\(name)")
        }
    }

    @Test func keptBeforeScreenAndClipboardWhenOnlyOneFits() {
        // Budget leaves room for roughly one optional block beyond the fixed parts.
        let style = ["I booked the kiln for Friday."]
        let withBoth = PromptInput(before: "Hi ", screenContext: String(repeating: "screen words ", count: 20),
                                   clipboard: String(repeating: "clip words ", count: 20), styleExamples: style)
        for (name, f, p) in framers() {
            let full = frame(f, p, PromptInput(before: "Hi ", styleExamples: style))
            let tight = text(full).unicodeScalars.count + 20
            let t = text(frame(f, p, withBoth, budget: tight))
            #expect(t.contains("kiln"), "\(name)")
        }
        #expect(BlockPriority.writer < BlockPriority.style && BlockPriority.style < BlockPriority.screen)
        #expect(BlockPriority.style < BlockPriority.clipboard)
    }

    @Test func labelsAreNeutralAndListedAsPrefacePhrases() {
        let w = [DocumentFramer.Wording.v1.style, DocumentFramer.Wording.v2.style,
                 ChatPrefillFramer.Wording.v1.style, ChatPrefillFramer.Wording.v2.style].joined(separator: " ").lowercased()
        for banned in ["assistant", "ai ", "model", "complete", "autocomplete", "predict", "suggest"] {
            #expect(!w.contains(banned), "\(banned)")
        }
        #expect(DocumentFramer.prefacePhrases.contains { $0.hasPrefix("Earlier sentences by the same writer") })
    }
}
