import Foundation
import Testing
@testable import HunchEndpoint
import HunchCore
import HunchPrompt

@Suite struct EndpointRequestTests {
    let config = EndpointConfig(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "m")

    private func json(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func completionsBody() throws {
        let body = try EndpointRequestBuilder.body(config: config, prompt: .raw("Hi"),
                                                   decode: DecodeConfig(maxTokens: 12), allowNewlines: false)
        let o = json(body)
        #expect(o["prompt"] as? String == "Hi")
        #expect(o["max_tokens"] as? Int == 12)
        #expect(o["temperature"] as? Int == 0)
        #expect(o["stream"] as? Bool == true)
        #expect(o["stop"] as? [String] == ["\n"])
        #expect(o["model"] as? String == "m")
    }

    @Test func noStopWhenNewlinesAllowed() throws {
        let body = try EndpointRequestBuilder.body(config: config, prompt: .raw("Hi"), decode: DecodeConfig(),
                                                   allowNewlines: true)
        #expect(json(body)["stop"] == nil)
    }

    @Test func chatBodyHasAssistantPrefill() throws {
        let body = try EndpointRequestBuilder.body(config: config, prompt: .chat(user: "U", assistantPrefill: "Dear"),
                                                   decode: DecodeConfig(), allowNewlines: false)
        let messages = json(body)["messages"] as! [[String: String]]
        #expect(messages == [["role": "user", "content": "U"], ["role": "assistant", "content": "Dear"]])
    }

    @Test func urlJoining() {
        let base = URL(string: "http://127.0.0.1:11434/v1")!
        #expect(EndpointRequestBuilder.endpointURL(base: base, api: .completions).path == "/v1/completions")
        #expect(EndpointRequestBuilder.endpointURL(base: base, api: .chatCompletions).path == "/v1/chat/completions")
        let full = URL(string: "http://127.0.0.1:1/v1/completions")!
        #expect(EndpointRequestBuilder.endpointURL(base: full, api: .completions) == full)
    }

    @Test func deltas() {
        #expect(EndpointRequestBuilder.delta(fromEventData: #"{"choices":[{"text":" there"}]}"#) == " there")
        #expect(EndpointRequestBuilder.delta(fromEventData: #"{"choices":[{"delta":{"content":"yo"}}]}"#) == "yo")
        #expect(EndpointRequestBuilder.delta(fromEventData: #"{"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(EndpointRequestBuilder.delta(fromEventData: "not json") == nil)
    }

    @Test func requiredPrefixStripping() {
        typealias B = EndpointRequestBuilder
        #expect(B.stripRequiredPrefix("hello", required: "").text == "hello")
        #expect(B.stripRequiredPrefix("wor", required: "world").text == nil)
        #expect(B.stripRequiredPrefix("wor", required: "world").mismatch == false)
        #expect(B.stripRequiredPrefix("world and", required: "world").text == " and")
        #expect(B.stripRequiredPrefix("xyz", required: "world").mismatch)
    }

    @Test func documentFramerYieldsRawPrompt() {
        let input = PromptInput(before: "Dear Sam, thanks for the", after: "")
        let profile = EndpointRequestBuilder.profile(for: .completions)
        let framed = DefaultFramerRegistry().framer(for: profile, override: nil)
            .frame(input, profile: profile, budget: 500, counter: CharacterTokenCounter())
        guard case .raw(let text) = EndpointRequestBuilder.prompt(from: framed, api: .completions) else {
            Issue.record("expected raw"); return
        }
        #expect(text.hasSuffix("Dear Sam, thanks for the") || text.hasSuffix("Dear Sam, thanks for"))
    }

    @Test func chatFramerSplitsTurns() {
        let input = PromptInput(before: "Dear Sam, thanks for the", after: "")
        let profile = EndpointRequestBuilder.profile(for: .chatCompletions)
        let framed = DefaultFramerRegistry().framer(for: profile, override: nil)
            .frame(input, profile: profile, budget: 500, counter: CharacterTokenCounter())
        guard case .chat(let user, let prefill) = EndpointRequestBuilder.prompt(from: framed, api: .chatCompletions) else {
            Issue.record("expected chat"); return
        }
        #expect(!user.isEmpty)
        #expect(!user.contains("\u{1}"))
        #expect(prefill.hasPrefix("Dear Sam"))
    }
}
