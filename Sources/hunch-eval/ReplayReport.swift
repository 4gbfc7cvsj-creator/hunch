// `replay` output: the markdown report, the CSVs and the blind rating page.
import Foundation
import HunchCore

private func pct(_ value: Double) -> String { String(format: "%.1f %%", value * 100) }
private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "–" }

/// Totals over a set of case results.
struct ReplayTotals {
    var characters = 0
    var keys = 0
    var acceptKeys = 0
    var acceptedChars = 0
    var requests = 0
    var shown = 0
    var helped = 0
    var aiShown = 0
    var requestMs: [Double] = []
    var firstMs: [Double] = []
    var decodedPrompt: [Double] = []

    init(_ results: [ReplayCaseResult]) {
        for r in results {
            characters += r.characters
            keys += r.keys
            acceptKeys += r.acceptKeys
            acceptedChars += r.acceptedChars
            requests += r.requests
            shown += r.shown
            helped += r.helped
            aiShown += r.aiShown
            requestMs += r.requestMs
            if let first = r.firstMs { firstMs.append(first) }
            decodedPrompt += r.decodedPrompt.map(Double.init)
        }
    }

    var saved: Double { keystrokesSaved(characters: characters, keys: keys) }
    var wordsPerShown: Double { shown > 0 ? Double(acceptKeys) / Double(shown) : 0 }
    var helpedShare: Double { shown > 0 ? Double(helped) / Double(shown) : 0 }
    var nothingShare: Double { requests > 0 ? Double(requests - shown) / Double(requests) : 0 }
}

func replayReport(runs: [ReplayModelRun], cases: [ReplayCase], profiles: [ReplayProfile], casesPath: String,
                  length: LengthPreset = .medium) -> String {
    var md = "# Replay benchmark\n\n"
    md += "- cases: \(cases.count) from `\(casesPath)`, \(cases.reduce(0) { $0 + $1.text.count }) characters per profile\n"
    md += "- profiles: " + profiles.map { p in
        let on = [p.screen ? "screen" : nil, p.windowTitle ? "window title" : nil, p.clipboard ? "clipboard" : nil,
                  p.about != nil ? "about me" : nil, p.styleExamples > 0 ? "\(p.styleExamples) writing samples" : nil]
            .compactMap { $0 }
        return "**\(p.name)** (app name, surface\(on.isEmpty ? "" : ", " + on.joined(separator: ", ")); languages "
            + p.languages.joined(separator: ", ") + ")"
    }.joined(separator: "; ") + "\n"
    md += "- typist: types each character; accepts a suggestion's next word (one key) whenever it is exactly the next "
        + "text; a typed character the suggestion predicted shrinks it, any other hides it. Requests are awaited one at "
        + "a time (no timing effects); the app's 2-word floor applies. Prompt budget "
        + "\(RuntimeOptions.defaultContextTokens - RuntimeOptions.decodeHeadroom) tokens, \(length.rawValue) length (\(length.minWords)–\(length.maxWords) words).\n"
    md += "- keystrokes saved = 1 − keys pressed / characters in the messages. helped = shown suggestions with at "
        + "least one word accepted; wrong shown = the rest. nothing shown = requests that showed no suggestion.\n"
    md += "- request ms: one awaited request while typing (mostly cache reuse); first in field: the first request "
        + "after the field's prewarm. prompt decoded: prompt tokens a request had to process after the field's "
        + "first (the rest reused from the KV cache), p50/p95.\n\n"

    md += "## Headline\n\n| model | profile | keystrokes saved | words accepted per shown | shown that helped | "
        + "wrong shown | nothing shown | AI voice shown | request p50/p95 ms | first in field p50 ms | prompt decoded p50/p95 |\n"
        + "|---|---|---|---|---|---|---|---|---|---|---|\n"
    for run in runs {
        for profile in profiles {
            let t = ReplayTotals(run.results.filter { $0.profile == profile.name })
            md += "| \(run.model) | \(profile.name) | **\(pct(t.saved))** | " + String(format: "%.2f", t.wordsPerShown)
                + " | \(pct(t.helpedShare)) | \(t.shown - t.helped) | \(pct(t.nothingShare)) | \(t.aiShown) | "
                + "\(ms(percentile(t.requestMs, 0.5)))/\(ms(percentile(t.requestMs, 0.95))) | "
                + "\(ms(percentile(t.firstMs, 0.5))) | "
                + "\(ms(percentile(t.decodedPrompt, 0.5)))/\(ms(percentile(t.decodedPrompt, 0.95))) |\n"
        }
    }

    md += "\n## Memory after the run (mmap load, as the app)\n\n| model | footprint | resident |\n|---|---|---|\n"
    for run in runs {
        md += String(format: "| %@ | %.0f MB | %.0f MB |\n", run.model, run.footprintMB, run.residentMB)
    }
    md += "\nWith mmap, weights count as resident (clean file pages) rather than footprint; "
        + "`hunch-eval memory --mode memory` gives the fully loaded figure.\n"

    // Per surface and tag: keystrokes saved, one table per profile.
    typealias Test = (SurfaceKind, [String]) -> Bool
    let surfaces: [(String, Test)] = SurfaceKind.allCases.filter { s in cases.contains { $0.surface == s } }
        .map { s in ("surface: \(s.rawValue)", { surface, _ in surface == s }) }
    let tags: [(String, Test)] = Array(Set(cases.flatMap { $0.tags ?? [] })).sorted()
        .map { t in ("tag: \(t)", { _, tags in tags.contains(t) }) }
    for profile in profiles {
        md += "\n## Keystrokes saved by kind (\(profile.name))\n\n| | cases | " + runs.map(\.model).joined(separator: " | ")
            + " |\n|---|---|" + String(repeating: "---|", count: runs.count) + "\n"
        for (label, test) in surfaces + tags {
            let n = cases.filter { test($0.surface, $0.tags ?? []) }.count
            md += "| \(label) | \(n) | " + runs.map { run in
                pct(ReplayTotals(run.results.filter { $0.profile == profile.name && test($0.surface, $0.tags) }).saved)
            }.joined(separator: " | ") + " |\n"
        }
    }

    // A few long accepted runs and AI-voice suggestions per model, for a feel of the output.
    for run in runs {
        let mine = run.events.filter { $0.profile == profiles.last?.name }
        let best = mine.sorted { $0.chars > $1.chars }.prefix(5)
        let ai = mine.filter(\.aiVoice).prefix(5)
        md += "\n### \(run.model) (\(profiles.last?.name ?? "")): longest accepted suggestions\n\n"
            + "| case | before | suggestion | accepted words |\n|---|---|---|---|\n"
        for e in best {
            md += "| \(e.caseID) | …\(mdEscape(String(e.before.suffix(40)))) | \(mdEscape(e.suggestion)) | \(e.units) |\n"
        }
        if !ai.isEmpty {
            md += "\nAI voice shown:\n\n| case | before | suggestion |\n|---|---|---|\n"
            for e in ai { md += "| \(e.caseID) | …\(mdEscape(String(e.before.suffix(40)))) | \(mdEscape(e.suggestion)) |\n" }
        }
    }
    return md
}

