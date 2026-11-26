import Testing
@testable import HunchCore

// Their newest message and its question sentences, from labeled screen text (lines as read in
// Claude Code, where the reply prompt sits above the closing recap).

@Suite struct ReplyQuestionTests {
    let claudeScreen = """
        Me: Tested the arrow keys, working as expected.
        Them: Reply "Done testing" with any notes, or "Skip testing".
        Them: Lines below the text box are now dropped in chats (master 1088115, merged). All tests pass.
        Them: • Needs your input
        """

    @Test func theirRunAfterMyLastMessage() {
        let run = ReplyQuestion.theirNewest(screen: claudeScreen)
        #expect(run == ["Reply \"Done testing\" with any notes, or \"Skip testing\".",
                        "Lines below the text box are now dropped in chats (master 1088115, merged). All tests pass."])
    }

    @Test func nothingWhenMyMessageIsNewest() {
        #expect(ReplyQuestion.theirNewest(screen: "Them: Ready?\nMe: Yes") == nil)
        #expect(ReplyQuestion.theirNewest(screen: "no labels here") == nil)
    }

    @Test func staleQuestionAboveMyAnswerIsNotTheirNewest() {
        let screen = "Them: Commit it?\nMe: Yes\nThem: Done, it's committed."
        #expect(ReplyQuestion.theirNewest(screen: screen) == ["Done, it's committed."])
    }

    @Test func keySentencesPreferQuestions() {
        let run = ReplyQuestion.theirNewest(screen: claudeScreen)!
        #expect(ReplyQuestion.keySentences(run) == ["Reply \"Done testing\" with any notes, or \"Skip testing\"."])
        #expect(ReplyQuestion.keySentences(["It's on master. Commit the fix to master?"]) == ["Commit the fix to master?"])
        #expect(ReplyQuestion.keySentences(["All done. Nothing is pushed."]).isEmpty)
        #expect(ReplyQuestion.keySentences(["Judges accept filler like \"let me know\"."]).isEmpty)
    }

    @Test func sameQuotedOptionsMatchDespiteOtherWords() {
        let a = "Reply \"Done testing\" with any notes, or \"Skip testing\"."
        let b = "Reply \"Done testing\" (with anything that looked wrong) when you've checked, or \"Skip testing\" to leave it."
        #expect(ReplyQuestion.similarity(a, b) == 1)
        #expect(ReplyQuestion.similarity("Good to go, or anything to change?", "Good to go, or anything to change?") == 1)
        #expect(ReplyQuestion.similarity("Commit the fix to master?", "Good to go, or anything to change?") < 0.5)
    }

    @Test func listCheckStaysTheFramers() {
        #expect(ReplyQuestion.isListOrStatus("• Needs your input"))
        #expect(!ReplyQuestion.isListOrStatus("see you in 5"))
    }

    @Test func endOfTaskQuestionsMatchByTheirOptions() {
        // Worded differently each time, one with a mistyped closing quote.
        let a = "Reply \"Done testing\" when you've done it, or \"Skip testing\"."
        let b = "Reply \"Done testing' (with anything that looked wrong) when you've checked, or \"Skip testing\" to leave it."
        #expect(ReplyQuestion.quoted(b) == ["done testing", "skip testing"])
        #expect(ReplyQuestion.similarity(a, b) == 1)
        #expect(ReplyQuestion.similarity([a], [b, "Reply when you've checked the labels in Messages."]) == 1)
    }

    @Test func apostrophesInWordsAreNotQuotes() {
        #expect(ReplyQuestion.quoted("Don't worry, you've got 'this' covered?") == ["this"])
        #expect(ReplyQuestion.words("testing'") == ["testing"])
    }

    @Test func commandLinesAreNotQuestions() {
        let line = ">_ Looked grep -c \"replies: same box\" ~/Library/Logs/Hunch/perf.log; grep -c \"replies: not offered\" ~/x"
        #expect(ReplyQuestion.keySentences([line]).isEmpty)
        #expect(ReplyQuestion.keySentences(["Run `swift test` now?"]).isEmpty)
        #expect(ReplyQuestion.keySentences(["Should I add Codex now?"]) == ["Should I add Codex now?"])
    }
}
