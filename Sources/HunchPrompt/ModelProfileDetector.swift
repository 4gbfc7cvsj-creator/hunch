import Foundation
import HunchCore

/// Chat-template marker tables authored by Hunch from the public template formats.
/// The framer emits `userOpen`, `turnClose`, `assistantOpen` (and `reasoningOff` right after
/// `assistantOpen` when present). `bos` is informational: BOS is added by the tokenizer via
/// `ModelProfile.addsBOS`, never as framer text.
public enum KnownChatMarkers {
    /// Gemma 4. VERIFIED 2026-10-11 against `tokenizer.chat_template` of the dev model
    /// gemma-4-E4B-it-Q5_K_M.gguf: turns open with the control token `<|turn>` followed by the role
    /// name (`system`, `user`, `model`) and a newline, and close with the control token `<turn|>`
    /// plus a newline; the generation prompt is `<|turn>model\n`. Thinking is OFF by default: it is
    /// only enabled by placing the `<|think|>` token at the top of a system turn, which Hunch
    /// never emits, so no reasoning-off directive is needed.
    public static let gemma4 = ChatMarkers(
        bos: "<bos>", systemOpen: "<|turn>system\n", userOpen: "<|turn>user\n", turnClose: "<turn|>\n",
        assistantOpen: "<|turn>model\n", reasoningOff: nil)

    /// Gemma 2/3. UNVERIFIED (written from knowledge of the public format; check against a real
    /// template before relying on it).
    public static let gemma3 = ChatMarkers(
        bos: "<bos>", systemOpen: nil, userOpen: "<start_of_turn>user\n", turnClose: "<end_of_turn>\n",
        assistantOpen: "<start_of_turn>model\n", reasoningOff: nil)

    /// ChatML (Qwen, SmolLM2, others). UNVERIFIED.
    public static let chatML = ChatMarkers(
        bos: nil, systemOpen: "<|im_start|>system\n", userOpen: "<|im_start|>user\n", turnClose: "<|im_end|>\n",
        assistantOpen: "<|im_start|>assistant\n", reasoningOff: nil)

    /// ChatML for templates with a think block (Qwen3 style): an empty think block pre-filled after
    /// the assistant opener disables reasoning. UNVERIFIED.
    public static let chatMLThinkingOff = ChatMarkers(
        bos: nil, systemOpen: "<|im_start|>system\n", userOpen: "<|im_start|>user\n", turnClose: "<|im_end|>\n",
        assistantOpen: "<|im_start|>assistant\n", reasoningOff: "<think>\n\n</think>\n\n")

    /// Llama 3.x header format. UNVERIFIED.
    public static let llama3 = ChatMarkers(
        bos: "<|begin_of_text|>", systemOpen: "<|start_header_id|>system<|end_header_id|>\n\n",
        userOpen: "<|start_header_id|>user<|end_header_id|>\n\n", turnClose: "<|eot_id|>",
        assistantOpen: "<|start_header_id|>assistant<|end_header_id|>\n\n", reasoningOff: nil)
}

/// Pure detection of family, instruct tuning, and chat markers from GGUF metadata (design §5.1).
public struct DefaultModelProfileDetector: ModelProfileDetecting {
    public init() {}

    public func detect(_ summary: GGUFSummary, fileName: String) -> ModelProfile {
        let stem = Self.stem(fileName)
        let family = Self.family(summary, fileStem: stem)
        let instruct = Self.isInstruct(summary, fileStem: stem)
        let markers = Self.markers(family: family, architecture: summary.architecture, template: summary.chatTemplate)
        let name = summary.name ?? summary.baseName ?? stem
        return ModelProfile(
            family: family, isInstruct: instruct, markers: markers,
            addsBOS: summary.addBOS ?? (family != .qwen),
            contextLength: summary.contextLength ?? 4096, slidingWindow: summary.slidingWindow,
            architecture: summary.architecture ?? "unknown", displayName: name)
    }

    // MARK: - Pieces (internal for tests)

    static func stem(_ fileName: String) -> String {
        let last = fileName.split(separator: "/").last.map(String.init) ?? fileName
        if last.lowercased().hasSuffix(".gguf") { return String(last.dropLast(5)) }
        return last
    }

    /// Lowercased alphanumeric words: "Gemma-4-E4B-It" → ["gemma", "4", "e4b", "it"].
    static func words(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ".") })
            .map(String.init)
    }

    /// Ordered most specific first: several of these ship with the `llama` architecture.
    private static let familyPrefixes: [(String, ModelFamily)] = [
        ("smollm", .smollm), ("mistral", .mistral), ("mixtral", .mistral), ("ministral", .mistral),
        ("phi", .phi), ("qwen", .qwen), ("gemma", .gemma), ("llama", .llama),
    ]

    private static func family(fromWords words: [String]) -> ModelFamily? {
        for (prefix, family) in familyPrefixes where words.contains(where: { $0.hasPrefix(prefix) }) {
            return family
        }
        return nil
    }

    static func family(_ summary: GGUFSummary, fileStem: String) -> ModelFamily {
        let arch = summary.architecture?.lowercased() ?? ""
        // Distinctive architectures are trusted first; generic `llama` defers to the names.
        if !arch.isEmpty, !arch.hasPrefix("llama"), let byArch = family(fromWords: [arch]) {
            return byArch
        }
        let nameWords = words(summary.name) + words(summary.baseName) + words(fileStem)
        if let byName = family(fromWords: nameWords) { return byName }
        if arch.hasPrefix("llama") { return .llama }
        return .unknown
    }

    private static let instructWords: Set<String> = ["it", "instruct", "chat", "sft", "dpo", "rlhf"]
    private static let baseWords: Set<String> = ["base", "pt", "pretrain", "pretrained"]

    /// Instruct when the finetune/name/file says so. A chat template alone does NOT count
    /// (base GGUFs often carry one). Finetune metadata wins over names; file name is the tie-breaker.
    /// With no word either way, a Qwen3 model is instruct.
    static func isInstruct(_ summary: GGUFSummary, fileStem: String) -> Bool {
        for source in [words(summary.finetune), words(summary.name) + words(summary.baseName), words(fileStem)] {
            let saysInstruct = source.contains(where: instructWords.contains)
            let saysBase = source.contains(where: baseWords.contains)
            if saysInstruct != saysBase { return saysInstruct }
        }
        // Qwen3's only checkpoints without "Base" are the post-trained (hybrid thinking) ones, and
        // their GGUFs carry no finetune or instruct word ("Qwen3 1.7B").
        let arch = summary.architecture?.lowercased() ?? ""
        return arch == "qwen3" || arch == "qwen3moe"
    }

    static func markers(family: ModelFamily, architecture: String?, template: String?) -> ChatMarkers? {
        if let template, !template.isEmpty {
            if template.contains("<|turn>") { return KnownChatMarkers.gemma4 }
            if template.contains("<start_of_turn>") { return KnownChatMarkers.gemma3 }
            if template.contains("<|im_start|>") {
                return template.contains("<think>") ? KnownChatMarkers.chatMLThinkingOff : KnownChatMarkers.chatML
            }
            if template.contains("<|start_header_id|>") { return KnownChatMarkers.llama3 }
            return nil
        }
        switch family {
        case .gemma:
            return (architecture?.lowercased().hasPrefix("gemma4") ?? false) ? KnownChatMarkers.gemma4 : KnownChatMarkers.gemma3
        case .qwen:
            return KnownChatMarkers.chatML
        default:
            return nil
        }
    }
}
