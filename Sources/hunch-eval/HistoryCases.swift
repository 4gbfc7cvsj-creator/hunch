// `history-cases`: turns the sentences Hunch saved from your own typing (the encrypted local
// history, read only) into replay cases. The output is personal: write it under eval/local/,
// which git ignores, and never commit or push it. History keeps only the text and the app, so
// these cases have no screen text.
import Foundation
import HunchCore
import HunchHistory

func runHistoryCasesCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--out", "--max"])
    let out = parsed.value("--out") ?? "eval/local/replay-history.jsonl"
    let maxCases = parsed.value("--max").flatMap(Int.init) ?? 80
    guard out.hasPrefix("eval/local/") || parsed.flags.contains("--allow-any-path") else {
        printErr("history-cases writes personal text: --out must be under eval/local/ (git-ignored)")
        return ExitCode.usage
    }
    let (model, state) = EncryptedHistoryStore().loadResult()
    let snippets = model.style.snippets
    guard !snippets.isEmpty else {
        printErr("no saved sentences in the local history (load state: \(state))")
        return ExitCode.failure
    }
    let cases = historyCases(snippets, max: maxCases)
    let lines = cases.compactMap { c -> String? in
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(c)).map { String(decoding: $0, as: UTF8.self) }
    }
    do {
        try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    } catch {
        printErr("history-cases: \(error)")
        return ExitCode.failure
    }
    let bySurface = Dictionary(grouping: cases, by: \.surface).mapValues(\.count)
        .sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
    printOut("wrote \(cases.count) cases from \(snippets.count) saved sentences to \(out) (\(bySurface))")
    return ExitCode.ok
}

/// The newest distinct sentences of a typable length, one case each, newest first.
func historyCases(_ snippets: [HunchHistory.StyleSnippet], max: Int) -> [ReplayCase] {
    var seen = Set<String>()
    var cases: [ReplayCase] = []
    for snippet in snippets.sorted(by: { $0.createdAt > $1.createdAt }) {
        let text = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20, text.count <= 300, !text.contains("\n"), seen.insert(text.lowercased()).inserted else {
            continue
        }
        let key = snippet.appKey ?? snippet.appBundleID ?? ""
        cases.append(ReplayCase(id: "h-\(cases.count + 1)", surface: surfaceGuess(appKey: key), tags: ["history"],
                                app: appNameGuess(appKey: key), domain: key.contains(".") && !key.contains("com.apple")
                                    && key.split(separator: ".").count <= 3 ? key : nil,
                                text: text, capturedAt: ISO8601DateFormatter().string(from: snippet.createdAt)))
        if cases.count >= max { break }
    }
    return cases
}

/// A rough surface from the app's bundle ID or site host.
func surfaceGuess(appKey: String) -> SurfaceKind {
    let k = appKey.lowercased()
    let table: [([String], SurfaceKind)] = [
        (["mail", "outlook", "spark", "superhuman"], .email),
        (["claude", "chatgpt", "openai", "gemini", "perplexity"], .agentPrompt),
        (["messages", "ichat", "slack", "discord", "whatsapp", "line", "telegram", "teams", "wechat", "signal", "messenger"], .chat),
        (["notes", "obsidian", "bear"], .note),
        (["docs", "pages", "word", "notion", "textedit"], .document),
        (["xcode", "vscode", "zed", "jetbrains"], .code),
    ]
    for (needles, surface) in table where needles.contains(where: { k.contains($0) }) { return surface }
    return .unknown
}

/// "com.tinyspeck.slackmacgap" → "slackmacgap", "mail.google.com" → "mail.google.com".
func appNameGuess(appKey: String) -> String? {
    guard !appKey.isEmpty else { return nil }
    if appKey.hasPrefix("com.") || appKey.hasPrefix("net.") || appKey.hasPrefix("org.") || appKey.hasPrefix("io.") {
        return appKey.split(separator: ".").last.map(String.init)
    }
    return appKey
}
