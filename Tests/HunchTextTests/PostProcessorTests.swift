import HunchCore
import Testing
@testable import HunchText

private let processor = DefaultPostProcessor()

private func run(_ raw: String, before: String, after: String = "", required: String = "", maxWords: Int = 6,
                 allowNewlines: Bool = false, meanLogProb: Float? = nil,
                 using p: DefaultPostProcessor = processor) -> PostOutcome {
    p.process(raw, meanLogProb: meanLogProb,
              context: PostContext(before: before, after: after, requiredPrefix: required,
                                   allowNewlines: allowNewlines, maxWords: maxWords))
}

// MARK: - AI voice through the processor

@Test func iAmABotIsAIVoice() {
    #expect(run(" bot.", before: "I am a", required: " a") == .suppress(.aiVoice))
}

@Test func iAmAStudentShows() {
    #expect(run(" student at UCLA", before: "I am a", required: " a") == .show(" student at UCLA"))
}

@Test func healedMidWordAIIsAIVoice() {
    // Required " a" was satisfied by " an", so the visible text starts mid-word.
    #expect(run("n AI language model", before: "I am a", required: " a") == .suppress(.aiVoice))
}

@Test func chatReplyOpenerIsMetaReply() {
    #expect(run(" Sure, here is a poem", before: "Write a poem about the sea.") == .suppress(.metaReply))
}

@Test func chineseSelfIdentificationSuppressed() {
    #expect(run("一个人工智能助手", before: "我是") == .suppress(.aiVoice))
}

@Test func chineseHumanContinuationShows() {
    #expect(run("一名大学生", before: "我是", maxWords: 4) == .show("一名大学生"))
}

// MARK: - Whitespace and spacing

@Test func trailingWhitespaceTrimmed() {
    #expect(run(" the meeting  \t", before: "See you at") == .show(" the meeting"))
}

@Test func whitespaceRunsCollapsed() {
    #expect(run(" see   you\tsoon", before: "Hope to") == .show(" see you soon"))
}

@Test func leadingSpaceDroppedAfterWhitespace() {
    #expect(run(" tomorrow", before: "See you ") == .show("tomorrow"))
}

@Test func midWordContinuationKeepsNoSpace() {
    #expect(run("ple pie", before: "I like ap", required: " ap") == .show("ple pie"))
}

@Test func leadingNewlineStrippedAndSpaced() {
    #expect(run("\nThanks again", before: "See you soon.") == .show(" Thanks again"))
}

@Test func leadingNewlineStrippedAfterSpace() {
    #expect(run("\n\nThanks again", before: "See you soon. ") == .show("Thanks again"))
}

@Test func cutAtNewlineWhenNotAllowed() {
    #expect(run(" the report\nBest,\nAnna", before: "I attached") == .show(" the report"))
}

@Test func newlinesKeptWhenAllowed() {
    #expect(run(" the report\n\n\nBest", before: "I attached", allowNewlines: true) == .show(" the report\nBest"))
}

// MARK: - Suppress reasons

@Test func emptySuppressed() {
    #expect(run("   ", before: "Hello") == .suppress(.empty))
    #expect(run("", before: "Hello") == .suppress(.empty))
}

@Test func punctuationOnlySuppressed() {
    #expect(run(" ...!", before: "Wow") == .suppress(.punctuationOnly))
    #expect(run("。", before: "今天") == .suppress(.punctuationOnly))
}

@Test func markupLeakSuppressed() {
    #expect(run(" thanks<|turn>", before: "Many") == .suppress(.markupLeak))
    #expect(run(" [INST] write", before: "Please") == .suppress(.markupLeak))
    #expect(run(" ```swift", before: "Here:") == .suppress(.markupLeak))
    #expect(run("<start_of_turn>user", before: "Hi") == .suppress(.markupLeak))
}

@Test func codeFenceAllowedInsideMarkdown() {
    #expect(run(" ``` block", before: "```\nlet x = 1\n```\nAnother", maxWords: 4) == .show(" ``` block"))
}

@Test func echoesAfterSuppressed() {
    #expect(run(" the meeting tomorrow", before: "See you at", after: " the meeting tomorrow.")
        == .suppress(.echoesAfter))
}

@Test func singleWordMatchingAfterIsFine() {
    #expect(run(" soon and", before: "See you", after: " soon") == .show(" soon and"))
}

@Test func echoesBeforeSuppressed() {
    #expect(run(" and I think that we should go", before: "I think that we should go",
                maxWords: 8) == .suppress(.echoesBefore))
}

