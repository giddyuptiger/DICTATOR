#!/usr/bin/env python3
"""Prepend a release to docs/appcast.xml (the Sparkle feed).

    python3 scripts/sparkle_appcast.py --version 131 --short 0.1.124 \
        --url https://github.com/giddyuptiger/DICTATOR/releases/download/mac-v0.1.124/Dictator.dmg \
        --length 24801234 --signature <edSignature> [--notes-url URL] [--min-os 14.0] [--keep 20]

`--version` is CFBundleVersion (must increase every release; the workflow uses the
run number), `--short` the version people see. The newest item goes first; only the
last `--keep` items are retained.
"""
import argparse, datetime, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--file", default="docs/appcast.xml")
ap.add_argument("--version", required=True)
ap.add_argument("--short", required=True)
ap.add_argument("--url", required=True)
ap.add_argument("--length", required=True)
ap.add_argument("--signature", required=True)
ap.add_argument("--notes-url", default="")
ap.add_argument("--min-os", default="14.0")
ap.add_argument("--keep", type=int, default=20)
a = ap.parse_args()

now = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
notes = f"      <sparkle:releaseNotesLink>{a.notes_url}</sparkle:releaseNotesLink>\n" if a.notes_url else ""
item = f"""    <item>
      <title>Dictator {a.short}</title>
      <pubDate>{now}</pubDate>
      <sparkle:version>{a.version}</sparkle:version>
      <sparkle:shortVersionString>{a.short}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{a.min_os}</sparkle:minimumSystemVersion>
{notes}      <enclosure url="{a.url}" length="{a.length}" type="application/octet-stream" sparkle:edSignature="{a.signature}"/>
    </item>
"""
xml = open(a.file, encoding="utf-8").read()
items = re.findall(r"    <item>.*?</item>\n", xml, flags=re.S)
if any(f"<sparkle:version>{a.version}</sparkle:version>" in i for i in items):
    print(f"appcast already has version {a.version}; nothing to do"); sys.exit(0)
# Everything before the first item (or before the channel's close when empty).
head = xml.split("    <item>")[0] if items else xml.split("  </channel>")[0]
tail = "  </channel>\n</rss>\n"
kept = [item] + items[: max(0, a.keep - 1)]
open(a.file, "w", encoding="utf-8").write(head + "".join(kept) + tail)
print(f"appcast: added {a.short} (build {a.version}); {len(kept)} items")
