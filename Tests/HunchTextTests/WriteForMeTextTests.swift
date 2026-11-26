import Foundation
import HunchCore
import Testing
@testable import HunchText

@Suite struct WriteRangeTests {
    @Test func wholeFieldWhenThereIsOneParagraph() throws {
        let r = try #require(WriteRange.find(before: "Agree to $75/month terms and will finish signup soon", after: "",
                                             selected: ""))
        #expect(r.source == "Agree to $75/month terms and will finish signup soon")
        #expect(r.deleteBackward == r.source.count)
        #expect(r.deleteForward == 0)
        #expect(!r.replacesSelection)
    }

    @Test func paragraphStopsAtBlankLines() throws {
        let before = "Hi Jordan,\n\nthank him for the quick reply and say yes to friday"
        let after = " at 3\n\nBest,\nAlex Morgan"
        let r = try #require(WriteRange.find(before: before, after: after, selected: ""))
        #expect(r.source == "thank him for the quick reply and say yes to friday at 3")
        #expect(r.deleteBackward == "thank him for the quick reply and say yes to friday".count)
        #expect(r.deleteForward == " at 3".count)
        #expect(r.textBefore == "Hi Jordan,\n\n")
        #expect(r.textAfter == "\n\nBest,\nAlex Morgan")
    }

    @Test func singleNewlinesStayInsideTheParagraph() throws {
        let r = try #require(WriteRange.find(before: "line one\nline two", after: "", selected: ""))
        #expect(r.source == "line one\nline two")
    }

    @Test func blankLineWithSpacesCounts() throws {
        let r = try #require(WriteRange.find(before: "Hello\n  \t\nask about the invoice", after: "", selected: ""))
        #expect(r.source == "ask about the invoice")
    }

    @Test func leadingAndTrailingWhitespaceStayInTheField() throws {
        let r = try #require(WriteRange.find(before: "Top\n\n   say thanks", after: "  \n\nquoted", selected: ""))
        #expect(r.source == "say thanks")
        #expect(r.deleteBackward == "say thanks".count)
        #expect(r.deleteForward == 0)
        #expect(r.textBefore == "Top\n\n   ")
        #expect(r.textAfter == "  \n\nquoted")
    }

    @Test func selectionWins() throws {
        let r = try #require(WriteRange.find(before: "keep this ", after: " and this", selected: "fix this part"))
        #expect(r.source == "fix this part")
        #expect(r.replacesSelection)
        #expect(r.deleteBackward == 0 && r.deleteForward == 0)
        #expect(r.textBefore == "keep this ")
    }

    @Test func nothingToWorkOn() {
        #expect(WriteRange.find(before: "", after: "", selected: "") == nil)
        #expect(WriteRange.find(before: "Hi\n\n  ", after: "\n\nBye", selected: "") == nil)
        #expect(WriteRange.find(before: String(repeating: "a", count: WriteRange.maxCharacters + 1), after: "",
                                selected: "") == nil)
    }

    @Test func chineseInstruction() throws {
        let r = try #require(WriteRange.find(before: "王經理您好，\n\n幫我回覆說我們同意新的價格", after: "", selected: ""))
        #expect(r.source == "幫我回覆說我們同意新的價格")
        #expect(r.deleteBackward == 13)
    }
}

@Suite struct WriteRangeInsertionTests {
    func selection(_ text: String) throws -> WriteRange {
        try #require(WriteRange.find(before: "a\n", after: "b", selected: text))
    }

    @Test func tripleClickedParagraphKeepsItsNewline() throws {
        #expect(try selection("Hello world\n").insertion(for: "Hello, world.") == "Hello, world.\n")
    }

    @Test func indentedSelectionKeepsItsIndent() throws {
        #expect(try selection("    - buy milk").insertion(for: "  - Buy milk.\n") == "    - Buy milk.")
    }

