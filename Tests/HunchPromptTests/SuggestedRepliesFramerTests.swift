import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct SuggestedRepliesFramerTests {
    private let framer = WriteForMeFramer()
    private func text(_ p: FramedPrompt) -> String { p.segments.map(\.text).joined() }

    private func request(screen: String? = "Jordan: Are you free Thursday at 3 for the design review?",
                         length: LengthPreset = .medium) -> WriteRequest {
        var r = WriteRequest(id: RequestID(1), mode: .write, source: "", shape: .message,
                             context: PromptInput(before: "", after: "", surface: .chat,
                                                  aboutWriter: "Name: Alex Morgan.", preferredLanguages: ["en"],
                                                  screenContext: screen, appName: "Slack"))
        r.replies = ReplyRequest(length: length)
        return r
    }

    @Test func instructPromptAsksForRepliesToTheScreenMessage() {
        let p = framer.frame(request(), profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
        let t = text(p)
        #expect(p.framerID == WriteForMeFramer.repliesFrameID)
        #expect(p.style == .chatPrefill)
        #expect(t.hasPrefix(KnownChatMarkers.gemma4.userOpen))
        #expect(t.hasSuffix(KnownChatMarkers.gemma4.turnClose + KnownChatMarkers.gemma4.assistantOpen))
        #expect(t.contains("Thursday at 3"))
        #expect(t.contains("Alex Morgan"))
        #expect(t.contains(ReplyRequest.noneMarker))
        #expect(!t.contains(WriteForMeFramer.writeTask))
        #expect(!t.contains("My instruction:"))
    }

    @Test func taskCoversChoicesYesNoAndOpenQuestions() {
        let task = WriteForMeFramer.repliesTask(ReplyRequest(length: .medium))
        // The model decides what fits, best first; options offered are usually the answers.
        #expect(task.contains("most likely"))
        #expect(task.contains("best first"))
        #expect(task.contains("those options are usually my answers"))
        #expect(task.contains("never turn its own request into a reply"))
        #expect(task.contains("not the same one in other words"))
        #expect(task.contains("Stop after one or two when no other real answer fits"))
        #expect(task.contains("language of the message"))
        // The newest message, not an older one or the app's own prompts; no padding.
        #expect(task.contains("Questions I already answered further up are done"))
        #expect(task.contains("never the app's name"))
    }

    @Test func lengthFollowsTheSetting() {
        #expect(WriteForMeFramer.repliesTask(ReplyRequest(length: .short)).contains("1 to 2 words"))
        #expect(WriteForMeFramer.repliesTask(ReplyRequest(length: .ultra)).contains("10 to 15 words"))
    }

    @Test func traditionalChineseScreenAsksForTraditional() {
        let t = text(framer.frame(request(screen: "小明：你週四下午三點有空開會嗎？"), profile: gemmaInstruct,
                                  budget: 4096, counter: ScalarCounter()))
        #expect(t.contains("繁體字"))
        let english = text(framer.frame(request(), profile: gemmaInstruct, budget: 4096, counter: ScalarCounter()))
        #expect(!english.contains("繁體字"))
    }

    @Test func screenSecretsAreMasked() {
        let secret = "ghp_" + String(repeating: "FaKe", count: 9)
        let t = text(framer.frame(request(screen: "Here is the token \(secret) for you"),
                                  profile: gemmaInstruct, budget: 4096, counter: ScalarCounter()))
        #expect(!t.contains(secret))
    }

    @Test func baseProfileStillFramesWithoutMarkers() {
        let p = framer.frame(request(), profile: gemmaBase, budget: 4096, counter: ScalarCounter())
        #expect(p.style == .document)
        #expect(!text(p).contains(KnownChatMarkers.gemma4.userOpen))
    }
}

@Suite struct SuggestedRepliesScreenLimitTests {
    @Test func screenTextIsCutToTheLimitKeepingTheNewest() {
        let old = String(repeating: "Older line about something else entirely. ", count: 300)
        var r = WriteRequest(id: RequestID(1), mode: .write, source: "", shape: .message,
                             context: PromptInput(before: "", after: "", surface: .chat,
                                                  screenContext: old + "\nJordan: Lunch at noon?"))
        r.replies = ReplyRequest(length: .medium)
        r.context.screenTokenLimit = 100
        let p = WriteForMeFramer().frame(r, profile: gemmaInstruct, budget: 8000, counter: ScalarCounter())
        let t = p.segments.map(\.text).joined()
        #expect(t.contains("Lunch at noon?"))
        #expect(t.count < old.count / 2)
    }

    @Test func taskWarnsAboutMisreadScreenText() {
        let task = WriteForMeFramer.repliesTask(ReplyRequest(length: .medium))
        #expect(task.contains("text recognition"))
        #expect(task.contains("never copy a misread word"))
    }

    @Test func aLabeledChatNamesTheirNewestMessageOrSaysNothingIsWaiting() {
        let late = "Jordan\nToday 5:05 PM\nMe: are you almost here\nDelivered\nThem: sorry yeah"
        let line = WriteForMeFramer.repliesSidesLine(screen: late)
        #expect(line?.contains("their newest message is \"sorry yeah\"") == true)
        #expect(line?.contains("as me") == true)
        let mine = "Them: want to grab lunch at noon?\nMe: sure, the usual place?\nDelivered"
        #expect(WriteForMeFramer.repliesSidesLine(screen: mine)?.contains("output only NONE") == true)
        let group = "Me: who's bringing the board?\nRiley: I can bring it"
        #expect(WriteForMeFramer.repliesSidesLine(screen: group)?.contains("\"I can bring it\"") == true)
        // No labels (Claude Code, email): nothing added; times like "5:05 PM" aren't labels.
        #expect(WriteForMeFramer.repliesSidesLine(screen: "Done testing or skip testing?\nToday 5:05 PM") == nil)
    }

    @Test func newestMessageSkipsTheirListItemsAndStatusRows() {
        let screen = """
            Me: Tested the arrow keys, they work
            Them: Built and installed. Should I commit it now?
            Them: • Merge into replies branch, build, install
            Them: © Commit on master
            Them: Thinking 41s ›
            Them: 2m 13s • 3.1K tokens
            Them: Ran 2 commands ›
            """
        let line = WriteForMeFramer.repliesSidesLine(screen: screen)
        #expect(line?.contains("\"Built and installed. Should I commit it now?\"") == true)
        // Status rows after my own message don't make it theirs to answer.
        let mineNewest = "Them: Want to grab dinner?\nMe: Sure, 7 works\nThem: Thinking 12s ›"
        #expect(WriteForMeFramer.repliesSidesLine(screen: mineNewest)?.contains("output only NONE") == true)
        // Short real messages are still messages.
        let short = "Me: Where are you?\nThem: at 5\nThem: lol"
        #expect(WriteForMeFramer.repliesSidesLine(screen: short)?.contains("\"lol\"") == true)
        #expect(!WriteForMeFramer.isListOrStatus("see you in 5"))
        #expect(!WriteForMeFramer.isListOrStatus("Running late, be there in 10 min."))
    }

    @Test func screenOfOnlyTheirMessagesStillNamesTheNewest() {
        let line = WriteForMeFramer.repliesSidesLine(screen: "Them: Hi!\nThem: Are you coming tonight?")
        #expect(line?.contains("\"Are you coming tonight?\"") == true)
    }
}
