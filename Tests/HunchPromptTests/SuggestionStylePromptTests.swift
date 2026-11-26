import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct SuggestionStylePromptTests {
    private func text(_ framer: any PromptFramer, _ input: PromptInput, profile: ModelProfile) -> String {
        framer.frame(input, profile: profile, budget: 4096, counter: ScalarCounter()).segments.map(\.text).joined()
    }

    @Test func instructFramerPutsTheStyleLastBeforeTheTurnCloses() {
        var input = PromptInput(before: "Hey team, ", surface: .chat, appInstructions: "Work notes.",
                                preferredLanguages: [], maxWords: 4, allowNewlines: false,
                                screenContext: "Some screen text")
        input.styleInstructions = "Write it casually."
        let prompt = text(ChatPrefillFramer(), input, profile: gemmaInstruct)
        let style = try! #require(prompt.range(of: "Write it casually."))
        #expect(prompt.range(of: "Some screen text")!.lowerBound < style.lowerBound)
        #expect(prompt.range(of: "Work notes.")!.lowerBound < style.lowerBound)
        #expect(prompt.contains("over any tone or length notes above"))
    }

    @Test func noStyleNoBlock() {
        let input = PromptInput(before: "Hey ", surface: .chat, preferredLanguages: [], maxWords: 4, allowNewlines: false)
        #expect(!text(ChatPrefillFramer(), input, profile: gemmaInstruct).contains("Style for this continuation"))
    }

    @Test func documentFramerCarriesTheStyleToo() {
        var input = PromptInput(before: "Hey ", surface: .chat, preferredLanguages: [], maxWords: 4, allowNewlines: false)
        input.styleInstructions = "Be formal."
        #expect(text(DocumentFramer(), input, profile: unknownBase).contains("Be formal."))
    }
}
