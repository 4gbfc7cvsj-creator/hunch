#!/usr/bin/env bash
# Fetch the pinned official whisper.cpp xcframework into Vendor/ and verify its SHA-256.
# Upgrading: change TAG and SHA256 together, then re-run the eval (speech-to-text, Settings → Dictation).
set -euo pipefail

TAG="b5454"
SHA256="e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${TAG}/whisper-${TAG}-xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DEST="$VENDOR/whisper.xcframework"
STAMP="$VENDOR/whisper.tag"

if [[ -d "$DEST" && -f "$STAMP" && "$(cat "$STAMP")" == "$TAG" ]]; then
  echo "whisper.xcframework $TAG already present"
  exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading whisper.cpp $TAG xcframework..."
curl -fL --retry 3 -o "$TMP/whisper.zip" "$URL"
echo "$SHA256  $TMP/whisper.zip" | shasum -a 256 -c -

ditto -x -k "$TMP/whisper.zip" "$TMP/unzipped"
FOUND="$(find "$TMP/unzipped" -maxdepth 3 -type d -name 'whisper.xcframework' | head -1)"
if [[ -z "$FOUND" ]]; then
  echo "error: whisper.xcframework not found in archive" >&2
  exit 1
fi

rm -rf "$DEST"
mv "$FOUND" "$DEST"
echo "$TAG" > "$STAMP"
echo "Installed $DEST ($TAG)"
