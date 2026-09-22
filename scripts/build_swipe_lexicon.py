#!/usr/bin/env python3
"""Build iOS/DictatorKeyboard/swipe-words.txt, the swipe-typing lexicon.

    python3 scripts/build_swipe_lexicon.py [--sub en_50k.txt] [--web 20k.txt] [--dic en_US.dic]

Sources (fetch once, not committed):
  - en_50k.txt: OpenSubtitles English word frequencies, the conversational
    ranking (hermitdave/FrequencyWords, content/2018/en/en_50k.txt).
  - 20k.txt: Google's trillion-word-corpus top 20k (first20hours/google-10000-english,
    20k.txt), the web ranking.
  - en_US.dic (optional): the hunspell en_US dictionary (LibreOffice/dictionaries,
    en/en_US.dic), used only to spot junk: a word whose only entry is
    capitalised is a proper noun ("Oahu", "Patti", "Lisa") and is dropped unless
    it ranks in the web top 3,000 (protects "ok", "us", "american", "january";
    the subtitle rank does not count here because subtitles are full of first
    names); a 2-3 letter token with no entry at all is an abbreviation ("af",
    "asu") and is dropped unless it ranks in the spoken top 5,000 or the web top
    3,000. The dictionary is NOT used to drop anything else: it lacks "is",
    "her", "into", "device", so a plain "not in the dictionary" rule would
    delete the language.

Rules, learned from device tests: keep the top 8k of each list, plus words in
both lists, plus a small app-domain allowlist ("swipe" only appears in the
subtitles list, at rank 14,646). Order by the better of the two ranks, so
"gonna" ranks as speech, not the web. Prune vowel-less tokens (except a few
real ones), contraction stems the subtitle corpus leaves behind ("didn"), and
a blocklist of names that survived the intersection. Contractions are added
near the top as keys=output (the finger draws "dont", the text says "don't").
"""
import argparse, re

SHORT_OK = {"tv","mr","mrs","dr","pm","am","dvd","gps","dj","ok","hmm","mm","shh","btw","omg","cd","jr","sr","lol","brb","idk","tbh","fyi","nyc","ps"}
STEMS = {"didn","doesn","wasn","isn","hasn","couldn","wouldn","shouldn","aren","weren","haven","hadn","mustn","needn","shan","oughtn","ain"}
BLOCK = {"terri","osu","seite","msn","kierkegaard","asp","pdas","http","www","href","php","cgi","xml","html",
         # Seen beating real words in device logs (0.1.116): rare enough that a
         # swipe is never meant as them.
         "af","aff","ir","au","asu","iot","og","sto","ste","los","sid","webb","acer","psi","patti","peru","oahu","yang","soo","thee","ay","eh","un","sweetie","phi","oi","ifyou","la","al","ie","ire","omni","ub","od",
         # Month abbreviations: web-frequent, never swiped.
         "jan","feb","mar","apr","jun","jul","aug","sep","sept","oct","nov","dec"}
PROTECT_SUB = 5000
PROTECT_WEB = 3000
DOMAIN = {"swipe","swiped","swipes","swiping","emoji","emojis","iphone","ipad","ios","mac","macos","app","apps","texting","texted","selfie","selfies","vibes","legit","tacos","dictate","dictated","dictation","dictator","keyboard","keyboards","transcribe","transcribed","transcription","podcast","playlist","spotify","netflix","uber","venmo","zoom","slack","gmail","tiktok","instagram","youtube","whatsapp","facetime","airpods","wifi","bluetooth","laptop","tonight","weekend","skateboard","skateboarding","surfing","brunch","haha","gonna","wanna","gotta","kinda","dude","bro","yep","nope","okay","yeah","hey","ugh","yay","cool","chill","awesome","amazing","stoked",
          # Capitalised-only in hunspell but everyday words; the dictionary filter would drop them.
          "facebook","google","twitter","amazon","apple","microsoft","walmart","starbucks","costco","target","ikea","tesla","toyota","honda","wikipedia","reddit","linkedin","snapchat","pinterest","paypal","android","samsung","xbox","playstation","nintendo","disney","marvel","nasa","nfl","nba","mlb","nhl","olympics","easter","halloween","thanksgiving","christmas","hanukkah","scottish","hispanic","cuban","manhattan","brooklyn","hollywood","broadway","vegas"}
CONTRACTIONS = ["dont=don't","cant=can't","wont=won't","im=I'm","ive=I've","ill=I'll","id=I'd","youre=you're","youve=you've","youll=you'll","youd=you'd","hes=he's","shes=she's","its=it's","were=we're","weve=we've","well=we'll","theyre=they're","theyve=they've","theyll=they'll","thats=that's","whats=what's","theres=there's","heres=here's","wheres=where's","whos=who's","didnt=didn't","doesnt=doesn't","isnt=isn't","wasnt=wasn't","werent=weren't","arent=aren't","havent=haven't","hasnt=hasn't","hadnt=hadn't","wouldnt=wouldn't","couldnt=couldn't","shouldnt=shouldn't","lets=let's","couldve=could've","wouldve=would've","shouldve=should've"]
TOP = 8000


def clean(w):
    return re.fullmatch(r"[a-z]{2,}", w) and (re.search(r"[aeiouy]", w) or w in SHORT_OK)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sub", default="en_50k.txt")
    ap.add_argument("--web", default="20k.txt")
    ap.add_argument("--dic", default=None)
    ap.add_argument("--out", default="iOS/DictatorKeyboard/swipe-words.txt")
    a = ap.parse_args()
    sub = [w for w in (l.split()[0] for l in open(a.sub) if l.strip()) if clean(w)]
    web = [w for w in (l.strip() for l in open(a.web)) if clean(w)]
    rs = {w: i for i, w in enumerate(sub)}
    rw = {w: i for i, w in enumerate(web)}
    keep = ({w for w in web if rw[w] < TOP} | {w for w in sub if rs[w] < TOP}
            | (set(web) & set(sub)) | DOMAIN) - STEMS - BLOCK
    if a.dic:
        lower, anycase = set(), set()
        for line in open(a.dic, encoding="utf-8", errors="ignore"):
            w = line.split("/")[0].strip()
            if w.isalpha():
                anycase.add(w.lower())
                if w[0].islower():
                    lower.add(w)
        def junk(w):
            if w in DOMAIN:
                return False
            if w in anycase and w not in lower:
                # Proper noun: only ever capitalised. Subtitles are full of
                # first names ("lisa" ranks 1,948 there), so only the web rank
                # protects these ("us", "ok", "american", "january").
                return rw.get(w, 10**9) >= PROTECT_WEB
            if len(w) <= 3 and w not in anycase:
                # An abbreviation the dictionary has never heard of.
                return rs.get(w, 10**9) >= PROTECT_SUB and rw.get(w, 10**9) >= PROTECT_WEB
            return False
        dropped = sorted(w for w in keep if junk(w))
        keep -= set(dropped)
        print(f"dictionary filter dropped {len(dropped)}: {' '.join(dropped[:60])} ...")
    merged = sorted(keep, key=lambda w: min(rw.get(w, 10**9), rs.get(w, 10**9)))
    lines = merged[:150] + CONTRACTIONS + merged[150:]
    open(a.out, "w").write("\n".join(lines) + "\n")
    print(f"{a.out}: {len(lines)} entries")


if __name__ == "__main__":
    main()