@Test func repeatedWordLoopSuppressed() {
    #expect(run(" very very very", before: "It is") == .suppress(.repetitionLoop))
    #expect(run(" very very", before: "It is very") == .suppress(.repetitionLoop))
}

@Test func repeatedBigramLoopSuppressed() {
    #expect(run(" the cat the cat the cat", before: "I saw", maxWords: 8) == .suppress(.repetitionLoop))
}

@Test func chineseLaughterIsNotALoop() {
    #expect(run("哈哈哈", before: "太好笑了") == .show("哈哈哈"))
}

@Test func lowConfidenceSuppressedOnlyWithThreshold() {
    let strict = DefaultPostProcessor(minMeanLogProb: -2.0)
    #expect(run(" maybe", before: "We could", meanLogProb: -3.1, using: strict) == .suppress(.lowConfidence))
    #expect(run(" maybe", before: "We could", meanLogProb: -1.0, using: strict) == .show(" maybe"))
    #expect(run(" maybe", before: "We could", meanLogProb: nil, using: strict) == .show(" maybe"))
    #expect(run(" maybe", before: "We could", meanLogProb: -9.0) == .show(" maybe"))
}

// MARK: - Clamping

@Test func clampToMaxWordsAtBoundary() {
    #expect(run(" the quarterly report by Friday", before: "Please send", maxWords: 3)
        == .show(" the quarterly report"))
}

@Test func clampKeepsAttachedPunctuation() {
    #expect(run(" soon, and then", before: "See you", maxWords: 1) == .show(" soon,"))
}

@Test func clampChineseByThreeCharacters() {
    // 4 words ≈ 12 CJK characters.
    #expect(run("一起去公园散步，然后去吃午饭吧", before: "今天天气很好，我们", maxWords: 4)
        == .show("一起去公园散步，然后去吃午"))
}

@Test func clampMixedScripts() {
    // "用" is one CJK unit (1 char → 1 word), "Swift" the second; "写代" still rounds within it.
    #expect(TextMeasure.clamp("用 Swift 写代码很有趣", maxWords: 2) == "用 Swift 写代")
    #expect(TextMeasure.wordCount("用 Swift 写代码很有趣") == 4)
}

@Test func wordCountMatchesDecoderRule() {
    #expect(TextMeasure.wordCount(" don't stop, well-known") == 3)
    #expect(TextMeasure.wordCount("今天天气") == 2)
    #expect(TextMeasure.wordCount("...") == 0)
}

// MARK: - Style-example copy guard

private func runStyle(_ raw: String, examples: [String], before: String = "So I was thinking") -> PostOutcome {
    processor.process(raw, meanLogProb: nil,
                      context: PostContext(before: before, after: "", requiredPrefix: "", allowNewlines: false,
                                           maxWords: 12, styleExamples: examples))
}

@Test func copyOfFourWordRunFromStyleExampleIsCutBeforeTheRunCompletes() {
    let ex = ["We should book the kiln for Friday afternoon."]
    #expect(runStyle(" about the kiln for Friday", examples: []) == .show(" about the kiln for Friday"))
    // Case-insensitive, punctuation-insensitive; the first three words of the run may stay.
    #expect(runStyle(" we should BOOK the kiln, ok", examples: ex) == .show(" we should BOOK"))
    // New words before the run are kept too.
    #expect(runStyle(" maybe we should book the kiln", examples: ex) == .show(" maybe we should book"))
}

@Test func threeWordOverlapWithStyleExampleShows() {
    let ex = ["We should book the kiln for Friday afternoon."]
    #expect(runStyle(" the kiln for lunch", examples: ex) == .show(" the kiln for lunch"))
}

@Test func shortOrUnrelatedStyleExamplesDoNotChangeOutput() {
    #expect(runStyle(" going to the market", examples: ["too short here", "other words entirely different"]) ==
        .show(" going to the market"))
}

@Test func cjkNeedsLongerRunForStyleCopy() {
    let ex = ["我們今天下午去看電影然後吃晚餐"]
    #expect(runStyle("今天下午去", examples: ex, before: "我") == .show("今天下午去"))
    #expect(runStyle("今天下午去看電影然後", examples: ex, before: "我") == .show("今天下午去看電"))
}

@Test func copyGuardKeepWordsCount() {
    let ex = ["one two three four five"]
    #expect(DefaultPostProcessor.styleCopyKeepWords(["x", "one", "two", "three", "four"], examples: ex) == 4)
    #expect(DefaultPostProcessor.styleCopyKeepWords(["one", "two", "three"], examples: ex) == nil)
    #expect(DefaultPostProcessor.styleCopyKeepWords(["one", "two", "three", "four"], examples: []) == nil)
}

