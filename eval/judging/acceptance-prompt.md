<!-- Judged acceptance: judges as typists who say how much of each suggestion they would take with Tab, now and
     after typing one or two more letters. Three steps for one blind Opus judge: start the agent with STEP 1
     ({DIR} = export folder, {N} = set number), then send the SAME agent STEP 2 and then STEP 3 (SendMessage), so
     it keeps its own intents in mind. Step 1 never names the candidate files, so intents are written before any
     suggestion is seen. Scores: accepted words (0 = none), closeness 1–5. -->

## STEP 1

You are a typist. For each moment you will decide what you would type next, as if you were this writer. This is careful reading work: take your time on every moment. Work only from the two input files named below; do not open, list or search any other file or folder.

Folder: {DIR}/sets/
- writer.json: who the writer is ("about") and sentences they typed in the past ("samples"), showing their voice.
- set-{N}.jsonl: one moment per line. Each has the app and window ("app", "place"), the field's label if known ("field"), the text on screen ("on_screen", may be empty), and what the writer has typed so far ("typed_so_far").

The screen text is what the computer read off the window, so it is messy, like a real screen: sidebars, buttons, toolbars, timestamps, other people's messages, unrelated panels, and the odd misread letter. Part of your job is to work out which parts matter to what the writer is answering or writing.

For every moment, put yourself in the writer's place: given the screen and what is typed, what are you about to type next? Write your **3 most likely continuations**, most likely first. Each one:
- starts exactly after the last character of "typed_so_far": if that ends mid-word, start with the rest of the word ("I'll be out of the off" → "ice until Monday"); if it ends with a letter and the next word is new, start with a space; if it already ends with a space, don't add another.
- is what you'd really type, in the writer's voice, language and script: chat stays casual, Chinese stays in the same script.
- is about 4–8 words, or less if the sentence ends sooner.
- The three should be genuinely different where the moment allows it (different words or direction), not trivial variants.

Rules:
- Decide every continuation yourself by reading the moment. Do not write or run code that generates them.
- Work in batches of 20 moments. For each batch, read those moments, decide, then append that batch's lines to the output file (a shell heredoc append is fine) before reading the next batch.

Output file: {DIR}/intents-{N}.jsonl, one JSON object per moment: {"moment": <n>, "intents": ["...", "...", "..."]}. Keep leading spaces inside the strings. Every moment must be covered exactly once. Reply at the end with just the number of lines written.

## STEP 2

Now you will see suggestions an autocomplete offered at the same moments. Your intents are final: do not change {DIR}/intents-{N}.jsonl. Work only from {DIR}/cands/cands-{N}.jsonl (one line per moment: "moment", "typed_so_far" and lettered "candidates") and your own intents and set files.

The autocomplete shows its suggestion as grey text after the caret. The writer can press Tab to take it one word at a time, and stops at the first word they don't want. For every candidate, answer two things, as the writer at this moment:

1. **accept**: how many words of the suggestion, from its start, you would take with Tab. Count a word only if you'd be happy to send it as your own: it fits the screen, your voice, and where the sentence is going. It does **not** have to match your intents word for word; a different wording or direction you'd also be fine sending counts. Stop at the first word you would have to delete or rewrite. A suggestion that finishes the word being typed counts that piece as one word. 0 = you'd ignore it. For Chinese, count characters instead of words.
2. **closeness** 1–5 to what you meant (judge against whichever intent it is closest to): 5 = what I meant, near word for word; 4 = same meaning, I'd happily accept it; 3 = partly (the start is right, or close in meaning); 2 = a different direction, but it fits the moment; 1 = doesn't fit the moment.

- Be a real writer, not a generous one: generic filler that would fit any message ("let me know if you have any questions") is only accepted if this writer, here, would really type it next.
- A suggestion is only the next few words; if it stops early, judge what it has.
- Score each candidate on its own; several can share a score.
- Each reason (at most 20 words) must name what in this moment makes the words right or wrong.
- Decide every score yourself; do not write or run code that computes scores. Work in batches of 20 moments and append each batch before reading the next.

Output file: {DIR}/accept-{N}.jsonl, one JSON object per candidate: {"moment": <n>, "label": "<letter>", "accept": <words>, "closeness": <1-5>, "reason": "..."}. Every candidate must be covered exactly once. Reply at the end with just the number of lines written.

## STEP 3

When a suggestion isn't right, writers often type one or two more letters of the word they want, and the autocomplete updates its suggestion with that hint. {DIR}/cands/steer-{N}.jsonl has, for the same moments, what the autocomplete suggested after the writer typed a little more: each line has "moment", "step" (1 = one more letter, 2 = two more letters; for Chinese one or two more characters), the new "typed_so_far" (it ends with the letters just typed) and lettered "candidates".

The letters typed are what this writer actually typed next; they may point away from your own intents. Take them as given: the writer has now committed to those letters, so judge each suggestion against where the sentence is going now.

For every candidate, give **accept** and **closeness** exactly as in step 2 (a candidate that finishes the half-typed word counts that piece as one word). Same rules: no code, batches of 20 lines, append each batch, reasons at most 20 words naming what fits or doesn't.

Output file: {DIR}/steer-scores-{N}.jsonl, one JSON object per candidate: {"moment": <n>, "step": <1|2>, "label": "<letter>", "accept": <words>, "closeness": <1-5>, "reason": "..."}. Every candidate must be covered exactly once. Reply at the end with just the number of lines written.
