import Testing
@testable import HunchCore

@Suite struct LearnedNoteDiagnosticsTests {
    var input: PromptInput {
        var i = PromptInput(before: "all good here! tell ", screenContext: "Mom: how's everyone doing? Northwind called")
        i.styleExamples = ["Bainbridge this weekend? weather looks good"]
        return i
    }
    let notes = LearnedNoteDiagnostics(
        picks: [.init(word: "Emma", reason: "lead-in \"tell\""), .init(word: "Northwind", reason: "topic {contract, renewal}"),
                .init(word: "Bainbridge", reason: "topic {weekend, weather}")],
        learnedHere: ["Emma", "Northwind", "Bainbridge", "Riley"], framerListsVocabulary: true)

    @Test func notesSayWhyAndWhereElse() {
        let items = DiagnosticSections.noteItems(notes, input: input)
        print(items.map { "\($0.label ?? ""): \($0.text)" }.joined(separator: "\n"))
        #expect(items.count == 1)
        let lines = items[0].text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Emma ← lead-in \"tell\"; not on screen or in the samples")
        #expect(lines[1] == "Northwind ← topic {contract, renewal}; also on screen")
        #expect(lines[2] == "Bainbridge ← topic {weekend, weather}; also in the writing samples")
    }

    @Test func noneAndBaseModels() {
        #expect(DiagnosticSections.noteItems(.init(framerListsVocabulary: true), input: input).first?.text == "none")
        #expect(DiagnosticSections.noteItems(.init(framerListsVocabulary: false), input: input).first?.text.hasPrefix("not used") == true)
    }

    @Test func suggestionLabels() {
        let bias = LearnedBias(strength: 3)
        #expect(DiagnosticSections.learnedInSuggestion(before: input.before, shown: "Emma i said hi", input: input, notes: notes, bias: bias)
                == "Emma: from notes")
        #expect(DiagnosticSections.learnedInSuggestion(before: input.before, shown: "Riley and Northwind hi", input: input, notes: notes, bias: bias)
                == "Northwind: also on screen; Riley: not gated")
        #expect(DiagnosticSections.learnedInSuggestion(before: input.before, shown: "everyone hi", input: input, notes: notes, bias: bias) == nil)
        // Mid-word: the completed word counts.
        #expect(DiagnosticSections.learnedInSuggestion(before: "tell Em", shown: "ma hi", input: input, notes: notes, bias: bias)
                == "Emma: from notes")
    }

    @Test func mangledLearnedWordNote() {
        let note = DiagnosticSections.mangledLearnedWord(before: "I lent my microsp", generated: "eak to the group", learned: ["microspikes"])
        print(note ?? "-")
        #expect(note == "dropped \"microsp\" + \"eak\" = \"microspeak\": not microspikes and not a dictionary word")
        #expect(DiagnosticSections.mangledLearnedWord(before: "I lent my microsp", generated: "ikes", learned: ["microspikes"]) == nil)
        #expect(DiagnosticSections.mangledLearnedWord(before: "I lent my ", generated: "boots", learned: ["microspikes"]) == nil)
    }

    @Test func midWordBoostTitle() {
        let sections = DiagnosticSections.forInput(PromptInput(before: "lent my micr"),
                                                   bias: LearnedBias(entries: [.init(text: "microspikes", weight: 0.9)], strength: 3),
                                                   notes: .init(picks: [.init(word: "microspikes", reason: "lead-in \"lent my\" + mid-word \"micr\"")],
                                                                framerListsVocabulary: true))
        let learned = sections.first { $0.title == "Learned words and phrases" }!
        for i in learned.items { print("\(i.label ?? ""): \(i.text)") }
        #expect(learned.items.map(\.label) == ["Learned-word notes (in the prompt)", "Mid-word boost (strength 3)"])
    }
}
