import Foundation
import HunchCore
import Testing
@testable import HunchHistory

// M3: the common-word list (12dicts + AGID + SCOWL), the tech-name allow-list, and names written
// with a capital mid-sentence.

private let scorer = VocabularyScorer()
private let field = FieldID(pid: 100, elementHash: 7, generation: 1)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: List data

@Test func frequentListIsCleanEnglishWords() {
    let list = CommonWords.frequent
    #expect((17_000...21_000).contains(list.count))
    #expect(list.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("a"..."z").contains($0) } })
    let words = CommonWords.frequentEnglishText.split(whereSeparator: { $0 == " " || $0 == "\n" })
    #expect(words.count == list.count)   // no duplicates
    let short: Set<String> = ["a", "ad", "ah", "am", "an", "as", "at", "ax", "be", "by", "do", "eh", "ex", "go",
                              "ha", "he", "hi", "if", "in", "is", "it", "me", "my", "no", "of", "oh", "on", "or",
                              "pa", "re", "sh", "so", "to", "uh", "um", "up", "us", "we", "ye"]
    #expect(list.filter { $0.count <= 2 }.isSubset(of: short))
}

@Test func techNamesAndPlainNamesAreLearnable() {
    for w in ["kubernetes", "python", "json", "api", "github", "javascript", "docker", "linux", "sql", "git",
              "java", "ruby", "django", "figma", "jira", "marc", "york", "alex", "london", "tokyo"] {
        #expect(scorer.candidates(typed: w, context: []).map(\.text) == [w], "\(w)")
    }
}

@Test func everydayWordsAreOrdinary() {
    for w in ["meeting", "meetings", "thanks", "would", "forget", "messages", "column", "apps", "tomorrow",
              "email", "emails", "online", "okay", "app", "download", "website", "password", "gonna", "dont",
              "years", "playing", "looks", "notes", "teams", "word"] {
        #expect(CommonWords.isOrdinaryEnglish(w), "\(w)")
        #expect(scorer.candidates(typed: w, context: []).isEmpty, "\(w)")
    }
}

@Test func lowercaseTechNamesOnTheAllowListAreLearnable() {
    for w in ["swift", "react", "rust", "node", "slack"] {
        #expect(CommonWords.frequent.contains(w), "\(w) is an English word")
        #expect(!CommonWords.isOrdinaryEnglish(w), "\(w)")
        #expect(scorer.candidates(typed: w, context: []).map(\.text) == [w], "\(w)")
    }
}

@Test func taiwanWordsCountAsCommon() {
    for w in ["時間", "網路", "訊息", "軟體", "资料"] {
        #expect(VocabularyScorer.isCommon(w), "\(w)")
    }
}

@Test func noticesFileCreditsTheWordLists() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
    for s in ["12dicts", "Alan Beale", "Copyright 2000-2014 by Kevin Atkinson", "WordNet 1.6 Copyright 1997",
              "Copyright 2000-2018 by Kevin Atkinson"] {
        #expect(text.contains(s), "\(s)")
    }
}

// MARK: Names mid-sentence

@Test func capitalizedMidSentenceIsAName() {
    #expect(WordText.namesMidSentence(in: "we built it in Swift today") == ["Swift"])
    #expect(WordText.namesMidSentence(in: "I asked Mark about it") == ["Mark"])
    #expect(WordText.namesMidSentence(in: "Hi, Mark") == ["Mark"])
    #expect(WordText.namesMidSentence(in: "see you in April, then") == ["April"])
    #expect(WordText.namesMidSentence(in: "flying to New York soon") == ["New"])
}

@Test func sentenceStartsTitleCaseAndCapsAreNotNames() {
    #expect(WordText.namesMidSentence(in: "Swift is fast").isEmpty)
    #expect(WordText.namesMidSentence(in: "done. Mark it").isEmpty)
    #expect(WordText.namesMidSentence(in: "done!\nMark it").isEmpty)
    #expect(WordText.namesMidSentence(in: "line one\nMeeting at noon").isEmpty)
    #expect(WordText.namesMidSentence(in: "he said \"Thanks a lot\"").isEmpty)
    #expect(WordText.namesMidSentence(in: "- Meeting notes").isEmpty)
    #expect(WordText.namesMidSentence(in: "Meeting Notes For Tomorrow").isEmpty)
    #expect(WordText.namesMidSentence(in: "this is VERY bad, OK").isEmpty)
    #expect(WordText.namesMidSentence(in: "then I left").isEmpty)
    #expect(WordText.namesMidSentence(in: "ask Mark", from: 4) == ["Mark"])
    #expect(WordText.namesMidSentence(in: "ask Mark", from: 5).isEmpty)
}

@Test func namesAreCandidatesButStopwordsNeverAre() {
    #expect(scorer.candidates(typed: "Mark", context: [], isName: true).map(\.text) == ["Mark"])
    #expect(scorer.candidates(typed: "Mark", context: []).isEmpty)
    #expect(scorer.candidates(typed: "The", context: [], isName: true).isEmpty)
    // A name on the hand-written common list earns full credit, not the common-word tenth.
    #expect(scorer.candidates(typed: "April", context: [], isName: true).first?.credit == 1)
    let words = [WordScore(text: " Mark", logProb: -6), WordScore(text: " said", logProb: -6)]
    #expect(scorer.candidates(words: words, context: ["ask"], names: ["Mark"]).map(\.text) == ["Mark", "Mark said"])
    #expect(scorer.candidates(words: words, context: ["ask"]).isEmpty)
}

@Test func trackerMarksNamesInTypedOverWords() {
    func typedOver(_ before: String, _ word: String) -> LearningEvent? {
        var t = OutcomeTracker()
        _ = t.suggestionShown(field: field, before: before, suggestion: " kotlin", scores: [], at: t0)
        return t.textChanged(field: field, before: before + " " + word + " ", at: t0 + 1).first
    }
    #expect(typedOver("we rewrote it in", "Swift")?.names == ["Swift"])
    #expect(typedOver("It works.", "Swift")?.names == [])
}

@Test func trackerMarksNamesInConfirmedText() {
    var t = OutcomeTracker()
    _ = t.suggestionShown(field: field, before: "Let's ask", suggestion: " Mark. Swift", scores: [], at: t0)
    _ = t.accepted(field: field, text: " Mark. Swift", at: t0 + 1)
    let ev = t.focusLeft(field: field, at: t0 + 2)
    #expect(ev.first?.names == ["Mark"])
}

@Test func learnedNameSurvivesConsolidation() {
    var m = VocabularyModel()
    for i in 0..<3 {
        let f = FieldID(pid: 1, elementHash: i, generation: 1)
        m.apply(LearningEvent(field: f, kind: .typedOver(context: ["in"], suggested: "x", typed: "Swift"),
                              names: ["Swift"]), now: t0 + Double(i) * 86_400)
        m.apply(LearningEvent(field: f, kind: .typedOver(context: ["in"], suggested: "x", typed: "Mark"),
                              names: ["Mark"]), now: t0 + Double(i) * 86_400)
    }
    #expect(m.entries["swift"] != nil)
    #expect(m.entries["mark"] != nil)
    var stray = VocabEntry(text: "meeting", now: t0)
    stray.positive = 4; stray.posMass = 4
    m.entries["meeting"] = stray
    m.consolidate(now: t0 + 3 * 86_400)
    #expect(m.entries["swift"]?.text == "Swift")
    #expect(m.entries["mark"]?.text == "Mark")
    #expect(m.entries["meeting"] == nil)
}
