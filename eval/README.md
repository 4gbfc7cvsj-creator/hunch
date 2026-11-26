# hunch-eval

Prompt, model and decoding comparison harness (design section 8). Build and run from the repo root:

```
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build -c release --product hunch-eval
M="/Volumes/Samsung 1TB/LLM/GhostType"
.build/release/hunch-eval inspect "$M"
.build/release/hunch-eval kvcheck "$M/gemma-4-E4B.i1-Q5_K_M.gguf"
.build/release/hunch-eval run \
  --models "$M/gemma-4-E4B.i1-Q5_K_M.gguf" "$M/gemma-4-E4B-it-Q5_K_M.gguf" \
  --configs eval/configs/*.json [--phrases eval/phrases.jsonl] [--subset tag] [--repeat N] [--quick] [--out dir]
.build/release/hunch-eval selftest
```

Reports go to `eval/reports/<timestamp>/` (`report.md`, `results.csv`). Exit codes: 0 ok, 1 failure, 2 usage.
Missing or invalid model/config files are skipped with a message. One model is loaded at a time
(n_ctx 2048, mmap, all layers on Metal).

## Passes
Every phrase runs twice per model x config. "cold" is the phrase as written (the engine keeps its KV cache, so
shared prefixes such as the chat system turn may be reused; the serve path is recorded). "replay" re-runs after 1-3
characters of the cold raw suggestion were appended (as if typed), measuring the warm per-keystroke path.

## Config format (`eval/configs/*.json`)
| key | meaning |
|---|---|
| `name` | label in reports (defaults to the file name) |
| `framer` | `auto`, `document-v1`, `document-v2`, `chat-prefill-v1` or `chat-prefill-v2` (a framer the model cannot use falls back; the report shows the effective one) |
| `length` | `short`, `medium`, `long`, `veryLong`, `ultra`; sets minWords/maxWords |
| `decode` | overrides for any `DecodeConfig` field (`maxTokens`, `firstTokenFanout`, `scoring`, `minMeanLogProb`, ...) |
| `promptTokenBudget` | framer token budget |
| `customInstructionsFile` | optional path (relative to cwd); read at runtime, never copied into reports |
| `addBOS` | `null` = trust the loaded vocabulary, `true`/`false` = force |
| `postConfidenceFloor` | extra mean log-prob floor, or `null` |

## Phrases (`eval/phrases.jsonl`)
One JSON object per line: `id`, `tags`, `before`, optional `after`, `surface` (SurfaceKind), optional `expect`
(acceptable first words of the continuation; for mid-word cases, the complete word), `aiTrap`. Tag `quick` marks
the 12 phrases run by `--quick`; `--subset <tag>` filters by any tag.

## Metrics
- AI-voice rate on traps: classifier verdict on the RAW candidate (before post-processing); "shown" is the verdict on
  what survived the filter; "trap shown" is how many traps still displayed something.
- Suppression rate and reasons; first-word match against `expect` (suppressed counts as a miss).
- Latency p50/p95 for time to first visible word and total, cold vs replay; decoded prompt tokens on replay.
- `--repeat N` re-runs everything and reports phrases whose raw output changed (determinism check).
- Rate metrics use the first repeat's cold pass.

## M3 additions
- The run engines use the app's post-processor (system spell checker, preferred languages, `DocumentFramer.prefacePhrases`). `--no-typo-check` drops only the spell checker, for A/B.
- Phrase tags: `ide` (code buffers: Swift, TypeScript, Python, shell; `closer` marks a caret in front of an auto-closed closer, run with `--subset ide`), `zhtrad` (traditional Chinese), `zhsimp` (kept simplified), `zhshort` (2-6 character prefixes), `typo` (last typed word misspelled; should be suppressed as `likelyTypo`), `rare` (correctly spelled rare word or name; must not be suppressed). The report has an "M3 checks" section per cell.
- `selftest` also fails when a `DocumentFramer.prefacePhrases` entry of 4+ words is not caught by HunchText's built-in preface list.
- `bias --model <file> --config <config.json> [--vocab eval/bias/vocab.json] [--cases eval/bias/cases.jsonl] [--strengths 0,1.5,3] [--no-typo-check]`:
  runs fit / no-fit cases plus the English `expect` phrases at each strength with a synthetic vocabulary; writes `bias-report.md` and `bias-results.csv`.

