// Pure request building and stream-delta parsing for OpenAI-compatible servers.
import Foundation
import HunchCore

public enum EndpointPrompt: Sendable, Equatable {
    case raw(String)
    case chat(user: String, assistantPrefill: String)
}

public enum EndpointRequestBuilder {
    /// Placeholder chat markers used only to let `ChatPrefillFramer` tell its turns apart; they
    /// never reach the wire (turns are rebuilt as JSON messages).
    static let userOpen = "\u{1}gt-user\u{1}"
    static let turnClose = "\u{1}gt-close\u{1}"
    static let assistantOpen = "\u{1}gt-assistant\u{1}"

    /// Profile of the remote model as seen by the framers.
    public static func profile(for api: EndpointAPI) -> ModelProfile {
        switch api {
        case .completions:
            ModelProfile(family: .unknown, isInstruct: false, markers: nil, addsBOS: false, contextLength: 4096,
                         slidingWindow: nil, architecture: "endpoint", displayName: "endpoint")
        case .chatCompletions:
            ModelProfile(family: .unknown, isInstruct: true,
                         markers: ChatMarkers(userOpen: userOpen, turnClose: turnClose, assistantOpen: assistantOpen),
                         addsBOS: false, contextLength: 4096, slidingWindow: nil, architecture: "endpoint",
                         displayName: "endpoint")
        }
    }

    public static func prompt(from framed: FramedPrompt, api: EndpointAPI) -> EndpointPrompt {
        switch api {
        case .completions:
            return .raw(framed.segments.map(\.text).joined())
        case .chatCompletions:
            enum Phase { case before, user, assistant }
            var phase = Phase.before
            var user = "", assistant = ""
            for segment in framed.segments {
                if segment.kind == .control {
                    switch segment.text {
                    case userOpen: phase = .user
                    case turnClose: phase = .before
                    case assistantOpen: phase = .assistant
                    default: break
                    }
                    continue
                }
                switch phase {
                case .user: user += segment.text
                case .assistant: assistant += segment.text
                case .before: break
                }
            }
            return .chat(user: user, assistantPrefill: assistant)
        }
    }

    public static func path(for api: EndpointAPI) -> [String] {
        api == .completions ? ["completions"] : ["chat", "completions"]
    }

    public static func endpointURL(base: URL, api: EndpointAPI) -> URL {
        var url = base
        let tail = path(for: api)
        let existing = base.pathComponents.suffix(tail.count)
        if Array(existing) == tail { return base }
        for part in tail { url = url.appendingPathComponent(part) }
        return url
    }

    public static func body(config: EndpointConfig, prompt: EndpointPrompt, decode: DecodeConfig,
                            allowNewlines: Bool) throws -> Data {
        var object: [String: Any] = [
            "model": config.model,
            "max_tokens": max(1, decode.maxTokens),
            "temperature": 0,
            "stream": true,
        ]
        if !allowNewlines { object["stop"] = ["\n"] }
        switch prompt {
        case .raw(let text):
            object["prompt"] = text
        case .chat(let user, let prefill):
            var messages: [[String: String]] = [["role": "user", "content": user]]
            if !prefill.isEmpty { messages.append(["role": "assistant", "content": prefill]) }
            object["messages"] = messages
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A write-for-me body: a long answer with newlines, a little temperature for natural prose.
    public static func writeBody(config: EndpointConfig, prompt: EndpointPrompt, decode: DecodeConfig,
                                 stops: [String], temperature: Double = 0.3) throws -> Data {
        var object: [String: Any] = [
            "model": config.model,
            "max_tokens": max(1, decode.maxTokens),
            "temperature": temperature,
            "stream": true,
        ]
        if !stops.isEmpty { object["stop"] = Array(stops.prefix(4)) }
        switch prompt {
        case .raw(let text):
            object["prompt"] = text
        case .chat(let user, let prefill):
            var messages: [[String: String]] = [["role": "user", "content": user]]
            if !prefill.isEmpty { messages.append(["role": "assistant", "content": prefill]) }
            object["messages"] = messages
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Text carried by one streamed JSON event, or nil if it has none.
    public static func delta(fromEventData data: String) -> String? {
        guard let raw = data.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first else { return nil }
        if let text = choice["text"] as? String { return text }
        if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String { return content }
        if let message = choice["message"] as? [String: Any], let content = message["content"] as? String { return content }
        return nil
    }

    /// Removes the healed required prefix from accumulated output. `text` is nil while the output
    /// is still a proper prefix of it; `mismatch` means the output cannot start with it.
    public static func stripRequiredPrefix(_ accumulated: String, required: String)
        -> (text: String?, mismatch: Bool) {
        if required.isEmpty { return (accumulated, false) }
        if accumulated.hasPrefix(required) { return (String(accumulated.dropFirst(required.count)), false) }
        if required.hasPrefix(accumulated) { return (nil, false) }
        return (nil, true)
    }
}
