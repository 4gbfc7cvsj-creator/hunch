// interface-review: which screen lines the interface filter would drop from replay cases, as a
// local HTML page to check by eye that no real message text goes.
import Foundation
import HunchScreen

func runInterfaceReviewCommand(_ args: [String]) -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--cases", "--out"])
    let casesPath = parsed.value("--cases") ?? "eval/local/replay-long-real.jsonl"
    let outPath = parsed.value("--out") ?? "eval/local/interface-review.html"
    guard parsed.positionals.isEmpty else {
        printErr("usage: hunch-eval interface-review [--cases eval/local/replay-long-real.jsonl] "
                 + "[--out eval/local/interface-review.html]")
        return ExitCode.usage
    }
    do {
        let cases = try loadReplayCases(casesPath)
        var rows: [(id: String, app: String, dropped: [String], kept: [String])] = []
        var totalLines = 0
        for c in cases {
            guard let screen = c.screen, !screen.isEmpty else { continue }
            let out = InterfaceLines.droppingTrailingRun(screen)
            totalLines += screen.components(separatedBy: "\n").count
            guard !out.dropped.isEmpty else { continue }
            // The last kept lines show where the run stopped.
            let kept = Array(out.text.components(separatedBy: "\n").suffix(4))
            rows.append((c.id, [c.app, c.domain].compactMap { $0 }.joined(separator: " · "), out.dropped, kept))
        }
        let droppedTotal = rows.reduce(0) { $0 + $1.dropped.count }
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Interface lines review</title>
        <style>
        body{font:14px -apple-system,sans-serif;margin:24px;max-width:960px;color:#222;background:#fff}
        @media (prefers-color-scheme: dark){body{color:#ddd;background:#1b1b1b}.kept{color:#999}}
        .case{border-top:1px solid #8884;padding:10px 0}.id{font-weight:600}.app{color:#888;margin-left:8px}
        pre{margin:4px 0;white-space:pre-wrap;font:12px ui-monospace,monospace}
        .kept{color:#666}.drop{color:#c33;text-decoration:line-through}
        </style></head><body>
        <h1>Interface lines the filter drops</h1>
        <p>\(cases.count) cases from <code>\(escape(casesPath))</code>, \(totalLines) screen lines.
        <b>\(droppedTotal)</b> lines dropped in <b>\(rows.count)</b> cases. Grey: the last lines kept (where the scan
        stopped). Red: dropped. Check that no red line is real message text.</p>
        """
        for r in rows {
            html += "<div class=\"case\"><span class=\"id\">\(escape(r.id))</span><span class=\"app\">\(escape(r.app))</span>"
            html += "<pre class=\"kept\">\(escape(r.kept.joined(separator: "\n")))</pre>"
            html += "<pre class=\"drop\">\(escape(r.dropped.joined(separator: "\n")))</pre></div>\n"
        }
        html += "</body></html>\n"
        try html.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("interface-review: \(droppedTotal) lines dropped in \(rows.count) of \(cases.count) cases -> \(outPath)")
        return ExitCode.ok
    } catch {
        printErr("interface-review: \(error)")
        return ExitCode.failure
    }
}

private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