## Bake-off (model, framer and version comparisons)

A **bake-off** compares models, prompt framings or Hunch versions on what using Hunch feels
like, not on exact-match guesses. Since 2026-11-19 its headline is **judged acceptance**: blind Opus
judges, playing the writer, say how many words of each suggestion they'd take with Tab, now and after
typing one or two more letters. Keystrokes saved stays as a secondary number: it needs the next words
to be exactly the written text, while a real sentence can go several acceptable ways. Parts, in order:

1. **Rating moments with steering** (`rate --moments-from`): 40 moments, 20 from the written set
   (`cases.jsonl`, no code, 2 Chinese) and 20 from the noisy set (`noisy-cases.jsonl`: group chats with
   crosstalk, cluttered screens with sidebars, toolbars and misread letters). Each moment is asked three
   times: as cut, after one more letter and after two (Chinese: characters), so the judges can see how
   well a hint steers the model. Every model or version answers the same moments. Pass `--app-screen`
   so case screens go through the app's screen pipeline (without it, screen-cleanup changes aren't
   measured at all).
2. **Judges as typists** (`eval/judging/acceptance-prompt.md`, three Opus agents, three steps each):
   each judge first writes its own three likely continuations without seeing any suggestion, then
   scores every suggestion with **accepted words** (any wording they'd happily send counts, not just
   their own) and closeness 1–5, then scores the steering suggestions the same way. A few planted
   generic suggestions check that judges don't wave filler through. Per model: words accepted now and
   within two letters, share of moments with at least one useful word, closeness, share that doesn't
   fit the moment. Give the judges the persona's writer sheet (`eval/judging/writer-persona.json`)
   so they judge as the same writer the model was told about.
3. **Typing replay** (`replay`, below), secondary: keystrokes saved on fixed samples (e.g. 30 written,
   20 noisy, 30 of your history), full profile; speed while typing, first suggestion in a field,
   memory. Add the `fresh` profile only for framer and first-run comparisons.
4. **Your blind rating**, only if steps 1–3 show the candidate is clearly better (much better
   quality, or the same quality at much lower resource cost): a page of 40 moments (no code,
   8 Chinese), shuffled per rater with 6 hidden repeats; Reveal shows per-model scores and a
   drift check. Ratings are read back from the app's browser pane into the page folder's
   `ratings.json`. Manual rating is the slow part, so it waits on the judges.
   When it is skipped, the report instead shows a few example moments with all three judges'
   reasons: ones where one model did much better than another, both ways, for a quick check that
   the judges think like you.

The older unrealistic-rate judges (`judge-export` / `judge-report`, `eval/judging/README.md`) still
work on any rating page; closeness 1 ("doesn't fit the moment") now covers the same failure.

Historical versions: build each commit's `hunch-eval` in its own worktree. Builds from before
2026-11-04 have no `replay`; `scratch/eval-tools/history_bakeoff_patch.py` backports it (and
`--moments-from` for builds before 2026-11-05). The 2026-11-19 run is the worked example
(`scratch/eval-tools/history_bakeoff_*.py`, `scratch/bakeoff-wt/run.sh`).

## Replay (keystrokes saved)

```
.build/release/hunch-eval replay --models "$M/gemma-4-E4B-it.i1-Q5_K_M.gguf" "$M/Qwen3-1.7B.i1-Q4_K_M.gguf" \
  [--cases eval/replay/cases.jsonl] [--profiles eval/replay/profiles/fresh.json eval/replay/profiles/full.json] \
  [--limit N] [--probes 40] [--out dir]
```

