// What the engines hand the diagnostic console. Everything here runs only while the console window is
// open (`DiagnosticRecorder.shared.isEnabled`); with it closed none of it is built. Observation only:
// nothing here changes a prompt, a search or a result.
import Foundation
import HunchCore
import HunchDecode
import HunchPrompt
import HunchText
import Synchronization

/// The prompt and the text so far of one request, collected inside the executor job for the console.
final class PromptCapture: Sendable {
    private struct State {
        var prompt: DiagnosticPrompt?
        var partial: String?
    }
    private let state = Mutex(State())

    var prompt: DiagnosticPrompt? { state.withLock { $0.prompt } }
    var partial: String? { state.withLock { $0.partial } }
    func set(prompt: DiagnosticPrompt) { state.withLock { $0.prompt = prompt } }
    func set(partial: String) { state.withLock { $0.partial = partial } }
}

enum DiagnosticCapture {
    /// The prompt as framed (already redacted by the framer), with what the sync reused.
    static func prompt(_ framed: FramedPrompt, promptTokens: Int, budget: Int?, report: PromptSyncReport?) -> DiagnosticPrompt {
        DiagnosticPrompt(
            framerID: framed.framerID, requiredPrefix: framed.requiredPrefix,
            segments: framed.segments.map {
                DiagnosticPromptSegment(text: $0.text, label: $0.label, isControl: $0.kind == .control)
            },
            promptTokens: promptTokens, budget: budget, decodedTokens: report?.decodedTokens,
            reusedTokens: report?.reusedTokens, notes: framed.budgetNotes)
    }

    private static func place(_ request: CompletionRequest) -> (app: String?, domain: String?, title: String?) {
        (request.input.appName ?? request.context.app.localizedName, request.context.urlHost ?? request.input.domain,
         request.input.windowTitle)
    }

    private static func sections(_ request: CompletionRequest, prompt: DiagnosticPrompt?, model: String?) -> [DiagnosticSection] {
        var all = DiagnosticSections.forInput(request.input, bias: request.bias, notes: request.learnedNotes)
        var framer: [DiagnosticSection.Item] = []
        if let prompt { framer.append(.init("Framer", prompt.framerName)) }
        if let model { framer.append(.init("Model", model)) }
        all.insert(DiagnosticSection("Framer and model", framer), at: 1)
        all.append(DiagnosticSections.budget(prompt))
        return all
    }

