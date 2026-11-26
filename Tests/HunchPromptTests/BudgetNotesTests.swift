import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct BudgetNotesTests {
    private func frame(_ input: PromptInput, budget: Int) -> FramedPrompt {
        DocumentFramer().frame(input, profile: unknownBase, budget: budget, counter: ScalarCounter())
    }

    @Test func nothingDroppedWithRoomToSpare() {
        let prompt = frame(PromptInput(before: "Hello", screenContext: "Some screen text", clipboard: "copied text"), budget: 4096)
        #expect(prompt.budgetNotes.isEmpty)
    }

    @Test func aBlockThatDoesNotFitIsReportedAsLeftOut() {
        let screen = String(repeating: "screen words ", count: 40)
        let input = PromptInput(before: "Dear team, the budget is ", screenContext: screen, clipboard: "Q3 revenue was 4.2M")
        // Room for the header and the caret text only.
        let prompt = frame(input, budget: 150)
        let names = prompt.budgetNotes.map(\.name)
        #expect(names.contains("Screen context") || names.contains("Clipboard"))
        #expect(prompt.budgetNotes.allSatisfy { !$0.detail.isEmpty })
        // Reported notes agree with the prompt: a left-out block's text is not in it.
        let text = prompt.segments.map(\.text).joined()
        if prompt.budgetNotes.contains(where: { $0.name == "Clipboard" && $0.kind == .dropped }) {
            #expect(!text.contains("Q3 revenue"))
        }
    }

    @Test func aShortenedBlockIsReportedAsCut() {
        let screen = (1...60).map { "line\($0) has some words" }.joined(separator: "\n")
        let prompt = frame(PromptInput(before: "Hi", screenContext: screen), budget: 400)
        let note = prompt.budgetNotes.first { $0.name == "Screen context" }
        #expect(note?.kind == .cut)
    }

    @Test func aLongTextBeforeTheCaretIsReportedAsCut() {
        let before = String(repeating: "word ", count: 400)
        let prompt = frame(PromptInput(before: before), budget: 300)
        #expect(prompt.budgetNotes.contains { $0.name == "Text before the caret" && $0.kind == .cut })
    }

    @Test func theNotesDoNotChangeThePrompt() {
        let input = PromptInput(before: "Dear team, ", screenContext: String(repeating: "screen words ", count: 40))
        let plain = DocumentFramer().frame(input, profile: unknownBase, budget: 200, counter: ScalarCounter())
        let again = DocumentFramer().frame(input, profile: unknownBase, budget: 200, counter: ScalarCounter())
        #expect(plain.segments == again.segments)
        #expect(plain.requiredPrefix == again.requiredPrefix)
    }
}
