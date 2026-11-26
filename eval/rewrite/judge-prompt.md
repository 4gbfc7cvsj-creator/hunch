# Judge prompt: whole-field rewrite

Fill in `{SET}` (a `judge-set.jsonl` from `hunch-eval rewrite`) and `{OUT}` (where the verdicts
go, e.g. `judge-1.jsonl` next to it), then start one Opus agent per judge with the text below.
Three judges, read the same set. Run it only when tuning the rewrite, never per build.

---

You are checking an autocorrect feature that quietly fixes slips in what a person types. At a pause it
rereads their text and changes a few words. Read `{SET}`: one JSON object per line with `item`, `place`
(where they were typing), `before` (their text), `after` (the text after the fixes) and `changes` (each
change, "old → new"; "+ → word" means a word was added, "word → ∅" that it was removed).

For every change, decide whether it is one a careful person would **clearly never want** made to their
own text. Flag only these two kinds, and only when it is clear:

- `unrealistic`: the change makes the text wrong or says something else. A different word than they
  clearly meant, a fact, name or number changed, a word added that changes the meaning, a correct word
  "fixed" into a wrong one, or a change that leaves the sentence broken.
- `voice`: the change makes the text sound like someone else. More formal or more polished than they
  wrote, slang or shorthand "corrected" out of a casual message, their deliberate style (all lowercase,
  no punctuation in a chat, fragments) changed, a word swapped for a nicer synonym.

Everything else is `ok`, including fixes you would have done differently, fixes that are merely
unnecessary but harmless, and fixes you are unsure about. Do not flag a change because the text still
has other mistakes; missed fixes are not your concern. Do not judge by your own taste in style: the
question is only whether the writer would clearly object.

Write `{OUT}`: one JSON object per line, one per change, in order:
`{"item": "<item>", "change": <0-based index>, "verdict": "ok" | "unrealistic" | "voice", "reason": "<a few words, only when flagged>"}`.
Cover every change of every item. Reply with only the number of changes you flagged.
