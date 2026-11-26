// LocalWriter against a scripted fake session: decoding, stops, streaming, cleanup.
import Foundation
import HunchCore
import HunchPrompt
import Synchronization
import Testing
@testable import HunchEngine

/// One byte per token (0...255) plus an end-of-generation token (256). `logProbs` favors the next
/// byte of `script`, then the end token.
final class ScriptedWriteSession: LanguageModelSession, @unchecked Sendable {
    struct Vocab: VocabularyTable {
        var count: Int { 257 }
        func bytes(_ id: TokenID) -> ArraySlice<UInt8> { id < 256 ? [UInt8(id)][...] : [] }
        func traits(_ id: TokenID) -> TokenTraits { id == 256 ? [.endOfGeneration, .control] : [] }
        func admissible(forRequired required: ArraySlice<UInt8>) -> [TokenID] { [] }
    }

    let script: [UInt8]
    var position = 0
    var prompt: [TokenID] = []
    var isCancellationRequested = false
    var cancelAfter: Int?
    var vocabulary: any VocabularyTable { Vocab() }
    var maxParallelSequences: Int { 1 }
    var reuseCapability: ReuseCapability { .trimSuffix }

    init(_ script: String) { self.script = Array(script.utf8) }

    func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] {
        segments.flatMap { $0.text.utf8.map { TokenID($0) } }
    }

    func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
        prompt = tokens
        position = 0
        return PromptSyncReport(decodedTokens: tokens.count, reusedTokens: 0, duration: .zero)
    }

    func fork(_ source: SeqID, into targets: [SeqID]) throws {}

    func step(_ appends: [(SeqID, TokenID)]) throws {
        position += 1
        if let cancelAfter, position >= cancelAfter { isCancellationRequested = true }
    }

    func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {
        buffer = [Float](repeating: -20, count: 257)
        if position < script.count { buffer[Int(script[position])] = -0.1 } else { buffer[256] = -0.1 }
    }

    func discard(_ seqs: [SeqID]) {}
}

final class WriteFakeHost: ModelHosting, @unchecked Sendable {
    let session: ScriptedWriteSession
    let profile: ModelProfile
    init(_ session: ScriptedWriteSession, profile: ModelProfile) {
        self.session = session
        self.profile = profile
    }
    func state() async -> ModelLoadState { .ready(ModelEntryID(relativePath: "fake-it.gguf"), profile) }
    func states() -> AsyncStream<ModelLoadState> { AsyncStream { $0.finish() } }
    func load(_ entry: ModelEntry, options: RuntimeOptions) async {}
    func unload() async {}
    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        try body(session)
    }
    func cancel(olderThan id: RequestID) {}
}

let instructProfile = ModelProfile(family: .gemma, isInstruct: true, markers: KnownChatMarkers.gemma4, addsBOS: true,
                                   contextLength: 8192, slidingWindow: nil, architecture: "gemma4", displayName: "fake-it")

private func writeRequest(_ mode: WriteMode = .write) -> WriteRequest {
    WriteRequest(id: RequestID(1), mode: mode, source: "say yes to friday", shape: .email,
                 context: PromptInput(before: "", aboutWriter: "Name: Alex Morgan."))
}

