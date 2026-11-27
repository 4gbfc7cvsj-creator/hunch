// `write`: write-for-me drafts and polishes from eval/write/cases.jsonl on one model: each case's
// draft, time, and whether it kept the facts it must (mustInclude) and avoided what it must not
// (mustExclude). Writes write-report.md. A case with `preset` is a dictation cleanup instead: `source`
// is the transcript, run through the dictation prompt and its output check.
import Foundation
import HunchCore
import HunchEngine
import HunchLlama
import HunchModels
import HunchPolicy
import HunchPrompt
import HunchText

struct WriteCase: Decodable {
    var id: String
    var mode: WriteMode
    var shape: WriteShape
    var source: String
    var about: String?
    var screen: String?
    /// The app's own notes (Settings → Apps), as the app sends them; "ai" means the AI category preset.
    var appNotes: String?
    /// The app the field is in, as "Where I am typing" names it.
    var app: String?
    var mustInclude: [String]
    var mustExclude: [String]
    // Dictation cleanup cases.
    var preset: DictationPreset?
    var textBefore: String?
    var spellings: [String]?
    var surface: SurfaceKind?
    var traditional: Bool?
    // Voice instruction cases (mode transform): the spoken instruction applied to `source`, the
    // script the output must be in ("han" or "latin"), and the most it may keep of the source's length.
    var instruction: String?
    var script: String?
    var maxLengthRatio: Double?
    // Suggested-replies cases: `screen` holds the conversation, `source` is empty; `minReplies` is the
    // fewest the parsed list may have (0 = must be none), and `length` the Length preset.
    var replies: Bool?
    var minReplies: Int?
    var length: LengthPreset?
    /// Screen-text token limit for a replies case (the app's Settings slider); default 1000.
    var screenTokens: Int?
    /// Replies case: words no reply may start with (e.g. "Yes"/"No" when the message offers named choices).
    var bannedStarts: [String]?
}