    @Test func draftWhitespaceIsTrimmedEitherWay() throws {
        #expect(try selection("plain").insertion(for: "\n Plain. \n") == "Plain.")
        let paragraph = try #require(WriteRange.find(before: "say yes", after: "", selected: ""))
        #expect(paragraph.insertion(for: " Yes!\n") == "Yes!")
    }

    @Test func crlfAndMixedWhitespaceComeBackAsSelected() throws {
        #expect(try selection("\t text \r\n").insertion(for: "Text") == "\t Text \r\n")
    }
}

@Suite struct WriteRangeCutWindowTests {
    // A paragraph longer than the read window, caret near its start: the window ends mid-word.
    let paragraph = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 30)

    @Test func paragraphRunningPastACutAfterNeedsAWiderRead() {
        let after = String(paragraph.dropFirst(10).prefix(400))
        #expect(WriteRange.lookup(before: String(paragraph.prefix(10)), after: after, selected: "",
                                  beforeIsCut: false, afterIsCut: true) == .needsWiderRead)
        #expect(WriteRange.find(before: String(paragraph.prefix(10)), after: after, selected: "",
                                afterIsCut: true) == nil)
    }

    @Test func paragraphRunningPastACutBeforeNeedsAWiderRead() {
        let before = String(paragraph.suffix(300))
        #expect(WriteRange.lookup(before: before, after: "", selected: "", beforeIsCut: true,
                                  afterIsCut: false) == .needsWiderRead)
    }

    @Test func blankLinesInsideTheWindowMakeTheCutIrrelevant() throws {
        let r = try #require(WriteRange.lookup(before: "older text\n\nsay yes", after: " to friday\n\nmore text",
                                               selected: "", beforeIsCut: true, afterIsCut: true).range)
        #expect(r.source == "say yes to friday")
    }

    @Test func dictatedParagraphRunningPastACutNeedsAWiderRead() {
        #expect(WriteRange.lookup(before: "so then we said yes", after: " and more", selected: "",
                                  dictated: "we said yes", beforeIsCut: false, afterIsCut: true) == .needsWiderRead)
    }

    @Test func aSelectionIsNeverCut() throws {
        let r = try #require(WriteRange.lookup(before: "abc", after: "def", selected: "pick me",
                                               beforeIsCut: true, afterIsCut: true).range)
        #expect(r.replacesSelection)
    }

    @Test func aParagraphLongerThanTheLimitIsNothing() {
        let long = String(repeating: "word ", count: 1300)
        #expect(WriteRange.lookup(before: long, after: "", selected: "", beforeIsCut: true,
                                  afterIsCut: false) == .nothing)
    }

    @Test func lookupReadsTheCutFlagsFromTheContext() {
        var context = TextContext(app: AppIdentity(bundleID: "x", pid: 1, localizedName: nil),
                                  field: FieldID(pid: 1, elementHash: 1, generation: 0),
                                  before: "abc", after: "def", contentSignature: 0)
        #expect(WriteRange.lookup(context).range?.source == "abcdef")
        context.afterIsCut = true
        #expect(WriteRange.lookup(context) == .needsWiderRead)
    }

    @Test func aWiderRangeStillHoldsInTheUsualWindow() throws {
        // Found by a wider read; the next read is the usual window, cut inside the range on both sides.
        let r = try #require(WriteRange.find(before: "aaaa bbbb", after: " cccc dddd", selected: ""))
        #expect(r.stillHolds(before: "bbbb", after: " cc", selected: "", selectionLength: 0, markedText: false,
                             beforeIsCut: true, afterIsCut: true))
        #expect(!r.stillHolds(before: "bbbb", after: " cc", selected: "", selectionLength: 0, markedText: false))
        #expect(!r.stillHolds(before: "xbbb", after: " cc", selected: "", selectionLength: 0, markedText: false,
                              beforeIsCut: true, afterIsCut: true))
    }
}

