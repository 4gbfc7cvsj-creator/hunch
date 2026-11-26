#!/usr/bin/env bash
# Makes the welcome tour's intro video (Resources/Intro/intro-dark.mp4 and intro-light.mp4).
#   1. The app's own effect frames (Paws, Matrix, Neon, Wisteria) and its cat glyphs: Tests/HunchOverlayTests/IntroVideoFrames.swift
#   2. The animation (intro.html), drawn frame by frame in headless Chrome and encoded by ffmpeg: render.mjs
# Needs Node 22+, Google Chrome and ffmpeg. Change the scenes, words and timing in intro.html.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(sed -n 's/^export DEVELOPER_DIR="\${DEVELOPER_DIR:-\(.*\)}"$/\1/p' "$(dirname "$0")/../build-app.sh")}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FRAMES="$ROOT/build/intro-video/frames"
OUT="${OUT:-$ROOT/Resources/Intro}"

GHOSTTYPE_INTRO_FRAMES="$FRAMES" swift test --filter IntroVideoFrames 2>&1 | grep -E '✘|error|Test run with'
for theme in dark light; do
  node scripts/intro-video/render.mjs --theme "$theme" --frames "$FRAMES" --out "$OUT/intro-$theme.mp4"
done
ls -lh "$OUT"
