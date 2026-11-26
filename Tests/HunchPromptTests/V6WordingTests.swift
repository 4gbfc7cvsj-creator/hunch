import HunchCore
import Testing
@testable import HunchPrompt

/// v6 screening wordings (framer bake-off, stage 1): v5 plus one change each.
@Suite struct V6WordingTests {
    typealias W = ChatPrefillFramer.Wording

    private func text(_ w: W, _ input: PromptInput = fullInput) -> String {
        ChatPrefillFramer(w).frame(input, profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
            .segments.map(\.text).joined()
    }

    private let chatInput = PromptInput(before: "Sounds good, I'll move the", after: "", surface: .chat,
                                        aboutWriter: "Alex Morgan, product designer.",
                                        screenContext: "Noah: can we push standup a bit tomorrow?",
                                        styleExamples: ["lol yeah that works", "ok see you there"])

    @Test func idsAreDistinctAndRegistered() {
        let ids = W.v6Screening.map(\.id)
        #expect(Set(ids).count == 9)
        let registry = DefaultFramerRegistry()
        for id in ids {
            #expect(registry.framer(for: gemmaInstruct, override: id).id == id)
        }
        // The automatic choice is i1g1 (2026-11-19, i1 plus gated learned-word notes), each id registered once.
        #expect(registry.all.filter { $0.id == W.v6b3.id }.count == 1)
        #expect(registry.framer(for: gemmaInstruct, override: nil).id == "chat-prefill-i1g1")
        #expect(registry.all.filter { $0.id == W.i1.id }.count == 1)
        #expect(registry.all.filter { $0.id == W.i1g1.id }.count == 1)
        // Base models keep the document framer, which names no learned words.
        #expect(registry.framer(for: gemmaBase, override: nil).id == "document-v1")
        #expect(!registry.framer(for: gemmaBase, override: nil).listsVocabulary)
        #expect(registry.framer(for: gemmaInstruct, override: nil).listsVocabulary)
    }

    @Test func instructionFramingIsV6b3PlusOneChange() {
        // i1 relabels only the two instruction blocks; i2 adds one sentence to the instruction.
        var relabeled = W.i1
        relabeled.id = W.v6b3.id
        relabeled.writerNotes = W.v6b3.writerNotes
        relabeled.appNotes = W.v6b3.appNotes
        #expect(relabeled == W.v6b3)
        #expect(W.i1.writerNotes.contains("as a whole") && W.i1.appNotes.contains("as a whole"))
        #expect(W.i2.instruction.hasPrefix(W.v6b3.instruction) && W.i2.writerNotes == W.v6b3.writerNotes)
    }

    @Test func layoutVariantsKeepV5Instruction() {
        for w in [W.v6a1, .v6a2, .v6a3, .v6c3] {
            #expect(w.instruction == W.v5.instruction)
        }
    }

    @Test func instructionGrowsByAtMostOneSentence() {
        let base = W.v5.instruction.unicodeScalars.count
        for w in W.v6Screening {
            #expect(w.instruction.unicodeScalars.count - base <= 110, "\(w.id)")
            #expect(w.instruction.hasPrefix("Continue my text from the exact point"), "\(w.id)")
        }
    }

    @Test func samplesBeforeScreenReordersOnlyThoseBlocks() {
        for (w, samplesFirst) in [(W.v5, false), (.v6a1, false), (.v6a2, true), (.v6a3, true)] {
            let t = text(w, chatInput)
            let sample = try! #require(t.range(of: "lol yeah that works"))
            let screen = try! #require(t.range(of: "Noah: can we push"))
            #expect((sample.lowerBound < screen.lowerBound) == samplesFirst, "\(w.id)")
            #expect(t.hasSuffix("Sounds good, I'll move"), "\(w.id)")
        }
    }

    @Test func screenLabelNamesNewestLines() {
        #expect(text(.v6a1, chatInput).contains("its last lines are the newest"))
        #expect(!text(.v5, chatInput).contains("its last lines are the newest"))
    }

    @Test func surfaceHintOnlyForCasualSurfaces() {
        #expect(text(.v6c3, chatInput).contains("I am writing a chat message. I type these casually"))
        var prompt = chatInput
        prompt.surface = .agentPrompt
        #expect(text(.v6c3, prompt).contains("in everyday words"))
        prompt.surface = .email
        let email = text(.v6c3, prompt)
        #expect(email.contains("I am writing an email."))
        #expect(!email.contains("I type these"))
    }

    @Test func traditionalChineseTextIsUntouched() {
        let input = PromptInput(before: "陳經理您好：\n\n謝謝您的來信，關於下週的會議時間，我這邊星期三下午都可",
                                after: "", surface: .email, preferredLanguages: ["zh-Hant"],
                                screenContext: "主旨：下週會議時間", styleExamples: ["好的，沒問題，我們再約。"])
        for w in W.v6Screening {
            let t = text(w, input)
            #expect(t.contains("主旨：下週會議時間"), "\(w.id)")
            #expect(t.contains("好的，沒問題，我們再約。"), "\(w.id)")
            #expect(t.contains("我這邊星期三下午都"), "\(w.id)")
        }
    }

    @Test func markersIntactAndNoChatbotEcho() {
        for w in W.v6Screening {
            let prompt = ChatPrefillFramer(w).frame(chatInput, profile: gemmaInstruct, budget: 4096,
                                                    counter: ScalarCounter())
            #expect(prompt.framerID == w.id)
            #expect(prompt.segments.first?.kind == .control)
            #expect(prompt.segments.filter { $0.kind == .control }.count >= 3, "\(w.id)")
            let added = w.instruction.replacingOccurrences(of: W.v5.instruction, with: "")
            for banned in ["model", "autocomplete", "suggest", "predict", "generate"] {
                #expect(!added.lowercased().contains(banned), "\(w.id): \(banned)")
            }
        }
    }
    @Test func vocabularyNotesAreI1PlusAStablePerFieldBlock() {
        var input = chatInput
        input.vocabulary = ["Priya", "Jira", "priya", " ", "SOW"]
        for w in [W.i1n1, W.i1n2] {
            var back = w
            back.id = W.i1.id
            back.vocabulary = nil
            #expect(back == W.i1)
            #expect(DefaultFramerRegistry().framer(for: gemmaInstruct, override: w.id).id == w.id)
            let t = text(w, input)
            #expect(t.contains(w.vocabulary! + "Priya, Jira, SOW"))
            // Early: before the surface line and the screen, after the writer's own blocks.
            #expect(t.range(of: "Priya, Jira")!.lowerBound < t.range(of: "Noah: can we")!.lowerBound)
            let seg = ChatPrefillFramer(w).frame(input, profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
                .segments.first { $0.text.contains("Priya, Jira") }
            #expect(seg?.stability == .perField)
        }
        // Framers without a label leave the words out, and an empty list adds nothing.
        #expect(!text(W.i1, input).contains("Priya"))
        #expect(text(W.i1n1, chatInput) == text(W.i1, chatInput))
    }

    @Test func gatedNotesGoLastAndChangePerKeystroke() {
        var input = chatInput
        input.vocabulary = ["Riley"]
        let framed = ChatPrefillFramer(W.i1g1).frame(input, profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
        let texts = framed.segments.map(\.text)
        let i = texts.firstIndex { $0.contains("Riley") }!
        #expect(framed.segments[i].stability == .perKeystroke)
        #expect(texts[i].hasPrefix(W.i1n1.vocabulary!))
        // After every context block: only the turn markers and the caret text follow.
        #expect(texts[(i + 1)...].allSatisfy { !$0.contains("Noah: can we") && !$0.contains("lol yeah") })
        #expect(text(W.i1g1, chatInput) == text(W.i1, chatInput))
    }
}

/// v7 bake-off combinations.
@Suite struct V7WordingTests {
    typealias W = ChatPrefillFramer.Wording

    @Test func combinationsAreBuiltFromTheWinners() {
        #expect(W.v7a.instruction == W.v6b3.instruction)
        #expect(W.v7a.screen == W.v6a3.screen && W.v7a.samplesBeforeScreen)
        #expect(W.v7a.surfaceHints.isEmpty)
        #expect(W.v7b.instruction == W.v6b3.instruction && W.v7b.samplesBeforeScreen)
        #expect(W.v7b.surfaceHints == W.v6c3.surfaceHints)
        let registry = DefaultFramerRegistry()
        for w in W.v7Combinations {
            #expect(registry.framer(for: gemmaInstruct, override: w.id).id == w.id)
        }
        #expect(registry.framer(for: gemmaInstruct, override: nil).id == "chat-prefill-i1g1")
    }

}