A simulated person types each message in `eval/replay/cases.jsonl` (80 messages: 72 English, 4 traditional Chinese,
4 code; chat, email, notes and docs, AI prompts) one character at a time. Whenever the suggestion's next word is
exactly what comes next, they accept it with one key; a typed character the suggestion predicted shrinks it, any
other hides it. Requests are awaited one at a time, so a run is deterministic (`typing` covers timing). The app's
prompt budget (3584 tokens), medium length and 2-word floor apply.

- **Profiles** (`eval/replay/profiles/`): `fresh` is a new install (app name, surface, the macOS full name, system
  languages); `full` adds screen text, window title, clipboard, an "about me" and 2 writing samples picked from the
  other messages typed in the same kind of place.
- **Headline**: keystrokes saved = 1 − keys pressed / characters. Also words accepted per shown suggestion, shown
  suggestions that helped vs wrong ones, requests that showed nothing, AI voice shown, request latency, first request
  in a field, memory.
- **Output**: `replay-report.md`, `replay-results.csv` (per case), `replay-suggestions.csv` (every shown suggestion
  with what was typed next), and `rate.html`: a blind rating page with the same 40 moments for every model (full
  profile), identical suggestions merged, model names hidden until Reveal. Ratings stay in the browser.
- **Case format**: `id`, `surface`, `tags`, `app`, optional `domain`, `windowTitle`, `fieldLabel`, `screen`,
  `clipboard`, `prefix` (already in the field), and `text` (what is typed). Generic names only; the file is pushed.

### Your own history (local only)

```
.build/release/hunch-eval history-cases [--max 80] [--out eval/local/replay-history.jsonl]
.build/release/hunch-eval replay --models ... --cases eval/local/replay-history.jsonl --out eval/local/replay-history-report
```

`history-cases` reads the sentences Hunch saved from your typing (encrypted local history, read only) and writes
them as cases under `eval/local/`, which git ignores. History keeps only text and app, so these cases have no screen
text and their surface is guessed from the app. Keep the report under `eval/local/` too.

## Noisy cases

`eval/replay/noisy-cases.jsonl` (40 cases) has screens like real captures: 20 group chats (Discord,
Slack, WhatsApp, Messages, Teams, LINE; 4 traditional Chinese) where several people talk over each
other and the writer answers one thread, with reply previews, reactions, badges and timestamps; and
20 cluttered screens (Mail, Gmail, Outlook, Claude, ChatGPT, Claude Code, Notion, Jira, Docs, forms,
Reddit, LinkedIn, Obsidian) with sidebars, toolbars, model pickers, ads and a few misread letters.
Some cases start with text already in the field (`prefix`) or a field label.

## Two-sided chat cases

`eval/replay/two-sided-cases.jsonl` (10 cases: Messages, WhatsApp, Telegram, Signal, LINE, Claude; 2 traditional
Chinese, 2 group chats) are 1:1 and group chats where the writer's own messages are on screen, so the next message
only makes sense once you know which side wrote what. With `--app-screen`, screen lines can carry a layout marker
that the eval turns into line positions for the app's screen pipeline, which then labels speakers ("Me: …",
"Them: …", a sender's name) in chat places (`ChatSides`):

- `» ` a line of the writer's own right-aligned bubble (consecutive ones are one bubble);
- `~ ` a sender's name in small type above the other side's bubble (group chats);
- `= ` a centered line (title bar, day stamps, "online").

Unmarked lines start at the column's left edge, as before; without `--app-screen` the markers are just dropped.
Leave out field placeholders ("iMessage", "Type a message"): the app reads the field's own text out of the screen.
`--no-sides` turns the labels off (the "before" side of a comparison), and
`hunch-eval app-screen --cases <file> [--no-sides]` prints each case's screen as the model would get it.
Case apps that are bubble apps (Messages, WhatsApp, Signal, Telegram, LINE, Claude, ChatGPT, LM Studio) are labeled as
the app labels them, so a screen of only the other side's messages gets labels too; AI chat apps get no sender names.