/// Share of letters that are Han characters.
private func hanShare(_ text: String) -> Double {
    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard !letters.isEmpty else { return 0 }
    let han = letters.filter { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    return Double(han.count) / Double(letters.count)
}

func runWriteCommand(_ args: [String]) async -> Int32 {
    var model = ""
    var casesPath = "eval/write/cases.jsonl"
    var out = "eval/reports/write"
    // The app loads the shared Language Model with at least 4096 tokens of context and a separate
    // writing model with 8192; replies tuning should pass the one the app uses (4096 for the
    // Language Model).
    var contextTokens = 8192
    var appScreen = false
    var i = 0
    func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
    while i < args.count {
        switch args[i] {
        case "--model": model = value() ?? ""
        case "--cases": casesPath = value() ?? casesPath
        case "--out": out = value() ?? out
        case "--context-tokens": contextTokens = Int(value() ?? "") ?? contextTokens
        // Replies cases: screens go through the app's screen pipeline (layout markers → "Me:"/"Them:").
        case "--app-screen": appScreen = true
        default:
            printErr("unknown option \(args[i])")
            return ExitCode.usage
        }
        i += 1
    }
    guard !model.isEmpty else {
        printErr("usage: hunch-eval write --model <file.gguf> [--cases eval/write/cases.jsonl] [--out dir] [--context-tokens 8192]")
        return ExitCode.usage
    }
    guard let data = FileManager.default.contents(atPath: casesPath) else {
        printErr("no cases at \(casesPath)")
        return ExitCode.failure
    }
    let decoder = JSONDecoder()
    let cases = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> WriteCase? in
        try? decoder.decode(WriteCase.self, from: Data(line.utf8))
    }
    let entry = makeEntry(path: model)
    guard entry.validity == .valid, entry.summary != nil else {
        printErr("not a usable model: \(model)")
        return ExitCode.failure
    }
    var options = evalRuntimeOptions
    options.contextTokens = contextTokens
    options.maxSequences = 1
    let host = LlamaModelHost(profileDetector: DefaultModelProfileDetector())
    await host.load(entry, options: options)
    guard case .ready(_, let profile) = await host.state() else {
        printErr("load failed: \(await host.state())")
        return ExitCode.failure
    }
    let counter = Counter()
    let writer = LocalWriter(host: host, promptTokenBudget: max(512, contextTokens - 900 - 64), maxTokens: min(900, contextTokens / 3),
                             nextID: { counter.next() })
    var md = "# Write for me: \(entry.id.relativePath) (\(profile.isInstruct ? "instruct" : "base"))\n\n"
    md += "| case | mode | ms | kept | avoided |\n|---|---|---|---|---|\n"
    var details = ""
    var allPass = true
    for c in cases {
        let dictation = c.preset.map {
            DictationCleanup(transcript: c.source, preset: $0,
                             context: DictationContext(spellings: c.spellings ?? [], textBefore: c.textBefore,
                                                       surface: c.surface, languages: ["en", "zh-Hant-TW"],
                                                       traditionalChinese: c.traditional ?? false),
                             shape: c.shape)
        }
        var request = WriteRequest(id: counter.next(), mode: c.mode, source: c.source, shape: c.shape,
                                   context: PromptInput(before: "", aboutWriter: c.about, preferredLanguages: ["en"],
                                                        screenContext: c.screen),
                                   dictation: dictation, instruction: c.instruction)
        request.context.appName = c.app
        if let notes = c.appNotes {
            request.context.appInstructions = notes == "ai" ? CategoryPresets.table[CategoryNames.ai]?.customInstructions : notes
        }
        if c.replies == true {
            if appScreen, let screen = c.screen {
                request.context.screenContext = pipelineScreen(screen, before: "", surface: c.surface ?? .chat)
            }
            request.replies = ReplyRequest(length: c.length ?? .medium)
            request.context.screenTokenLimit = c.screenTokens ?? 1000
        }
        let start = ContinuousClock.now
        let text: String
        do {
            let reply = try await writer.write(request) { _ in }
            // As the app does: a chat message gets the casual style after the cleanup too.
            text = dictation != nil && c.shape == .message
                ? DictationText.chatStyle(DictationText.stripWrappers(reply), transcript: c.source) : reply
        } catch {
            md += "| \(c.id) | \(c.mode.rawValue) | - | error | \(error) |\n"
            allPass = false
            continue
        }
        let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        var verdict = ""
        if dictation != nil {
            switch DictationText.check(text, transcript: c.source, textBefore: c.textBefore) {
            case .accept: verdict = " (check: ok)"
            case .reject(let why):
                verdict = " (check: rejected \(why.rawValue), raw goes in)"
                allPass = false
            }
        }
        var missing = c.mustInclude.filter { !text.localizedCaseInsensitiveContains($0) }
        if c.replies == true {
            let parsed = SuggestedReplies.parse(text)
            let least = c.minReplies ?? 2
            if least == 0, !parsed.isEmpty { missing.append("expected none, got \(parsed.count)") }
            if least > 0, parsed.count < least { missing.append("replies \(parsed.count) < \(least)") }
            if c.traditional == true, parsed.contains(where: HanScript.usesSimplified) { missing.append("simplified") }
            for start in c.bannedStarts ?? [] where parsed.contains(where: {
                $0.range(of: "^\\(start)\\b", options: [.regularExpression, .caseInsensitive]) != nil
            }) {
                missing.append("starts with \(start)")
            }
        }
        let present = c.mustExclude.filter { text.contains($0) }
        let share = hanShare(text)
        if c.script == "han", share < 0.5 { missing.append("script han (\(Int(share * 100))%)") }
        if c.script == "latin", share > 0.1 { missing.append("script latin (\(Int(share * 100))% han)") }
        if let ratio = c.maxLengthRatio, Double(text.count) > ratio * Double(c.source.count) {
            missing.append("length \(text.count)/\(c.source.count) > \(ratio)")
        }
        if !missing.isEmpty || !present.isEmpty { allPass = false }
        md += "| \(c.id) | \(c.mode.rawValue) | \(ms) | \(missing.isEmpty ? "yes" : "missing " + missing.joined(separator: ", ")) "
            + "| \(present.isEmpty ? "yes" : "has " + present.joined(separator: ", ")) |\n"
        details += "\n## \(c.id)\(verdict)\n\nSource: \(c.source)\n\n"
            + (c.instruction.map { "Instruction: \($0)\n\n" } ?? "") + "```\n\(text)\n```\n"
        printOut("\(c.id): \(ms) ms, missing \(missing), unwanted \(present)\(verdict)\n    → \(text)")
        if c.replies == true {
            let kept = ReplyScoring.keep(SuggestedReplies.parse(text), scores: writer.lastReplyScores)
            let scores = writer.lastReplyScores.map {
                "    \($0 == kept.dropped ? "✗" : "·") \($0.reply)  (\(ReplyScoring.describe($0)))"
            }
            printOut(scores.joined(separator: "\n"))
            details += scores.joined(separator: "\n") + "\n"
        }
    }
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let path = (out as NSString).appendingPathComponent("write-report.md")
    try? (md + details).write(toFile: path, atomically: true, encoding: .utf8)
    printOut("wrote \(path)")
    await host.unload()
    return allPass ? ExitCode.ok : ExitCode.failure
}

private final class Counter: @unchecked Sendable {
    private var value: UInt64 = 0
    private let lock = NSLock()
    func next() -> RequestID { lock.withLock { value += 1; return RequestID(value) } }
}
