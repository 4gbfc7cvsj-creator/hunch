import Foundation
import Testing
@testable import HunchCore

@Suite struct SuggestedRepliesTests {
    // MARK: Parsing

    @Test func oneReplyPerLineInAnyListStyle() {
        #expect(SuggestedReplies.parse("Yes, Thursday works.\nNo, I'm away that week.\nMaybe, let me check.")
                == ["Yes, Thursday works.", "No, I'm away that week.", "Maybe, let me check."])
        #expect(SuggestedReplies.parse("1. Done testing, it all works.\n2) Skip testing for now.")
                == ["Done testing, it all works.", "Skip testing for now."])
        #expect(SuggestedReplies.parse("- \"Go ahead with the spec.\"\n* “Change the delay slider first.”\n• Looks good!")
                == ["Go ahead with the spec.", "Change the delay slider first.", "Looks good!"])
        #expect(SuggestedReplies.parse("(1) Tea, please.\n(2) Coffee, please.") == ["Tea, please.", "Coffee, please."])
    }

    @Test func headingsBlanksFencesAndDuplicatesAreDropped() {
        let raw = "Here are three replies:\n```\n\n**Yes, see you at 3.**\nyes, see you at 3.\nNo, can we do 4?\n```"
        #expect(SuggestedReplies.parse(raw) == ["Yes, see you at 3.", "No, can we do 4?"])
    }

    @Test func atMostThree() {
        #expect(SuggestedReplies.parse("a\nb\nc\nd\ne").count == 3)
    }

    @Test func noneMeansNothingToReplyTo() {
        #expect(SuggestedReplies.parse("NONE").isEmpty)
        #expect(SuggestedReplies.parse("None.").isEmpty)
        #expect(SuggestedReplies.parse("  \n").isEmpty)
    }

    @Test func traditionalChineseRepliesKeepTheirText() {
        let raw = "1．好啊，週四下午三點可以。\n2、不行，我那天要開會。\n「再看看，我確認一下行程。」"
        #expect(SuggestedReplies.parse(raw) == ["好啊，週四下午三點可以。", "不行，我那天要開會。", "再看看，我確認一下行程。"])
        #expect(SuggestedReplies.parse("回覆：\n可以。") == ["可以。"])
    }

    @Test func numbersInsideARelyStay() {
        #expect(SuggestedReplies.parse("3pm works for me.") == ["3pm works for me."])
        #expect(SuggestedReplies.parse("2026 is fine.") == ["2026 is fine."])
    }

    // MARK: Picker

    @Test func nothingIsHighlightedUntilTabThenItWraps() {
        var p = ReplyPicker(replies: ["a", "b", "c"])
        #expect(p.highlighted == nil && p.chosen == nil)
        p.next()
        #expect(p.chosen == "a")
        p.next(); p.next()
        #expect(p.chosen == "c")
        p.next()
        #expect(p.chosen == "a")
    }

    @Test func lengthFollowsThePreset() {
        let r = ReplyRequest(length: .long)
        #expect(r.minWords == 4 && r.maxWords == 7)
        #expect(ReplyRequest(length: .ultra).maxTokens <= 400)
    }

    // MARK: Gate

    private let app = AppIdentity(bundleID: "com.example.chat", pid: 7, localizedName: "Chat")
    private let field = FieldID(pid: 7, elementHash: 1, generation: 1)

    private func context(_ before: String = "", after: String = "", surface: SurfaceKind = .chat,
                         selection: Int = 0, marked: Bool = false) -> TextContext {
        TextContext(app: app, field: field, before: before, after: after, selectionLength: selection,
                    hasMarkedText: marked, metadata: FieldMetadata(surface: surface), contentSignature: 0)
    }

    private func offers(_ c: TextContext, featureOn: Bool = true, suggestionsOn: Bool = true,
                        policy: AppPolicy = .default) -> Bool {
        SuggestedRepliesGate.mayOffer(featureOn: featureOn, suggestionsOn: suggestionsOn, context: c, policy: policy)
    }

    @Test func onlyInAnEmptyFieldWithEverythingOn() {
        #expect(offers(context()))
        #expect(offers(context(" \n")))
        #expect(!offers(context("H")))
        #expect(!offers(context(after: "draft")))
        #expect(!offers(context(), featureOn: false))
        #expect(!offers(context(), suggestionsOn: false))
    }

    @Test func perAppSwitchKeepsRepliesOut() {
        #expect(!offers(context(), policy: AppPolicy(suggestedRepliesAllowed: false)))
        #expect(SuggestedRepliesGate.whyNot(featureOn: true, suggestionsOn: true, context: context(),
                                            policy: AppPolicy(suggestedRepliesAllowed: false)) == "replies off for this app")
    }

    @Test func whyNotNeverSaysTheText() {
        #expect(SuggestedRepliesGate.whyNot(featureOn: true, suggestionsOn: true, context: context("secret"),
                                            policy: .default) == "field has text (6 characters, no placeholder, no label)")
    }

    // Discord's empty box holds U+FEFF and a newline; some web editors report their placeholder as
    // the value.
    @Test func invisibleCharactersAndPlaceholderCountAsEmpty() {
        #expect(offers(context("\u{FEFF}\n")))
        #expect(offers(context("\u{200B}")))
        var c = context(after: "Ask ChatGPT\n")
        #expect(!offers(c))
        c.metadata.placeholder = "Ask ChatGPT"
        #expect(offers(c))
        c.metadata.placeholder = nil
        c.metadata.label = "Ask ChatGPT Ask ChatGPT"   // ChatGPT names it only in its title and description
        #expect(offers(c))
        c.metadata.label = "Ask"
        #expect(!offers(c))
        #expect(BlankText.trimmed("\u{FEFF} hi\u{200B}\n") == "hi")
    }

    @Test func notInShellsSelectionsOrCompositionOrBlockedPlaces() {
        #expect(!offers(context(surface: .shell)))
        #expect(!offers(context(selection: 3)))
        #expect(!offers(context(marked: true)))
        var off = AppPolicy.default
        off.enabled = false
        #expect(!offers(context(), policy: off))
        var noScreen = AppPolicy.default
        noScreen.screenContextAllowed = false
        #expect(!offers(context(), policy: noScreen))
        var secure = AppPolicy.default
        secure.secureExcluded = true
        #expect(!offers(context(), policy: secure))
    }
}

