import Foundation
import HunchCore
import Testing
@testable import HunchHistory

// Learned replies: answers to a recurring question are learned per app, offered best first (with a
// shared start), and once the habit is clear shown without the model; old habits fade.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let app = "com.anthropic.claudefordesktop"
private let ask = ["Reply \"Done testing\" with any notes, or \"Skip testing\"."]
private let ask2 = ["Reply \"Done testing\" when you've checked, or \"Skip testing\" to leave it."]
private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

@Suite struct LearnedRepliesTests {
    @Test func secondSendIsOfferedButNotYetAHabit() throws {
        var r = LearnedReplies()
        let learned = r.record(keys: ask, answer: "Done testing, working as expected", appKey: app, now: t0)
        #expect(learned)
        #expect(r.suggestion(keys: ask2, appKey: app, now: t0) == nil)   // one send is not a habit
        r.record(keys: ask2, answer: "Done testing, working as expected.", appKey: app, now: t0)
        let s = try #require(r.suggestion(keys: ask2, appKey: app, now: t0))
        #expect(s.replies == ["Done testing, working as expected."])
        #expect(!s.skipModel)
        #expect(r.suggestion(keys: ask, appKey: "com.tinyspeck.slackmacgap", now: t0) == nil)
    }

    @Test func habitSkipsTheModelWithSharedStart() throws {
        var r = LearnedReplies()
        r.record(keys: ask, answer: "Done testing, working as expected", appKey: app, now: day(0))
        r.record(keys: ask2, answer: "Done testing, found a bug: the chips overlap", appKey: app, now: day(1))
        r.record(keys: ask, answer: "Skip testing", appKey: app, now: day(2))
        r.record(keys: ask2, answer: "Done testing, working as expected.", appKey: app, now: day(3))
        #expect(r.questions.count == 1)
        // "Skip testing" sent once is not offered, so the replies cover too little to skip the model.
        #expect(r.suggestion(keys: ask, appKey: app, now: day(3))?.skipModel == false)
        r.record(keys: ask, answer: "Skip testing", appKey: app, now: day(4))
        let s = try #require(r.suggestion(keys: ask, appKey: app, now: day(4)))
        #expect(s.replies.first == "Done testing, ")
        #expect(s.replies.contains("Done testing, working as expected."))
        #expect(s.replies.contains("Skip testing"))
        #expect(s.cases == 5)
        #expect(s.skipModel)
    }

    @Test func scatteredAnswersKeepAskingTheModel() throws {
        var r = LearnedReplies()
        let q = ["What do you think?"]
        for (i, a) in ["Looks fine", "Hmm, not sure yet", "Let me check tonight", "No idea honestly"].enumerated() {
            r.record(keys: q, answer: a, appKey: app, now: day(Double(i)))
        }
        // No answer was sent twice and none share a start: nothing to offer, the model answers alone.
        #expect(r.suggestion(keys: q, appKey: app, now: day(4)) == nil)
    }

    @Test func differentQuestionsStayApart() {
        var r = LearnedReplies()
        r.record(keys: ["Commit the fix to master?"], answer: "Yes, commit", appKey: app, now: t0)
        r.record(keys: ["Good to go, or anything to change?"], answer: "Good to go", appKey: app, now: t0)
        r.record(keys: ["Good to go, or anything to change?"], answer: "Good to go!", appKey: app, now: t0)
        #expect(r.questions.count == 2)
        #expect(r.suggestion(keys: ["Good to go, or anything to change?"], appKey: app, now: t0)?.replies == ["Good to go!"])
    }

    @Test func oldAnswersFadeAndNewHabitTakesOver() throws {
        var r = LearnedReplies()
        for i in 0..<4 { r.record(keys: ask, answer: "Skip testing", appKey: app, now: day(Double(i))) }
        r.record(keys: ask, answer: "Done testing", appKey: app, now: day(70))
        r.record(keys: ask, answer: "Done testing", appKey: app, now: day(71))
        let s = try #require(r.suggestion(keys: ask, appKey: app, now: day(71)))
        #expect(s.replies == ["Done testing"])   // "Skip testing" not sent for 60+ days
        r.prune(now: day(200))
        #expect(r.questions.isEmpty)
    }