To replay real reads instead of made-up cases, turn on debug logging (Diagnostics) and use
`hunch-eval screen-log --log ~/Library/Logs/Hunch/screen.log [--grep text] [--last N] [--bundle id] [--dump]`:
it runs each logged OCR read (lines with their rects, the field, the caret) through the screen pipeline and prints the
screen text the model would get (`--bundle` sets the app, default Messages; `--dump` also prints the raw lines).
Run it before and after a `ChatSides` or pipeline change and diff the two outputs to see every read it changes.

## Personal context (`eval/replay/persona.json`)

The `full` profile sends what the app sends for someone who has typed with Hunch for a while
(since 2026-11-19; earlier results were measured without it). Its `persona` names a made-up writer,
Alex Morgan, a product manager in Seattle who also writes traditional Chinese:

- **Instructions**: short general instructions, and per-app instructions for Slack, Messages, Gmail
  and LINE (other apps have none, as for most users).
- **Learned words and phrases, and writing samples**: about 250 past sentences across the case apps
  (mostly chats, work chat and email, dated over the last two months), including habits: names,
  places and work terms typed again and again in the same phrasings ("sync with Riley", "file a Jira
  ticket"). The sentences fill a throwaway history store as writing samples, and each one is also
  *typed* through the app's learning path, on its own date: at every word a suggestion is showing and
  the writer types their own word over it. So the app's rules decide which words are learned and
  with which context (3+ times on 2+ days; about 20 words), as in real use; two more are added by
  hand like a Settings list. The app's `HistoryService` then answers learned words, learned phrases
  and per-app samples, with Personalize word choice at its default (1.5). Your real history is never
  read. No past sentence shares a five-word run with any case, so phrases can't hand over the answer.
- **Personal cases** (`eval/replay/personal-cases.jsonl`, 15, tag `personal`): moments where the next
  word is one of the writer's own (Riley, Priya, Jira, SOW, microspikes…) and the screen doesn't show
  it; `cutBefore` names the word, so a moment is cut right before it (then +1 and +2 letters). Add them
  to a bake-off whenever learned words or phrases could matter.
- **Clipboard**: as with the app's 5-minute clipboard, most moments have none; about a quarter get an
  unrelated copy (a link, an address, a tracking number); six cases get a related one (an error message,
  a flight, a baggage report). Cases with their own `clipboard` keep it.

Code moments get instructions but no learned words or samples, as in the app. `fresh` stays a first
run with no personal context. Rebuild the persona with `scratch/eval-tools/persona_gen.py` (it also
writes the judges' writer sheet). To see what each request gets, set `GT_PERSONA_DEBUG=1`.

## Long-context cases

`eval/replay/long-cases.jsonl` (40 cases: 20 AI chat threads in Claude/ChatGPT, 20 email chains) gives the model
about 400–1,600 tokens of screen text instead of a line or two. 16 cases (tag `far`) continue with a detail
that only appears far up the screen. Run them like any replay set:

```
.build/release/hunch-eval replay --models ... --cases eval/replay/long-cases.jsonl --out eval/reports/replay-long-<name>
```

Run each model in its own process on a 24 GB Mac (several big models in one run can fail to load and show
nothing). Rating pages and judges get the full screen text.

**Your own long contexts**: Settings → Privacy → Diagnostics → Save eval captures writes each message you send in
an AI chat (Claude/ChatGPT apps and sites) or email (Mail, Outlook, webmail), with the screen text the model saw
at its start, to `~/Library/Logs/Hunch/eval-captures.jsonl` (plain text, this Mac only). Turn it into a local
replay set with:

```
.build/release/hunch-eval capture-cases [--min-screen 2000] [--out eval/local/replay-long-real.jsonl]
```

## Blind judges

`judge-export` / `judge-report` add the unrealistic rate from three blind Opus judges to a rating
page comparison. Costly; only for model selection and framer tuning. See `eval/judging/README.md`.