@Suite struct SuggestedRepliesScreenTests {
    private let chat = "Jordan: Morning! Did you see the slides?\nMe: Yes, they look great.\nJordan: Are you free Thursday at 3 for the review?"

    @Test func aRereadWithAFewMisreadWordsIsTheSameScreen() {
        let reread = chat.replacingOccurrences(of: "slides", with: "slidos").replacingOccurrences(of: "great", with: "qreat")
        #expect(SuggestedReplies.sameScreen(reread, chat))
    }

    @Test func aNewMessageIsAChange() {
        let newer = chat + "\nJordan: Actually, can we move it to Friday morning instead? The room is booked Thursday."
        #expect(!SuggestedReplies.sameScreen(newer, chat))
        #expect(!SuggestedReplies.sameScreen(chat, nil))
    }
}

@Suite struct SuggestedRepliesDiagnosticsTests {
    @Test func similarityIsOneForTheSameReadAndLowForANewMessage() {
        let chat = "Jordan: Are you free Thursday at 3 for the review?"
        #expect(SuggestedReplies.screenSimilarity(chat, chat) == 1)
        #expect(SuggestedReplies.screenSimilarity("", "") == 1)
        #expect(SuggestedReplies.screenSimilarity(chat, "Priya: Lunch tomorrow somewhere near the office?") < 0.2)
    }

