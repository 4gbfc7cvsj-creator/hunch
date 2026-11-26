#!/usr/bin/env bash
# Package the built app as a drag-to-Applications disk image: build/Hunch-<version>-<date>.dmg.
#   scripts/make-dmg.sh                       build the app, then the DMG
#   scripts/make-dmg.sh --no-build            package the app already in build/
#   scripts/make-dmg.sh --release owner/repo  also publish it as a GitHub release (needs `gh` signed in)
#
# The app is signed with the self-signed identity from build-app.sh (no Developer ID, not notarized), so a
# user's Mac can't verify it: they allow it once (Privacy & Security → Open Anyway, see INSTALL below). Later
# versions signed with the same identity keep their Accessibility and Input Monitoring grants.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD=1
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --release) REPO="${2:?--release needs owner/repo}"; shift ;;
    *) echo "usage: $0 [--no-build] [--release owner/repo]" >&2; exit 2 ;;
  esac
  shift
done

[[ $BUILD == 1 ]] && "$ROOT/scripts/build-app.sh"
APP="$ROOT/build/Hunch.app"
[[ -d "$APP" ]] || { echo "error: build first (scripts/build-app.sh)" >&2; exit 1; }
codesign --verify --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DATE="$(date +%Y%m%d)"
NAME="Hunch-$VERSION-$DATE"
DMG="$ROOT/build/$NAME.dmg"

read -r -d '' INSTALL <<'TEXT' || true
Installing Hunch

1. Drag Hunch onto the Applications folder, then open it from Applications.
2. Hunch isn't signed with an Apple Developer ID or notarized, so the first time macOS says
   "Hunch" Not Opened. Click Done (not Move to Trash).
3. Open System Settings > Privacy & Security and scroll down to Security. Next to
   "Hunch" was blocked to protect your Mac, click Open Anyway. (The button shows for about an hour
   after you tried to open the app; if it isn't there, open Hunch again first.)
4. Click Open Anyway in the dialog and confirm with your password or Touch ID. You only do this once.
   (Or instead of steps 2-4, in Terminal: xattr -dr com.apple.quarantine /Applications/Hunch.app)
5. The welcome tour opens: allow Accessibility and Input Monitoring, then download the recommended
   language model (and a speech model for dictation) inside the app.

Updating: quit Hunch from its menu bar icon, drag the new version over the old one, and open it.
Your permissions and settings stay.

Needs an Apple silicon Mac on macOS 26 or later.
TEXT

# Stage in a private temp dir (not a synced folder) with an Applications link to drop onto.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Hunch/Hunch.app"
ln -s /Applications "$STAGE/Hunch/Applications"
printf '%s\n' "$INSTALL" > "$STAGE/Hunch/How to Install.txt"
xattr -cr "$STAGE/Hunch"

rm -f "$DMG"
hdiutil create -quiet -volname "Hunch" -srcfolder "$STAGE/Hunch" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"

if [[ -n "$REPO" ]]; then
  TAG="v$VERSION-$DATE"
  NOTES="$STAGE/notes.md"
  { echo "Download **$NAME.dmg** below, open it, and follow these steps."; echo; echo '```'; printf '%s\n' "$INSTALL"; echo '```'; } > "$NOTES"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "$DMG" --repo "$REPO" --title "Hunch $VERSION ($DATE)" --notes-file "$NOTES" --latest
  fi
  echo "Released $TAG on $REPO"
fi
