// Autocorrect for ambiguous words on the real suggestion model: the model picks among the typed
// word and its candidates using the word after it. Prints a table of margins, used to set
// `TypoChoice.defaultMargin`. Skipped when the dev models folder is absent.
import Foundation
import HunchCore
import HunchModels
import HunchPrompt
import HunchText
import Testing
@testable import HunchEngine
@testable import HunchLlama

private enum ScorerModel {
    static let name = "gemma-4-E4B-it.i1-Q5_K_M.gguf"
    static var present: Bool { DevModels.exists(name) }
}

@Suite(.serialized, .enabled(if: ScorerModel.present, "dev model not present"))
final class ContinuationScorerModelTests {
    static let model = ScorerModel.name
    private let hold: ModelHold
    init() async { hold = await ModelHold() }

    /// head, typed word, next word, candidates (as the finder would list them), expected choice
    /// (nil = not applied: kept, or only offered).
    static let cases: [(String, String, String, [String], String?)] = [
        ("thanks ", "fo", "the", ["to", "of", "do", "go", "for", "fox", "fog"], "for"),
        ("I'll have a cup ", "fo", "tea", ["to", "of", "do", "go", "for", "fox", "fog"], "of"),
        ("This is one ", "fo", "the", ["to", "of", "do", "go", "for", "fox", "fog"], "of"),
        ("I want ", "fo", "go", ["to", "of", "do", "go", "for", "fox", "fog"], "to"),
        ("We're still waiting ", "fo", "you", ["to", "of", "do", "go", "for", "fox", "fog"], "for"),
        ("Sorry, I need ", "fo", "leave", ["to", "of", "do", "go", "for", "fox", "fog"], "to"),
        ("The new ", "ui", "is", ["up", "us", "is", "i"], nil),
        ("I went with ", "thier", "friends", ["their", "thieve", "tier", "thief"], "their"),
        ("I ", "wnat", "to", ["want", "what", "wait", "neat"], "want"),
        ("She said ", "taht", "he", ["that", "tact", "taut"], "that"),
        ("Let's meet at ", "fo", "PM", ["to", "of", "do", "go", "for", "fox", "fog"], nil),
    ]

    @Test func picksTheFixInContext() async throws {
        let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
        let options = RuntimeOptions(contextTokens: 2048, batchTokens: 512, gpuLayers: -1, loadMode: .mmap,
                                     fullSlidingWindowCache: true, maxSequences: 4, idleReleaseAfterSeconds: nil)
        _ = DevModels.noResidency
        await host.load(DevModels.entry(Self.model), options: options)
        guard case .ready = await host.state() else {
            Issue.record("load failed")
            return
        }
        let engine = LocalCompletionEngine(host: host)
        var lines = ["[scorer] \(Self.model)", "  text | best (margin over runner-up) | choice | ms"]
        var id: UInt64 = 0
        for (head, word, next, candidates, expected) in Self.cases {
            id += 1
            let request = makeRequest(id, before: head)
            let all = [word] + candidates
            let start = ContinuousClock.now
            let scores = try #require(try await engine.scoreContinuations(request, continuations: all.map { $0 + " " + next }))
            let elapsed = ContinuousClock.now - start
            let order = scores.indices.sorted { scores[$0] > scores[$1] }
            let margin = scores[order[0]] - scores[order[1]]
            let choice = TypoChoice.decide(candidates: candidates, scores: scores)
            let shown = String(format: "%@ (%.2f over %@)", all[order[0]], margin, all[order[1]])
            lines.append("  \(head)\(word) \(next) | \(shown) | \(choice) | "
                + String(format: "%.0f", Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000))
            switch choice {
            case .fix(let pick): #expect(pick == expected, "\(head)\(word) \(next)")
            // Unsure is never applied: right for a real fix (only offered) and for "leave it".
            case .unsure(let pick): #expect(expected == nil || pick == expected, "\(head)\(word) \(next) (unsure)")
            case .keep: #expect(expected == nil, "\(head)\(word) \(next) kept")
            }
        }
        // A suggestion right after still reuses the prompt the scorer left.
        id += 1
        let after = try await engine.complete(makeRequest(id, before: "thanks for the ")) { _ in }
        lines.append("  next suggestion path: \(after.path.rawValue), decoded \(after.timings.decodedPromptTokens)")
        print(lines.joined(separator: "\n"))
        await host.unload()
    }
}
