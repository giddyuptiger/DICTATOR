# Swipe decoder replay

A Python replica of `iOS/DictatorKeyboard/SwipeDecoder.swift` that replays the
swipe log from Details → Report a problem against known target words, so a
change to the decoder can be judged on real thumbs before it ships.

- `replica.py`: the 0.1.116 decoder, line for line (all 50 device picks in the
  log reproduce). `python3 replica.py` prints the agreement and the misses.
- `fast.py`: the same scoring vectorised with numpy, plus the tunable options
  that became 0.1.119 (`K` reach scale, `LOC` sum/avg, `GRADED` start penalty)
  and a 300-path synthetic guard set. `BASE` holds the 0.1.116 weights.
- `twoscale.py`: `KS=(0.95, 0.85)` scoring, the shipped form. Run it for the
  before/after numbers.
- `swipes-0.1.116.txt`: the first log, one line per swipe, newest first; the
  intended words are listed (oldest first) in `replica.py` (`DATA`).
- `swipes-0.1.118.txt` + `set118.py`: the second log (`DATA118`), the same
  sentence swiped again on 0.1.118. Tuning on the first set alone gave 37/48
  there but only 25/41 here: always score both, and treat a gain that shows
  on one set only as noise.
- `sweep3.py`: the two-set parameter sweep that chose the 0.1.120 weights.

Adding a new report: paste its `swipe →` lines into a new file, list the
intended words in order, and point `replica.py` at it. Keep the old sets:
tuning must not regress them.

The replica reads the lexicon and bigrams from `iOS/DictatorKeyboard/`, so it
tracks the shipped files. It uses the 0.1.116 device layout (kw 38, top row
y 79, rows 54 apart), logged as the `swipe-layout` line.