    /// A finished request (or its search result). `trace` holds the post-processor's notes.
    static func record(_ request: CompletionRequest, found: Searched, outcome: PostOutcome, alternatives: [String],
                       trace: DefaultPostProcessor.Trace?, timings: CompletionTimings, decode: DecodeConfig,
                       floor: Float?, model: String) -> DiagnosticRecord {
        let best = found.scored.first
        let generated = best?.untrimmedText ?? best?.candidate.text ?? found.lastPartial ?? ""
        let tokens = best?.spans.map { DiagnosticToken(byteCount: $0.byteCount, logProb: $0.logProb) } ?? []
        var trim: (kept: String, facts: ConfidenceTrimFacts)?
        if let best, let untrimmed = best.untrimmedText,
           let facts = ConfidenceTrim.explain(untrimmed: untrimmed, kept: best.candidate.text, spans: best.spans,
                                              dropLogProb: decode.trimDropLogProb, window: decode.trimWindow) {
            trim = (best.candidate.text, facts)
        }
        var shown: String?
        var fate = DiagnosticFate.pending
        switch outcome {
        case .show(let text): shown = text
        case .suppress(let reason):
            var detail: String?
            if reason == .lowConfidence, let best {
                let mean = best.candidate.meanLogProb, first = best.spans.first?.logProb
                switch ConfidenceFloor.check(text: best.candidate.text, mean: mean, firstLogProb: first,
                                             midWord: ConfidenceFloor.isMidWord(requiredPrefix: Array(found.requiredPrefix.utf8)),
                                             config: decode) {
                case .firstToken(let limit)?:
                    let f = first ?? 0
                    detail = "first word starts at \(CutReason.log(f)) (\(CutReason.percent(f))), "
                        + "word-start floor \(CutReason.log(limit)) (\(CutReason.percent(limit)))"
                case .mean(let limit)?:
                    detail = "average \(CutReason.log(mean)) (\(CutReason.percent(mean))) "
                        + "per token, floor \(CutReason.log(limit)) (\(CutReason.percent(limit)))"
                case nil:
                    let limit = floor ?? decode.minMeanLogProb
                    detail = "average \(CutReason.log(mean)) (\(CutReason.percent(mean))) "
                        + "per token, floor \(CutReason.log(limit)) (\(CutReason.percent(limit)))"
                }
            }
            fate = .suppressed(reason, detail: detail)
        }
        let stop = best?.candidate.stop
        let stopText = stop.map { $0 == .confidenceTrim ? nil : "The model stopped because \($0.plainWords)." } ?? nil
        let output = DiagnosticWords.output(
            generated: generated, tokens: tokens, trim: trim, postCuts: trace?.cuts ?? [], shown: shown,
            stopText: stopText, meanLogProb: best?.candidate.meanLogProb, alternatives: alternatives)
        let place = place(request)
        var sections = sections(request, prompt: found.prompt, model: model)
        // Learned words in what was shown, and a learned word the finished-word check refused.
        var extra: [DiagnosticSection.Item] = []
        if let shown, let line = DiagnosticSections.learnedInSuggestion(before: request.input.before, shown: shown,
                                                                         input: request.input, notes: request.learnedNotes,
                                                                         bias: request.bias) {
            extra.append(.init("Learned words in the suggestion", line))
        }
        if case .suppress(.likelyTypo) = outcome,
           let line = DiagnosticSections.mangledLearnedWord(before: request.input.before, generated: generated,
                                                            learned: LocalCompletionEngine.learnedWords(input: request.input, bias: request.bias)) {
            extra.append(.init("Finished-word check", line))
        }
        if !extra.isEmpty, let i = sections.firstIndex(where: { $0.title == "Learned words and phrases" }) {
            sections[i].items += extra
        }
        return DiagnosticRecord(
            requestKey: request.id.raw, kind: .suggestion, appName: place.app, domain: place.domain,
            windowTitle: place.title, model: model, servePath: found.path.rawValue,
            sections: sections, prompt: found.prompt, output: output,
            fate: fate, timing: DiagnosticTiming(timings),
            note: trace?.prefaceEcho == true ? "PrefaceEcho blocked this: it repeated the prompt's own wording." : nil)
    }

    /// A request answered from the result cache: the model did not run.
    static func cacheHit(_ request: CompletionRequest, outcome: PostOutcome, rawText: String, timings: CompletionTimings,
                         model: String) -> DiagnosticRecord {
        var fate = DiagnosticFate.pending
        if case .suppress(let reason) = outcome { fate = .suppressed(reason, detail: nil) }
        let place = place(request)
        return DiagnosticRecord(
            requestKey: request.id.raw, kind: .suggestion, appName: place.app, domain: place.domain,
            windowTitle: place.title, model: model, servePath: ServePath.cache.rawValue,
            sections: sections(request, prompt: nil, model: model),
            output: DiagnosticOutput(text: rawText), fate: fate, timing: DiagnosticTiming(timings),
            note: "Served from the result cache: the model did not run for this request, so there is no prompt "
                + "and no per-word confidence here. The text is what the cache kept.")
    }

    /// A request that ended before it finished (a newer keystroke cancelled it, or it failed).
    static func interrupted(_ request: CompletionRequest, prompt: DiagnosticPrompt?, partial: String?, error: any Error,
                            model: String) -> DiagnosticRecord {
        let cancelled = error is CancellationError
        let place = place(request)
        return DiagnosticRecord(
            requestKey: request.id.raw, kind: .suggestion, appName: place.app, domain: place.domain,
            windowTitle: place.title, model: model,
            sections: sections(request, prompt: prompt, model: model), prompt: prompt,
            output: partial.map { DiagnosticOutput(text: $0) },
            fate: cancelled ? .cancelled : .notApplicable,
            note: cancelled ? "Cancelled while the model was working. The text, if any, is what it had written so far."
                : "The request failed: \(String(describing: error))")
    }
}