@Test func styleCopyCannotLeakAFewWordsAtATime() {
    let ex = ["I'll be at the shed around 6 tonight."]
    // After accepting "I'll be at", the next chunk would finish the sentence: the typed words count.
    #expect(runStyle(" the shed around 6", examples: ex, before: "ok I'll be at") == .suppress(.copiesStyleExample))
    // Typed text that does not follow the example leaves the same words alone.
    #expect(runStyle(" the shed around 6", examples: ex, before: "we should meet at") == .show(" the shed"))
}

@Test func styleCopyMatchesAWordTheCompletionFinishes() {
    let ex = ["I'll be at the shed around 6 tonight."]
    #expect(runStyle("ed around 6 tonight", examples: ex, before: "ok I'll be at the sh") == .suppress(.copiesStyleExample))
}

private func runScreen(_ raw: String, screen: String, before: String) -> PostOutcome {
    processor.process(raw, meanLogProb: nil,
                      context: PostContext(before: before, after: "", requiredPrefix: "", allowNewlines: false,
                                           maxWords: 12, screenText: screen))
}

@Test func screenCopyIsCutBeforeASixWordRun() {
    let screen = "Sam\nanyone want to grab ramen after the raid tonight?\nJo\nsure"
    #expect(runScreen(" want to grab ramen after the", screen: screen, before: "does anyone") == .show(" want to grab ramen"))
    #expect(runScreen(" ramen after the raid", screen: screen, before: "anyone want to grab") == .show(" ramen"))
    #expect(runScreen(" after the raid", screen: screen, before: "anyone want to grab ramen") == .suppress(.copiesScreen))
}

@Test func screenCopyInChineseIsCutAtEightCharacters() {
    let screen = "mika 9:02 PM\n我昨天去參加朋友的婚禮，喝到半夜才回家"
    #expect(runScreen("昨天去參加朋友的婚禮，", screen: screen, before: "我") == .show("昨天去參加朋"))
}

@Test func screenWordingInShortRunsShows() {
    let screen = "Can you review the Q3 roadmap draft before Friday?"
    #expect(runScreen(" the Q3 roadmap draft today", screen: screen, before: "I'll review") == .show(" the Q3 roadmap draft today"))
}

// MARK: - Next list item

@Test func markerAfterCaretSentenceEndGetsSpace() {
    #expect(run("3. Email - Gmail", before: "2. Social - i want to sound casual.") == .show(" 3. Email - Gmail"))
    #expect(run("2. don't use \"AI\"", before: "don't use first person perspective.") == .show(" 2. don't use \"AI\""))
}

@Test func markerGluedInsideCompletionGetsSpace() {
    #expect(run("al.3. Email", before: "i want to sound casu", maxWords: 8) == .show("al. 3. Email"))
    #expect(run("ive.2) Next", before: "first person perspect", maxWords: 8) == .show("ive. 2) Next"))
    #expect(run("al.- Email", before: "sound casu", maxWords: 8) == .show("al. - Email"))
}

@Test func markerAfterDroppedLineBreakGetsSpace() {
    #expect(run("\n3. Email", before: "i want to sound casual.") == .show(" 3. Email"))
    #expect(run("\n- Email", before: "i want to sound casual.") == .show(" - Email"))
}

@Test func markerLookalikesUntouched() {
    #expect(run(" the U.S. Army", before: "He joined") == .show(" the U.S. Army"))
    #expect(run(" v.3.5 now", before: "Update to") == .show(" v.3.5 now"))
    #expect(run(" v1.2. Then", before: "Update to") == .show(" v1.2. Then"))
    #expect(run(" 3 people came", before: "It cost $5.") == .show(" 3 people came"))
    #expect(run(" a.m. today", before: "at 9") == .show(" a.m. today"))
}

@Test func wordAcceptStopsBeforeMarker() {
    let shown = run("al.3. Email", before: "i want to sound casu", maxWords: 8)
    guard case .show(let text) = shown else { Issue.record("suppressed"); return }
    #expect(text.prefix(while: { $0 != " " }) == "al.")
}

// MARK: - List markers inside existing text

