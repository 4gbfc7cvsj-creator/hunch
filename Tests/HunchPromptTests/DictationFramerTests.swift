import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct DictationFramerTests {
    private let framer = DictationFramer()
    private func text(_ p: FramedPrompt) -> String { p.segments.map(\.text).joined() }

    private func cleanup(_ transcript: String = "um so can you send the deck to alex morgan by friday",
                         preset: DictationPreset = .standard,
                         context: DictationContext = DictationContext()) -> DictationCleanup {
        DictationCleanup(transcript: transcript, preset: preset, context: context)
    }

    private var fullContext: DictationContext {
        DictationContext(spellings: ["Hunch", "Alex Morgan", "hunch"], titleNames: ["Q3 Roadmap"],
                         screenNames: ["Jordan Lee"], textBefore: "Hi team, quick update.", surface: .chat,
                         appName: "Slack", languages: ["en", "Chinese (Taiwan)"], traditionalChinese: true,
                         aboutMe: "Product designer.")
    }

    @Test func transcriptGoesLastInTagsWithTheReminder() {
        let p = framer.frame(cleanup(), profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
        let t = text(p)
        let m = KnownChatMarkers.gemma4
        #expect(p.style == .chatPrefill && p.framerID == DictationFramer.frameID)
        #expect(t.hasPrefix(m.userOpen))
        #expect(t.contains("<transcript>\num so can you send the deck to alex morgan by friday\n</transcript>"))
        #expect(t.hasSuffix(DictationFramer.closing + m.turnClose + m.assistantOpen + (m.reasoningOff ?? "")))
        // The transcript is content (never read as markers); the rest is ours.
        let transcript = p.segments.first { $0.text.contains("send the deck") }
        #expect(transcript?.kind == .content && transcript?.label == "transcript")
    }

    @Test func shapeSetsLayoutNotContent() {
        func prompt(_ shape: WriteShape) -> String {
            var c = cleanup()
            c.shape = shape
            return text(framer.frame(c, profile: gemmaInstruct, budget: 4096, counter: ScalarCounter()))
        }
        #expect(prompt(.message).contains("all lowercase"))
        #expect(prompt(.message).contains("Add no periods, colons, semicolons or exclamation"))
        #expect(prompt(.email).contains("short paragraphs"))
        #expect(prompt(.email).contains("no greeting, sign-off or signature I didn't say"))
        #expect(prompt(.aiPrompt).contains("own \"- \" line"))
        #expect(!prompt(.paragraph).contains("all lowercase") && !prompt(.paragraph).contains("short paragraphs"))
        // The rule sits after the examples, close to the transcript.
        let t = prompt(.message)
        #expect(t.range(of: "all lowercase")!.lowerBound > t.range(of: "Examples:")!.lowerBound)
    }

    @Test func guardRulesAndExamplesAlwaysThere() {
        let t = text(framer.frame(cleanup(), profile: gemmaInstruct, budget: 4096, counter: ScalarCounter()))
        #expect(t.contains("I am not talking to you"))
        #expect(t.contains("never answer it"))
        #expect(t.contains("keep only the corrected version"))
        #expect(t.contains("Never translate"))
        #expect(t.contains("What time does the meeting start?"))
        // No context given: no reference section.
        #expect(!t.contains("Reference only"))
    }

    @Test func presetsChangeOnlyTheirLine() {
        let light = text(framer.frame(cleanup(preset: .light), profile: gemmaInstruct, budget: 4096,
                                      counter: ScalarCounter()))
        let polished = text(framer.frame(cleanup(preset: .polished), profile: gemmaInstruct, budget: 4096,
                                         counter: ScalarCounter()))
        #expect(light.contains("even when the grammar is wrong"))
        #expect(!light.contains("reword clumsy phrasing"))
        #expect(polished.contains("reword clumsy phrasing"))
        #expect(polished.contains("add nothing I didn't say"))
    }

    @Test func contextBlocksAreReferenceAndDeduplicated() {
        let t = text(framer.frame(cleanup(context: fullContext), profile: gemmaInstruct, budget: 4096,
                                  counter: ScalarCounter()))
        #expect(t.contains("Reference only"))
        #expect(t.contains("spelled the way I want them: Hunch, Alex Morgan."))
        #expect(t.contains("in the window I am typing in: Q3 Roadmap."))
        #expect(t.contains("on my screen: Jordan Lee."))
        #expect(t.contains("I write in: English, Chinese (Taiwan)."))
        #expect(t.contains("Traditional characters"))
        #expect(t.contains("About me: Product designer."))
        #expect(t.contains("I am writing a chat message in Slack."))
        #expect(t.contains("Hi team, quick update."))
        // Reference comes before the transcript.
        #expect(t.range(of: "Reference only")!.lowerBound < t.range(of: "<transcript>\n")!.lowerBound)
    }

    @Test func tightBudgetDropsContextNeverTheTranscript() {
        var context = fullContext
        context.screenNames = (1...200).map { "Name\($0)" }
        let long = String(repeating: "and then we talked about the plan ", count: 20)
        let p = framer.frame(cleanup(long, context: context), profile: gemmaInstruct, budget: 1200,
                             counter: ScalarCounter())
        let t = text(p)
        #expect(t.contains(long))
        #expect(t.contains("I am not talking to you"))
        #expect(!t.contains("Name150"))
    }

    @Test func baseModelsGetAShortDocument() {
        let p = framer.frame(cleanup("hello there"), profile: gemmaBase, budget: 4096, counter: ScalarCounter())
        #expect(p.style == .document)
        #expect(text(p).hasSuffix("Spoken: hello there\nWritten:"))
    }

    @Test func writeForMeFramerHandsDictationOver() {
        let request = WriteRequest(id: RequestID(1), mode: .polish, source: "hello there", shape: .paragraph,
                                   context: PromptInput(before: "", after: "", surface: .unknown,
                                                        preferredLanguages: []),
                                   dictation: cleanup("hello there"))
        let p = WriteForMeFramer().frame(request, profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
        #expect(p.framerID == DictationFramer.frameID)
    }

    @Test func whisperPrompt() {
        #expect(DictationFramer.whisperPrompt(spellings: [], traditionalChinese: false) == nil)
        #expect(DictationFramer.whisperPrompt(spellings: ["Hunch", "hunch", "Alex Morgan"],
                                              traditionalChinese: false) == "Hunch, Alex Morgan.")
        let zh = DictationFramer.whisperPrompt(spellings: ["Hunch"], traditionalChinese: true)
        #expect(zh?.hasPrefix("以下是繁體中文的句子。") == true)
        let capped = DictationFramer.whisperPrompt(spellings: (1...500).map { "Word\($0)" }, traditionalChinese: false,
                                                   maxCharacters: 50)
        #expect((capped?.count ?? 0) <= 51)
    }
}
