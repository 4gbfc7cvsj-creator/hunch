#!/usr/bin/env bash
# Build Hunch.app: swift build, assemble the bundle, embed llama.framework and whisper.framework, sign with the
# stable self-signed identity so TCC grants survive rebuilds (design §2).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
CONFIG="${CONFIG:-release}"
# The self-signed identity in the login keychain. It was made under the app's first name, so fall
# back to that until a "Hunch Local Signing" identity exists. Making a new identity means granting
# Accessibility and Input Monitoring again, since macOS ties the grants to the certificate.
if [[ -z "${HUNCH_SIGN_IDENTITY:-}" ]] && ! security find-identity -p codesigning | grep -q '"Hunch Local Signing"'; then
  IDENTITY="GhostType Local Signing" # LEGACY_GHOSTTYPE
else
  IDENTITY="${HUNCH_SIGN_IDENTITY:-Hunch Local Signing}"
fi
BUNDLE_ID="local.hunch.app"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/fetch-llama.sh"
"$ROOT/scripts/fetch-whisper.sh"

swift build -c "$CONFIG" --product HunchApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# Assemble and sign in a private temp dir, not under the repo: a synced folder (OneDrive, iCloud Drive)
# stamps Finder info and file-provider attributes onto new directories asynchronously, and codesign refuses
# to seal a bundle that carries them ("resource fork, Finder information, or similar detritus not allowed").
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Hunch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
ditto "$ROOT/Resources/AppIcons" "$APP/Contents/Resources/AppIcons"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
# The welcome tour's intro video (made by scripts/intro-video/make.sh).
cp "$ROOT"/Resources/Intro/intro-*.mp4 "$APP/Contents/Resources/"
cp "$BIN_DIR/HunchApp" "$APP/Contents/MacOS/Hunch"
ditto "$ROOT/Vendor/llama.xcframework/macos-arm64_x86_64/llama.framework" "$APP/Contents/Frameworks/llama.framework"
ditto "$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
# The copied sources may already carry those attributes; drop them before sealing.
xattr -cr "$APP"

# SwiftPM links the framework via @rpath; make sure the bundle's Frameworks dir is searched.
if ! otool -l "$APP/Contents/MacOS/Hunch" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Hunch"
fi

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/llama.framework"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/whisper.framework"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" --entitlements "$ROOT/Resources/Hunch.entitlements" "$APP"

codesign --verify --strict "$APP"

OUT="$ROOT/build/Hunch.app"
rm -rf "$OUT"
mkdir -p "$ROOT/build"
ditto "$APP" "$OUT"
echo "Built $OUT"
codesign -d -r- "$OUT" 2>&1 | grep designated
