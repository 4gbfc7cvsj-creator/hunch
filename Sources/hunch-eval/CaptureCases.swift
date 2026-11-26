// `capture-cases`: turns Hunch's opt-in eval captures (Settings → Privacy → Diagnostics →
// Save eval captures, written to ~/Library/Logs/Hunch/eval-captures.jsonl) into replay cases.
// The captures are your own messages and screens: the output goes under eval/local/, which git
// ignores, and is never committed or pushed.
import Foundation

func runCaptureCasesCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--in", "--out", "--min-screen"])
    let input = parsed.value("--in") ?? (NSHomeDirectory() + "/Library/Logs/Hunch/eval-captures.jsonl")
    let out = parsed.value("--out") ?? "eval/local/replay-long-real.jsonl"
    // Characters of screen text a case needs to count as long context (~4 characters a token).
    let minScreen = parsed.value("--min-screen").flatMap(Int.init) ?? 2000
    guard out.hasPrefix("eval/local/") else {
        printErr("capture-cases writes personal text: --out must be under eval/local/ (git-ignored)")
        return ExitCode.usage
    }
    do {
        let all = try loadReplayCases(input)
        let cases = captureCases(all, minScreen: minScreen)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let lines = try cases.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        let bySurface = Dictionary(grouping: cases, by: \.surface).mapValues(\.count)
            .sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
        printOut("wrote \(cases.count) of \(all.count) captures to \(out) (\(bySurface)); "
                 + "kept screens of \(minScreen)+ characters")
        return ExitCode.ok
    } catch {
        printErr("capture-cases: \(error)")
        return ExitCode.failure
    }
}

/// Long-screen captures, the same message only once (the last capture of it wins), numbered
/// `real-01`… in capture order and tagged `long`.
func captureCases(_ captures: [ReplayCase], minScreen: Int) -> [ReplayCase] {
    var seen: [String: Int] = [:]
    var kept: [ReplayCase] = []
    for c in captures where (c.screen ?? "").count >= minScreen {
        let key = (c.prefix ?? "") + c.text
        if let i = seen[key] { kept[i] = c; continue }
        seen[key] = kept.count
        kept.append(c)
    }
    return kept.enumerated().map { i, c in
        var c = c
        c.id = String(format: "real-%02d", i + 1)
        c.tags = Array(Set((c.tags ?? []) + ["long", "real"])).sorted()
        return c
    }
}
