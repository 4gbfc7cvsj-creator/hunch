// CSV and Markdown rendering plus the per-cell metrics.
import Foundation

struct CellInfo {
    var model: String
    var config: String
    var framer: String
    var requestedFramer: String
    var isInstruct: Bool
    var addBOSOverride: Bool?
    var usesInstructions: Bool
}

struct CellMetrics {
    var info: CellInfo
    var traps = 0
    var trapsAIRaw = 0
    var trapsAIShown = 0
    var trapsShown = 0
    var allCold = 0
    var allAIRaw = 0
    var suppressed = 0
    var reasons: [String: Int] = [:]
    var expectCount = 0
    var matchShown = 0
    var matchRaw = 0
    var errors = 0
    var nondeterministic = 0
    var coldFV: [Double] = [], coldTotal: [Double] = [], replayFV: [Double] = [], replayTotal: [Double] = []
    var replayTokens: [Double] = []
    var replayPaths: [String: Int] = [:]
    var coldPaths: [String: Int] = [:]
}

func computeMetrics(rows: [ResultRow], info: CellInfo) -> CellMetrics {
    var m = CellMetrics(info: info)
    let mine = rows.filter { $0.model == info.model && $0.config == info.config }
    var rawByKey: [String: String] = [:]
    for row in mine {
        if row.error != nil { m.errors += 1 }
        if row.pass == "cold" {
            // Determinism check across repeats of the same phrase.
            if let prior = rawByKey[row.phraseID], prior != row.raw { m.nondeterministic += 1 }
            rawByKey[row.phraseID] = row.raw
            m.coldFV += row.firstVisibleMs.map { [$0] } ?? []
            m.coldTotal += row.totalMs.map { [$0] } ?? []
            m.coldPaths[row.path, default: 0] += 1
        } else {
            m.replayFV += row.firstVisibleMs.map { [$0] } ?? []
            m.replayTotal += row.totalMs.map { [$0] } ?? []
            m.replayTokens += row.decodedPromptTokens.map { [Double($0)] } ?? []
            m.replayPaths[row.path, default: 0] += 1
        }
    }
    // Rate metrics use the cold pass of the first repeat only.
    for row in mine where row.pass == "cold" && row.repeatIndex == 0 && row.error == nil {
        m.allCold += 1
        if row.aiRaw { m.allAIRaw += 1 }
        if row.suppressed {
            m.suppressed += 1
            m.reasons[row.suppressReason ?? "unknown", default: 0] += 1
        }
        if row.aiTrap {
            m.traps += 1
            if row.aiRaw { m.trapsAIRaw += 1 }
            if row.aiShown { m.trapsAIShown += 1 }
            if !row.suppressed { m.trapsShown += 1 }
        }
        if row.hasExpect {
            m.expectCount += 1
            if row.matchShown { m.matchShown += 1 }
            if row.matchRaw { m.matchRaw += 1 }
        }
    }
    return m
}

func renderCSV(_ rows: [ResultRow]) -> String {
    var out = "model,config,framer,phrase_id,pass,repeat,tags,ai_trap,before,raw,final,suppress_reason,ai_raw,ai_shown,"
        + "has_expect,match_final,match_raw,first_visible_ms,total_ms,framing_ms,prompt_sync_ms,decoded_prompt_tokens,"
        + "serve_path,error,style_snippets,style_copy\n"
    for r in rows {
        let cols: [String] = [
            r.model, r.config, r.framer, r.phraseID, r.pass, String(r.repeatIndex), r.tags.joined(separator: "|"),
            String(r.aiTrap), r.before, r.raw, r.shown ?? "", r.suppressReason ?? "", String(r.aiRaw), String(r.aiShown),
            String(r.hasExpect), String(r.matchShown), String(r.matchRaw),
            r.firstVisibleMs.map { String(format: "%.1f", $0) } ?? "", r.totalMs.map { String(format: "%.1f", $0) } ?? "",
            r.framingMs.map { String(format: "%.1f", $0) } ?? "", r.syncMs.map { String(format: "%.1f", $0) } ?? "",
            r.decodedPromptTokens.map(String.init) ?? "", r.path, r.error ?? "", String(r.styleInjected), String(r.styleCopy),
        ]
        out += cols.map(csvEscape).joined(separator: ",") + "\n"
    }
    return out
}

