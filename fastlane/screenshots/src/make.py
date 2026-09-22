#!/usr/bin/env python3
"""Render an App Store screenshot card from a raw phone screenshot.

    python3 make.py --phone ready.png --out 03-ready.png \
        --headline "Tap the mic." --accent "Speak. Done." \
        --subline "One tap from any app, then just talk."

The headline is two lines: `--headline` in white, `--accent` in mint. Output is
1284x2778 (iPhone 6.5"), which App Store Connect also accepts for the 6.7" slot
when scaled. Needs a Chromium (Playwright's, at $PLAYWRIGHT_BROWSERS_PATH or
/opt/pw-browsers) and the Inter woff2 files next to this script in fonts/
(fetch once from Google Fonts: Inter 400, 600, 800).

No price words on a screenshot, ever (guideline 2.3.7): not "free", not
"no subscription", not a dollar amount. The script refuses them.
"""
import argparse, glob, html, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PRICE_WORDS = re.compile(r"\bfree\b|subscription|\$\s?\d|/mo\b|per month|a month", re.I)


def chromium():
    roots = [os.environ.get("PLAYWRIGHT_BROWSERS_PATH", ""), "/opt/pw-browsers"]
    for root in roots:
        if not root:
            continue
        for pat in ("chromium_headless_shell-*/chrome-linux/headless_shell",
                    "chromium-*/chrome-linux/chrome",
                    "chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium"):
            hits = sorted(glob.glob(os.path.join(root, pat)))
            if hits:
                return hits[-1]
    for name in ("chromium", "chromium-browser", "google-chrome"):
        path = shutil.which(name)
        if path:
            return path
    sys.exit("no Chromium found; set PLAYWRIGHT_BROWSERS_PATH")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phone", required=True, help="raw phone screenshot PNG")
    ap.add_argument("--out", required=True)
    ap.add_argument("--headline", required=True, help="first line, white")
    ap.add_argument("--accent", required=True, help="second line, mint")
    ap.add_argument("--subline", default="")
    ap.add_argument("--phone-top", type=int, default=560)
    ap.add_argument("--subline-top", type=int, default=470)
    ap.add_argument("--fonts", default=os.path.join(HERE, "fonts"))
    a = ap.parse_args()

    for label, text in (("headline", a.headline), ("accent", a.accent), ("subline", a.subline)):
        if PRICE_WORDS.search(text):
            sys.exit(f"{label} contains a price reference ({text!r}); App Review rejects that (2.3.7)")

    tpl = open(os.path.join(HERE, "card.html"), encoding="utf-8").read()
    page = (tpl
            .replace("{{FONT_DIR}}", "file://" + os.path.abspath(a.fonts))
            .replace("{{HEADLINE}}", f"{html.escape(a.headline)}<br><span class=\"accent\">{html.escape(a.accent)}</span>")
            .replace("{{SUBLINE}}", html.escape(a.subline))
            .replace("{{SUBLINE_TOP}}", str(a.subline_top))
            .replace("{{PHONE_TOP}}", str(a.phone_top))
            .replace("{{PHONE}}", "file://" + os.path.abspath(a.phone)))

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "card.html")
        open(src, "w", encoding="utf-8").write(page)
        out = os.path.abspath(a.out)
        cmd = [chromium(), "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
               "--allow-file-access-from-files", "--force-device-scale-factor=1",
               "--window-size=1284,2778", f"--screenshot={out}", "file://" + src]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(out)


if __name__ == "__main__":
    main()
