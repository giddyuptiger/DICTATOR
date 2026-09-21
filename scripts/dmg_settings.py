# dmgbuild settings for the branded Dictator installer DMG.
#
# WHY dmgbuild (not create-dmg) on CI: dmgbuild writes the window background and
# icon positions straight into the DMG's .DS_Store, with no Finder/AppleScript.
# That is the whole point — create-dmg styles the window by driving Finder, which
# has no GUI session on a headless GitHub Actions runner and silently produces an
# unstyled DMG. dmgbuild gives the same branded result headlessly.
#
# Geometry mirrors scripts/make-dmg.sh (the local builder) so the auto-released
# DMG looks identical to the hand-built one: a fixed 660x400-point window with
# fixed icon positions, laid out the same on every display.
#
# Invoked by .github/workflows/mac-release.yml:
#   dmgbuild -s scripts/dmg_settings.py \
#     -D app=<path/to/Dictator.app> -D bg=<path/to/background.tiff> \
#     "Dictator" Dictator.dmg
import os.path

app = defines.get("app", "Dictator.app")
bg = defines.get("bg", "design/dmg-background.png")

format = "UDZO"  # compressed, read-only
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [os.path.basename(app)]

background = bg
window_rect = ((200, 120), (660, 400))  # (x, y), (width, height) in points
default_view = "icon-view"
icon_size = 120
icon_locations = {
    os.path.basename(app): (180, 200),
    "Applications": (480, 200),
}
