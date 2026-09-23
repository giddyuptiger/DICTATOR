import re
from replica import LINE
raw=[l for l in open('swipes-0.1.120.txt') if l.startswith('swipe →')][::-1]
# oldest first: attempt 1 (okay ... now), then attempt 2 (okay ... yeah)
intended=["okay","let's","try","this","swipe","to","text","feature","and","see","if","it","actually","works","now",
          "okay","let's","try","this","swipe","to","text","feature","and","see","if","it","actually","works","now","looks","like","it's","getting","closer","yeah"]
assert len(raw)==len(intended),(len(raw),len(intended))
DATA120=[]
for l,want in zip(raw,intended):
    m=LINE.match(l.strip()); pick,cands,start,prev,pts=m.groups()
    path=[tuple(map(float,p.split(','))) for p in pts.split(';')]
    DATA120.append(dict(pick=pick,logged=cands,start=start,prev=(None if prev=='-' else prev),path=path,want=want))
