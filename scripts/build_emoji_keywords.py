#!/usr/bin/env python3
"""Build iOS/DictatorKeyboard/emoji-keywords.txt, the index behind emoji search.

    python3 scripts/build_emoji_keywords.py --cldr cldr-en.json --derived cldr-en-derived.json

Sources (fetch once, not committed; both from github.com/unicode-org/cldr-json,
cldr-json/cldr-annotations-full/annotations/en/annotations.json and
cldr-json/cldr-annotations-derived-full/annotationsDerived/en/annotations.json):
Unicode's own English names ("tts") and keywords ("default") for every emoji.

Output, one line per emoji in the keyboard's catalogue (EmojiData.swift), in
catalogue order: `emoji<TAB>name<TAB>keyword keyword ...`, all lowercase. A few
everyday synonyms Unicode does not list (lol, haha, ok, yay...) are added here.
"""
import argparse, json, re

EXTRA = {
    "😂": "lol haha lmao funny crying laughing",
    "🤣": "lol haha lmao rofl funny",
    "😆": "haha lol",
    "😊": "happy smile",
    "❤️": "love heart red",
    "😍": "love crush",
    "🥰": "love",
    "😘": "kiss love",
    "👍": "ok yes thumbs up good like",
    "👎": "no thumbs down bad dislike",
    "👌": "ok okay perfect",
    "🙏": "please thanks thank you pray",
    "🔥": "fire lit hot",
    "💯": "hundred perfect",
    "🎉": "party congrats congratulations celebrate yay",
    "🥳": "party celebrate birthday yay",
    "😭": "cry crying sad sob",
    "😢": "cry sad tear",
    "😅": "sweat nervous phew",
    "🙄": "eyeroll whatever",
    "😬": "grimace awkward yikes",
    "🤔": "thinking hmm",
    "🤷": "shrug dunno",
    "👋": "hi hello bye wave",
    "✅": "check done yes",
    "❌": "no cross wrong",
    "⭐": "star",
    "🚀": "rocket launch ship",
    "☕": "coffee",
    "🍺": "beer",
    "🍕": "pizza",
    "🛹": "skateboard skate",
    "🏄": "surf surfing",
    "💪": "strong flex muscle",
    "🙌": "yay hooray praise",
    "👏": "clap applause bravo",
    "😴": "sleep tired zzz",
    "🤮": "sick gross puke",
    "🥲": "happy cry bittersweet",
    "🫡": "salute yes sir",
    "💀": "dead skull lol",
    "🫠": "melting",
    "🙃": "upside down",
    "😉": "wink",
    "🤝": "deal handshake thanks",
    "🎂": "birthday cake",
    "🎁": "gift present",
    "💩": "poop",
}

def norm(s):
    return s.replace("️", "")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cldr", required=True)
    ap.add_argument("--derived", required=True)
    ap.add_argument("--data", default="iOS/DictatorKeyboard/EmojiData.swift")
    ap.add_argument("--out", default="iOS/DictatorKeyboard/emoji-keywords.txt")
    a = ap.parse_args()
    ann = {}
    for path, key in ((a.cldr, "annotations"), (a.derived, "annotationsDerived")):
        d = json.load(open(path, encoding="utf-8"))[key]["annotations"]
        for k, v in d.items():
            ann[norm(k)] = v
    src = open(a.data, encoding="utf-8").read()
    body = src[src.index("private static let smileys"):]
    seen, out, missing = set(), [], []
    for e in re.findall(r'"([^"\\]+)"', body):
        if e in seen or len(e) > 16 or e in ("🏻", "🏼", "🏽", "🏾", "🏿"):
            continue
        seen.add(e)
        v = ann.get(norm(e))
        if v is None:
            missing.append(e); continue
        name = " ".join(v.get("tts", [])).lower()
        words = []
        for w in v.get("default", []):
            for t in re.split(r"[\s|,:]+", w.lower()):
                if t and t not in words: words.append(t)
        for t in EXTRA.get(e, "").split():
            if t not in words: words.append(t)
        name = re.sub(r"[^\w\s'-]", " ", name).strip()
        out.append(f"{e}\t{name}\t{' '.join(words)}")
    open(a.out, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"{a.out}: {len(out)} emoji indexed; {len(missing)} without annotations: {' '.join(missing[:40])}")

if __name__ == "__main__":
    main()
