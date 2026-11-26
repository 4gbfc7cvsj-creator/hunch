<!-- Judges as typists: the prompts for one blind judge, in two steps. Start one Opus agent per set with
     STEP 1 ({DIR} = the export folder, {N} = the set number). When it has replied, send the SAME agent
     STEP 2 (SendMessage), so it still has its own intents in mind. Step 1 never names the candidates
     folder, so the intents are written before any suggestion is seen. Scoring: words accepted (the
     replay's rule, against the best of the judge's three intents) and closeness 1–5. -->

## STEP 1

You are a typist. For each moment you will decide what you would type next, as if you were this writer. This is careful reading work: take your time on every moment. Work only from the two input files named below; do not open, list or search any other file or folder.

Folder: {DIR}/sets/
- writer.json: who the writer is ("about") and sentences they typed in the past ("samples"), showing their voice.
- set-{N}.jsonl: one moment per line. Each has the app and window ("app", "place"), text on screen near the field ("on_screen", may be empty), and what the writer has typed so far ("typed_so_far").

For every moment, put yourself in the writer's place: given the screen and what is typed, what are you about to type next? Write your **3 most likely continuations**, most likely first. Each one:
- starts exactly after the last character of "typed_so_far": if that ends mid-word, start with the rest of the word ("I'll be out of the off" → "ice until Monday"); if it ends with a letter and the next word is new, start with a space; if it already ends with a space, don't add another.
- is what you'd really type, in the writer's voice, language and script: chat stays casual, Chinese stays in the same script.
- is about 4–8 words, or less if the sentence ends sooner.
- The three should be genuinely different where the moment allows it (different words or direction), not trivial variants. If only one continuation is really plausible, still give three, the likeliest first.

Rules:
- Decide every continuation yourself by reading the moment. Do not write or run code that generates them.
- Work in batches of 20 moments. For each batch, read those moments, decide, then append that batch's lines to the output file (a shell heredoc append is fine) before reading the next batch.

Output file: {DIR}/intents-{N}.jsonl, one JSON object per moment: {"moment": <n>, "intents": ["...", "...", "..."]}. Keep leading spaces inside the strings. Every moment must be covered exactly once. Reply at the end with just the number of lines written.

## STEP 2

Now you will see suggestions an autocomplete offered at the same moments. Your intents are final: do not change {DIR}/intents-{N}.jsonl. Work only from {DIR}/cands/cands-{N}.jsonl (one line per moment: "moment", "typed_so_far" and lettered "candidates") and your own intents file.

For every candidate, score 1–5 how close it is to what you meant to type at that moment (judge against whichever of your three intents it is closest to):
5 = what I meant, near word for word; 4 = same meaning, I'd happily accept it; 3 = partly what I meant (the start is right, or close in meaning); 2 = a different direction, but it fits the moment; 1 = not what I meant and doesn't fit.

- A suggestion is only the next few words. If its start is what you meant and it stops early, that still counts as close.
- Score each candidate on its own; several can share a score.
- Each reason (at most 20 words) must name what matches or differs from your intent at this moment.
- Decide every score yourself; do not write or run code that computes scores. Work in batches of 20 moments and append each batch before reading the next.

Output file: {DIR}/closeness-{N}.jsonl, one JSON object per candidate: {"moment": <n>, "label": "<letter>", "score": <1-5>, "reason": "..."}. Every candidate must be covered exactly once. Reply at the end with just the number of lines written.
