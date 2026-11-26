import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct ClipboardContextTests {
    private func text(_ p: FramedPrompt) -> String { p.segments.map(\.text).joined() }
    private func framers() -> [(String, any PromptFramer, ModelProfile)] {
        [("doc1", DocumentFramer(), unknownBase), ("doc2", DocumentFramer(.v2), unknownBase),
         ("chat1", ChatPrefillFramer(), gemmaInstruct), ("chat2", ChatPrefillFramer(.v2), gemmaInstruct)]
    }
    private func frame(_ f: any PromptFramer, _ p: ModelProfile, _ input: PromptInput, budget: Int = 4096,
                       counter: any TokenCounting = ScalarCounter()) -> FramedPrompt {
        f.frame(input, profile: p, budget: budget, counter: counter)
    }

    @Test func presentInEveryFramerAndPromptEndsWithCaretText() {
        let input = PromptInput(before: "Dear team, the budget is ", after: "", clipboard: "Q3 revenue was 4.2M")
        for (name, f, p) in framers() {
            let prompt = frame(f, p, input)
            #expect(text(prompt).contains("Q3 revenue was 4.2M"), "\(name)")
            #expect(text(prompt).hasSuffix("Dear team, the budget is"), "\(name)")
            #expect(prompt.segments.last?.stability == .perKeystroke, "\(name)")
        }
    }

    @Test func omittedWhenNilEmptyOrWhitespace() {
        for (name, f, p) in framers() {
            let base = text(frame(f, p, PromptInput(before: "Hello")))
            for clip in [nil, "", "  \n\t "] as [String?] {
                #expect(text(frame(f, p, PromptInput(before: "Hello", clipboard: clip))) == base, "\(name)")
            }
        }
    }

    @Test func dedupedAgainstBeforeAndAfter() {
        for (name, f, p) in framers() {
            let base = text(frame(f, p, PromptInput(before: "We met about the launch plan today", after: "see you")))
            let inBefore = PromptInput(before: "We met about the launch plan today", after: "see you",
                                       clipboard: " launch plan ")
            let inAfter = PromptInput(before: "We met about the launch plan today", after: "see you",
                                      clipboard: "see you\n")
            #expect(text(frame(f, p, inBefore)) == base, "\(name)")
            #expect(text(frame(f, p, inAfter)) == base, "\(name)")
            let distinct = PromptInput(before: "We met", after: "see you", clipboard: "launch plan")
            #expect(text(frame(f, p, distinct)).contains("launch plan"), "\(name)")
        }
    }

    @Test func charCapKeepsBeginningAtWordBoundary() {
        let long = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let got = clipboardBackground(PromptInput(before: "x", clipboard: long))!
        #expect(got.count <= clipboardCharLimit)
        #expect(long.hasPrefix(got))
        #expect(long.dropFirst(got.count).first == " ")
        #expect(got.hasPrefix("word0 word1"))
        for (name, f, p) in framers() {
            let t = text(frame(f, p, PromptInput(before: "x", clipboard: long), counter: WordCounter()))
            #expect(t.contains(got), "\(name)")
            #expect(!t.contains("word399"), "\(name)")
        }
        #expect(clipboardBackground(PromptInput(before: "x", clipboard: String(repeating: "a", count: 900)))!.count
                == clipboardCharLimit)
    }

    @Test func tokenCapAppliesAndClipboardDroppedBeforeScreen() {
        let clip = (0..<100).map { "c\($0)" }.joined(separator: " ")
        let counter = WordCounter()
        let t = text(frame(DocumentFramer(), unknownBase, PromptInput(before: "Hi", clipboard: clip), counter: counter))
        #expect(t.contains("c\(clipboardTokenLimit > 99 ? 99 : clipboardTokenLimit - 1)"))
        // Budget with room for screen but not clipboard: clipboard goes first.
        let input = PromptInput(before: "Hi", screenContext: "screen words here now", clipboard: clip)
        let without = frame(DocumentFramer(), unknownBase, PromptInput(before: "Hi", screenContext: "screen words here now"),
                            budget: 100_000, counter: counter)
        let needed = without.segments.map { counter.tokenCount($0.text) }.reduce(0, +)
        let tight = text(frame(DocumentFramer(), unknownBase, input, budget: needed + 6, counter: counter))
        #expect(tight.contains("screen words"))
        #expect(!tight.contains("c50"))
        #expect(!tight.contains(DocumentFramer.Wording.v1.clipboard))
    }

    @Test func coexistsWithScreenContextAndPrecedesAfterText() {
        let input = PromptInput(before: "Hi Sam, thanks ", after: "Best, Lee", screenContext: "Re: launch plan",
                                clipboard: "tracking number 998877")
        for (name, f, p) in framers() {
            let t = text(frame(f, p, input))
            let screen = t.range(of: "Re: launch plan")
            let clip = t.range(of: "tracking number 998877")
            let after = t.range(of: "Best, Lee")
            #expect(screen != nil && clip != nil && after != nil, "\(name)")
            guard let screen, let clip, let after else { continue }
            #expect(screen.upperBound <= clip.lowerBound, "\(name)")
            #expect(clip.upperBound <= after.lowerBound, "\(name)")
            #expect(t.hasSuffix("Hi Sam, thanks"), "\(name)")
        }
    }

    @Test func shortCJKStartKeepsClipboardButDropsHeader() {
        let input = PromptInput(before: "你好", screenContext: "会议纪要", clipboard: "项目截止日期是周五")
        for wording in [DocumentFramer.Wording.v1, .v2] {
            let t = text(frame(DocumentFramer(wording), unknownBase, input))
            #expect(!t.contains(wording.header))
            #expect(t.contains("会议纪要"))
            #expect(t.contains("项目截止日期是周五"))
            #expect(t.contains(wording.clipboard.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(t.hasSuffix("你好"))
        }
    }

    @Test func documentClipboardLabelIsNeutralAndListedAsPreface() {
        for wording in [DocumentFramer.Wording.v1, .v2] {
            let label = wording.clipboard.lowercased()
            for banned in ["assistant", "model", "complet", "suggest", "bot", "llm", "autocomplete"] {
                #expect(!label.contains(banned))
            }
            #expect(!label.split(whereSeparator: { !$0.isLetter }).contains("ai"))
        }
        let phrases = DocumentFramer.prefacePhrases
        #expect(phrases.contains("Passage the writer recently copied (reference)"))
        #expect(phrases.contains("Excerpt the author copied earlier (not part of this text)"))
    }
}
