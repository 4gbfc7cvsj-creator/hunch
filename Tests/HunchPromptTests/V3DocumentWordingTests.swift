import Foundation
import HunchCore
import Testing
@testable import HunchPrompt

/// v3 base screening wordings (base framer bake-off, stage 1): document-v1 plus one change each.
@Suite struct V3DocumentWordingTests {
    typealias W = DocumentFramer.Wording

    private func text(_ w: W, _ input: PromptInput) -> String {
        DocumentFramer(w).frame(input, profile: gemmaBase, budget: 4096, counter: ScalarCounter())
            .segments.map(\.text).joined()
    }

    private let chatInput = PromptInput(before: "Sounds good, I'll move the", after: "", surface: .chat,
                                        aboutWriter: "Alex Morgan, product designer.",
                                        screenContext: "Noah: can we push standup a bit tomorrow?",
                                        styleExamples: ["lol yeah that works", "ok see you there"])

    private let chineseInput = PromptInput(before: "陳經理您好：\n\n謝謝您的來信，關於下週的會議時間，我這邊星期三下午都可",
                                           after: "", surface: .email, preferredLanguages: ["zh-Hant"],
                                           screenContext: "主旨：下週會議時間", styleExamples: ["好的，沒問題，我們再約。"])

    @Test func idsAreDistinctRegisteredAndV1StaysDefault() {
        let ids = W.v3Screening.map(\.id)
        #expect(Set(ids).count == 9)
        let registry = DefaultFramerRegistry()
        for id in ids {
            #expect(registry.framer(for: gemmaBase, override: id).id == id)
            #expect(registry.all.filter { $0.id == id }.count == 1)
        }
        #expect(registry.framer(for: gemmaBase, override: nil).id == "document-v1")
        #expect(registry.framer(for: gemmaInstruct, override: nil).id == "chat-prefill-i1g1")
    }

