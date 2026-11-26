import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct ProfileDetectorTests {
    let detector = DefaultModelProfileDetector()

    /// Mirrors the dev model's real metadata (no `general.finetune`; name says "It").
    @Test func gemma4DevModelIsInstructWithVerifiedMarkers() {
        let summary = GGUFSummary(version: 3, architecture: "gemma4", name: "Gemma-4-E4B-It", type: "model",
                                  baseName: "Gemma-4-E4B-It", contextLength: 131072, slidingWindow: 512,
                                  chatTemplate: "{{ bos_token }}{{ '<|turn>' + role + '\\n' }}...<turn|>", addBOS: true)
        let profile = detector.detect(summary, fileName: "gemma-4-E4B-it-Q5_K_M.gguf")
        #expect(profile.family == .gemma)
        #expect(profile.isInstruct)
        #expect(profile.markers == KnownChatMarkers.gemma4)
        #expect(profile.markers?.userOpen == "<|turn>user\n")
        #expect(profile.markers?.turnClose == "<turn|>\n")
        #expect(profile.markers?.assistantOpen == "<|turn>model\n")
        #expect(profile.markers?.reasoningOff == nil)
        #expect(profile.addsBOS)
        #expect(profile.contextLength == 131072)
        #expect(profile.slidingWindow == 512)
        #expect(profile.displayName == "Gemma-4-E4B-It")
    }

    @Test func chatTemplateAloneDoesNotImplyInstruct() {
        let summary = GGUFSummary(version: 3, architecture: "gemma4", name: "Gemma 4 E4B",
                                  chatTemplate: "<|turn>user ...")
        let profile = detector.detect(summary, fileName: "gemma-4-E4B-Q8_0.gguf")
        #expect(!profile.isInstruct)
        #expect(profile.markers != nil)
    }

    @Test func finetuneMetadataWinsOverFileName() {
        let base = GGUFSummary(version: 3, architecture: "qwen3", name: "Qwen3 8B", finetune: "Base")
        #expect(!detector.detect(base, fileName: "qwen3-8b-instruct.gguf").isInstruct)
        // Qwen3's hybrid checkpoints say nothing either way (metadata of Qwen3-1.7B.i1-Q4_K_M.gguf).
        let hybrid = GGUFSummary(version: 3, architecture: "qwen3", name: "Qwen3 1.7B", baseName: "Qwen3")
        #expect(detector.detect(hybrid, fileName: "Qwen3-1.7B.i1-Q4_K_M.gguf").isInstruct)
        let qwenBase = GGUFSummary(version: 3, architecture: "qwen3", name: "Qwen3 1.7B Base", baseName: "Qwen3")
        #expect(!detector.detect(qwenBase, fileName: "Qwen3-1.7B-Base.i1-Q4_K_M.gguf").isInstruct)
        let chat = GGUFSummary(version: 3, architecture: "qwen2", name: "Qwen2.5 7B", finetune: "Instruct")
        #expect(detector.detect(chat, fileName: "model.gguf").isInstruct)
    }

    @Test func fileNameIsTheTieBreaker() {
        let bare = GGUFSummary(version: 3, architecture: "llama")
        #expect(detector.detect(bare, fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf").isInstruct)
        #expect(!detector.detect(bare, fileName: "Llama-3.2-3B-Q4_K_M.gguf").isInstruct)
        #expect(!detector.detect(bare, fileName: "gemma-3-4b-pt.gguf").isInstruct)
    }

    @Test func familiesFromArchitectureAndNames() {
        func family(_ arch: String?, _ name: String?, _ file: String) -> ModelFamily {
            detector.detect(GGUFSummary(version: 3, architecture: arch, name: name), fileName: file).family
        }
        #expect(family("gemma3", nil, "x.gguf") == .gemma)
        #expect(family("qwen2", nil, "x.gguf") == .qwen)
        #expect(family("phi3", nil, "x.gguf") == .phi)
        #expect(family("llama", "SmolLM2 1.7B Instruct", "x.gguf") == .smollm)
        #expect(family("llama", "Mistral 7B Instruct v0.3", "x.gguf") == .mistral)
        #expect(family("llama", nil, "Meta-Llama-3-8B.gguf") == .llama)
        #expect(family("llama", nil, "mystery.gguf") == .llama)
        #expect(family(nil, nil, "dolphin-mix.gguf") == .unknown)
        #expect(family(nil, nil, "Phi-4-mini.gguf") == .phi)
    }

    @Test func markersChosenFromTemplate() {
        #expect(DefaultModelProfileDetector.markers(family: .qwen, architecture: "qwen2",
                                                    template: "<|im_start|>{{ role }}") == KnownChatMarkers.chatML)
        #expect(DefaultModelProfileDetector.markers(family: .qwen, architecture: "qwen3",
                                                    template: "<|im_start|> <think>") == KnownChatMarkers.chatMLThinkingOff)
        #expect(DefaultModelProfileDetector.markers(family: .llama, architecture: "llama",
                                                    template: "<|start_header_id|>") == KnownChatMarkers.llama3)
        #expect(DefaultModelProfileDetector.markers(family: .gemma, architecture: "gemma3",
                                                    template: "<start_of_turn>") == KnownChatMarkers.gemma3)
        #expect(DefaultModelProfileDetector.markers(family: .phi, architecture: "phi3", template: "<|user|>") == nil)
        #expect(DefaultModelProfileDetector.markers(family: .gemma, architecture: "gemma4", template: nil)
                == KnownChatMarkers.gemma4)
    }

    @Test func defaultsWhenMetadataIsMissing() {
        let profile = detector.detect(GGUFSummary(version: 3), fileName: "/models/thing.gguf")
        #expect(profile.family == .unknown)
        #expect(!profile.isInstruct)
        #expect(profile.markers == nil)
        #expect(profile.architecture == "unknown")
        #expect(profile.displayName == "thing")
        #expect(profile.contextLength == 4096)
    }
}