@Suite struct WriteRangeStillHoldsTests {
    @Test func sameTextHolds() throws {
        let r = try #require(WriteRange.find(before: "Hi\n\nsay yes to fri", after: "day\n\nAlex", selected: ""))
        #expect(r.stillHolds(before: "Hi\n\nsay yes to fri", after: "day\n\nAlex", selected: "", selectionLength: 0,
                             markedText: false))
    }

    @Test func nonBreakingSpacesCountAsSpaces() throws {
        let r = try #require(WriteRange.find(before: "say yes ", after: "", selected: ""))
        #expect(r.stillHolds(before: "say\u{00A0}yes\u{00A0}", after: "", selected: "", selectionLength: 0,
                             markedText: false))
    }

    @Test func editedOrSelectedTextDoesNot() throws {
        let r = try #require(WriteRange.find(before: "say yes", after: "", selected: ""))
        #expect(!r.stillHolds(before: "say no", after: "", selected: "", selectionLength: 0, markedText: false))
        #expect(!r.stillHolds(before: "say yes", after: "", selected: "x", selectionLength: 1, markedText: false))
        #expect(!r.stillHolds(before: "say yes", after: "", selected: "", selectionLength: 0, markedText: true))
    }

    @Test func selectionMustBeTheSame() throws {
        let r = try #require(WriteRange.find(before: "a ", after: " b", selected: "fix this"))
        #expect(r.stillHolds(before: "a ", after: " b", selected: "fix this", selectionLength: 8, markedText: false))
        #expect(!r.stillHolds(before: "a ", after: " b", selected: "", selectionLength: 0, markedText: false))
    }
}

@Suite struct WriteModeGuessTests {
    @Test func instructionsAreWrite() {
        for text in ["Agree to $75/month terms and will finish payment signup soon",
                     "tell him we can't make it friday",
                     "ask about the invoice from last month",
                     "decline politely",
                     "thanks for the update, will review tomorrow",
                     "幫我回覆說我們同意新的價格",
                     "告訴他我們下週再談"] {
            #expect(WriteModeGuess.guess(text) == .write, "\(text)")
        }
    }

    @Test func finishedMessagesArePolish() {
        let email = """
            Hi Jordan,

            thanks for getting back so quick. we're good with the new rate starting in january \
            and i'll finish the signup this week. let me know which day works for the switch.

            Alex
            """
        #expect(WriteModeGuess.guess(email) == .polish)
        let prose = "The quarterly numbers came in above plan. Revenue grew in every region except the north. "
            + "We expect the trend to continue. Hiring stays on hold until the spring review."
        #expect(WriteModeGuess.guess(prose) == .polish)
        #expect(WriteModeGuess.guess("我們今天開會討論了新的合約條款。大家都同意下個月開始執行。"
            + "財務部門會負責後續的付款安排，業務部門則會通知所有客戶這次的變更。") == .polish)
    }

    @Test func greetingWithAShortLineIsStillAnInstructionWhenTiny() {
        #expect(WriteModeGuess.guess("hi") == .write)
    }

    @Test func emptyIsWrite() {
        #expect(WriteModeGuess.guess("  ") == .write)
    }
}

@Suite struct WriteShapeResolverTests {
    @Test func settingWins() {
        #expect(WriteShapeResolver.resolve(.message, surface: .email, urlHost: "mail.google.com") == .message)
    }

    @Test func adaptiveFromSiteThenSurface() {
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "mail.google.com") == .email)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "app.slack.com") == .message)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .email, urlHost: nil) == .email)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .chat, urlHost: nil) == .message)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .document, urlHost: nil) == .paragraph)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "example.com") == .paragraph)
    }

    @Test func aiPromptFromSitesAppsTerminalAgentsAndEditorChat() {
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "claude.ai") == .aiPrompt)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "chatgpt.com") == .aiPrompt)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "www.perplexity.ai") == .aiPrompt)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: nil,
                                           bundleID: "com.anthropic.claudefordesktop") == .aiPrompt)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: nil,
                                           bundleID: "com.openai.codex") == .aiPrompt)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .agentPrompt, urlHost: nil) == .aiPrompt)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: nil,
                                           bundleID: "com.todesktop.230313mzl4w4u92", isAIChatInput: true) == .aiPrompt)
        // A fixed setting still wins; look-alike hosts don't match.
        #expect(WriteShapeResolver.resolve(.paragraph, surface: .agentPrompt, urlHost: "claude.ai") == .paragraph)
        #expect(WriteShapeResolver.resolve(.adaptive, surface: .unknown, urlHost: "notclaude.ai") == .paragraph)
    }
}

