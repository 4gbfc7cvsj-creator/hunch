// Voice instructions (experimental): a spoken instruction's draft when the Language Model was
// idle-released before the shortcut was pressed. The writer loads it and writes, with no second press.
import Foundation
import HunchCore
import Synchronization
import Testing
@testable import HunchEngine

/// Like `WriteFakeHost`, but released while idle until a job asks for it (as the real host reloads).
final class IdleReleasedWriteHost: ModelHosting, @unchecked Sendable {
    let session: ScriptedWriteSession
    let profile: ModelProfile
    let loaded = Mutex(false)
    let jobs = Mutex(0)
    init(_ session: ScriptedWriteSession, profile: ModelProfile) {
        self.session = session
        self.profile = profile
    }
    func state() async -> ModelLoadState {
        let id = ModelEntryID(relativePath: "fake-it.gguf")
        return loaded.withLock { $0 } ? .ready(id, profile) : .releasedIdle(id)
    }
    func states() -> AsyncStream<ModelLoadState> { AsyncStream { $0.finish() } }
    func load(_ entry: ModelEntry, options: RuntimeOptions) async {}
    func unload() async {}
    func withSession<T: Sendable>(_ id: RequestID,
                                  _ body: @escaping @Sendable (any LanguageModelSession) throws -> T) async throws -> T {
        loaded.withLock { $0 = true }
        jobs.withLock { $0 += 1 }
        return try body(session)
    }
    func cancel(olderThan id: RequestID) {}
}

@Suite struct VoiceInstructionWriterTests {
    @Test func transformAfterIdleReleaseLoadsAndWrites() async throws {
        let session = ScriptedWriteSession("We ship Friday if QA passes Thursday.")
        let host = IdleReleasedWriteHost(session, profile: instructProfile)
        let writer = LocalWriter(host: host, promptTokenBudget: 4000, maxTokens: 200, nextID: { RequestID(1) })
        let request = WriteRequest(id: RequestID(1), mode: .transform,
                                   source: "We will most likely ship the update on Friday, assuming QA signs off.",
                                   shape: .message, context: PromptInput(before: ""), instruction: "make this shorter")
        let text = try await writer.write(request) { _ in }
        #expect(text == "We ship Friday if QA passes Thursday.")
        // One load job for the profile, one for the draft: the same request, no retry needed.
        #expect(host.jobs.withLock { $0 } == 2)
        let prompt = String(decoding: session.prompt.map { UInt8($0) }, as: UTF8.self)
        #expect(prompt.contains("make this shorter"))
    }

    @Test func spokenDescriptionWritesLikeATypedOne() async throws {
        let session = ScriptedWriteSession("Yes, but next week works better for me.")
        let host = IdleReleasedWriteHost(session, profile: instructProfile)
        let writer = LocalWriter(host: host, promptTokenBudget: 4000, maxTokens: 200, nextID: { RequestID(1) })
        let request = WriteRequest(id: RequestID(1), mode: .write, source: "tell him yes, but next week works better",
                                   shape: .message, context: PromptInput(before: ""))
        let text = try await writer.write(request) { _ in }
        #expect(text == "Yes, but next week works better for me.")
    }
}
