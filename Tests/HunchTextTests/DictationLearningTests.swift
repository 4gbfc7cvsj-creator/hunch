import Foundation
import HunchCore
import Testing
@testable import HunchText

@Suite struct DictationChatStyleTests {
    @Test func lowercasesAndDropsFormalMarks() {
        let said = "ok sounds good see you at 3:30 can alex come too"
        #expect(DictationText.chatStyle("Ok, sounds good. See you at 3:30! Can Alex come too?", transcript: said)
                == "ok, sounds good see you at 3:30 can alex come too?")
        #expect(DictationText.chatStyle("Note: bring the slides; the iPad too.", transcript: "note bring the slides")
                == "note bring the slides, the ipad too")
    }

    @Test func keepsWhatWasDictatedAndWhatIsNotPunctuation() {
        #expect(DictationText.chatStyle("Done. Ship it.", transcript: "done period ship it period")
                == "done. ship it.")
        #expect(DictationText.chatStyle("Wow!", transcript: "wow exclamation mark") == "wow!")
        #expect(DictationText.chatStyle("Call ABC now", transcript: "call capital abc now") == "Call ABC now")
        // Decimals, domains, ellipses and links stay.
        #expect(DictationText.chatStyle("It's v1.2 on claude.ai... see https://x.com", transcript: "")
                == "it's v1.2 on claude.ai... see https://x.com")
    }

    @Test func restoresADroppedQuestionMark() {
        #expect(DictationText.chatStyle("can alex come too", transcript: "Can Alex come too?") == "can alex come too?")
        #expect(DictationText.chatStyle("你要來嗎", transcript: "你要來嗎？") == "你要來嗎？")
        #expect(DictationText.chatStyle("你要帶筆電嗎", transcript: "你要帶筆電嗎") == "你要帶筆電嗎？")
        #expect(DictationText.chatStyle("can alex come too？", transcript: "") == "can alex come too?")
    }

    @Test func chineseChat() {
        #expect(DictationText.chatStyle("好的。明天見！", transcript: "好的 明天見") == "好的 明天見")
        #expect(DictationText.chatStyle("好的。", transcript: "好的 句號") == "好的。")
        #expect(DictationText.chatStyle("你要來嗎？", transcript: "你要來嗎") == "你要來嗎？")
    }
}

@Suite struct DictationFixRuleTests {
    @Test func replacesWholeWordsInAnyCase() {
        let fixes = [DictationFix(heard: "clock code", written: "Claude Code")]
        let (text, applied) = DictationText.applyFixes(fixes, to: "I use Clock Code daily, clock codes no.")
        #expect(text == "I use Claude Code daily, clock codes no.")
        #expect(applied.count == 1)
        #expect(DictationText.applyFixes(fixes, to: "the clock").applied.isEmpty)
    }

    @Test func skipsDisabledAndHandlesChinese() {
        var off = DictationFix(heard: "night owl", written: "NightOwl")
        off.enabled = false
        #expect(DictationText.applyFixes([off], to: "night owl").text == "night owl")
        let zh = DictationFix(heard: "城市", written: "程式")
        #expect(DictationText.applyFixes([zh], to: "我在寫城市碼").text == "我在寫程式碼")
    }

    @Test func longestRuleFirst() {
        let fixes = [DictationFix(heard: "code", written: "Kode"), DictationFix(heard: "clock code", written: "Claude Code")]
        #expect(DictationText.applyFixes(fixes, to: "clock code").text == "Claude Code")
    }
}

@Suite struct DictationCorrectionTests {
    let known: (String) -> Bool = { ["clock", "code", "cloud"].contains($0.lowercased()) }

    func found(_ inserted: String, _ field: String, chat: Bool = false) -> [DictationText.Correction] {
        guard case .present(let list) = DictationText.corrections(inserted: inserted, field: field, chat: chat,
                                                                 isKnownWord: known) else { return [] }
        return list
    }

    @Test func learnsAMisheardWordWithItsNeighbour() {
        let list = found("It works in Safari and Clock Code.", "It works in Safari and Claude Code.")
        #expect(list.count == 1)
        #expect(list.first?.word == "Claude")
        #expect(list.first?.rule?.heard == "Clock Code")
        #expect(list.first?.rule?.written == "Claude Code")
    }

    @Test func aMadeUpMishearingNeedsNoNeighbour() {
        let list = found("Ask Shinade about it", "Ask Sinead about it")
        #expect(list.first?.word == "Sinead")
        #expect(list.first?.rule?.heard == "Shinade")
    }

    @Test func textAroundTheDictationIsNotAnEdit() {
        let field = "Earlier text here. It works in Safari and Claude Code. And then I kept typing more words."
        let list = found("It works in Safari and Clock Code.", field)
        #expect(list.map(\.word) == ["Claude"])
        #expect(DictationText.corrections(inserted: "See you soon", field: "Hi. See you soon. Bye", chat: false)
                == .present([]))
    }

    @Test func ignoresCommonWordsRewritesAndUnrelatedSwaps() {
        // Content edit with an everyday word.
        #expect(found("Why did you go", "What did you go").isEmpty)
        // Unrelated replacement.
        #expect(found("Meet at the Hilton tomorrow", "Meet at the Marriott tomorrow").isEmpty)
        // Rewritten: more than half changed.
        #expect(found("send the deck by friday", "push the slides to monday").isEmpty)
        // Too short.
        #expect(found("ask jo", "ask Jo", chat: true).isEmpty)
    }

    @Test func capitalsAreFixesOutsideChatOnly() {
        #expect(found("I bought an iphone today", "I bought an iPhone today").map(\.word) == ["iPhone"])
        #expect(found("I bought an iphone today", "I bought an iPhone today", chat: true).isEmpty)
        // Capitalizing a sentence start is not a name.
        #expect(found("ok. sounds good", "ok. Sounds good").isEmpty)
    }

    @Test func goneWhenSentOrDeleted() {
        #expect(DictationText.corrections(inserted: "see you at the cafe tonight", field: "", chat: true) == .gone)
        #expect(DictationText.corrections(inserted: "see you at the cafe tonight", field: "something else entirely",
                                          chat: true) == .gone)
    }

    @Test func traditionalChineseHomophone() {
        let list = found("我在寫城市碼給你看", "我在寫程式碼給你看")
        #expect(list.first?.word == "程式")
        #expect(list.first?.rule?.heard == "城市")
        // Different length: an edit of what was said, not a homophone.
        #expect(found("我們明天開會", "我們後天下午開會").isEmpty)
    }
}
