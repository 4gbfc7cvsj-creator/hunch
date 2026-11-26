<!-- The prompt for one blind judge. Start one Opus agent per set, replacing {DIR} with the
     judge-export --out folder and {N} with the set number. -->

You are rating autocomplete suggestions for realism. This is careful reading work: take your time on every moment. Work only from the two input files named below; do not open, list or search any other file or folder.

Folder: {DIR}/sets/
- writer.json: who the writer is ("about") and sentences they typed in the past ("samples"), showing their voice.
- set-{N}.jsonl: one moment per line. Each has the app and window ("app", "place"), text on screen near the field ("on_screen", may be empty), what the writer has typed so far ("typed_so_far"; the suggestion continues right after its last character, so it can finish a half-typed word), and "candidates": lettered suggestions for what comes next.

For every candidate, score 1–5 how likely THIS writer would actually have typed that continuation at that moment:
5 = exactly what they'd write; 4 = likely; 3 = plausible; 2 = unlikely; 1 = they would never write this.

Judge context fit and realism first: does it make sense given what's on screen and what was typed so far (someone off sick doesn't promise to check in later the same afternoon; a reply to "I GOT THE JOB" doesn't restate that they got the job)? Would a real person write it, in this writer's voice, language and script? Does it join the typed text correctly (spacing, half-typed word, grammar)?

- A suggestion is only the next few words, not the whole sentence. Score it by its most natural way to continue: "Can you share the details on that marketing" is fine when the marketing numbers aren't ready yet, because "…spend when you have them?" is the obvious ending.
- Casual messages don't follow formal rules: lowercase, loose punctuation and run-on commas are normal in chat. Don't mark them down for that.
- Don't reward polish or length for its own sake. Score each candidate on its own merits; several can share a score.

Rules:
- Decide every score yourself by reading the moment. Do not write or run code that computes, guesses or fills in scores.
- Each reason (at most 20 words) must name the specific thing in this moment that drives the score. Generic reasons ("natural", "ok", "judged on context") are not acceptable.
- Work in batches of 20 moments. For each batch, read those moments, decide, then append that batch's lines to the output file (a shell heredoc append is fine) before reading the next batch.

Output file: {DIR}/judge-{N}.jsonl, one JSON object per candidate: {"moment": <n>, "label": "<letter>", "score": <1-5>, "reason": "..."}. Every candidate must be covered exactly once. Reply at the end with just the number of lines written.
