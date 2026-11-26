import HunchCore
import Testing
@testable import HunchText

@Suite struct DictationTextTests {
    @Test func scrubsNonSpeechMarkers() {
        #expect(DictationText.scrubTranscript(" [BLANK_AUDIO] ") == "")
        #expect(DictationText.scrubTranscript("Hello [Music] there (laughs)") == "Hello there")
        #expect(DictationText.scrubTranscript("Thanks for watching!") == "")
        #expect(DictationText.scrubTranscript("字幕由 Amara.org 社群提供") == "")
        // A real sentence that happens to contain the words stays.
        let long = "I told him thanks for watching the kids yesterday, it really helped us get the move done."
        #expect(DictationText.scrubTranscript(long) == long)
        #expect(DictationText.scrubTranscript("Thanks for watching. Please subscribe!") == "")
        #expect(DictationText.scrubTranscript("請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目") == "")
        #expect(DictationText.scrubTranscript("Subtitles by the Amara.org community") == "")
        // Short real sentences that hold the words stay.
        for said in ["Thanks for watching the kids", "Please subscribe me to the newsletter",
                     "我想訂閱這個頻道", "訂閱", "Thanks for watching. See you at six."] {
            #expect(DictationText.scrubTranscript(said) == said)
        }
        #expect(DictationText.isEmptySpeech("Um. Uh..."))
        #expect(DictationText.isEmptySpeech("嗯"))
        #expect(!DictationText.isEmptySpeech("Um, hi"))
    }

    @Test func acceptsAnOrdinaryCleanup() {
        let said = "um so can you send me the the slides by thursday no wait friday"
        #expect(DictationText.check("Can you send me the slides by Friday?", transcript: said, textBefore: nil)
                == .accept("Can you send me the slides by Friday?"))
        // Wrappers and labels come off.
        #expect(DictationText.check("Cleaned transcript: <transcript>Hi there.</transcript>", transcript: "hi there",
                                    textBefore: nil) == .accept("Hi there."))
        #expect(DictationText.check("我們明天四點開會。", transcript: "我們明天 呃 三點開會 不對 四點開會 句號",
                                    textBefore: nil) == .accept("我們明天四點開會。"))
    }

    @Test func rejectsAnswersAndOtherDrift() {
        #expect(DictationText.check("  ", transcript: "hello", textBefore: nil) == .reject(.empty))
        // Answering the question instead of writing it down.
        let answer = "The capital of France is Paris. It has been the capital since the tenth century and is the "
            + "largest city in the country, home to about two million people."
        #expect(DictationText.check(answer, transcript: "what's the capital of france", textBefore: nil)
                == .reject(.tooLong))
        // Cut off or summarised.
        let said = "first we need to finish the onboarding screens then fix the crash on launch and after "
            + "that ship the beta to the testers on friday"
        #expect(DictationText.check("Finish onboarding.", transcript: said, textBefore: nil) == .reject(.tooShort))
        // The whole thing twice.
        let once = "Please send the updated contract to the legal team today"
        #expect(DictationText.check(once + " " + once, transcript: once.lowercased(), textBefore: nil)
                == .reject(.doubled))
        // Said twice for real: kept.
        #expect(DictationText.check(once + " " + once, transcript: once + " " + once, textBefore: nil)
                == .accept(once + " " + once))
        // The field's text copied in.
        let before = "Thanks for the notes from yesterday's planning meeting about the launch timeline."
        let copied = "Thanks for the notes from yesterday's planning meeting. Sounds good."
        #expect(DictationText.check(copied, transcript: "sounds good", textBefore: before) == .reject(.copiedContext))
        let saidMore = "sounds good to me and I think we can move ahead with the plan as written by the team"
        let copiedLong = "Thanks for the notes from yesterday's planning meeting. Sounds good to me, and I think we "
            + "can move ahead with the plan."
        #expect(DictationText.check(copiedLong, transcript: saidMore, textBefore: before) == .reject(.copiedContext))
    }

    @Test func fitsAfterTheFieldText() {
        #expect(DictationText.fitted("Hello", after: "") == "Hello")
        #expect(DictationText.fitted("Hello", after: "Done.") == " Hello")
        #expect(DictationText.fitted("Hello", after: "Done. ") == "Hello")
        #expect(DictationText.fitted("Hello", after: "line\n") == "Hello")
        #expect(DictationText.fitted(", then", after: "first") == ", then")
        #expect(DictationText.fitted("我們走吧", after: "好的。") == "我們走吧")
        #expect(DictationText.fitted("OK", after: "好的") == "OK")
        #expect(DictationText.fitted("name", after: "(") == "name")
    }

    @Test func namesFromTitlesAndScreens() {
        #expect(DictationText.names(in: "Re: Q3 Roadmap with Alex Morgan — Inbox") == ["Q3 Roadmap", "Alex Morgan"])
        let screen = "Hi Jordan, the Hunch build for iOS is ready. Jordan said GPT-5 runs fine on the M4. "
            + "The team met on Monday."
        let names = DictationText.names(in: screen)
        #expect(names.first == "Jordan")
        #expect(names.contains("Hunch") && names.contains("iOS") && names.contains("GPT-5") && names.contains("M4"))
        #expect(!names.contains("The") && !names.contains("Monday") && !names.contains("Hi"))
        #expect(DictationText.names(in: "我們今天開會").isEmpty)
        #expect(DictationText.names(in: String(repeating: "Alpha Beta ", count: 10), limit: 1).count == 1)
    }
}