    @Test func theConsoleListsTheRepliesTheAppRead() {
        var request = WriteRequest(id: RequestID(7), mode: .write, source: "", shape: .message,
                                   context: PromptInput(before: "", screenContext: "Jordan: Free Thursday?"))
        request.context.screenTokenLimit = 1000
        let replies = ReplyRequest(minWords: 4, maxWords: 8)
        let sections = DiagnosticSections.forReplies(request, replies: replies, raw: "1. Yes, Thursday works.\n2. No, sorry.")
        let read = sections.first { $0.title == "Replies read from the model's text" }
        #expect(read?.items.map(\.text) == ["Yes, Thursday works.", "No, sorry."])
        let asked = sections.first { $0.title == "Request" }
        #expect(asked?.items.contains { $0.text == "1000 tokens" } == true)
        let none = DiagnosticSections.forReplies(request, replies: replies, raw: "NONE")
        #expect(none.last?.items.first?.text.hasPrefix("None") == true)
    }

    @Test func aBubbleFateReadsAsItsDetailAndListsAsItsSummary() {
        let fate = DiagnosticFate.replies(summary: "inserted #2", detail: "inserted reply 2 of 3 with Return after 2 Tabs")
        #expect(fate.summary == "inserted #2")
        #expect(fate.text.hasPrefix("inserted reply 2"))
        #expect(DiagnosticKind.suggestedReplies.title == "Quick replies")
    }
}

@Suite struct ReplyScoringTests {
    private func steps(_ pieces: [(String, Float, Float)]) -> [ReplyStep] {
        pieces.map { ReplyStep(bytes: Array($0.0.utf8), logProb: $0.1, stopLogProb: $0.2) }
    }

    @Test func eachReplyGetsItsConfidenceAndTheChanceOfStoppingBeforeIt() {
        let scores = ReplyScoring.score(steps([
            ("Done", 0, -9), (" testing", 0, -9), ("\n", 0, -6),
            ("Skip", log(0.5), -9), (" testing", log(0.5), -9), ("\n", 0, log(0.3)),
            ("Let", log(0.4), -9), (" me check", log(0.4), -9),
        ]))
        #expect(scores.map(\.reply) == ["Done testing", "Skip testing", "Let me check"])
        #expect(scores[0].stopChance == nil)
        #expect(abs(scores[0].confidence - 1) < 1e-6)
        #expect(abs(scores[1].confidence - 0.5) < 1e-6)
        #expect(abs((scores[2].stopChance ?? 0) - 0.3) < 1e-6)
    }

    @Test func aWeakLastReplyIsDroppedButNeverBelowTwo() {
        let a = ReplyScore(reply: "Done testing", confidence: 0.9, stopChance: nil)
        let b = ReplyScore(reply: "Skip testing", confidence: 0.9, stopChance: 0)
        let nearlyStopped = ReplyScore(reply: "Let me check", confidence: 0.9, stopChance: 0.3)
        let unsure = ReplyScore(reply: "Let me check", confidence: 0.4, stopChance: 0)
        let fine = ReplyScore(reply: "Let me check", confidence: 0.8, stopChance: 0.05)
        let three = ["Done testing", "Skip testing", "Let me check"]
        #expect(ReplyScoring.keep(three, scores: [a, b, nearlyStopped]).replies.count == 2)
        #expect(ReplyScoring.keep(three, scores: [a, b, unsure]).dropped == unsure)
        #expect(ReplyScoring.keep(three, scores: [a, b, fine]).replies == three)
        #expect(ReplyScoring.keep(Array(three.prefix(2)), scores: [a, nearlyStopped]).replies.count == 2)
        #expect(ReplyScoring.keep(three, scores: []).replies == three)   // an endpoint: no scores
    }
}

@Test func arrowsStepBetweenRepliesAndStopAtTheEnds() {
    var p = ReplyPicker(replies: ["a", "b", "c"])
    p.step(forward: true)
    #expect(p.highlighted == nil)  // nothing until Tab picks one
    p.next()
    p.step(forward: false)
    #expect(p.highlighted == 0)
    p.step(forward: true); p.step(forward: true); p.step(forward: true)
    #expect(p.highlighted == 2)
    p.step(forward: false)
    #expect(p.chosen == "b")
}