@Suite struct DraftGapsTests {
    @Test func splitsAFinalMissingLine() {
        let (draft, gaps) = DraftGaps.split("Fix the crash in the panel.\n\nMissing: which file the crash is in")
        #expect(draft == "Fix the crash in the panel.")
        #expect(gaps == "which file the crash is in")
        #expect(DraftGaps.split("Fix it.\nmissing: the error text").gaps == "the error text")
    }

    @Test func noNoteLeavesTheDraftAlone() {
        let text = "Fix the crash.\n\n- keep the tests passing\n- no new dependencies"
        #expect(DraftGaps.split(text).draft == text)
        #expect(DraftGaps.split(text).gaps == nil)
        // "Missing:" inside the prompt is part of it.
        let inside = "Missing: a null check in Panel.swift. Add it.\nThen run the tests."
        #expect(DraftGaps.split(inside).draft == inside)
    }

    @Test func aStartedMarkerIsHiddenWhileStreaming() {
        #expect(DraftGaps.split("Fix the crash.\n\nMiss").draft == "Fix the crash.")
        #expect(DraftGaps.split("Fix the crash.\n\nMiss").gaps == nil)
        #expect(DraftGaps.split("Fix the crash.\nMi").draft == "Fix the crash.\nMi")
    }
}

@Suite struct DraftCleanupTests {
    @Test func stripsPrefaceFenceQuotesAndSubject() {
        #expect(DraftCleanup.clean("Here's a draft:\n\nHi Jordan,\n\nThanks!", mode: .write, shape: .email)
            == "Hi Jordan,\n\nThanks!")
        #expect(DraftCleanup.clean("```\nHello there\n```", mode: .write, shape: .paragraph) == "Hello there")
        #expect(DraftCleanup.clean("\u{201C}Sounds good, see you then.\u{201D}", mode: .polish, shape: .paragraph)
            == "Sounds good, see you then.")
        #expect(DraftCleanup.clean("Subject: New rate\n\nHi Jordan,", mode: .write, shape: .email) == "Hi Jordan,")
    }

    @Test func collapsesBlankLinesAndBold() {
        #expect(DraftCleanup.clean("One  \n\n\n\nTwo **now**", mode: .write, shape: .paragraph) == "One\n\nTwo now")
    }

    @Test func keepsQuotesInsideText() {
        let text = "\"Yes\" he said, then \"no\""
        #expect(DraftCleanup.clean(text, mode: .polish, shape: .paragraph) == text)
    }
}

@Suite struct WordDiffTests {
    private func changed(_ a: String, _ b: String) -> [String] {
        WordDiff.changedRanges(original: a, revised: b).map { String(b[$0]) }
    }

    @Test func identicalHasNoChanges() {
        #expect(changed("We are ready to go.", "We are ready to go.").isEmpty)
    }

    @Test func marksReplacedAndInsertedWords() {
        #expect(changed("we r ready to go", "We are ready to go.") == ["We are", "."])
        #expect(changed("thanks for the update", "Thanks so much for the update") == ["Thanks so much"])
    }

    @Test func whitespaceChangesAreIgnored() {
        #expect(changed("one two", "one   two").isEmpty)
    }

    @Test func hanCharactersCompareOneByOne() {
        #expect(changed("我們同意價格", "我們同意新的價格") == ["新的"])
    }

