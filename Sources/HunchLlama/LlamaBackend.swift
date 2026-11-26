// Process-wide llama.cpp setup: backend init and log routing.
import Foundation
import llama
import Synchronization

public enum LlamaError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No model has been loaded, or it was explicitly unloaded.
    case notLoaded
    /// A model load is in progress; requests fail fast instead of queueing behind it.
    case loading
    case loadFailed(String)
    case contextCreationFailed
    case tokenizeFailed
    case emptyPrompt
    case promptTooLong(tokens: Int, limit: Int)
    /// `llama_decode` found no KV slot (context full).
    case contextFull
    case decodeFailed(Int32)
    case invalidSequence(Int32)
    /// No logits are available for this sequence (nothing decoded since its last change).
    case noLogits(Int32)
    /// The session was used after its model/context was freed.
    case sessionClosed
    case executorStopped

    public var description: String {
        switch self {
        case .notLoaded: "no model is loaded"
        case .loading: "the model is still loading"
        case .loadFailed(let why): "model load failed: \(why)"
        case .contextCreationFailed: "llama context creation failed"
        case .tokenizeFailed: "tokenization failed"
        case .emptyPrompt: "the prompt has no tokens"
        case .promptTooLong(let n, let limit): "prompt of \(n) tokens exceeds the context (\(limit))"
        case .contextFull: "the KV cache is full"
        case .decodeFailed(let code): "llama_decode failed (\(code))"
        case .invalidSequence(let s): "invalid or empty sequence \(s)"
        case .noLogits(let s): "no logits available for sequence \(s)"
        case .sessionClosed: "the session was closed"
        case .executorStopped: "the generation executor is stopped"
        }
    }
}

enum LlamaBackend {
    /// Set `HUNCH_LLAMA_LOG=1` to forward llama.cpp's own log to stderr (debug only; off by default
    /// because Hunch never logs user text and llama's verbose paths are not audited for that).
    static let forwardLog: Bool = ProcessInfo.processInfo.environment["HUNCH_LLAMA_LOG"] == "1"

    /// Most recent error-level line from llama.cpp, used to explain load failures.
    private static let lastError = Mutex<String?>(nil)

    private static let initialized: Bool = {
        llama_log_set(llamaLogCallback, nil)
        llama_backend_init()
        return true
    }()

    static func ensureInitialized() { _ = initialized }

    static func takeLastError() -> String? {
        lastError.withLock { value in
            defer { value = nil }
            return value
        }
    }

    fileprivate static func record(level: ggml_log_level, text: UnsafePointer<CChar>?) {
        guard let text else { return }
        if forwardLog { fputs(String(cString: text), stderr) }
        if level == GGML_LOG_LEVEL_ERROR {
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            lastError.withLock { $0 = String(line.prefix(300)) }
        }
    }
}

private let llamaLogCallback: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
    level, text, _ in
    LlamaBackend.record(level: level, text: text)
}
