#!/usr/bin/env bash
# Build a branded Dictator.dmg installer: the app plus an Applications
# drop-link, laid out over design/dmg-background.png (arrow + instructions).
#
# Requires: brew install create-dmg
# Usage:    scripts/make-dmg.sh /path/to/Dictator.app [output.dmg]
set -euo pipefail
APP="${1:?Usage: make-dmg.sh /path/to/Dictator.app [output.dmg]}"
OUT="${2:-$HOME/Desktop/Dictator.dmg}"
BG="$(cd "$(dirname "$0")/.." && pwd)/design/dmg-background.png"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Dictator.app"

rm -f "$OUT"
create-dmg \
  --volname "Dictator" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 120 \
  --icon "Dictator.app" 180 200 \
  --app-drop-link 480 200 \
  --hide-extension "Dictator.app" \
  --no-internet-enable \
  "$OUT" \
  "$STAGE"

rm -rf "$STAGE"
echo "Built $OUT"