@Test func midLineCutsGluedNextItemNumber() {
    // The reported shape: the model ran on into the next item's number right after a ")".
    #expect(run(", emoji search, smart quotes)3.", before: "2. Polish (autocorrect", after: " for notes\n3. Ship",
                maxWords: 10) == .show(", emoji search, smart quotes)"))
    #expect(run(" for notes.3. Ship it", before: "2. Polish", after: " later\n3. Ship", maxWords: 10)
            == .show(" for notes."))
    #expect(run("ive.2) Next", before: "first person perspect", after: " here", maxWords: 8) == .show("ive."))
}

@Test func midLineCutsSpacedNextItemMarker() {
    #expect(run(" casual. 3. Email - Gmail", before: "2. Social - i want to sound", after: " and short",
                maxWords: 10) == .show(" casual."))
    #expect(run(" casual. - Email", before: "- Social: sound", after: " and short", maxWords: 10)
            == .show(" casual."))
}

@Test func midLineMarkerOnlySuppressed() {
    #expect(run("3. Email", before: "2. Social - casual.", after: " Short too.") == .suppress(.empty))
}

@Test func nextItemAfterCaretCutsMarker() {
    // End of the line, but the next line already starts item 3: don't suggest it again.
    #expect(run(" casual. 3. Email", before: "2. Social - sound", after: "\n3. Email - Gmail", maxWords: 8)
            == .show(" casual."))
    #expect(run(" now.\n- Call", before: "- Buy milk", after: "\n- Call mom", maxWords: 8) == .show(" now."))
}

@Test func midLineTraditionalChineseListCut() {
    #expect(run("媽媽。3. 寫報告", before: "1. 買牛奶\n2. 打電話給", after: "，問週末的事\n3. 寫報告", maxWords: 10)
            == .show("媽媽。"))
    #expect(run("媽媽。3.寫報告", before: "1. 買牛奶\n2. 打電話給", after: "，問週末的事", maxWords: 10)
            == .show("媽媽。"))
    #expect(run("媽媽）3、寫報告", before: "1、買牛奶\n2、打電話（給", after: "，問週末的事", maxWords: 10)
            == .show("媽媽）"))
}

@Test func midLineMarkerLookalikesUntouched() {
    #expect(run(" the U.S. Army", before: "He joined", after: " in May") == .show(" the U.S. Army"))
    #expect(run(" v1.2. Then", before: "Update to", after: " today") == .show(" v1.2. Then"))
    #expect(run(" page 3. Then", before: "See", after: " below", maxWords: 8) == .show(" page 3. Then"))
    #expect(run(" well-known - and", before: "It is", after: " here", maxWords: 8) == .show(" well-known - and"))
    #expect(run(" (see above) - and", before: "It is", after: " here", maxWords: 8) == .show(" (see above) - and"))
    #expect(run("二〇二六年3月", before: "日期是", after: "。") == .show("二〇二六年3月"))
}

@Test func endOfLineMarkerStillOnlySpaced() {
    #expect(run("al.3. Email", before: "i want to sound casu", after: "", maxWords: 8) == .show("al. 3. Email"))
    #expect(run("al.3. Email", before: "i want to sound casu", after: "\nThanks", maxWords: 8) == .show("al. 3. Email"))
}

// MARK: - Colons between digits are not sentence ends

@Test func verseAndTimeColonsGetNoSpace() {
    #expect(ListMarker.separated("(John 3:16) says", before: "as written ") == "(John 3:16) says")
    #expect(ListMarker.separated("the call (at 10:30) went", before: "") == "the call (at 10:30) went")
    #expect(ListMarker.separated("a (16:9) screen", before: "") == "a (16:9) screen")
    // The caret sits right after "3:" and the suggestion starts "16)".
    #expect(ListMarker.separated("16) says", before: "(John 3:") == "16) says")
    #expect(run("16) says", before: "As written in (John 3:", maxWords: 8) == .show("16) says"))
    #expect(run(" (at 10:30) went well", before: "The call", maxWords: 8) == .show(" (at 10:30) went well"))
    // 傳統中文: 經文出處與時間也不加空格。
    #expect(run("16）說", before: "經上記著（約翰福音 3:", maxWords: 8) == .show("16）說"))
}

@Test func verseAndTimeColonsDoNotCutMidLine() {
    #expect(ListMarker.cutBeforeNextItem("the call (at 10:30) went", before: "") == "the call (at 10:30) went")
    #expect(ListMarker.cutBeforeNextItem("(John 3:16) says", before: "as written ") == "(John 3:16) says")
    #expect(ListMarker.cutBeforeNextItem("16) says", before: "(John 3:") == "16) says")
    #expect(run(" (at 10:30) went", before: "The call", after: " well", maxWords: 8) == .show(" (at 10:30) went"))
    #expect(run("16) says", before: "As written in (John 3:", after: " that", maxWords: 8) == .show("16) says"))
}