    @Test func emptyOriginalMarksEverything() {
        let b = "Hello there"
        #expect(WordDiff.changedRanges(original: "", revised: b) == [b.startIndex..<b.endIndex])
    }
}

@Suite struct WriteRangeLandingTests {
    @Test func clearedWhenTheTextAroundMeetsAtTheCaret() throws {
        let r = try #require(WriteRange.find(before: "Hi\n\nsay yes to fri", after: "day\n\nAlex", selected: ""))
        #expect(!r.isCleared(before: "Hi\n\nsay yes to fri", after: "day\n\nAlex"))
        // Half the deletes have landed.
        #expect(!r.isCleared(before: "Hi\n\nsay yes", after: "\n\nAlex"))
        #expect(r.isCleared(before: "Hi\n\n", after: "\n\nAlex"))
    }

    @Test func wholeFieldIsClearedOnlyWhenEmpty() throws {
        let r = try #require(WriteRange.find(before: "say yes", after: "", selected: ""))
        #expect(!r.isCleared(before: "s", after: ""))
        #expect(r.isCleared(before: "", after: ""))
    }

    @Test func longTextAroundComparesItsEdges() throws {
        let intro = String(repeating: "Earlier paragraph text. ", count: 20) + "\n\n"
        let r = try #require(WriteRange.find(before: intro + "fix this", after: "", selected: ""))
        // A windowed read keeps only the end of the text before.
        #expect(r.isCleared(before: String(intro.suffix(100)), after: ""))
        #expect(!r.isCleared(before: String((intro + "fix").suffix(100)), after: ""))
    }

    @Test func selectionNeedsNoDeletes() throws {
        let r = try #require(WriteRange.find(before: "a ", after: " b", selected: "fix this"))
        #expect(r.isCleared(before: "a ", after: " b"))
    }

    @Test func emptiedWebEditorsLeftoverWhitespaceCounts() throws {
        let r = try #require(WriteRange.find(before: "say yes", after: "", selected: ""))
        #expect(r.isCleared(before: "", after: "\n"))
        #expect(r.isCleared(before: "\u{00A0}", after: ""))
        let p = try #require(WriteRange.find(before: "Hi Alex,\n\nsay yes", after: "", selected: ""))
        #expect(p.isCleared(before: "Hi Alex,\n", after: "\n"))
    }

    @Test func goneFromCaretOnBothSides() throws {
        let r = try #require(WriteRange.find(before: "Hi\n\nsay yes to fri", after: "day\n\nAlex", selected: ""))
        #expect(!r.isGoneFromCaret(before: "Hi\n\nsay yes to fri", after: "day\n\nAlex"))
        #expect(!r.isGoneFromCaret(before: "Hi\n\n", after: "day\n\nAlex"))
        // The host reports the emptied paragraph in its own way.
        #expect(r.isGoneFromCaret(before: "Hi\n\u{200B}", after: "\n\n\nAlex"))
    }

    @Test func draftShowsBeforeTheCaret() {
        let draft = "Thanks, Alex.\n\nWe agree to the new price."
        #expect(WriteRange.showsDraft(draft, before: "Hi\n\n" + draft))
        // Hosts may turn pasted newlines into other whitespace.
        #expect(WriteRange.showsDraft(draft, before: "Thanks, Alex. We agree to the new\u{00A0}price."))
        #expect(!WriteRange.showsDraft(draft, before: "Hi\n\n"))
        #expect(!WriteRange.showsDraft(draft, before: "Thanks, Alex.\n\nWe agree"))
        #expect(WriteRange.showsDraft("我們同意新的價格。", before: "王經理您好，\n\n我們同意新的價格。"))
    }
}

@Suite struct WriteShapeChoiceTests {
    let shape = CustomWriteShape(name: "Team update", text: "Write it as a short status update.")

