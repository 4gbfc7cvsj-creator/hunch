# Hunch: notes for cloud sessions

Hunch is an on-device writing companion for macOS: ghost-text suggestions at the cursor in any app,
autocorrect and dictation, all running on a local language model. Swift 6, SwiftPM, macOS 26.

This repo is a public snapshot of the maintainer's local repo. Work started here is brought back to
the local repo by hand, so keep the change small and self-contained, and leave the merging to them.

## What you can't do here

- **You probably can't build or test.** The package targets macOS only: AppKit, CoreGraphics, the
  Accessibility APIs, and prebuilt llama.cpp/whisper.cpp frameworks that are fetched at build time.
  If `swift build` or `swift test` fails on missing Apple frameworks or `Vendor/`, don't work around
  it (no stubs, no `#if os(Linux)`, no Package.swift changes). Write the code and its tests carefully
  and say in the PR that nothing was built or run.
- **No design notes, backlog or eval results.** They stay local. If a task needs them, say so in the
  PR instead of guessing.
- **No models, no running the app, no evals.**

## Layout

- `Sources/HunchCore`: shared value types and protocols.
- Pure logic (easiest to change safely, each with tests in `Tests/<Target>Tests`): `HunchPolicy`,
  `HunchPrompt`, `HunchText`, `HunchSession`, `HunchDecode`, `HunchEmoji`, `HunchShell`,
  `HunchHistory`, and `HunchInput/Pure`.
- Side-effectful: `HunchFocus` (Accessibility), `HunchInput` (key events), `HunchOverlay` (ghost
  text window), `HunchScreen`, `HunchLlama`, `HunchWhisper`, `HunchEngine`, `HunchModels`,
  `HunchSettingsStore`, `HunchEndpoint`.
- `Sources/HunchApp`: the app itself (coordinator, settings panes, menus).
- `hunch-eval`: the offline evaluation tool.

Match the style of the code around your change. Every behavior change in pure logic gets a test.

## Rules (the repo is public)

- **No personal info** anywhere: code, tests, test data, defaults, comments, commit messages, PR text.
  No real names, emails, usernames, machine names, addresses or private sites. Use the stand-ins
  already in the tests (`Alex Morgan`, `alex@example.com`).
- **No competitor product names.** Write "competitors".
- Don't touch `LICENSE`, signing, release scripts, `.github/` or `Vendor/` unless the task says so.
- Settings defaults must suit a stranger's fresh install.
- User-facing copy: plain and short. Avoid "It + verb" taglines ("It learns…"); write "Hunch …" or
  recast the sentence.

## Finishing

Open a pull request against `main` and **don't merge it**. In the description, say:

- what changed and why, in a few lines;
- what you couldn't check (build, tests, behavior in the app);
- anything the maintainer should try by hand on the Mac.