func replayCSV(_ runs: [ReplayModelRun]) -> String {
    var out = "model,profile,case,surface,tags,characters,keys,saved,accept_keys,accepted_chars,requests,shown,helped,"
        + "ai_shown,first_ms,request_ms_p50\n"
    for run in runs {
        for r in run.results {
            out += [r.model, r.profile, r.caseID, r.surface.rawValue, r.tags.joined(separator: ";"), "\(r.characters)",
                    "\(r.keys)", String(format: "%.4f", keystrokesSaved(characters: r.characters, keys: r.keys)),
                    "\(r.acceptKeys)", "\(r.acceptedChars)", "\(r.requests)", "\(r.shown)", "\(r.helped)",
                    "\(r.aiShown)", ms(r.firstMs), ms(percentile(r.requestMs, 0.5))]
                .map(csvEscape).joined(separator: ",") + "\n"
        }
    }
    return out
}

func replayEventsCSV(_ runs: [ReplayModelRun]) -> String {
    var out = "model,profile,case,before,suggestion,next,accepted_words,accepted_chars,ai_voice\n"
    for run in runs {
        for e in run.events {
            out += [e.model, e.profile, e.caseID, e.before, e.suggestion, e.next, "\(e.units)", "\(e.chars)",
                    e.aiVoice ? "1" : "0"].map(csvEscape).joined(separator: ",") + "\n"
        }
    }
    return out
}

// MARK: - Blind rating page

private struct RatingItem: Encodable {
    var id: String
    var app: String
    var place: String
    var screen: String
    var before: String
    var cards: [RatingCard]
}

private struct RatingCard: Encodable {
    var key: String
    var text: String
    /// Models (by index into `models`) that gave this text.
    var models: [Int]
}