    @Test func customShapeWritesWithItsOwnText() {
        let library = WriteShapeLibrary(custom: [shape])
        let policy = AppPolicy(writeShape: .email, writeCustomShapeID: shape.id)
        let r = WriteShapeChoice.resolve(policy: policy, library: library, mode: .write, surface: .email, urlHost: nil)
        #expect(r.shape == .paragraph && r.text == shape.text)
    }

    @Test func polishIgnoresCustomShape() {
        let library = WriteShapeLibrary(custom: [shape])
        let policy = AppPolicy(writeCustomShapeID: shape.id)
        let r = WriteShapeChoice.resolve(policy: policy, library: library, mode: .polish, surface: .unknown,
                                         urlHost: "claude.ai")
        #expect(r.shape == .aiPrompt && r.text == nil)
    }

    @Test func deletedCustomShapeFallsBackAndEditedPresetIsUsed() {
        let library = WriteShapeLibrary(presetTexts: ["message": "Short, lowercase."])
        let policy = AppPolicy(writeCustomShapeID: UUID())
        let r = WriteShapeChoice.resolve(policy: policy, library: library, mode: .write, surface: .chat, urlHost: nil)
        #expect(r.shape == .message && r.text == "Short, lowercase.")
    }

    @Test func customNamesCountUp() {
        var library = WriteShapeLibrary()
        #expect(library.nextCustomName() == "Custom 1")
        library.custom = [CustomWriteShape(name: "Custom 1", text: ""), CustomWriteShape(name: "custom 2", text: "")]
        #expect(library.nextCustomName() == "Custom 3")
    }
}

@Suite struct BoostRangeTests {
    @Test func dictationAtTheEndOfAParagraphPolishesTheWholeParagraph() throws {
        let before = "Notes\n\nWe met on Monday. The plan is set. and we ship friday"
        let range = try #require(WriteRange.find(before: before, after: "", selected: "",
                                                 dictated: " and we ship friday"))
        #expect(range.source == "We met on Monday. The plan is set. and we ship friday")
        #expect(range.textBefore == "Notes\n\n")
    }

    @Test func dictationOverSeveralParagraphsPolishesEveryOneItTouched() throws {
        let before = "Intro\n\nTyped first. Then said this.\n\nAnd a second paragraph."
        let range = try #require(WriteRange.find(before: before, after: "\n\nLater", selected: "",
                                                 dictated: " Then said this.\n\nAnd a second paragraph."))
        #expect(range.source == "Typed first. Then said this.\n\nAnd a second paragraph.")
        #expect(range.textBefore == "Intro\n\n")
        #expect(range.textAfter == "\n\nLater")
    }

    @Test func dictationThatStartsANewParagraphLeavesTheOneAboveAlone() throws {
        let before = "Earlier paragraph.\n\nDictated words here."
        let range = try #require(WriteRange.find(before: before, after: "", selected: "",
                                                 dictated: "\n\nDictated words here."))
        #expect(range.source == "Dictated words here.")
    }

    @Test func hostChangedSpacesFallsBackToCountingParagraphs() throws {
        // The field reports a non-matching form (a trailing space dropped, a quote curled).
        let before = "Top\n\nOne said\u{2019}s.\n\nTwo."
        let range = try #require(WriteRange.find(before: before, after: "", selected: "",
                                                 dictated: "One said's.\n\nTwo. "))
        #expect(range.source == "One said\u{2019}s.\n\nTwo.")
    }

    @Test func nonBreakingSpacesStillMatch() throws {
        let before = "First.\n\nHello\u{00A0}there friend"
        let range = try #require(WriteRange.find(before: before, after: "", selected: "",
                                                 dictated: "there friend"))
        #expect(range.source == "Hello\u{00A0}there friend")
    }

    @Test func aSelectionStillWins() throws {
        let range = try #require(WriteRange.find(before: "a ", after: " c", selected: "b", dictated: "zzz"))
        #expect(range.replacesSelection)
        #expect(range.source == "b")
    }
}
