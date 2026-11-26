import HunchCore
import Testing
@testable import HunchText

@Suite struct HanScriptTests {
    @Test func convertsBothWays() {
        #expect(HanScript.simplified("這個密碼") == "这个密码")
        #expect(HanScript.traditional("这个密码") == "這個密碼")
        #expect(HanScript.usesTraditional("我們今天") && !HanScript.usesSimplified("我們今天"))
        #expect(HanScript.usesSimplified("我们今天") && !HanScript.usesTraditional("我们今天"))
        #expect(!HanScript.usesTraditional("hello") && !HanScript.usesSimplified("我今天"))
    }

    @Test func suggestionFollowsTheWritersScript() {
        #expect(DefaultPostProcessor.matchHanScript("们一起去", before: "我們今天和朋友們") == "們一起去")
        // Simplified writer, or no Chinese before the caret: left alone.
        #expect(DefaultPostProcessor.matchHanScript("们一起去", before: "我们今天和朋友") == "们一起去")
        #expect(DefaultPostProcessor.matchHanScript("们一起去", before: "Hello ") == "们一起去")
    }

    @Test func japaneseIsNeverConverted() {
        // Kana in the recent text: shinjitai kanji must stay as written.
        #expect(DefaultPostProcessor.matchHanScript("会学気", before: "東京で") == "会学気")
        #expect(DefaultPostProcessor.matchHanScript("会学気", before: "東京の國で、") == "会学気")
        #expect(DefaultPostProcessor.matchHanScript("会学気", before: "今日は學校へ行きます。") == "会学気")
        // Preferred Japanese without kana: needs clearly traditional evidence (4+ characters).
        #expect(DefaultPostProcessor.matchHanScript("们", before: "東京與臺", languages: ["ja"]) == "们")
        #expect(DefaultPostProcessor.matchHanScript("们", before: "東京與臺灣們學習", languages: ["ja"]) == "們")
        // One traditional-only character is not enough evidence.
        #expect(DefaultPostProcessor.matchHanScript("们", before: "東京") == "们")
    }

    @Test func oneToManyConversionsUseTheRightCharacter() {
        let before = "我們今天去學校，老師說"
        #expect(DefaultPostProcessor.matchHanScript("头发很长", before: before) == "頭髮很長")
        #expect(DefaultPostProcessor.matchHanScript("皇后来了", before: before) == "皇后來了")
        #expect(DefaultPostProcessor.matchHanScript("然后吃面条", before: before) == "然後吃麵條")
        #expect(DefaultPostProcessor.matchHanScript("一只猫在里面", before: before) == "一隻貓在裡面")
        #expect(DefaultPostProcessor.matchHanScript("干净的钟", before: before) == "乾淨的鐘")
        for (key, value) in HanConversion.phrases {
            #expect(key.unicodeScalars.count == value.unicodeScalars.count)
        }
    }

    @Test func mixedEnglishAndChinese() {
        let before = "Hello 我們今天 meeting 學校 "
        #expect(DefaultPostProcessor.matchHanScript("ok 们的 plan", before: before) == "ok 們的 plan")
        #expect(DefaultPostProcessor.matchHanScript("plain english", before: before) == "plain english")
    }

    @Test func traditionalSelfIdentificationIsCaught() {
        #expect(AIVoiceClassifierProbe.chinese(before: "", completion: "我是一個人工智能"))
    }
}

enum AIVoiceClassifierProbe {
    static func chinese(before: String, completion: String) -> Bool {
        DefaultAIVoiceClassifier.chineseSelfIdentification(before: before, completion: completion)
    }
}