@Suite struct LocalWriterTests {
    @Test func writesUntilEndOfGenerationAndCleansUp() async throws {
        let session = ScriptedWriteSession("Here's a draft:\n\nHi Jordan,\n\nFriday works for me.\n\nAlex")
        let writer = LocalWriter(host: WriteFakeHost(session, profile: instructProfile), promptTokenBudget: 4000,
                                 maxTokens: 500, nextID: { RequestID(1) })
        let partials = Mutex<[String]>([])
        let text = try await writer.write(writeRequest()) { p in partials.withLock { $0.append(p) } }
        #expect(text == "Hi Jordan,\n\nFriday works for me.\n\nAlex")
        #expect(!partials.withLock { $0 }.isEmpty)
        // The chat prompt went to the model, ending with the open model turn.
        let prompt = String(decoding: session.prompt.map { UInt8($0) }, as: UTF8.self)
        #expect(prompt.hasSuffix("say yes to friday" + KnownChatMarkers.gemma4.turnClose
                                 + KnownChatMarkers.gemma4.assistantOpen))
    }

    @Test func tokenCapStopsALongDraft() async throws {
        let session = ScriptedWriteSession(String(repeating: "a", count: 100))
        let writer = LocalWriter(host: WriteFakeHost(session, profile: instructProfile), promptTokenBudget: 4000,
                                 maxTokens: 10, nextID: { RequestID(1) })
        let text = try await writer.write(writeRequest()) { _ in }
        #expect(text.count <= 10)
    }

    @Test func baseModelStopsWhereTheDocumentWouldGoOn() async throws {
        let session = ScriptedWriteSession("Hi Jordan,\n\nFriday works.\n\n\nTheir quick note on what to say:\nnext")
        let base = ModelProfile(family: .gemma, isInstruct: false, markers: KnownChatMarkers.gemma4, addsBOS: true,
                                contextLength: 4096, slidingWindow: nil, architecture: "gemma4", displayName: "base")
        let writer = LocalWriter(host: WriteFakeHost(session, profile: base), promptTokenBudget: 3000,
                                 maxTokens: 500, nextID: { RequestID(1) })
        let text = try await writer.write(writeRequest()) { _ in }
        #expect(text == "Hi Jordan,\n\nFriday works.")
        let prompt = String(decoding: session.prompt.map { UInt8($0) }, as: UTF8.self)
        #expect(prompt.hasSuffix("in their own name and in the note's language:\n\n"))
    }

    @Test func cancellationStopsDecoding() async {
        let session = ScriptedWriteSession(String(repeating: "word ", count: 50))
        session.cancelAfter = 5
        let writer = LocalWriter(host: WriteFakeHost(session, profile: instructProfile), promptTokenBudget: 4000,
                                 maxTokens: 500, nextID: { RequestID(1) })
        await #expect(throws: CancellationError.self) { try await writer.write(writeRequest()) { _ in } }
    }

    @Test func partialUTF8IsHeldBack() {
        let bytes = Array("價".utf8)
        #expect(LocalWriter.validPrefix(Array(bytes.prefix(2))).isEmpty)
        #expect(Array(LocalWriter.validPrefix(bytes)) == bytes)
        #expect(Array(LocalWriter.validPrefix(Array("ok".utf8) + bytes.prefix(1))) == Array("ok".utf8))
    }

    @Test func repetitionPenaltyBreaksALoop() throws {
        // A session whose favorite next token is always "a" by a small margin over "b".
        final class Loop: LanguageModelSession, @unchecked Sendable {
            var vocabulary: any VocabularyTable { ScriptedWriteSession.Vocab() }
            var maxParallelSequences: Int { 1 }
            var reuseCapability: ReuseCapability { .none }
            var isCancellationRequested: Bool { false }
            func tokenize(_ segments: [PromptSegment], addBOS: Bool) throws -> [TokenID] { [] }
            func syncPrompt(_ tokens: [TokenID], plan: ReusePlan) throws -> PromptSyncReport {
                PromptSyncReport(decodedTokens: 0, reusedTokens: 0, duration: .zero)
            }
            func fork(_ source: SeqID, into targets: [SeqID]) throws {}
            func step(_ appends: [(SeqID, TokenID)]) throws {}
            func logProbs(_ seq: SeqID, into buffer: inout [Float]) throws {
                buffer = [Float](repeating: -20, count: 257)
                buffer[Int(UInt8(ascii: "a"))] = -1.0
                buffer[Int(UInt8(ascii: "b"))] = -1.2
            }
            func discard(_ seqs: [SeqID]) {}
        }
        let text = try LocalWriter.decode(Loop(), maxTokens: 6, stops: []) { _ in }
        #expect(text.contains("b"))
    }
}
