import HunchCore
import Testing
@testable import HunchPrompt

private func joined(_ prompt: FramedPrompt) -> String { prompt.segments.map(\.text).joined() }

private let codeInput = PromptInput(before: "func add(a: Int, b: Int) -> Int {\n    return", after: "\n}", surface: .code,
                                    appName: "Cursor", windowTitle: "● Calculator.swift — hunch — Cursor")

@Suite struct CodeFileHintTests {
    @Test func fileNameAndLanguageFromEditorTitles() {
        #expect(CodeFileHint.describe(windowTitle: "● Calculator.swift — hunch — Cursor") == "Swift, in Calculator.swift")
        #expect(CodeFileHint.describe(windowTitle: "Hunch — Seeds.swift") == "Swift, in Seeds.swift")
        #expect(CodeFileHint.describe(windowTitle: "index.tsx - web - Visual Studio Code") == "TypeScript, in index.tsx")
        #expect(CodeFileHint.describe(windowTitle: "deploy.sh (Working Tree) — infra") == "shell script, in deploy.sh")
        #expect(CodeFileHint.describe(windowTitle: "notes.txt — scratch") == "in notes.txt")
        #expect(CodeFileHint.describe(windowTitle: "my_module.test.py — api") == "Python, in my_module.test.py")
    }

    @Test func titlesWithoutAFileGiveNoHint() {
        #expect(CodeFileHint.describe(windowTitle: nil) == nil)
        #expect(CodeFileHint.describe(windowTitle: "Welcome — Visual Studio Code") == nil)
        #expect(CodeFileHint.describe(windowTitle: "Cursor") == nil)
        #expect(CodeFileHint.describe(windowTitle: "Settings") == nil)
        #expect(CodeFileHint.describe(windowTitle: ". ..") == nil)
    }
}

@Suite struct CodeFramingTests {
    @Test func documentFramerUsesTheCodeHeaderAndHint() {
        for wording in [DocumentFramer.Wording.v1, .v2] {
            let prompt = DocumentFramer(wording).frame(codeInput, profile: unknownBase, budget: 1024, counter: ScalarCounter())
            let text = joined(prompt)
            #expect(text.hasPrefix(wording.codeHeader), Comment(rawValue: wording.id))
            #expect(!text.contains(wording.header), Comment(rawValue: wording.id))
            #expect(text.contains("source code (Swift, in Calculator.swift)"), Comment(rawValue: wording.id))
            // The caret text comes last; the half-typed keyword is healed into the required prefix.
            #expect(text.hasSuffix("-> Int {\n") && prompt.requiredPrefix == "    return", Comment(rawValue: wording.id))
        }
    }

    @Test func chatFramerUsesTheCodeInstruction() {
        for wording in [ChatPrefillFramer.Wording.v1, .v2] {
            let text = joined(ChatPrefillFramer(wording).frame(codeInput, profile: gemmaInstruct, budget: 1024,
                                                              counter: ScalarCounter()))
            #expect(text.contains(wording.codeInstruction), Comment(rawValue: wording.id))
            #expect(!text.contains(wording.instruction), Comment(rawValue: wording.id))
            #expect(text.contains("source code (Swift, in Calculator.swift)"), Comment(rawValue: wording.id))
        }
    }

    @Test func proseKeepsTheProseWordingAndNoHintWithoutATitle() {
        var prose = codeInput
        prose.surface = .email
        let text = joined(DocumentFramer().frame(prose, profile: unknownBase, budget: 1024, counter: ScalarCounter()))
        #expect(text.hasPrefix(DocumentFramer.Wording.v1.header))
        #expect(!text.contains("source code"))
        var untitled = codeInput
        untitled.windowTitle = nil
        let plain = joined(DocumentFramer().frame(untitled, profile: unknownBase, budget: 1024, counter: ScalarCounter()))
        #expect(plain.contains("Kind of text: source code\n"))
    }

    @Test func codeWordingHasNoAssistantVocabulary() {
        let texts = [DocumentFramer.Wording.v1.codeHeader, DocumentFramer.Wording.v2.codeHeader,
                     ChatPrefillFramer.Wording.v1.codeInstruction, ChatPrefillFramer.Wording.v2.codeInstruction]
        for text in texts.map({ $0.lowercased() }) {
            let words = text.split(whereSeparator: { !$0.isLetter && $0 != "." })
            for banned in ["ai", "bot", "llm"] { #expect(!words.contains(Substring(banned)), Comment(rawValue: text)) }
            for banned in ["assistant", "model", "autocomplete", "complet", "suggest", "chatbot", "predict", "generate"] {
                #expect(!text.contains(banned), Comment(rawValue: text))
            }
        }
    }
}
