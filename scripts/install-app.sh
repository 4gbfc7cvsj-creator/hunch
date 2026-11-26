#!/usr/bin/env bash
# Install the built app to a FIXED path (~/Applications/Hunch.app), replacing it in place,
# so macOS keeps the Accessibility / Input Monitoring grants across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Hunch.app"
DEST="$HOME/Applications/Hunch.app"

[[ -d "$SRC" ]] || { echo "error: build first (scripts/build-app.sh)" >&2; exit 1; }

pkill -x Hunch 2>/dev/null || true
# The app under its earlier names: quit it and move it to the Trash so two copies never run side by side.
for OLDNAME in GhostWriter GhostType; do # LEGACY_GHOSTTYPE
  OLD="$HOME/Applications/$OLDNAME.app"
  if [[ -d "$OLD" ]]; then
    pkill -x "$OLDNAME" 2>/dev/null || true
    sleep 1
    mv "$OLD" "$HOME/.Trash/$OLDNAME-$(date +%Y%m%d-%H%M%S).app"
  fi
done
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
# The staged bundle under build/ may have picked up Finder info or file-provider attributes from a synced
# folder (OneDrive, iCloud Drive); strip them so strict signature checks pass on the installed copy.
xattr -cr "$DEST"
echo "Installed $DEST"
if [[ "${1:-}" == "--open" ]]; then open "$DEST"; fi