    @Test func onlyTheIntendedPartChanges() {
        for w in [W.v3a1, .v3a2, .v3a3, .v3c1] { #expect(w.header == W.v1.header, "\(w.id)") }
        for w in [W.v3b1, .v3b2, .v3b3] {
            #expect(w.header.hasPrefix(W.v1.header), "\(w.id)")
            #expect(w.header.count - W.v1.header.count <= 160, "\(w.id)")
            #expect(w.screen == W.v1.screen && w.caretLabel.isEmpty && w.surfaceHints.isEmpty)
        }
        #expect(W.v3a1.caretLabel.isEmpty && W.v3a2.screen == W.v1.screen)
    }

    @Test func caretLabelOnlyWithScreenText() {
        let t = text(.v3a2, chatInput)
        #expect(t.hasSuffix("\n\n" + W.followsOn + "\nSounds good, I'll move"))
        var noScreen = chatInput
        noScreen.screenContext = nil
        #expect(!text(.v3a2, noScreen).contains(W.followsOn))
        #expect(!text(.v1, chatInput).contains(W.followsOn))
    }

    @Test func screenLabelNamesNewestLines() {
        #expect(text(.v3a1, chatInput).contains("its last lines are the newest"))
        #expect(text(.v3a3, chatInput).contains("its last lines are the newest"))
        #expect(!text(.v1, chatInput).contains("its last lines are the newest"))
    }

    @Test func surfaceHintOnlyForCasualSurfaces() {
        #expect(text(.v3c1, chatInput).contains("Kind of text: a chat message, typed casually"))
        var prompt = chatInput
        prompt.surface = .email
        let email = text(.v3c1, prompt)
        #expect(email.contains("Kind of text: an email\n"))
    }

    @Test func chineseHeaderMatchesScript() {
        let traditional = text(.v3c2, chineseInput)
        #expect(traditional.hasPrefix(W.chinese[0]))
        #expect(!traditional.contains(W.v1.header))
        var simplified = chineseInput
        simplified.before = "王经理您好：\n\n谢谢您的来信，关于下周的会议时间，我这边星期三下午都可"
        #expect(text(.v3c3, simplified).hasPrefix(W.chinese[1]))
        // English, Japanese and code keep the English headers.
        #expect(text(.v3c2, chatInput).hasPrefix(W.v1.header))
        #expect(text(.v3c2, PromptInput(before: "今日は会議がありますので、明日の予定を確認して")).hasPrefix(W.v1.header))
        #expect(text(.v3c2, PromptInput(before: "// 設定\nlet city = \"東京都中央區銀座\"", surface: .code)).hasPrefix(W.v1.codeHeader))
    }

    @Test func traditionalChineseTextIsUntouched() {
        for w in W.v3Screening {
            let t = text(w, chineseInput)
            #expect(t.contains("主旨：下週會議時間"), "\(w.id)")
            #expect(t.contains("好的，沒問題，我們再約。"), "\(w.id)")
            #expect(t.contains("我這邊星期三下午都"), "\(w.id)")
        }
    }

    @Test func noMachineWordsAndPrefaceEchoCovered() {
        for w in W.v3Screening {
            for surface in SurfaceKind.allCases {
                var input = chatInput
                input.surface = surface
                let t = text(w, input).lowercased()
                let words = t.split(whereSeparator: { !$0.isLetter && $0 != "." })
                for banned in ["ai", "bot", "llm"] { #expect(!words.contains(Substring(banned)), "\(w.id)") }
                for banned in ["assistant", "model", "autocomplete", "complet", "suggest", "chatbot", "predict",
                               "generate"] {
                    #expect(!t.contains(banned), "\(w.id): \(banned)")
                }
            }
        }
        let phrases = DocumentFramer.prefacePhrases
        #expect(phrases.contains(W.followsOn.trimmingCharacters(in: CharacterSet(charactersIn: ":"))))
        #expect(phrases.contains(W.chinese[0]))
        #expect(phrases.allSatisfy { !$0.isEmpty })
    }
}

/// v4 base bake-off combinations of the stage-1 winners (a1, b3, c3).
@Suite struct V4DocumentWordingTests {
    typealias W = DocumentFramer.Wording

    private func text(_ w: W, _ input: PromptInput) -> String {
        DocumentFramer(w).frame(input, profile: gemmaBase, budget: 4096, counter: ScalarCounter())
            .segments.map(\.text).joined()
    }

    @Test func combinationsAreBuiltFromTheWinners() {
        #expect(W.v4a.screen == W.v3a1.screen && W.v4a.header == W.v3b3.header)
        #expect(W.v4a.surfaceHints.isEmpty && W.v4a.chineseHeaders.isEmpty && W.v4a.caretLabel.isEmpty)
        #expect(W.v4b.screen == W.v3a1.screen && W.v4b.header == W.v3b3.header)
        #expect(W.v4b.surfaceHints == W.v3c3.surfaceHints && W.v4b.chineseHeaders == W.v3c3.chineseHeaders)
        #expect(W.v4c.screen == W.v1.screen && W.v4c.header == W.v3b3.header)
        #expect(W.v4c.surfaceHints == W.v3c3.surfaceHints && W.v4c.chineseHeaders == W.v3c3.chineseHeaders)
        for w in W.v4Combinations { #expect(w.caretLabel.isEmpty, "\(w.id)") }
    }

    @Test func idsAreRegisteredAndV1StaysDefault() {
        let ids = W.v4Combinations.map(\.id)
        #expect(ids == ["document-v4a", "document-v4b", "document-v4c"])
        let registry = DefaultFramerRegistry()
        for id in ids {
            #expect(registry.framer(for: gemmaBase, override: id).id == id)
            #expect(registry.all.filter { $0.id == id }.count == 1)
        }
        #expect(registry.framer(for: gemmaBase, override: nil).id == "document-v1")
        #expect(registry.framer(for: gemmaInstruct, override: nil).id == "chat-prefill-i1g1")
    }

    @Test func chineseTextGetsChineseHeaderAndStaysUntouched() {
        let input = PromptInput(before: "陳經理您好：\n\n謝謝您的來信，關於下週的會議時間，我這邊星期三下午都可",
                                after: "", surface: .email, screenContext: "主旨：下週會議時間")
        for w in [W.v4b, .v4c] {
            let t = text(w, input)
            #expect(t.hasPrefix(W.chinese[0]), "\(w.id)")
            #expect(t.contains("我這邊星期三下午都"), "\(w.id)")
        }
        #expect(text(.v4a, input).hasPrefix(W.v3b3.header))
    }

    @Test func noMachineWords() {
        for w in W.v4Combinations {
            for surface in SurfaceKind.allCases {
                let input = PromptInput(before: "Sounds good, I'll move the", after: "", surface: surface,
                                        screenContext: "Noah: can we push standup a bit tomorrow?")
                let t = text(w, input).lowercased()
                let words = t.split(whereSeparator: { !$0.isLetter && $0 != "." })
                for banned in ["ai", "bot", "llm"] { #expect(!words.contains(Substring(banned)), "\(w.id)") }
                for banned in ["assistant", "model", "autocomplete", "complet", "suggest", "predict", "generate"] {
                    #expect(!t.contains(banned), "\(w.id): \(banned)")
                }
            }
        }
    }
}
