import HunchCore
import Testing
@testable import HunchPrompt

/// Synthetic fixtures, one per key family, assembled from pieces (never real credentials).
private let secrets = [
    "AKIA" + "FAKEFAKEFAKEFAKE",
    "sk_" + "live_" + "FAKEfake0000FAKEfake",
    "sk-" + "FAKEfake0000FAKEfake0000",
    "ghp_" + String(repeating: "FaKe", count: 9),
    "github_pat_" + "FAKE0000fake_FAKE0000fake",
    "AIza" + String(repeating: "FaKe", count: 8) + "x_y",
    "xoxp-" + "0000-0000-FAKEfakeFAKE",
    "eyJ" + "hbGciOiJub25lIn0" + ".eyJ" + "zdWIiOiJmYWtlIn0" + ".ZmFrZXNpZw",
    "-----BEGIN " + "EC PRIVATE KEY-----\nFAKEFAKEFAKE\n-----END EC PRIVATE KEY-----",
    "https://sam:" + "fakePass99@db.example.com",
    "password=" + "fakePass99",
    "FR00" + "FAKE12345678901234",
    "https://cdn.example.com/a.png?X-Amz-Signature=" + "fa4e0000fake",
]

/// The secret's own characters that must never appear (labels like `password=` may stay).
private func core(_ secret: String) -> String {
    if secret.hasPrefix("https://sam:") { return "fakePass99" }
    if secret.hasPrefix("password=") { return "fakePass99" }
    if secret.contains("X-Amz-Signature=") { return "fa4e0000fake" }
    return secret
}

private let framers: [(any PromptFramer, ModelProfile)] = [
    (DocumentFramer(), unknownBase), (DocumentFramer(.v2), unknownBase),
    (ChatPrefillFramer(), gemmaInstruct), (ChatPrefillFramer(.v2), gemmaInstruct),
]

private let filler = String(repeating: "We met at the cafe and talked for a while. ", count: 8)  // 352 characters

private func text(_ prompt: FramedPrompt) -> String { prompt.segments.map(\.text).joined() }

@Suite struct SecretRedactionTests {
    @Test(arguments: secrets)
    func secretsNeverReachThePrompt(_ secret: String) {
        let input = PromptInput(before: "Old note \(secret) end. " + filler + "So I think we", after: "Next: \(secret)",
                                surface: .email, screenContext: "Shown nearby \(secret) here",
                                clipboard: "Copied \(secret) text", appName: "Mail",
                                windowTitle: "Draft \(secret)", styleExamples: ["I wrote \(secret) once."],
                                fieldLabel: "Reply \(secret)")
        for (framer, profile) in framers {
            let prompt = framer.frame(input, profile: profile, budget: 20_000, counter: ScalarCounter())
            let out = text(prompt)
            #expect(!out.contains(core(secret)), "\(framer.id)")
            // Every block survived (redacted), so the check above is not vacuous.
            #expect(out.contains("Old note ") && out.contains("[redacted]"), "\(framer.id)")
            #expect(out.contains("Shown nearby"), "\(framer.id)")
            #expect(out.contains("Copied"), "\(framer.id)")
            #expect(out.contains("I wrote"), "\(framer.id)")
            #expect(out.contains("Next:"), "\(framer.id)")
        }
    }

    @Test func lastCharactersBeforeTheCaretStayExact() {
        let tail = String(filler.suffix(150)) + "my key is \(secrets[0]) and"
        #expect(tail.count < PromptRedactor.exactBefore)
        let before = "Earlier key \(secrets[2]) noted. " + filler + tail
        let input = PromptInput(before: before, surface: .note)
        for (framer, profile) in framers {
            let prompt = framer.frame(input, profile: profile, budget: 20_000, counter: ScalarCounter())
            let full = text(prompt) + prompt.requiredPrefix
            #expect(full.hasSuffix(String(before.suffix(PromptRedactor.exactBefore))), "\(framer.id)")
            #expect(full.contains(secrets[0]), "\(framer.id)")
            #expect(!full.contains(secrets[2]), "\(framer.id)")
        }
    }

    @Test func codeSurfaceKeepsEnvironmentAssignments() {
        let input = PromptInput(before: "let x = 1\n", after: "BUILD_FLAVOR=releasecandidate\n", surface: .code)
        let prompt = DocumentFramer().frame(input, profile: unknownBase, budget: 4_000, counter: ScalarCounter())
        #expect(text(prompt).contains("BUILD_FLAVOR=releasecandidate"))
        let prose = PromptInput(before: "Set it to\n", after: "BUILD_FLAVOR=releasecandidate\n", surface: .note)
        let redacted = DocumentFramer().frame(prose, profile: unknownBase, budget: 4_000, counter: ScalarCounter())
        #expect(text(redacted).contains("BUILD_FLAVOR=[redacted]"))
    }

    @Test func repeatedFramingIsStable() {
        let framer = DocumentFramer()
        let input = PromptInput(before: "Key \(secrets[1]) " + filler + "and", after: "x \(secrets[3])",
                                clipboard: "c \(secrets[4])")
        let first = framer.frame(input, profile: unknownBase, budget: 4_000, counter: ScalarCounter())
        let second = framer.frame(input, profile: unknownBase, budget: 4_000, counter: ScalarCounter())
        #expect(first == second)
    }
}
