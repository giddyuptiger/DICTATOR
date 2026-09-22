import math, re
KW=38.0
layout="a=41,133 b=265,187 c=175,187 d=131,133 e=111,79 f=175,133 g=220,133 h=265,133 i=330,79 j=309,133 k=354,133 l=399,133 m=355,187 n=310,187 o=373,79 p=417,79 q=23,79 r=154,79 s=86,133 t=198,79 u=286,79 v=220,187 w=67,79 x=130,187 y=242,79 z=86,187"
C={kv.split('=')[0]:tuple(map(float,kv.split('=')[1].split(','))) for kv in layout.split()}
ROOT='/home/user/DICTATOR/iOS/DictatorKeyboard/'
words=[]
for line in open(ROOT+'swipe-words.txt'):
    line=line.strip()
    if not line: continue
    keys,out=(line.split('=',1) if '=' in line else (line,line))
    col=[]
    for ch in keys:
        if not col or col[-1]!=ch: col.append(ch)
    words.append((col,out))
byfirst={}
for i,(col,out) in enumerate(words): byfirst.setdefault(col[0],[]).append(i)
# bigrams: keyed by the entry's OUTPUT? the Swift uses entryBigramID built in rebuildBuckets — check: we mirror by output lowercased
big={}
for line in open(ROOT+'swipe-bigrams.txt'):
    a,b,s=line.split()
    big[(a,b)]=int(s)
N=40
def resample(pts,n=N):
    if len(pts)<2: return [pts[0]]*n
    d=[0.0]
    for a,b in zip(pts,pts[1:]): d.append(d[-1]+math.dist(a,b))
    L=d[-1]
    if L==0: return [pts[0]]*n
    out=[]; j=0
    for k in range(n):
        t=L*k/(n-1)
        while j<len(d)-2 and d[j+1]<t: j+=1
        seg=d[j+1]-d[j]; f=0 if seg==0 else (t-d[j])/seg
        out.append((pts[j][0]+(pts[j+1][0]-pts[j][0])*f, pts[j][1]+(pts[j+1][1]-pts[j][1])*f))
    return out
def plen(p): return sum(math.dist(a,b) for a,b in zip(p,p[1:]))
P=dict(TOL=1.4, WEND=1.2, WLOC=1.0, TUN=0.65, LENW=0.25, LAM=0.30, STARTPEN=0.6, CW=0.12, CF=4.5, CC=5.0)
def decode(path, start=None, prev=None, topn=5, P=P, scorer=None):
    rp=resample(path); L=plen(path)
    first=[c for c,p in C.items() if math.dist(p,path[0])<=P['TOL']*KW] or [min(C,key=lambda c:math.dist(C[c],path[0]))]
    last=set([c for c,p in C.items() if math.dist(p,path[-1])<=P['TOL']*KW] or [min(C,key=lambda c:math.dist(C[c],path[-1]))])
    res=[]
    for f in first:
        for rank in byfirst[f]:
            col,out=words[rank]
            if col[-1] not in last: continue
            if scorer: s=scorer(path,rp,L,col,out,rank,start,prev,P)
            else: s=score_v1(path,rp,L,col,out,rank,start,prev,P)
            res.append((s/KW,out))
    res.sort()
    return res[:topn]
def ctx(prev,out,P):
    if prev is None: return 0.0
    s=big.get((prev,out.lower()))
    if s is None: return 0.0
    return min(P['CC'],max(0.0,s/10-P['CF']))
def score_v1(path,rp,L,col,out,rank,start,prev,P):
    ideal=[C[c] for c in col]; il=plen(ideal); ri=resample(ideal)
    shape=sum(math.dist(a,b) for a,b in zip(rp,ri))/N
    end=math.dist(path[0],ideal[0])+math.dist(path[-1],ideal[-1])
    loc=sum(max(0.0,min(math.dist(c,q) for q in rp)-P['TUN']*KW) for c in ideal)/len(ideal)
    lp=abs(math.log((L+0.5*KW)/(il+0.5*KW)))
    sm=P['STARTPEN']*KW if (start and col[0]!=start) else 0.0
    return shape+P['WEND']*end+P['WLOC']*loc+sm+P['LENW']*KW*lp+P['LAM']*KW*math.log10(rank+1)-P['CW']*KW*ctx(prev,out,P)

# dataset: oldest first, with intended words
LINE=re.compile(r"swipe → (\S+) \[(.*?)\] start=(\S) prev=(\S+) n=\d+ (.*)")
raw=[l for l in open('swipes-0.1.116.txt') if l.startswith('swipe →')][::-1]
intended=["okay",None,"okay","let's","test","swipe","texting",None,"looks","like","it",
 "let's","test","swipe","texting","at","version","looks","like","it","didn't","add","space","after","that","word","when","typed","manually",
 "so","let's","please","make","sure","it","adds","space","after","each","swiped","word","immediately","instead","of","upon","adding","the","next","swiped","word"]
assert len(raw)==len(intended),(len(raw),len(intended))
DATA=[]
for l,want in zip(raw,intended):
    m=LINE.match(l.strip()); pick,cands,start,prev,pts=m.groups()
    path=[tuple(map(float,p.split(','))) for p in pts.split(';')]
    prev=None if prev=='-' else prev
    DATA.append(dict(pick=pick,logged=cands,start=start,prev=prev,path=path,want=want))
def evaluate(P=P, scorer=None, verbose=False, data=None):
    data=data or DATA
    top1=top3=n=0; misses=[]
    for d in data:
        if d['want'] is None: continue
        n+=1
        r=decode(d['path'],d['start'],d['prev'],topn=5,P=P,scorer=scorer)
        outs=[o for s,o in r]
        if outs and outs[0]==d['want']: top1+=1
        elif d['want'] in outs[:3]: top3+=1; misses.append((d['want'],outs[:3]))
        else: misses.append((d['want'],outs[:3]))
    if verbose:
        for m in misses: print("   miss:",m)
    return top1,top1+top3,n
if __name__=='__main__':
    # sanity: replica should reproduce the device picks
    agree=0
    for d in DATA:
        r=decode(d['path'],d['start'],d['prev'])
        if r and r[0][1]==d['pick']: agree+=1
        else: print("replica differs:",d['pick'],"vs",[(o,round(s,2)) for s,o in r[:3]],"| logged",d['logged'])
    print("replica agrees with device on",agree,"/",len(DATA))
    print("baseline top1/top3/n:",evaluate(verbose=True))