@Test func colonBeforeListStillSeparatesAndCuts() {
    // A sentence-ending colon (word before it, or a space after it) still starts a list.
    #expect(ListMarker.separated("Steps:1) Plan", before: "") == "Steps: 1) Plan")
    #expect(run(" 2024: 1) Plan", before: "Steps for", after: " later", maxWords: 8) == .show(" 2024:"))
    #expect(run(" steps: 1) Plan", before: "Three", after: " later", maxWords: 8) == .show(" steps:"))
}

@Suite struct PostProcessorTraceTests {
    private func traced(_ raw: String, before: String = "Hello ", after: String = "", maxWords: Int = 3,
                        allowNewlines: Bool = false, allowedScripts: Set<String>? = nil)
        -> (PostOutcome, DefaultPostProcessor.Trace) {
        let trace = DefaultPostProcessor.Trace()
        let outcome = DefaultPostProcessor().process(
            raw, meanLogProb: nil,
            context: PostContext(before: before, after: after, requiredPrefix: "", allowNewlines: allowNewlines,
                                 maxWords: maxWords, allowedScripts: allowedScripts),
            trace: trace)
        return (outcome, trace)
    }

    @Test func theWordLimitIsNotedWhenItShortensTheText() {
        let (outcome, trace) = traced("one two three four five")
        #expect(outcome == .show("one two three"))
        #expect(trace.cuts == [.wordLimit(3)])
        #expect(traced("one two").1.cuts.isEmpty)
    }

    @Test func aLineBreakCutIsNoted() {
        #expect(traced("one two\nthree four", maxWords: 10).1.cuts == [.lineBreak])
        #expect(traced("one two\nthree four", maxWords: 10, allowNewlines: true).1.cuts.isEmpty)
    }

    @Test func aScriptGuardCutIsNoted() {
        let (outcome, trace) = traced("see you tomorrow \u{41F}\u{440}\u{438}\u{432}\u{435}\u{442} \u{43C}\u{438}\u{440}", maxWords: 10,
                                      allowedScripts: ["latin"])
        #expect(outcome == .show("see you tomorrow"))
        #expect(trace.cuts == [.scriptGuard])
    }

    @Test func theTraceNeverChangesTheOutcome() {
        let processor = DefaultPostProcessor()
        let context = PostContext(before: "Hello ", after: "", requiredPrefix: "", allowNewlines: false, maxWords: 3)
        for raw in ["one two three four five", "x", "", "\u{41F}\u{440}\u{438}", "see you soon.\nNext line"] {
            #expect(processor.process(raw, meanLogProb: nil, context: context)
                == processor.process(raw, meanLogProb: nil, context: context, trace: DefaultPostProcessor.Trace()))
        }
    }
}

// MARK: - Task talk is cut, not hidden

@Test func taskTalkMidwayIsCutBeforeIt() {
    let before = "Before we build, I think we have a lot of switches that sound very similar, and may be technically different, but when it comes to the scope of perm"
    #expect(run("issions, they might be functionally identical for the user.", before: before, maxWords: 12)
        == .show("issions, they might be functionally identical"))
}

@Test func taskTalkCutRecordsTheCut() {
    let trace = DefaultPostProcessor.Trace()
    let outcome = processor.process(" the plan is fine for the user.", meanLogProb: nil,
                                    context: PostContext(before: "I think", after: "", requiredPrefix: "",
                                                         allowNewlines: false, maxWords: 8), trace: trace)
    #expect(outcome == .show(" the plan is fine"))
    #expect(trace.cuts.contains(.taskTalk))
}

@Test func taskTalkAtStartIsStillHidden() {
    #expect(run(" the user wants a summary", before: "Tell") == .suppress(.metaReply))
    #expect(run("the user wants a summary", before: "Tell ") == .suppress(.metaReply))
}

@Test func taskTalkLeavingOnlyDanglingWordsIsHidden() {
    #expect(run(" and the continuation", before: "Tell me") == .suppress(.metaReply))
}

@Test func taskTalkCutKeepsFinishedWordEvenIfSmall() {
    // "int" + "o" finishes "into": the completion's own word is kept.
    #expect(run("o the continuation of", before: "Look int") == .show("o"))
}

@Test func taskTalkCutThatStillSoundsLikeAReplyIsHidden() {
    #expect(run(" Sure, here is the continuation", before: "Write a poem about the sea.") == .suppress(.metaReply))
}
