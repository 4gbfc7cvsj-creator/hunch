# Blind judges (unrealistic rate)

Three Opus agents rate every suggestion on a rating page 1–5 for context fit and realism, blind to
which model wrote it. The headline is each model's **unrealistic rate**: the share of its
suggestions the judges rate low (average ≤ 2.34). Judges agree with a human on clearly bad
suggestions (2026-11-04: same pick for 10 of 10 clear-last moments, 79 % of pairs 2+ points apart)
but not on close calls (64 % of 1-point pairs), which are left to your own blind ratings. Judges
are never tuned on your ratings.

**Cost: three Opus agents, about 3 minutes and ~100k tokens each per 80 moments. Run it only when
choosing models or tuning the prompt framer, never per build. Nothing runs it automatically.**

1. Make rating pages (`hunch-eval rate --models ...`, or `replay`, which also writes one).
2. `hunch-eval judge-export --pages <page>/rate.html ... --out eval/local/judging/<name>`
   writes `sets/set-1..3.jsonl` (moments shuffled and suggestions lettered differently per judge, no
   model names), `sets/writer.json` (the full profile's about-me and 12 of your saved sentences from
   `eval/local/replay-history.jsonl`), and `key.json` outside `sets/`. Everything stays under
   `eval/local/`, which git ignores.
3. Start one Opus agent per set with `judge-prompt.md`, `{DIR}` and `{N}` filled in.
4. `hunch-eval judge-report --dir eval/local/judging/<name>` reads `judge-<n>.jsonl` through the
   key and writes `judge-report.md`: per model the unrealistic rate and mean, judge-to-judge
   agreement, and, when a page's folder has your `ratings.json`, agreement with you. It flags a
   judge that left suggestions out or wrote the same few reasons everywhere (Sonnet judges did:
   they didn't read the moments).
