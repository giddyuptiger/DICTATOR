#!/usr/bin/env bash
# Build a branded Dictator.dmg installer that looks right on EVERY Mac,
# regardless of screen size or resolution.
#
# Why it's device-independent:
#   * The DMG window is a fixed 660x400 POINTS with fixed icon positions,
#     so Finder lays it out identically on any display.
#   * The background is assembled into a multi-resolution TIFF holding both a
#     1x (660x400) and a 2x (1320x800, HiDPI-tagged) image, so Finder shows a
#     crisp background on Retina and the correctly-sized one on non-Retina.
#
# Requires: brew install create-dmg   (tiffutil ships with macOS)
# Usage:    scripts/make-dmg.sh /path/to/Dictator.app [output.dmg]
set -euo pipefail

APP="${1:?Usage: make-dmg.sh /path/to/Dictator.app [output.dmg]}"
OUT="${2:-$HOME/Desktop/Dictator.dmg}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BG1="$ROOT/design/dmg-background.png"
BG2="$ROOT/design/dmg-background@2x.png"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Dictator.app"

# Assemble a HiDPI-aware background: a TIFF with both 1x and 2x reps so it's
# crisp on Retina and correctly sized everywhere. Fall back to the 1x PNG if
# tiffutil or the 2x asset is unavailable.
BG="$BG1"
BG_TIFF="$STAGE/dmg-background.tiff"
if command -v tiffutil >/dev/null 2>&1 && [ -f "$BG2" ]; then
  tiffutil -cathidpicheck "$BG1" "$BG2" -out "$BG_TIFF"
  BG="$BG_TIFF"
fi

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
