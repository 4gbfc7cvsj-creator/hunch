// Speech to text for dictation: whisper.cpp on 16 kHz mono samples, one recording at a time.
import Foundation
import HunchCore
import Synchronization
internal import whisper

/// What a transcription returns.
public struct Transcript: Sendable, Equatable {
    public var text: String
    /// The language whisper detected (ISO code such as "en", "zh"), when it ran auto-detection.
    public var language: String?
    public init(text: String, language: String?) {
        self.text = text
        self.language = language
    }
}

public enum TranscriptionError: Error, Sendable, Equatable {
    case modelMissing(String)
    case loadFailed(String)
    case failed(Int32)
    case cancelled
}

/// One loaded whisper model. Loads on first use (or `preload`), transcribes on its own serial queue
/// so the decode never blocks Swift's cooperative pool, and frees the model after a few idle minutes.
/// Never logs text.
public final class WhisperTranscriber: @unchecked Sendable {
    /// whisper.cpp wants 16 kHz mono float samples.
    public static let sampleRate: Double = 16_000

    private let queue = DispatchQueue(label: "hunch.whisper", qos: .userInitiated)
    // Touched only on `queue`.
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var lastUse = Date()
    private let idleRelease: TimeInterval
    private let cancelFlag = CancelFlag()

    public init(idleReleaseSeconds: TimeInterval = 300) {
        idleRelease = idleReleaseSeconds
        Self.silenceLogs()
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Loads `model` ahead of time (pressing the shortcut does this, so the load overlaps speaking).
    public func preload(_ model: URL) {
        queue.async { [self] in _ = try? LocalWork.run { try ensureLoaded(model) } }
    }

    /// Transcribes `samples`. `prompt` is whisper's initial prompt (names and terms to spell, a
    /// script hint); `language` nil auto-detects.
    public func transcribe(_ samples: [Float], model: URL, prompt: String?, language: String? = nil) async throws
        -> Transcript {
        cancelFlag.set(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Transcript, any Error>) in
                queue.async { [self] in
                    cont.resume(with: Result { try run(samples, model: model, prompt: prompt, language: language) })
                }
            }
        } onCancel: { [cancelFlag] in
            cancelFlag.set(true)
        }
    }

    /// Stops a transcription in progress (it ends with `TranscriptionError.cancelled`).
    public func cancel() { cancelFlag.set(true) }

    /// Frees the model now.
    public func unload() {
        queue.async { [self] in free() }
    }

    // MARK: On the queue

    private func ensureLoaded(_ model: URL) throws -> OpaquePointer {
        let path = model.path
        if let context, loadedPath == path { return context }
        free()
        guard FileManager.default.fileExists(atPath: path) else { throw TranscriptionError.modelMissing(path) }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw TranscriptionError.loadFailed(model.lastPathComponent)
        }
        context = ctx
        loadedPath = path
        scheduleIdleRelease()
        return ctx
    }

    private func run(_ samples: [Float], model: URL, prompt: String?, language: String?) throws -> Transcript {
        LocalWork.begin()
        defer { LocalWork.end() }
        let ctx = try ensureLoaded(model)
        defer {
            lastUse = Date()
            scheduleIdleRelease()
        }
        if cancelFlag.get() { throw TranscriptionError.cancelled }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.threadCount)
        params.translate = false
        params.no_timestamps = true
        params.no_context = true
        params.single_segment = false
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        let flag = Unmanaged.passUnretained(cancelFlag).toOpaque()
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<CancelFlag>.fromOpaque(data).takeUnretainedValue().get()
        }
        params.abort_callback_user_data = flag
        let lang = language ?? "auto"
        let status: Int32 = lang.withCString { langPtr in
            params.language = langPtr
            let run = { (promptPtr: UnsafePointer<CChar>?) -> Int32 in
                params.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
            if let prompt, !prompt.isEmpty { return prompt.withCString { run($0) } }
            return run(nil)
        }
        if cancelFlag.get() { throw TranscriptionError.cancelled }
        guard status == 0 else { throw TranscriptionError.failed(status) }
        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, i) { text += String(cString: segment) }
        }
        let id = whisper_full_lang_id(ctx)
        let detected = id >= 0 ? whisper_lang_str(id).map { String(cString: $0) } : nil
        return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: detected)
    }

    private func scheduleIdleRelease() {
        let wait = idleRelease
        queue.asyncAfter(deadline: .now() + wait + 1) { [weak self] in
            guard let self, self.context != nil, Date().timeIntervalSince(self.lastUse) >= wait else { return }
            self.free()
        }
    }

    private func free() {
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
    }

    /// Performance cores, leaving the rest to the app the user is dictating into.
    static var threadCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(min(count, 8))
        }
        return max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// whisper.cpp prints its model load and timings to stderr; none of that is wanted.
    private static func silenceLogs() {
        whisper_log_set({ _, _, _ in }, nil)
    }
}

/// A cancel flag the C abort callback can read.
final class CancelFlag: Sendable {
    private let value = Atomic<Bool>(false)
    func set(_ on: Bool) { value.store(on, ordering: .relaxed) }
    func get() -> Bool { value.load(ordering: .relaxed) }
}
