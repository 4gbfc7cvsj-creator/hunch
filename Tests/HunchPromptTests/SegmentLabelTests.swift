import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct SegmentLabelTests {
    /// Every framed block carries a label for the debug prompt log; the caret text is "text".
    @Test func blocksAreLabeled() {
        let input = PromptInput(before: "Thanks for the update, I", surface: .chat, globalInstructions: "Short and warm.",
                                aboutWriter: "Name: Ann Lee.", screenContext: "Can you send the file?")
        for framer in [DocumentFramer(), ChatPrefillFramer()] as [any PromptFramer] {
            let segments = framer.frame(input, profile: unknownBase, budget: 1024, counter: ScalarCounter()).segments
            let labels = segments.compactMap(\.label)
            #expect(labels.last == "text")
            #expect(labels.contains { $0.hasPrefix("writer") })
            #expect(labels.contains { $0.hasPrefix("screen") })
        }
    }

    /// A long screen block fits a large budget whole, and is trimmed from the top under a small one.
    @Test func largeBudgetKeepsTheWholeScreen() {
        let screen = (1...300).map { "message line \($0) about the release" }.joined(separator: "\n")
        let input = PromptInput(before: "Sounds good,", surface: .chat, screenContext: screen)
        func screenText(_ budget: Int) -> String {
            DocumentFramer().frame(input, profile: unknownBase, budget: budget, counter: ScalarCounter())
                .segments.first { $0.label?.hasPrefix("screen") == true }?.text ?? ""
        }
        #expect(screenText(16_000).contains("message line 1 about"))
        #expect(!screenText(1024).contains("message line 1 about"))
        #expect(screenText(1024).contains("message line 300"))
    }
}