private struct RatingData: Encodable {
    var runID: String
    var profile: String
    var models: [String]
    /// Keystrokes saved per model under the page's profile; nil when the page was made without a replay.
    var saved: [Double?]
    var nothing: [Int]
    var items: [RatingItem]
}

/// A self-contained page: each moment shows its context and the distinct suggestions in shuffled order, rated 1–5,
/// without model names. Each rater gets a random moment order with six hidden repeats near the end;
/// ratings stay in the browser. "Reveal" shows the per-model result next to keystrokes saved, and a
/// drift check (first vs second half of the session, and how the repeated moments were re-rated).
func ratingPage(runs: [ReplayModelRun], cases: [ReplayCase], profileName: String, runID: String) -> String {
    var rng = SplitMix64(seed: 7)
    let byID = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var items: [RatingItem] = []
    var nothing = Array(repeating: 0, count: runs.count)
    let probeCount = runs.map(\.probes.count).min() ?? 0
    for p in 0..<probeCount {
        let probe = runs[0].probes[p]
        guard let c = byID[probe.caseID] else { continue }
        var cards: [String: [Int]] = [:]
        for (m, run) in runs.enumerated() {
            guard let text = run.probes[p].suggestion else { nothing[m] += 1; continue }
            cards[text, default: []].append(m)
        }
        var list = cards.map { RatingCard(key: "", text: $0.key, models: $0.value) }.sorted { $0.text < $1.text }
        for i in stride(from: list.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            list.swapAt(i, j)
        }
        for i in list.indices { list[i].key = "\(p)-\(i)" }
        let place = [c.windowTitle, c.domain].compactMap { $0 }.joined(separator: " · ")
        items.append(RatingItem(id: "\(p)", app: c.app ?? c.surface.rawValue, place: place,
                                screen: c.screen ?? "", before: probe.before, cards: list))
    }
    let saved: [Double?] = runs.map { run in
        let mine = run.results.filter { $0.profile == profileName }
        return mine.isEmpty ? nil : ReplayTotals(mine).saved
    }
    let data = RatingData(runID: runID, profile: profileName, models: runs.map(\.model), saved: saved, nothing: nothing,
                          items: items)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let json = (try? String(decoding: encoder.encode(data), as: UTF8.self)) ?? "{}"
    // Keep the JSON from closing the script element.
    let safe = json.replacingOccurrences(of: "</", with: "<\\/")
    return ratingTemplate.replacingOccurrences(of: "__DATA__", with: safe)
}