private func pair(_ a: Double?, _ b: Double?) -> String { "\(fmtMs(a))/\(fmtMs(b))" }

func renderReport(rows: [ResultRow], cells: [CellInfo], phraseCount: Int, options: RunOptions) -> String {
    let metrics = cells.map { computeMetrics(rows: rows, info: $0) }
    var md = "# hunch-eval report\n\n"
    md += "- typo check: \(options.typoCheck ? "on" : "OFF (--no-typo-check)")\n- generated: \(timestampString())\n- phrases: \(phraseCount) (repeat \(options.repeats)"
    md += options.quick ? ", --quick" : ""
    md += options.subset.map { ", subset \($0)" } ?? ""
    md += ")\n- runtime: n_ctx \(evalRuntimeOptions.contextTokens), mmap, all layers on Metal; greedy decoding\n"
    md += "- rate metrics use the first repeat's cold pass; latency uses every pass. \"cold\" is a new phrase on a warm "
        + "engine (shared prefix may be reused); \"replay\" re-runs after 1-3 characters of the suggestion were typed.\n"
    md += "- AI-voice raw = classifier verdict on the raw candidate before post-processing; shown = classifier on what "
        + "the post-processor let through; trap shown = share of traps where any suggestion was displayed.\n\n"

    md += "## Headline\n\n"
    md += "| model | config | framer | AI raw (traps) | AI shown (traps) | trap shown | suppression | first-word match | "
        + "FV p50/p95 replay (ms) | total p50 replay (ms) |\n|---|---|---|---|---|---|---|---|---|---|\n"
    for m in metrics {
        md += "| \(m.info.model) | \(m.info.config) | \(m.info.framer)\(m.info.framer != m.info.requestedFramer && m.info.requestedFramer != "auto" ? " (fallback from \(m.info.requestedFramer))" : "") "
            + "| \(fmtPct(m.trapsAIRaw, m.traps)) | \(fmtPct(m.trapsAIShown, m.traps)) | \(fmtPct(m.trapsShown, m.traps)) "
            + "| \(fmtPct(m.suppressed, m.allCold)) | \(fmtPct(m.matchShown, m.expectCount)) "
            + "| \(pair(percentile(m.replayFV, 0.5), percentile(m.replayFV, 0.95))) "
            + "| \(fmtMs(percentile(m.replayTotal, 0.5))) |\n"
    }

    md += "\n## Details per model x config\n"
    for m in metrics {
        md += "\n### \(m.info.model) x \(m.info.config)\n\n"
        md += "- framer \(m.info.framer); \(m.info.isInstruct ? "instruct" : "base") weights"
        md += "; custom instructions: \(m.info.usesInstructions ? "yes" : "no")"
        md += "; addBOS override: \(m.info.addBOSOverride.map { "\($0)" } ?? "auto")\n"
        md += "- AI voice on all phrases (raw): \(fmtPct(m.allAIRaw, m.allCold)); on traps raw \(m.trapsAIRaw)/\(m.traps), shown \(m.trapsAIShown)/\(m.traps)\n"
        let reasons = m.reasons.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        md += "- suppressed \(m.suppressed)/\(m.allCold)\(reasons.isEmpty ? "" : " (\(reasons))")\n"
        md += "- first-word match: final \(m.matchShown)/\(m.expectCount), raw \(m.matchRaw)/\(m.expectCount)\n"
        md += "- decoded prompt tokens on replay: p50 \(fmtMs(percentile(m.replayTokens, 0.5))), p95 \(fmtMs(percentile(m.replayTokens, 0.95))), "
            + "mean \(m.replayTokens.isEmpty ? "-" : String(format: "%.1f", m.replayTokens.reduce(0, +) / Double(m.replayTokens.count)))\n"
        md += "- serve paths cold: \(m.coldPaths.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")); "
            + "replay: \(m.replayPaths.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        if options.repeats > 1 { md += "- nondeterministic phrases across repeats: \(m.nondeterministic)\n" }
        if m.errors > 0 { md += "- request errors: \(m.errors)\n" }
        md += "\n| pass | FV p50 | FV p95 | total p50 | total p95 |\n|---|---|---|---|---|\n"
        md += "| cold | \(fmtMs(percentile(m.coldFV, 0.5))) | \(fmtMs(percentile(m.coldFV, 0.95))) | \(fmtMs(percentile(m.coldTotal, 0.5))) | \(fmtMs(percentile(m.coldTotal, 0.95))) |\n"
        md += "| replay | \(fmtMs(percentile(m.replayFV, 0.5))) | \(fmtMs(percentile(m.replayFV, 0.95))) | \(fmtMs(percentile(m.replayTotal, 0.5))) | \(fmtMs(percentile(m.replayTotal, 0.95))) |\n"

        let traps = rows.filter { $0.model == m.info.model && $0.config == m.info.config && $0.pass == "cold"
            && $0.repeatIndex == 0 && $0.aiTrap }
        if !traps.isEmpty {
            md += "\nTraps (cold):\n\n| id | before | raw | final | AI raw |\n|---|---|---|---|---|\n"
            for t in traps {
                md += "| \(t.phraseID) | \(mdEscape(t.before)) | \(mdEscape(t.raw)) | \(mdEscape(t.shown ?? "(\(t.suppressReason ?? "-"))")) | \(t.aiRaw ? "yes" : "no") |\n"
            }
        }
    }

    // BOS comparison: same model, config with addBOS override vs the same config without.
    let overridden = cells.filter { $0.addBOSOverride != nil }
    for o in overridden {
        guard let baseCell = cells.first(where: { $0.model == o.model && $0.addBOSOverride == nil
            && $0.framer == o.framer && $0.usesInstructions == o.usesInstructions }) else { continue }
        let a = rows.filter { $0.model == o.model && $0.config == baseCell.config && $0.pass == "cold" && $0.repeatIndex == 0 }
        let b = rows.filter { $0.model == o.model && $0.config == o.config && $0.pass == "cold" && $0.repeatIndex == 0 }
        let bByID = Dictionary(b.map { ($0.phraseID, $0) }, uniquingKeysWith: { x, _ in x })
        var differ = 0, comparable = 0
        var examples: [String] = []
        for r in a {
            guard let other = bByID[r.phraseID] else { continue }
            comparable += 1
            if other.raw != r.raw {
                differ += 1
                if examples.count < 8 {
                    examples.append("- \(r.phraseID): bos=\(mdEscape(r.raw)) | nobos=\(mdEscape(other.raw))")
                }
            }
        }
        let ma = metrics.first { $0.info.model == o.model && $0.info.config == baseCell.config }
        let mb = metrics.first { $0.info.model == o.model && $0.info.config == o.config }
        md += "\n## BOS comparison: \(baseCell.config) vs \(o.config) on \(o.model)\n\n"
        md += "- raw continuation differs on \(differ)/\(comparable) phrases\n"
        if let ma, let mb {
            md += "- first-word match: \(ma.matchShown)/\(ma.expectCount) (auto BOS) vs \(mb.matchShown)/\(mb.expectCount) (override)\n"
            md += "- AI raw on traps: \(ma.trapsAIRaw)/\(ma.traps) vs \(mb.trapsAIRaw)/\(mb.traps); suppressed \(ma.suppressed) vs \(mb.suppressed)\n"
        }
        md += examples.joined(separator: "\n") + "\n"
    }

    md += renderM3Sections(rows: rows, cells: cells)

    md += "\n## Notes\n\nPer-phrase raw and final text are in results.csv (one row per phrase and pass). "
        + "Custom-instructions content is never written to reports.\n"
    return md
}