    @Test func secretsAndLongTextAreNotLearned() {
        var r = LearnedReplies()
        let learnedSecret = r.record(keys: ask, answer: "my key is sk9aF3kdQ2", appKey: app, now: t0)
        #expect(!learnedSecret)
        let learnedLong = r.record(keys: ask, answer: String(repeating: "word ", count: 80), appKey: app, now: t0)
        #expect(!learnedLong)
        let learnedMail = r.record(keys: ask, answer: "mail me at alex@example.com", appKey: app, now: t0)
        #expect(!learnedMail)
        #expect(r.questions.isEmpty)
    }

    @Test func blockedQuestionLearnsAndOffersNothing() throws {
        var r = LearnedReplies()
        r.record(keys: ask, answer: "Skip testing", appKey: app, now: t0)
        let id = r.questions[0].id
        try r.setBlocked(id: id, true)
        let learnedBlocked = r.record(keys: ask, answer: "Skip testing", appKey: app, now: t0)
        #expect(!learnedBlocked)
        #expect(r.suggestion(keys: ask, appKey: app, now: t0) == nil)
        r.prune(now: day(365))
        #expect(r.questions.count == 1)   // kept so it stays blocked
    }

    @Test func handAddedPairIsAClearHabitAndNeverFades() throws {
        var r = LearnedReplies()
        let id = try r.addManual(question: "Good to go, or anything to change?", answers: ["Good to go", "Change something"],
                                 appKey: app, now: t0)
        r.prune(now: day(365))
        let s = try #require(r.suggestion(keys: ["Good to go, or anything to change?"], appKey: app, now: day(365)))
        #expect(s.questionID == id)
        #expect(s.replies == ["Good to go", "Change something"])
        #expect(s.skipModel)
        #expect(throws: LearnedReplyError.emptyAnswer) { try r.addManual(question: "Ready?", answers: [" "], appKey: app) }
    }

    @Test func editsRenameAndDelete() throws {
        var r = LearnedReplies()
        r.record(keys: ask, answer: "Done testng", appKey: app, now: t0)
        let id = r.questions[0].id
        try r.renameAnswer(questionID: id, from: "Done testng", to: "Done testing", now: t0)
        #expect(r.questions[0].answers.map(\.text) == ["Done testing"])
        #expect(r.questions[0].answers[0].manual)
        try r.deleteAnswer(questionID: id, text: "Done testing")
        #expect(r.questions[0].answers.isEmpty)
        try r.deleteQuestion(id: id)
        #expect(r.questions.isEmpty)
    }

    @Test func savedWithTheHistoryModel() throws {
        var m = VocabularyModel()
        m.replies.record(keys: ask, answer: "Skip testing", appKey: app, now: t0)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(VocabularyModel.self, from: data)
        #expect(back.replies == m.replies)
        // Files written before learned replies existed still load.
        let old = try JSONDecoder().decode(VocabularyModel.self, from: Data(#"{"entries":{}}"#.utf8))
        #expect(old.replies.questions.isEmpty)
    }

    @Test func onlyAPickedReplyIsAnswered() {
        let field = FieldID(pid: 1, elementHash: 2, generation: 0)
        let other = FieldID(pid: 1, elementHash: 3, generation: 0)
        let now = Date()
        let pick = ReplyPick(text: "Done testing", field: field, at: now)
        #expect(pick.isAnswered(by: "Done testing", field: field, now: now))
        #expect(pick.isAnswered(by: "done testing.", field: field, now: now))
        #expect(pick.isAnswered(by: "Done testing, the labels look right", field: field, now: now))
        #expect(!pick.isAnswered(by: "Done testingg", field: field, now: now))
        #expect(!pick.isAnswered(by: "Ok. I clicked the text field in Discord", field: field, now: now))
        #expect(!pick.isAnswered(by: "Done testing", field: other, now: now))
        #expect(!pick.isAnswered(by: "Done testing", field: field, now: now.addingTimeInterval(ReplyPick.lifetime + 1)))
        let start = ReplyPick(text: "Done testing, ", field: field, at: now)
        #expect(start.isAnswered(by: "Done testing, all good", field: field, now: now))
    }

    @Test func pickedRepliesWithAddedWordsTeachTheUsualStart() {
        let a1 = LearnedAnswer(text: "Done testing, found a bug with animation", sends: 1, mass: 1,
                               asOf: Date(), lastSent: Date(timeIntervalSinceNow: -60))
        let a2 = LearnedAnswer(text: "Done testing, found a bug with settings", sends: 1, mass: 1,
                               asOf: Date(), lastSent: Date())
        #expect(LearnedReplies.sharedStarts([a1, a2]) == ["Done testing, found a bug with "])
    }
}
