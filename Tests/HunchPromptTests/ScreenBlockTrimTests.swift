import HunchCore
import Testing
@testable import HunchPrompt

// The screen excerpt arrives in reading order, so the lines just above the field (the newest chat
// messages) come last. When the block has to be cut, those are the lines to keep.

private func joinedText(_ prompt: FramedPrompt) -> String { prompt.segments.map(\.text).joined() }

private let longScreen = (1...60).map { "older message number \($0) in the thread" }.joined(separator: "\n")
    + "\nnewest message just above the field"

private func screenInput() -> PromptInput {
    PromptInput(before: "Sounds good, I", surface: .chat, screenContext: longScreen)
}

@Test func documentFramerCutsScreenFromTheTop() {
    let text = joinedText(DocumentFramer().frame(screenInput(), profile: unknownBase, budget: 700,
                                                 counter: ScalarCounter()))
    #expect(text.contains("newest message just above the field"))
    #expect(!text.contains("older message number 1 in"))
}

@Test func chatPrefillFramerCutsScreenFromTheTop() {
    let text = joinedText(ChatPrefillFramer().frame(screenInput(), profile: gemmaInstruct, budget: 900,
                                                    counter: ScalarCounter()))
    #expect(text.contains("newest message just above the field"))
    #expect(!text.contains("older message number 1 in"))
}
