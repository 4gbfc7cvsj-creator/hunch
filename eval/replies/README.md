# Suggested replies eval

Cases for the suggested-replies prompt (`SuggestedRepliesFramer`), run with the `write` command:

```bash
"$(swift build --show-bin-path)/hunch-eval" write --model <file.gguf> --cases eval/replies/cases.jsonl --context-tokens 4096 --app-screen
```

- `cases.jsonl`: short, clean messages: yes/no, offered choices, open questions, Traditional Chinese,
  nothing to reply to, and the Length presets.
- `screen-cases.jsonl`: screen text as Hunch really reads it (text recognition with misread
  words and interface labels). Replies must not copy misread words (`mustExclude`).

Match the app with `--context-tokens`: 4096 when replies come from the Language Model (the app
loads it with at least 4096, whatever `runtime.contextTokens` says, so the prompt budget is 3132),
8192 with a separate writing model. Each
case's `screenTokens` is the "Suggested replies screen text" slider (default 1000).

Checks are basic (reply count, none when nothing asks for a reply, script, required and banned
words); read `write-report.md` for quality.

Pass `--app-screen` so case screens go through the app's screen pipeline: layout markers (`»` my
bubble, `~` sender name, `=` centered; see eval/README.md) become the "Me:"/"Them:" labels the app
sends. The two-sided chat cases in `eval/replay/two-sided-cases.jsonl` work as replies moments too
(their `text` is what the writer really sent).
