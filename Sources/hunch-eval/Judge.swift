// Blind LLM judges for the "unrealistic rate": the share of a model's suggestions that clearly
// don't fit the moment. Only for model selection and prompt-framer tuning, never per build: each
// round is three Opus agents started by hand (see eval/judging/README.md).
//
// `judge-export` turns rating pages into anonymous sets (suggestions lettered and shuffled
// differently per judge, no model names) plus a separate key. `judge-report` reads the judges'
// scores back through the key and reports per model, and against your own page ratings if present.
import Foundation

/// The data a rating page embeds (`ratingPage`).
struct PageData: Decodable {
    struct Card: Decodable { var key: String; var text: String; var models: [Int] }
    struct Item: Decodable { var id: String; var app: String; var place: String; var screen: String; var before: String; var cards: [Card] }
    var runID: String
    var models: [String]
    var items: [Item]
}

func loadPageData(_ path: String) throws -> PageData {
    guard let html = try? String(contentsOfFile: path, encoding: .utf8) else { throw EvalError("cannot read \(path)") }
    let open = #"<script id="data" type="application/json">"#
    guard let start = html.range(of: open), let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
        throw EvalError("\(path) is not a rating page")
    }
    let json = html[start.upperBound..<end.lowerBound].replacingOccurrences(of: "<\\/", with: "</")
    return try JSONDecoder().decode(PageData.self, from: Data(json.utf8))
}

private struct JudgeMoment: Encodable {
    var moment: Int
    var app: String
    var place: String
    var on_screen: String
    var typed_so_far: String
    var candidates: [String: String]
}

private struct JudgeKeyEntry: Codable { var judge: Int; var moment: Int; var label: String; var card: String }

private struct JudgeManifest: Codable {
    var pages: [String]
    var judges: Int
    var models: [String]
}

func runJudgeExportCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--pages", "--out", "--judges", "--writer-samples", "--profile", "--seed"])
    let pages = parsed.values("--pages")
    guard !pages.isEmpty, let out = parsed.value("--out") else {
        printErr("usage: hunch-eval judge-export --pages <rate.html>... --out eval/local/judging/<name> [--judges 3] "
            + "[--writer-samples eval/local/replay-history.jsonl] [--profile eval/replay/profiles/full.json] [--seed 100]")
        return ExitCode.usage
    }
    guard out.hasPrefix("eval/local/") else {
        printErr("judge-export writes your saved sentences into the sets: --out must be under eval/local/ (git-ignored)")
        return ExitCode.usage
    }
    let judges = parsed.value("--judges").flatMap(Int.init) ?? 3
    let seed = parsed.value("--seed").flatMap(UInt64.init) ?? 100
    do {
        let data = try pages.map(loadPageData)
        guard Set(data.map(\.models)).count == 1 else { throw EvalError("pages must compare the same models in the same order") }
        // Moments: every item with at least one suggestion, card ids prefixed by page.
        var moments: [(item: PageData.Item, page: Int)] = []
        for (p, page) in data.enumerated() { for item in page.items where !item.cards.isEmpty { moments.append((item, p + 1)) } }

        let sets = out + "/sets"
        try FileManager.default.createDirectory(atPath: sets, withIntermediateDirectories: true)
        var key: [JudgeKeyEntry] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        for judge in 1...judges {
            var rng = SplitMix64(seed: seed + UInt64(judge))
            var order = Array(moments.indices)
            for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            var lines: [String] = []
            for (n, index) in order.enumerated() {
                let (item, page) = moments[index]
                var cardOrder = Array(item.cards.indices)
                for i in stride(from: cardOrder.count - 1, to: 0, by: -1) { cardOrder.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
                var candidates: [String: String] = [:]
                for (slot, card) in cardOrder.enumerated() {
                    let label = String(UnicodeScalar(UInt8(65 + slot)))
                    candidates[label] = item.cards[card].text
                    key.append(JudgeKeyEntry(judge: judge, moment: n + 1, label: label, card: "p\(page):\(item.cards[card].key)"))
                }
                let moment = JudgeMoment(moment: n + 1, app: item.app, place: item.place, on_screen: item.screen,
                                         typed_so_far: item.before, candidates: candidates)
                lines.append(String(decoding: try encoder.encode(moment), as: UTF8.self))
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: "\(sets)/set-\(judge).jsonl", atomically: true, encoding: .utf8)
        }

        // Who the writer is: the profile's about-me and a dozen of their own saved sentences.
        let profilePath = parsed.value("--profile") ?? "eval/replay/profiles/full.json"
        let about = (FileManager.default.contents(atPath: profilePath)).flatMap { try? JSONDecoder().decode(ReplayProfile.self, from: $0) }?.about
        var samples: [String] = []
        let samplesPath = parsed.value("--writer-samples") ?? "eval/local/replay-history.jsonl"
        if let cases = try? loadReplayCases(samplesPath) {
            var rng = SplitMix64(seed: seed)
            var texts = cases.map(\.text)
            for i in stride(from: texts.count - 1, to: 0, by: -1) { texts.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            samples = Array(texts.prefix(12))
        }
        let writer: [String: AnyEncodable] = ["about": AnyEncodable(about ?? ""), "samples": AnyEncodable(samples)]
        try encoder.encode(writer).write(to: URL(fileURLWithPath: "\(sets)/writer.json"))
        // The key and manifest sit outside sets/, the only folder the judges are told to read.
        try encoder.encode(key).write(to: URL(fileURLWithPath: "\(out)/key.json"))
        try encoder.encode(JudgeManifest(pages: pages, judges: judges, models: data[0].models))
            .write(to: URL(fileURLWithPath: "\(out)/manifest.json"))
        let suggestions = moments.reduce(0) { $0 + $1.item.cards.count }
        printOut("wrote \(judges) anonymous sets of \(moments.count) moments, \(suggestions) suggestions each, to \(sets)/")
        printOut("next: start \(judges) Opus judges with eval/judging/judge-prompt.md (one per set), each writing "
            + "\(out)/judge-<n>.jsonl, then: hunch-eval judge-report --dir \(out)")
        return ExitCode.ok
    } catch {
        printErr("judge-export: \(error)")
        return ExitCode.failure
    }
}

/// Encodes heterogeneous dictionary values.
struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

// MARK: - Report

/// Spearman rank correlation (average ranks for ties).
func spearman(_ a: [Double], _ b: [Double]) -> Double? {
    guard a.count == b.count, a.count > 2 else { return nil }
    func ranks(_ x: [Double]) -> [Double] {
        let order = x.indices.sorted { x[$0] < x[$1] }
        var r = Array(repeating: 0.0, count: x.count)
        var i = 0
        while i < order.count {
            var k = i
            while k + 1 < order.count, x[order[k + 1]] == x[order[i]] { k += 1 }
            for t in i...k { r[order[t]] = Double(i + k) / 2 }
            i = k + 1
        }
        return r
    }
    let ra = ranks(a), rb = ranks(b)
    let ma = ra.reduce(0, +) / Double(ra.count), mb = rb.reduce(0, +) / Double(rb.count)
    var num = 0.0, da = 0.0, db = 0.0
    for i in ra.indices {
        num += (ra[i] - ma) * (rb[i] - mb)
        da += (ra[i] - ma) * (ra[i] - ma)
        db += (rb[i] - mb) * (rb[i] - mb)
    }
    return da > 0 && db > 0 ? num / (da * db).squareRoot() : nil
}

/// A judge average at or below this counts as "rated low" (mostly 2s and 1s).
let judgeLowThreshold = 2.34

func runJudgeReportCommand(_ args: [String]) async -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--dir"])
    guard let dir = parsed.value("--dir") else {
        printErr("usage: hunch-eval judge-report --dir eval/local/judging/<name>")
        return ExitCode.usage
    }
    do {
        guard let manifestData = FileManager.default.contents(atPath: "\(dir)/manifest.json"),
              let keyData = FileManager.default.contents(atPath: "\(dir)/key.json") else {
            throw EvalError("\(dir) has no manifest.json/key.json: run judge-export first")
        }
        let manifest = try JSONDecoder().decode(JudgeManifest.self, from: manifestData)
        let key = Dictionary(try JSONDecoder().decode([JudgeKeyEntry].self, from: keyData)
            .map { ("\($0.judge)/\($0.moment)/\($0.label)", $0.card) }, uniquingKeysWith: { a, _ in a })
        let pages = try manifest.pages.map(loadPageData)
        var cardModels: [String: [Int]] = [:]
        var cardMoment: [String: String] = [:]
        for (p, page) in pages.enumerated() {
            for item in page.items {
                for card in item.cards {
                    cardModels["p\(p + 1):\(card.key)"] = card.models
                    cardMoment["p\(p + 1):\(card.key)"] = "p\(p + 1):\(item.id)"
                }
            }
        }

        struct Score: Decodable { var moment: Int; var label: String; var score: Int; var reason: String? }
        var judgeScores: [Int: [String: Double]] = [:]
        var problems: [String] = []
        for judge in 1...manifest.judges {
            let path = "\(dir)/judge-\(judge).jsonl"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { problems.append("judge \(judge): no \(path)"); continue }
            var scores: [String: Double] = [:]
            var reasons = Set<String>()
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let s = try? JSONDecoder().decode(Score.self, from: Data(line.utf8)),
                      let card = key["\(judge)/\(s.moment)/\(s.label)"], (1...5).contains(s.score) else {
                    problems.append("judge \(judge): unreadable line \(line.prefix(60))")
                    continue
                }
                scores[card] = Double(s.score)
                if let r = s.reason { reasons.insert(r) }
            }
            if scores.count < cardModels.count { problems.append("judge \(judge): \(scores.count) of \(cardModels.count) suggestions scored") }
            // A judge that writes the same few reasons everywhere didn't read the moments.
            if Double(reasons.count) < Double(scores.count) * 0.5 {
                problems.append("judge \(judge): only \(reasons.count) distinct reasons for \(scores.count) scores; it may not have read each moment")
            }
            judgeScores[judge] = scores
        }
        let judgesDone = judgeScores.keys.sorted()
        guard !judgesDone.isEmpty else { throw EvalError("no judge output in \(dir)") }
        let cards = cardModels.keys.filter { c in judgesDone.allSatisfy { judgeScores[$0]?[c] != nil } }.sorted()
        let avg = Dictionary(uniqueKeysWithValues: cards.map { c in
            (c, judgesDone.map { judgeScores[$0]![c]! }.reduce(0, +) / Double(judgesDone.count))
        })

        // Your own ratings, from each page's ratings.json (first showings only).
        var user: [String: Double] = [:]
        for (p, path) in manifest.pages.enumerated() {
            let ratingsPath = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ratings.json")
            guard let data = FileManager.default.contents(atPath: ratingsPath),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ratings = object["ratings"] as? [String: Any] else { continue }
            for (k, v) in ratings where !k.hasPrefix("r:") {
                if let n = v as? NSNumber { user["p\(p + 1):\(k)"] = n.doubleValue }
            }
        }

        var md = "# Judge report\n\n"
        md += "- pages: " + manifest.pages.map { "`\($0)`" }.joined(separator: ", ") + "\n"
        md += "- judges: \(judgesDone.count) of \(manifest.judges); \(cards.count) suggestions scored by all of them\n"
        md += "- rated low = judges' average ≤ " + String(format: "%.2f", judgeLowThreshold)
            + " (mostly 2s and 1s): clearly unrealistic for the moment. Close calls are left to your own ratings.\n"
        if !problems.isEmpty { md += "\n**Problems**\n\n" + problems.map { "- \($0)" }.joined(separator: "\n") + "\n" }

        md += "\n## Per model\n\n| model | suggestions | rated low by judges | judges' mean |"
            + (user.isEmpty ? "" : " you 1–2 | your mean |") + "\n|---|---|---|---|" + (user.isEmpty ? "" : "---|---|") + "\n"
        var rows: [(String, Double, String)] = []
        for (m, name) in manifest.models.enumerated() {
            let mine = cards.filter { cardModels[$0]?.contains(m) ?? false }
            guard !mine.isEmpty else { continue }
            let low = Double(mine.filter { avg[$0]! <= judgeLowThreshold }.count) / Double(mine.count)
            let mean = mine.map { avg[$0]! }.reduce(0, +) / Double(mine.count)
            var row = "| \(name) | \(mine.count) | **" + String(format: "%.0f %%", low * 100) + "** | " + String(format: "%.2f", mean) + " |"
            let rated = mine.compactMap { user[$0] }
            if !user.isEmpty {
                row += rated.isEmpty ? " – | – |"
                    : String(format: " %.0f %% | %.2f |", Double(rated.filter { $0 <= 2 }.count) * 100 / Double(rated.count),
                             rated.reduce(0, +) / Double(rated.count))
            }
            rows.append((name, low, row))
        }
        md += rows.sorted { $0.1 < $1.1 }.map(\.2).joined(separator: "\n") + "\n"

        md += "\n## Judges\n\n"
        for (i, a) in judgesDone.enumerated() {
            for b in judgesDone[(i + 1)...] {
                if let r = spearman(cards.map { judgeScores[a]![$0]! }, cards.map { judgeScores[b]![$0]! }) {
                    md += String(format: "- judge %d vs %d: rank correlation %.2f\n", a, b, r)
                }
            }
        }
        let shared = cards.filter { user[$0] != nil }
        if shared.count > 2 {
            md += "\n## Against your ratings (\(shared.count) suggestions)\n\n"
            if let r = spearman(shared.map { user[$0]! }, shared.map { avg[$0]! }) {
                md += String(format: "- rank correlation, judges' average vs you: %.2f\n", r)
            }
            // Agreement by size of your gap: big gaps are where judges should match you.
            var byMoment: [String: [String]] = [:]
            for c in shared { byMoment[cardMoment[c]!, default: []].append(c) }
            func concordance(_ test: (Double) -> Bool) -> String {
                var same = 0, total = 0
                for group in byMoment.values {
                    for i in group.indices { for j in group.indices where j > i {
                        let du = user[group[i]]! - user[group[j]]!, dj = avg[group[i]]! - avg[group[j]]!
                        guard du != 0, dj != 0, test(abs(du)) else { continue }
                        total += 1
                        if (du > 0) == (dj > 0) { same += 1 }
                    } }
                }
                return total > 0 ? "\(same) of \(total) (" + String(format: "%.0f %%", Double(same) * 100 / Double(total)) + ")" : "–"
            }
            md += "- pairs in the same moment ordered the same way, your gap 2+ points: \(concordance { $0 >= 2 }); "
                + "1 point: \(concordance { $0 == 1 })\n"
            let yourLow = shared.filter { user[$0]! <= 2 }
            if !yourLow.isEmpty {
                md += String(format: "- of your 1–2 ratings, judges also rated low: %.0f %%\n",
                             Double(yourLow.filter { avg[$0]! <= judgeLowThreshold }.count) * 100 / Double(yourLow.count))
            }
        }
        try md.write(toFile: "\(dir)/judge-report.md", atomically: true, encoding: .utf8)
        printOut(md)
        printErr("report: \(dir)/judge-report.md")
        return problems.isEmpty ? ExitCode.ok : ExitCode.failure
    } catch {
        printErr("judge-report: \(error)")
        return ExitCode.failure
    }
}
