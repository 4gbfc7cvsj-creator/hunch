import HunchCore
import Testing
@testable import HunchPrompt

private func joined(_ p: FramedPrompt) -> String { p.segments.map(\.text).joined() }

@Suite struct HeaderLeakTests {
    let framer = DocumentFramer()
    let counter = ScalarCounter()

    @Test func shortChinesePrefixDropsHeader() {
        let prompt = framer.frame(PromptInput(before: "我今天去了"), profile: unknownBase, budget: 1024, counter: counter)
        #expect(joined(prompt) == "我今天去了")  // healing never crosses CJK
        #expect(prompt.requiredPrefix == "")
    }

    @Test func shortChineseKeepsUserNotesButNotHeader() {
        let input = PromptInput(before: "你好，我想", globalInstructions: "Casual.")
        let text = joined(framer.frame(input, profile: unknownBase, budget: 1024, counter: counter))
        #expect(!text.contains(DocumentFramer.header))
        #expect(text.contains("Casual."))
        #expect(text.hasSuffix("\n\n你好，我想"))
    }

    @Test func longChineseKeepsHeader() {
        let before = String(repeating: "今天天气很好", count: 3)
        let text = joined(framer.frame(PromptInput(before: before), profile: unknownBase, budget: 1024, counter: counter))
        #expect(text.hasPrefix(DocumentFramer.header))
    }

    @Test func chineseWithPriorLineKeepsHeader() {
        let text = joined(framer.frame(PromptInput(before: "你好\n我想"), profile: unknownBase, budget: 1024,
                                       counter: counter))
        #expect(text.hasPrefix(DocumentFramer.header))
    }

    @Test func englishAndMixedKeepHeader() {
        for before in ["Hello there", "Please review the 文档 before Friday", ""] {
            let text = joined(framer.frame(PromptInput(before: before), profile: unknownBase, budget: 1024,
                                           counter: counter))
            #expect(text.hasPrefix(DocumentFramer.header), "\(before)")
        }
    }

    @Test func prefacePhrasesIncludeHeaders() {
        let phrases = DocumentFramer.prefacePhrases
        #expect(phrases.contains(DocumentFramer.Wording.v1.header))
        #expect(phrases.contains(DocumentFramer.Wording.v2.header))
        #expect(phrases.allSatisfy { !$0.isEmpty })
    }
}
