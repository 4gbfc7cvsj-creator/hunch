// swift-tools-version: 6.2
// Hunch: personal on-device, system-wide ghost-text autocomplete for macOS.
// Owner: integrator (orchestrator). Implementers request changes instead of editing this file.
import PackageDescription

let package = Package(
    name: "Hunch",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "HunchApp", targets: ["HunchApp"]),
        .executable(name: "hunch-eval", targets: ["hunch-eval"]),
    ],
    targets: [
        // Prebuilt llama.cpp, fetched and pinned by scripts/fetch-llama.sh.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        // Prebuilt whisper.cpp (speech to text), fetched and pinned by scripts/fetch-whisper.sh.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),

        // Shared contract: value types and cross-module protocols. Foundation/CoreGraphics only.
        .target(name: "HunchCore"),

        // Pure modules (Foundation + HunchCore only).
        .target(name: "HunchPolicy", dependencies: ["HunchCore"]),
        .target(name: "HunchPrompt", dependencies: ["HunchCore"]),
        .target(name: "HunchText", dependencies: ["HunchCore"]),
        .target(name: "HunchSession", dependencies: ["HunchCore"]),
        .target(name: "HunchDecode", dependencies: ["HunchCore"]),

        // Side-effectful modules.
        .target(name: "HunchModels", dependencies: ["HunchCore"]),
        .target(name: "HunchLlama", dependencies: ["HunchCore", "llama"]),
        // Dictation's speech to text (whisper.cpp). Its own framework copy of ggml, kept apart from llama's.
        .target(name: "HunchWhisper", dependencies: ["HunchCore", "whisper"]),
        .target(name: "HunchEngine", dependencies: ["HunchCore", "HunchPrompt", "HunchDecode", "HunchText", "HunchLlama"]),
        .target(name: "HunchEndpoint", dependencies: ["HunchCore", "HunchText", "HunchPrompt"]),
        .target(name: "HunchFocus", dependencies: ["HunchCore", "HunchPolicy"]),
        .target(name: "HunchInput", dependencies: ["HunchCore", "HunchText"]),
        .target(name: "HunchOverlay", dependencies: ["HunchCore"]),
        .target(name: "HunchSettingsStore", dependencies: ["HunchCore"]),
        .target(name: "HunchScreen", dependencies: ["HunchCore", "HunchPolicy"]),
        // Learning from the user's writing (M3 track L): outcome tracking, scoring, encrypted store.
        .target(name: "HunchHistory", dependencies: ["HunchCore"]),
        // Emoji suggestions (M3 track E2): ":" search, emoticons, skin tone. No model involved.
        .target(name: "HunchEmoji", dependencies: ["HunchCore"]),
        // Shell-command suggestions at a terminal's shell prompt: history lookup, command checks.
        .target(name: "HunchShell", dependencies: ["HunchCore"]),

        // Executables.
        .executableTarget(
            name: "HunchApp",
            dependencies: [
                "HunchCore", "HunchPolicy", "HunchPrompt", "HunchText", "HunchSession", "HunchDecode", "HunchModels",
                "HunchLlama", "HunchEngine", "HunchEndpoint", "HunchFocus", "HunchInput", "HunchOverlay", "HunchSettingsStore", "HunchScreen", "HunchHistory", "HunchEmoji", "HunchShell",
                "HunchWhisper",
            ]
        ),
        .executableTarget(
            name: "hunch-eval",
            dependencies: ["HunchCore", "HunchModels", "HunchPrompt", "HunchDecode", "HunchText", "HunchLlama", "HunchEngine", "HunchScreen", "HunchSession", "HunchHistory", "HunchPolicy"]
        ),

        // Tests for pure logic.
        .testTarget(name: "HunchCoreTests", dependencies: ["HunchCore"]),
        .testTarget(name: "HunchPolicyTests", dependencies: ["HunchPolicy", "HunchCore"]),
        .testTarget(name: "HunchPromptTests", dependencies: ["HunchPrompt", "HunchCore"]),
        .testTarget(name: "HunchTextTests", dependencies: ["HunchText", "HunchCore"]),
        .testTarget(name: "HunchSessionTests", dependencies: ["HunchSession", "HunchCore"]),
        .testTarget(name: "HunchDecodeTests", dependencies: ["HunchDecode", "HunchCore"]),
        .testTarget(name: "HunchModelsTests", dependencies: ["HunchModels", "HunchCore"]),
        .testTarget(name: "HunchScreenTests", dependencies: ["HunchScreen", "HunchCore"]),
        .testTarget(name: "HunchHistoryTests", dependencies: ["HunchHistory", "HunchCore"]),
        .testTarget(name: "HunchEmojiTests", dependencies: ["HunchEmoji", "HunchCore"]),
        .testTarget(name: "HunchShellTests", dependencies: ["HunchShell", "HunchCore"]),
        .testTarget(name: "HunchFocusTests", dependencies: ["HunchFocus", "HunchPolicy", "HunchCore"]),
        .testTarget(name: "HunchOverlayTests", dependencies: ["HunchOverlay", "HunchCore"]),
        .testTarget(name: "HunchInputTests", dependencies: ["HunchInput", "HunchCore"]),
        .testTarget(name: "HunchSettingsStoreTests", dependencies: ["HunchSettingsStore", "HunchCore"]),
        .testTarget(name: "HunchEndpointTests", dependencies: ["HunchEndpoint", "HunchPrompt", "HunchText", "HunchCore"]),
        .testTarget(
            name: "HunchEngineTests",
            dependencies: ["HunchEngine", "HunchLlama", "HunchPrompt", "HunchDecode", "HunchText", "HunchModels", "HunchCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
        // Whisper integration test; runs only with a model and audio given (see the test).
        .testTarget(
            name: "HunchWhisperTests",
            dependencies: ["HunchWhisper", "HunchCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
        // Integration tests; they run only when the dev models folder is mounted.
        .testTarget(
            name: "HunchLlamaTests",
            dependencies: ["HunchLlama", "HunchModels", "HunchCore"],
            // The xctest bundle lives three levels below Products/<config>, where llama.framework is.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
