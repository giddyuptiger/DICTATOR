#!/usr/bin/env python3
"""Build iOS/DictatorKeyboard/swipe-bigrams.txt, the swipe decoder's context model.

    python3 scripts/build_swipe_bigrams.py --source count_2w.txt

Source (fetch once, not committed): Peter Norvig's count_2w.txt, 286k two-word
counts from the Google Web Trillion Word Corpus (norvig.com/ngrams; a mirror is
vendored in github.com/gjorm/WordSeg). Lines are "w1 w2<TAB>count"; "<S>" marks a
sentence start.

Kept: pairs whose words are both in the swipe lexicon (matched by their swipe
keys, i.e. lowercase letters with apostrophes removed, so "don't" matches
"dont"), plus "<s>" pairs for sentence starts. Written as "prev word score"
where score = round(10 * log10(count)); the decoder turns the previous word's
row into a bonus for candidates that commonly follow it.
"""
import argparse, math, re


def keys(w):
    return re.sub(r"[^a-z]", "", w.lower())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="count_2w.txt")
    ap.add_argument("--lexicon", default="iOS/DictatorKeyboard/swipe-words.txt")
    ap.add_argument("--out", default="iOS/DictatorKeyboard/swipe-bigrams.txt")
    ap.add_argument("--min-count", type=int, default=50_000)
    a = ap.parse_args()
    lex = set()
    for line in open(a.lexicon):
        line = line.strip()
        if not line:
            continue
        out = line.split("=", 1)[1] if "=" in line else line
        k = keys(out)
        if k:
            lex.add(k)
    counts = {}   # (prev, word) -> summed count; case variants collide once lowercased
    for line in open(a.source, encoding="utf-8", errors="ignore"):
        try:
            pair, count = line.rstrip("\n").split("\t")
            w1, w2 = pair.split(" ")
            count = int(count)
        except ValueError:
            continue
        if count < a.min_count:
            continue
        k1 = "<s>" if w1 == "<S>" else keys(w1)
        k2 = keys(w2)
        if (k1 != "<s>" and k1 not in lex) or k2 not in lex:
            continue
        counts[(k1, k2)] = counts.get((k1, k2), 0) + count
    rows = sorted((k1, k2, round(10 * math.log10(c))) for (k1, k2), c in counts.items())
    with open(a.out, "w") as f:
        for k1, k2, s in rows:
            f.write(f"{k1} {k2} {s}\n")
    print(f"{a.out}: {len(rows)} pairs")


if __name__ == "__main__":
    main()
