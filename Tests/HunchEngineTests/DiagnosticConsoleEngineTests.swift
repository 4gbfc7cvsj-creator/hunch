// What the engines hand the diagnostic console: nothing while it is closed, a full record while open.
import Foundation
import HunchCore
import HunchDecode
import Testing
@testable import HunchEngine

/// A search whose result was cut back by the confidence trim.
private struct TrimmedSearch: BiasedCompletionSearching {
    func search(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                onPartial: (Candidate) -> Void) throws -> [Candidate] { [] }

    func searchScored(in session: any LanguageModelSession, requiredPrefix: [UInt8], config: DecodeConfig,
                      bias: LearnedBias, onPartial: (Candidate) -> Void) throws -> [ScoredCandidate] {
        let candidate = Candidate(text: " student at", tokens: [], meanLogProb: -0.4, totalLogProb: -0.8,
                                  stop: .confidenceTrim)
        let spans = [TokenSpan(byteCount: 8, logProb: -0.2), TokenSpan(byteCount: 3, logProb: -0.6),
                     TokenSpan(byteCount: 5, logProb: -3.0)]
        return [ScoredCandidate(candidate: candidate, spans: spans, untrimmedText: " student at UCLA")]
    }
}

@Suite(.serialized) struct DiagnosticConsoleEngineTests {
    /// Instruct model with gated notes: the console names the notes and why, the mid-word boost, and
    /// labels the learned word in the suggestion.
    @Test func recordsGatedNotesTheMidWordBoostAndTheirSource() async throws {
        DiagnosticRecorder.shared.enable()
        defer { DiagnosticRecorder.shared.disable() }
        let recorder = BiasRecorder()
        let engine = LocalCompletionEngine(host: FakeHost(profile: instructProfile), search: {
            ScriptedBiasedSearch(text: "ospikes to Sarah", spans: [], recorder: recorder)
        })
        var request = makeRequest(9010, before: "sounds good, I lent my micr")
        request.bias = LearnedBias(entries: [.init(text: "microspikes", weight: 0.9), .init(text: " Riley", weight: 0.3)], strength: 3)
        request.input.vocabulary = ["microspikes"]
        request.learnedNotes = LearnedNoteDiagnostics(
            picks: [.init(word: "microspikes", reason: "lead-in \"lent my\" + mid-word \"micr\"")], learnedHere: ["microspikes", "Riley"])
        _ = try await engine.complete(request) { _ in }
        let entry = try #require(DiagnosticRecorder.shared.entries.first { $0.requestKey == 9010 })
        let learned = try #require(entry.sections.first { $0.title == "Learned words and phrases" })
        let lines = learned.items.map { "\($0.label ?? ""): \($0.text)" }
        print(lines.joined(separator: "\n"))
        #expect(lines.contains("Learned-word notes (in the prompt): microspikes ← lead-in \"lent my\" + mid-word \"micr\"; not on screen or in the samples"))
        #expect(lines.contains("Mid-word boost (strength 3): microspikes (0.90)"))
        #expect(lines.contains("Learned words in the suggestion: microspikes: from notes"))
    }

    @Test func recordsNothingWhileTheConsoleIsClosed() async throws {
        DiagnosticRecorder.shared.disable()
        let engine = LocalCompletionEngine(host: FakeHost(profile: baseProfile), search: { TrimmedSearch() })
        _ = try await engine.complete(makeRequest(9001, before: "I am a")) { _ in }
        #expect(DiagnosticRecorder.shared.entries.isEmpty)
    }

