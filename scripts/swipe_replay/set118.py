import re
from replica import LINE
raw=[l for l in open('swipes-0.1.118.txt') if l.startswith('swipe →')][::-1]
intended=["okay","let's","test","swipe","texting","at","version","looks","like","it","didn't","add","space","after","that","word","when","typed",
          "manually","manually","so","let's","please","make","sure","it","adds","space","after","each","swiped","word","immediately","instead","of","upon",None,"adding","the","next","swiped","word"]
assert len(raw)==len(intended),(len(raw),len(intended))
DATA118=[]
for l,want in zip(raw,intended):
    m=LINE.match(l.strip()); pick,cands,start,prev,pts=m.groups()
    path=[tuple(map(float,p.split(','))) for p in pts.split(';')]
    DATA118.append(dict(pick=pick,logged=cands,start=start,prev=(None if prev=='-' else prev),path=path,want=want))
