#!/usr/bin/env bash
# Fetch the pinned official llama.cpp xcframework into Vendor/ and verify its SHA-256.
# Upgrading: change TAG and SHA256 together, then re-run the eval (see docs/design.md §5.4).
set -euo pipefail

TAG="b11552"
SHA256="ac195b4693da8e250ed778bc66a137912b912c0a6733f9c3e52153d7258172b8"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DEST="$VENDOR/llama.xcframework"
STAMP="$VENDOR/llama.tag"

if [[ -d "$DEST" && -f "$STAMP" && "$(cat "$STAMP")" == "$TAG" ]]; then
  echo "llama.xcframework $TAG already present"
  exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading llama.cpp $TAG xcframework..."
curl -fL --retry 3 -o "$TMP/llama.zip" "$URL"
echo "$SHA256  $TMP/llama.zip" | shasum -a 256 -c -

ditto -x -k "$TMP/llama.zip" "$TMP/unzipped"
FOUND="$(find "$TMP/unzipped" -maxdepth 3 -type d -name 'llama.xcframework' | head -1)"
if [[ -z "$FOUND" ]]; then
  echo "error: llama.xcframework not found in archive" >&2
  exit 1
fi

rm -rf "$DEST"
mv "$FOUND" "$DEST"
echo "$TAG" > "$STAMP"
echo "Installed $DEST ($TAG)"
