import Foundation
import Synchronization
import Testing
@testable import HunchEndpoint
import HunchCore

@Suite struct EndpointWriteTests {
    private func writeRequest(screen: String? = "Your rate drops to $75/month on Jan 1.") -> WriteRequest {
        WriteRequest(id: RequestID(1), mode: .write, source: "agree and say I'll finish signup", shape: .email,
                     context: PromptInput(before: "", after: "", surface: .email, aboutWriter: "Name: Alex Morgan.",
                                          screenContext: screen, domain: "mail.google.com"))
    }

    @Test func streamsAMultiLineDraftOverChat() async throws {
        let id = "w-" + UUID().uuidString
        stubState.behaviors.withLock {
            $0[id] = StubBehavior(chunks: sse(["Hi Jordan,", "\n\nWe agree", " to the new rate.", "\n\nAlex"], chat: true))
        }
        let engine = makeEngine(id: id, api: .chatCompletions)
        let partials = Mutex<[String]>([])
        let text = try await engine.write(writeRequest()) { p in partials.withLock { $0.append(p) } }
        #expect(text == "Hi Jordan,\n\nWe agree to the new rate.\n\nAlex")
        #expect(partials.withLock { $0 }.count >= 3)
        let body = try JSONSerialization.jsonObject(with: stubState.bodies.withLock { $0[id] }!) as! [String: Any]
        #expect(body["stop"] == nil)
        #expect(body["max_tokens"] as? Int == EndpointCompletionEngine.writeMaxTokens)
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.count == 1)
        #expect(messages[0]["content"]!.contains("agree and say I'll finish signup"))
        // Loopback: the screen goes along.
        #expect(messages[0]["content"]!.contains("$75/month"))
    }

    @Test func remoteHostsGetNoScreenAndMaskedSecrets() {
        var r = writeRequest()
        r.source = "send key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCD to ops"
        let remote = EndpointCompletionEngine.outbound(r, isLoopback: false)
        #expect(remote.context.screenContext == nil)
        #expect(remote.context.domain == nil)
        #expect(!remote.source.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        let local = EndpointCompletionEngine.outbound(r, isLoopback: true)
        #expect(local.context.screenContext != nil)
        #expect(local.source == r.source)
    }

    @Test func completionsApiUsesTheDocumentPromptWithStops() async throws {
        let id = "w-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(chunks: sse(["Hi Jordan,\n\nSounds good."])) }
        let engine = makeEngine(id: id, api: .completions)
        let text = try await engine.write(writeRequest()) { _ in }
        #expect(text == "Hi Jordan,\n\nSounds good.")
        let body = try JSONSerialization.jsonObject(with: stubState.bodies.withLock { $0[id] }!) as! [String: Any]
        #expect((body["prompt"] as? String)?.hasSuffix("in their own name and in the note's language:\n\n") == true)
        #expect((body["stop"] as? [String])?.contains("\n\n\n") == true)
    }

    @Test func httpErrorFails() async {
        let id = "w-" + UUID().uuidString
        stubState.behaviors.withLock { $0[id] = StubBehavior(status: 500) }
        let engine = makeEngine(id: id, api: .chatCompletions)
        await #expect(throws: EndpointError.self) { try await engine.write(writeRequest()) { _ in } }
    }
}