private let ratingTemplate = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Blind suggestion rating</title>
<style>
:root { --bg:#fafaf9; --card:#fff; --ink:#1c1917; --muted:#78716c; --line:#e7e5e4; --accent:#2563eb;
        --yes:#16a34a; --part:#ca8a04; --no:#dc2626; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0c0a09; --card:#1c1917; --ink:#f5f5f4; --muted:#a8a29e; --line:#292524; --accent:#60a5fa;
          --yes:#22c55e; --part:#eab308; --no:#f87171; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
main { max-width: 760px; margin: 0 auto; padding: 24px 16px 80px; }
h1 { font-size: 20px; margin: 0 0 4px; }
.sub { color: var(--muted); margin: 0 0 20px; }
.bar { position: sticky; top: 0; background: var(--bg); padding: 10px 0; border-bottom: 1px solid var(--line);
       display: flex; gap: 8px; align-items: center; flex-wrap: wrap; z-index: 1; }
.bar .count { margin-right: auto; color: var(--muted); }
button { font: inherit; border: 1px solid var(--line); background: var(--card); color: var(--ink); border-radius: 8px;
         padding: 6px 12px; cursor: pointer; }
button:hover { border-color: var(--accent); }
.item { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; margin: 16px 0; }
.meta { color: var(--muted); font-size: 13px; margin-bottom: 8px; }
details { margin-bottom: 10px; }
summary { color: var(--muted); font-size: 13px; cursor: pointer; }
pre.screen { white-space: pre-wrap; font: 12px/1.4 ui-monospace, Menlo, monospace; color: var(--muted);
             background: var(--bg); padding: 8px; border-radius: 8px; max-height: 180px; overflow: auto; }
.typed { white-space: pre-wrap; word-break: break-word; }
.ghost { color: var(--muted); opacity: .75; }
.card { display: flex; gap: 12px; align-items: center; border-top: 1px solid var(--line); padding: 10px 0; flex-wrap: wrap; }
.card .text { flex: 1 1 260px; white-space: pre-wrap; word-break: break-word; }
.choices { display: flex; gap: 6px; }
.choices button { min-width: 36px; }
.choices button.on { background: var(--accent); color: #fff; border-color: var(--accent); }
.scale { color: var(--muted); font-size: 12px; }
#result { display: none; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.wrap { overflow-x: auto; }
h2 { font-size: 16px; margin: 16px 0 6px; }
h2:first-child { margin-top: 0; }
</style>
</head>
<body>
<main>
  <h1>Blind suggestion rating</h1>
  <p class="sub">Each block is a moment while typing. The grey text after it is a suggestion; the same text from several
  models is shown once. Rate how likely you would have written it here, from 1 (never) to 5 (exactly what I'd
  write). Model names stay hidden until you press Reveal.</p>
  <div class="bar">
    <span class="count" id="count"></span>
    <button id="reveal">Reveal</button>
    <button id="export">Copy ratings</button>
    <button id="clear">Clear</button>
  </div>
  <section id="result" class="item"></section>
  <div id="items"></div>
</main>
<script id="data" type="application/json">__DATA__</script>
<script>
const data = JSON.parse(document.getElementById('data').textContent);
const storeKey = 'hunch-rating-v3-' + data.runID;
// Moments come back unannounced near the end to measure how steady the scale is.
const REPEATS = 6;
const shuffle = a => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
let state = {};
try { state = JSON.parse(localStorage.getItem(storeKey) || '{}') || {}; } catch (e) { state = {}; }
const save = () => { try { localStorage.setItem(storeKey, JSON.stringify(state)); } catch (e) {} };

function setUp() {
  state.ratings = state.ratings || {};
  state.log = state.log || [];
  if (state.order) return;
  // A new random order per rater, topics mixed. Repeats: moments from the first half, shown again
  // in the last third with their suggestions in reverse order.
  const order = shuffle(data.items.map((_, i) => i)).map(i => ({ item: i, repeat: false }));
  const early = order.slice(0, Math.floor(order.length / 2)).filter(s => data.items[s.item].cards.length > 1);
  const start = Math.ceil(order.length * 2 / 3);
  shuffle(early.slice()).slice(0, REPEATS).forEach(p => {
    const at = start + Math.floor(Math.random() * (order.length - start + 1));
    order.splice(at, 0, { item: p.item, repeat: true });
  });
  state.order = order;
  save();
}
setUp();

const keyOf = (slot, card) => (slot.repeat ? 'r:' : '') + card.key;
const cardsOf = slot => slot.repeat ? data.items[slot.item].cards.slice().reverse() : data.items[slot.item].cards;
const total = () => state.order.reduce((n, s) => n + data.items[s.item].cards.length, 0);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

function render() {
  const root = document.getElementById('items');
  root.textContent = '';
  state.order.forEach((slot, n) => {
    const it = data.items[slot.item];
    const box = el('div', 'item');
    box.appendChild(el('div', 'meta', `${n + 1} of ${state.order.length} · ${it.app}${it.place ? ' · ' + it.place : ''}`));
    if (it.screen) {
      const d = el('details'); d.open = true; d.appendChild(el('summary', null, 'On screen'));
      const pre = el('pre', 'screen', it.screen); d.appendChild(pre); box.appendChild(d);
      requestAnimationFrame(() => { pre.scrollTop = pre.scrollHeight; });
    }
    if (!it.cards.length) box.appendChild(el('div', 'meta', 'No model suggested anything here.'));
    cardsOf(slot).forEach(card => {
      const key = keyOf(slot, card);
      const row = el('div', 'card');
      const text = el('div', 'text');
      text.appendChild(el('span', 'typed', '…' + it.before.slice(-140)));
      text.appendChild(el('span', 'ghost', card.text));
      row.appendChild(text);
      const choices = el('div', 'choices');
      choices.appendChild(el('span', 'scale', 'never'));
      [1, 2, 3, 4, 5].forEach(v => {
        const b = el('button', state.ratings[key] === v ? 'on' : '', String(v));
        b.title = ['', 'I would never write this', 'Unlikely', 'Plausible', 'Likely', "Exactly what I'd write"][v];
        b.onclick = () => { state.ratings[key] = v; state.log.push({ k: key, v, pos: n, t: Date.now() }); save(); render(); };
        choices.appendChild(b);
      });
      choices.appendChild(el('span', 'scale', 'exactly me'));
      row.appendChild(choices);
      box.appendChild(row);
    });
    root.appendChild(box);
  });
  document.getElementById('count').textContent = `${Object.keys(state.ratings).length} of ${total()} rated`;
}

function table(headers, rows) {
  const wrap = el('div', 'wrap');
  const t = el('table');
  const head = el('tr');
  headers.forEach((h, i) => head.appendChild(el('th', i ? 'num' : '', h)));
  t.appendChild(head);
  rows.forEach(r => { const tr = el('tr'); r.forEach((c, i) => tr.appendChild(el('td', i ? 'num' : '', c))); t.appendChild(tr); });
  wrap.appendChild(t);
  return wrap;
}
const mean = a => a.length ? a.reduce((x, y) => x + y, 0) / a.length : null;
const fmt = v => v == null ? '–' : v.toFixed(2);

function reveal() {
  // Model scores use first showings only; position splits the session into halves for the drift check.
  const half = state.order.length / 2;
  const per = data.models.map(() => ({ all: [], early: [], late: [] }));
  state.order.forEach((slot, n) => {
    if (slot.repeat) return;
    data.items[slot.item].cards.forEach(card => {
      const v = state.ratings[card.key];
      if (v == null) return;
      card.models.forEach(m => { per[m].all.push(v); (n < half ? per[m].early : per[m].late).push(v); });
    });
  });
  const box = document.getElementById('result');
  box.textContent = '';
  box.appendChild(el('h2', null, 'Models'));
  box.appendChild(el('div', 'meta', `Profile: ${data.profile}. Mean of your 1–5 ratings (first showings only); "rated 4–5" is the share you found likely or exact.`));
  const order = data.models.map((_, i) => i).sort((a, b) => (mean(per[b].all) || 0) - (mean(per[a].all) || 0));
  box.appendChild(table(['Model', 'Rated', 'Mean (1–5)', 'Rated 4–5', 'Showed nothing', 'Keystrokes saved'], order.map(i => {
    const a = per[i].all;
    return [data.models[i], String(a.length), fmt(mean(a)), a.length ? Math.round(100 * a.filter(v => v >= 4).length / a.length) + ' %' : '–',
            String(data.nothing[i]), data.saved[i] == null ? '–' : (100 * data.saved[i]).toFixed(1) + ' %'];
  })));

  box.appendChild(el('h2', null, 'Drift check'));
  const early = per.flatMap(p => p.early), late = per.flatMap(p => p.late);
  box.appendChild(el('div', 'meta', `Moments are in random order, so a difference between the first and second half of the session is your scale moving, not the topics. Overall: first half ${fmt(mean(early))}, second half ${fmt(mean(late))}.`));
  box.appendChild(table(['Model', 'First half', 'Second half', 'Change'], order.map(i => {
    const e = mean(per[i].early), l = mean(per[i].late);
    return [data.models[i], fmt(e), fmt(l), e == null || l == null ? '–' : (l - e >= 0 ? '+' : '') + (l - e).toFixed(2)];
  })));
  const pairs = [];
  state.order.forEach(slot => {
    if (!slot.repeat) return;
    data.items[slot.item].cards.forEach(card => {
      const first = state.ratings[card.key], again = state.ratings['r:' + card.key];
      if (first != null && again != null) pairs.push(again - first);
    });
  });
  box.appendChild(el('div', 'meta', pairs.length
    ? `Repeated moments: ${pairs.length} suggestions rated twice. Same rating ${Math.round(100 * pairs.filter(d => d === 0).length / pairs.length)} %, within one point ${Math.round(100 * pairs.filter(d => Math.abs(d) <= 1).length / pairs.length)} %; average change on the second rating ${(mean(pairs) >= 0 ? '+' : '') + mean(pairs).toFixed(2)} (positive: you rated higher later).`
    : 'Repeated moments: none rated twice yet (six moments come back near the end).'));
  box.style.display = 'block';
  box.scrollIntoView({ behavior: 'smooth' });
}

document.getElementById('reveal').onclick = reveal;
document.getElementById('export').onclick = () => {
  const out = JSON.stringify({ runID: data.runID, models: data.models, order: state.order, ratings: state.ratings, log: state.log,
                               items: data.items.map(it => ({ id: it.id, cards: it.cards })) });
  navigator.clipboard.writeText(out).then(() => alert('Ratings copied.'), () => prompt('Copy the ratings:', out));
};
document.getElementById('clear').onclick = () => {
  if (confirm('Clear all ratings and start over in a new order?')) { state = {}; setUp(); render(); document.getElementById('result').style.display = 'none'; }
};
render();
</script>
</body>
</html>
"""#