    @Test func recordsThePromptTheWordsAndTheCutWhileOpen() async throws {
        DiagnosticRecorder.shared.enable()
        defer { DiagnosticRecorder.shared.disable() }
        let engine = LocalCompletionEngine(host: FakeHost(profile: baseProfile), search: { TrimmedSearch() })
        var request = makeRequest(9002, before: "I am a")
        request.input.appName = "Notes"
        request.bias = LearnedBias(entries: [.init(text: " UCLA", weight: 0.9)], strength: 1.5)
        let result = try await engine.complete(request) { _ in }
        #expect(result.outcome == .show(" student at"))

        let entry = try #require(DiagnosticRecorder.shared.entries.first { $0.requestKey == 9002 })
        #expect(entry.kind == .suggestion)
        #expect(entry.appName == "Notes")
        #expect(entry.model == "fake")
        let prompt = try #require(entry.prompt)
        #expect(prompt.framerID == "document-v1")
        #expect(prompt.framerName == "DocumentFramer (document-v1)")
        #expect(prompt.fullText.hasSuffix("I am"))
        #expect(prompt.promptTokens > 0)
        // Sections the spec names are all there, learned words included.
        let titles = entry.sections.map(\.title)
        for wanted in ["App, site and window", "Framer and model", "Text before the caret", "Screen context", "Clipboard",
                       "Learned words and phrases", "Languages and style hints", "Left out by the token budget"] {
            #expect(titles.contains(wanted), "\(wanted)")
        }
        let learned = try #require(entry.sections.first { $0.title == "Learned words and phrases" })
        #expect(learned.items.first?.text.contains("UCLA") == true)
        // The output: three words, a confidence cut after the second, "shown" still to be decided.
        let output = try #require(entry.output)
        #expect(output.text == " student at UCLA")
        #expect(output.words.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["student", "at", "UCLA"])
        #expect(output.words.allSatisfy { $0.probability != nil })
        #expect(output.cuts.count == 1)
        #expect(output.cuts[0].afterWords == 2)
        if case .confidenceTrim(let facts) = output.cuts[0].reason {
            #expect(facts.dropText == "UCLA")
            #expect(facts.limit == DecodeConfig.defaultTrimDropLogProb)
        } else {
            Issue.record("expected a confidence trim")
        }
        #expect(entry.fate == .pending)
        #expect(entry.timing.totalMs != nil)
    }

    @Test func aSuppressedResultSaysWhy() async throws {
        DiagnosticRecorder.shared.enable()
        defer { DiagnosticRecorder.shared.disable() }
        let engine = LocalCompletionEngine(host: FakeHost(profile: baseProfile),
                                           search: { ScriptedSearch(text: " as an AI language model", meanLogProb: -0.3) })
        _ = try await engine.complete(makeRequest(9003, before: "I am a")) { _ in }
        let entry = try #require(DiagnosticRecorder.shared.entries.first { $0.requestKey == 9003 })
        guard case .suppressed(let reason, _) = entry.fate else {
            Issue.record("expected a suppression, got \(entry.fate)")
            return
        }
        #expect(reason == .aiVoice || reason == .metaReply)
        #expect(entry.output?.hasScores == false)  // the scripted search reports no per-token scores
    }

    @Test func aWriteForMeDraftHasTextAndAStopReasonButNoPercentages() async throws {
        DiagnosticRecorder.shared.enable()
        defer { DiagnosticRecorder.shared.disable() }
        let session = ScriptedWriteSession("Yes, but next week works better for me.")
        let host = IdleReleasedWriteHost(session, profile: instructProfile)
        let writer = LocalWriter(host: host, promptTokenBudget: 4000, maxTokens: 200, nextID: { RequestID(1) })
        let request = WriteRequest(id: RequestID(1), mode: .write, source: "tell him yes, but next week works better",
                                   shape: .message, context: PromptInput(before: "", appName: "Mail"))
        _ = try await writer.write(request) { _ in }
        let entry = try #require(DiagnosticRecorder.shared.entries.first { $0.kind == .writeForMe && $0.appName == "Mail" })
        #expect(entry.output?.text == "Yes, but next week works better for me.")
        #expect(entry.output?.hasScores == false)
        #expect(entry.output?.stopText?.contains("ended its turn") == true)
        #expect((entry.output?.generatedTokens ?? 0) > 0)
        #expect(entry.prompt?.framerID == "write-for-me-v1")
        #expect(entry.sections.contains { $0.title == "Request" })
    }

    @Test func aDictationCleanupIsRecordedAsDictation() async throws {
        DiagnosticRecorder.shared.enable()
        defer { DiagnosticRecorder.shared.disable() }
        let session = ScriptedWriteSession("We ship on Friday.")
        let host = IdleReleasedWriteHost(session, profile: instructProfile)
        let writer = LocalWriter(host: host, promptTokenBudget: 4000, maxTokens: 200, nextID: { RequestID(1) })
        let cleanup = DictationCleanup(transcript: "um we ship on friday", preset: .standard,
                                       context: DictationContext(spellings: ["Friday"], appName: "Slack"))
        let request = WriteRequest(id: RequestID(1), mode: .polish, source: "um we ship on friday", shape: .paragraph,
                                   context: PromptInput(before: ""), dictation: cleanup)
        _ = try await writer.write(request) { _ in }
        let entry = try #require(DiagnosticRecorder.shared.entries.first { $0.kind == .dictation })
        #expect(entry.appName == "Slack")
        #expect(entry.prompt?.framerID == "dictation-cleanup-v2")
        #expect(entry.sections.first?.items.first?.text == "um we ship on friday")
    }
}
