// One loaded model + context. Created, used, and freed only on the generation executor.
import Foundation
import HunchCore
import llama

final class LlamaRuntime {
    let entry: ModelEntry
    let options: RuntimeOptions
    let profile: ModelProfile
    let session: LlamaSession
    let table: LlamaVocabularyTable
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?

    private init(entry: ModelEntry, options: RuntimeOptions, profile: ModelProfile, session: LlamaSession,
                 table: LlamaVocabularyTable, model: OpaquePointer, ctx: OpaquePointer) {
        self.entry = entry
        self.options = options
        self.profile = profile
        self.session = session
        self.table = table
        self.model = model
        self.ctx = ctx
    }

    /// Frees the context, then the model, explicitly (a competitor hit a ggml-metal destructor assert
    /// when this was left to process exit).
    func close() {
        session.close()
        if let ctx { llama_free(ctx) }
        ctx = nil
        if let model { llama_model_free(model) }
        model = nil
    }

    deinit { close() }

    /// Loads synchronously. `progress` is called on this thread; returning false aborts the load.
    static func load(entry: ModelEntry, options: RuntimeOptions, executor: GenerationExecutor,
                     profileDetector: (any ModelProfileDetecting)? = nil,
                     progress: @escaping (Double) -> Bool) throws -> LlamaRuntime {
        LlamaBackend.ensureInitialized()
        _ = LlamaBackend.takeLastError()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(clamping: options.gpuLayers)
        mparams.load_mode = switch options.loadMode {
        case .memory: LLAMA_LOAD_MODE_NONE
        case .mmap: LLAMA_LOAD_MODE_MMAP
        }
        mparams.lazy_mode = LLAMA_LAZY_MODE_OFF
        let progressBox = ProgressBox(progress)
        mparams.progress_callback = { value, data in
            guard let data else { return true }
            return Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue().report(Double(value))
        }
        mparams.progress_callback_user_data = Unmanaged.passUnretained(progressBox).toOpaque()

        let loaded: OpaquePointer? = withExtendedLifetime(progressBox) {
            entry.url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return nil }
                return llama_model_load_from_file(path, mparams)
            }
        }
        guard let model = loaded else {
            throw LlamaError.loadFailed(LlamaBackend.takeLastError() ?? "the model file could not be loaded")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(clamping: options.contextTokens)
        cparams.n_batch = UInt32(clamping: options.batchTokens)
        cparams.n_ubatch = UInt32(clamping: options.batchTokens)
        let maxSeq = max(1, min(options.maxSequences, Int(llama_max_parallel_sequences())))
        // One sequence more than the search can use: the parked prompt (`LlamaSession.swapParkedPrompt`).
        let parking = maxSeq > 1 && maxSeq < Int(llama_max_parallel_sequences())
        cparams.n_seq_max = UInt32(parking ? maxSeq + 1 : maxSeq)
        cparams.swa_full = options.fullSlidingWindowCache
        cparams.kv_unified = true // one shared buffer: seq_cp is a metadata copy
        cparams.no_perf = true
        cparams.embeddings = false

        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaError.contextCreationFailed
        }
        llama_set_abort_callback(ctx, executorAbortCallback,
                                 Unmanaged.passUnretained(executor.cancelState).toOpaque())

        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(ctx)
            llama_model_free(model)
            throw LlamaError.loadFailed("model has no vocabulary")
        }
        let table = LlamaVocabularyTable.build(from: vocab)
        let session = LlamaSession(ctx: ctx, vocab: vocab, table: table, executor: executor, parking: parking)
        session.reuseCapability = session.probeReuseCapability()
        let reader = ProfileReader(model: model, vocab: vocab, entry: entry)
        var profile = reader.profile()
        if let detector = profileDetector, let summary = entry.summary {
            let detected = detector.detect(summary, fileName: entry.url.lastPathComponent)
            profile = LlamaModelHost.resolveProfile(detected: detected, vocabAddsBOS: profile.addsBOS)
        }
        return LlamaRuntime(entry: entry, options: options, profile: profile, session: session, table: table,
                            model: model, ctx: ctx)
    }
}

private final class ProgressBox {
    let callback: (Double) -> Bool
    init(_ callback: @escaping (Double) -> Bool) { self.callback = callback }
    func report(_ value: Double) -> Bool { callback(value) }
}

/// Minimal M1 profile from GGUF metadata. HunchPrompt owns proper detection later.
struct ProfileReader {
    let model: OpaquePointer
    let vocab: OpaquePointer
    let entry: ModelEntry

    func meta(_ key: String) -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        var n = llama_model_meta_val_str(model, key, &buf, buf.count)
        if n < 0 { return nil }
        if Int(n) >= buf.count {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_model_meta_val_str(model, key, &buf, buf.count)
            if n < 0 { return nil }
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func profile() -> ModelProfile {
        let arch = meta("general.architecture") ?? "unknown"
        let name = meta("general.name")
        let finetune = meta("general.finetune")
        let fileName = entry.url.deletingPathExtension().lastPathComponent
        let ctxLen = meta("\(arch).context_length").flatMap(Int.init) ?? Int(llama_model_n_ctx_train(model))
        let swa = Int(llama_model_n_swa(model))
        let hasTemplate = llama_model_chat_template(model, nil) != nil
        let words = [name, finetune, fileName].compactMap { $0?.lowercased() }
            .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        let instructWord = words.contains { $0 == "it" || $0 == "instruct" || $0 == "chat" }
        return ModelProfile(
            family: Self.family(arch: arch, name: name ?? fileName),
            isInstruct: hasTemplate && instructWord,
            markers: nil,
            addsBOS: llama_vocab_get_add_bos(vocab),
            contextLength: ctxLen,
            slidingWindow: swa > 0 ? swa : nil,
            architecture: arch,
            displayName: name ?? fileName
        )
    }

    static func family(arch: String, name: String) -> ModelFamily {
        let a = arch.lowercased()
        let n = name.lowercased()
        if a.hasPrefix("gemma") { return .gemma }
        if a.hasPrefix("qwen") { return .qwen }
        if a.hasPrefix("phi") { return .phi }
        if a.hasPrefix("mistral") || n.contains("mistral") { return .mistral }
        if n.contains("smollm") { return .smollm }
        if a.hasPrefix("llama") { return .llama }
        return .unknown
    }
}
