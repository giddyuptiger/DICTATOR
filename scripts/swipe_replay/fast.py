import math, random, numpy as np
from replica import C, words, byfirst, KW, N, resample, plen, DATA, big, ROOT
keystext={}
for line in open(ROOT+'swipe-words.txt'):
    line=line.strip()
    if not line: continue
    k,o=(line.split('=',1) if '=' in line else (line,line)); keystext[o]=k
CX=220.0
W=len(words); MAXL=max(len(c) for c,o in words)
LET=np.full((W,MAXL),-1,int); LN=np.zeros(W,int)
A='abcdefghijklmnopqrstuvwxyz'
for i,(col,out) in enumerate(words):
    LN[i]=len(col)
    for j,ch in enumerate(col): LET[i,j]=A.index(ch)
CEN=np.array([C[ch] for ch in A])
LOGR=np.log10(np.arange(W)+1.0)
_cache={}
def ideal_for(k):
    if k in _cache: return _cache[k]
    cen=CEN.copy(); cen[:,0]=CX+(cen[:,0]-CX)*k
    RI=np.zeros((W,N,2)); IL=np.zeros(W); LC=np.zeros((W,MAXL,2)); 
    for i in range(W):
        pts=[tuple(cen[LET[i,j]]) for j in range(LN[i])]
        RI[i]=resample(pts); IL[i]=plen(pts)
        for j in range(LN[i]): LC[i,j]=cen[LET[i,j]]
    _cache[k]=(RI,IL,LC,cen); return _cache[k]
FIRST=LET[:,0]; LAST=LET[np.arange(W),LN-1]
def decode(path,start,prev,P,topn=3):
    k=P.get('K',1.0); RI,IL,LC,cen=ideal_for(k)
    p0=np.array(path[0]); p1=np.array(path[-1])
    rp=np.array(resample(path)); L=plen(path)
    d0=np.linalg.norm(CEN-p0,axis=1); d1=np.linalg.norm(CEN-p1,axis=1)
    tol=P['TOL']*KW
    f=np.where(d0<=tol)[0]; l=np.where(d1<=tol)[0]
    if len(f)==0: f=np.array([d0.argmin()])
    if len(l)==0: l=np.array([d1.argmin()])
    mask=np.isin(FIRST,f)&np.isin(LAST,l)
    idx=np.where(mask)[0]
    if len(idx)==0: return []
    shape=np.linalg.norm(RI[idx]-rp[None],axis=2).mean(1)
    end=np.linalg.norm(LC[idx,0]-p0,axis=1)+np.linalg.norm(LC[idx,LN[idx]-1]-p1,axis=1)
    lc=LC[idx]
    dd=np.linalg.norm(lc[:,:,None,:]-rp[None,None,:,:],axis=3).min(2)
    valid=np.arange(MAXL)[None,:]<LN[idx][:,None]
    pen=np.where(valid,np.maximum(0,dd-P['TUN']*KW),0)
    loc=pen.sum(1)/LN[idx] if P.get('LOC','avg')=='avg' else pen.sum(1)
    lp=np.abs(np.log((L+0.5*KW)/(IL[idx]+0.5*KW)))
    sm=np.zeros(len(idx))
    if start:
        si=A.index(start); mis=FIRST[idx]!=si
        if P.get('GRADED'):
            d=np.linalg.norm(CEN[FIRST[idx]]-p0,axis=1)/KW
            sm=np.where(mis,P['STARTPEN']*KW*np.clip((d-0.5)/0.5,0,1),0)
        else: sm=np.where(mis,P['STARTPEN']*KW,0)
    cx=np.zeros(len(idx))
    if prev is not None:
        for n,i in enumerate(idx):
            s=big.get((prev,keystext.get(words[i][1],words[i][1])))
            if s is not None: cx[n]=min(P['CC'],max(0.0,s/10-P['CF']))
    score=shape+P['WEND']*end+P['WLOC']*loc+sm+P['LENW']*KW*lp+P['LAM']*KW*LOGR[idx]-P['CW']*KW*cx
    order=np.argsort(score)[:topn]
    return [(score[o]/KW,words[idx[o]][1]) for o in order]
def synth(col, mid=0.22, endn=0.12, cut=0.2):
    ideal=[C[c] for c in col]; pts=[]
    for i,(x,y) in enumerate(ideal):
        if 0<i<len(ideal)-1:
            px,py=ideal[i-1]; nx,ny=ideal[i+1]; mx,my=(px+nx)/2,(py+ny)/2
            x,y=x+(mx-x)*cut*random.random(), y+(my-y)*cut*random.random()
        pts.append((x,y))
    dense=[]
    for a,b in zip(pts,pts[1:]):
        for k in range(8): dense.append((a[0]+(b[0]-a[0])*k/8, a[1]+(b[1]-a[1])*k/8))
    dense.append(pts[-1])
    return [(x+random.gauss(0,(endn if i in (0,len(dense)-1) else mid)*KW), y+random.gauss(0,(endn if i in (0,len(dense)-1) else mid)*KW)) for i,(x,y) in enumerate(dense)]
random.seed(7); SYN=[]
for _ in range(300):
    r=int(min(W-1, abs(random.gauss(0,1))*3000+random.random()*300)); col,out=words[r]
    if len(col)<2: continue
    SYN.append(dict(path=synth(col),start=col[0],prev=None,want=out))
    SYN.append(dict(path=synth(col,mid=0.3,endn=0.15,cut=0.35),start=col[0],prev=None,want=out))
def evaluate(P,data=DATA,verbose=False):
    t1=t3=n=0
    for d in data:
        if d['want'] is None: continue
        n+=1; r=decode(d['path'],d['start'],d['prev'],P); outs=[o for s,o in r]
        if outs and outs[0]==d['want']: t1+=1
        else:
            if d['want'] in outs: t3+=1
            if verbose: print("   miss:",d['want'],[(o,round(float(s),2)) for s,o in r])
    return t1,t1+t3,n
BASE=dict(TOL=1.4, WEND=1.2, WLOC=1.0, TUN=0.65, LENW=0.25, LAM=0.30, STARTPEN=0.6, CW=0.12, CF=4.5, CC=5.0)
def run(P,label="",verbose=False):
    t1,t3,n=evaluate(P,verbose=verbose); s1,_,sn=evaluate(P,SYN)
    print(f"{label:70s} real {t1}/{n} top3 {t3}  synth {s1}/{sn}",flush=True); return t1,s1
if __name__=='__main__':
    import time; t=time.time(); run(BASE,"baseline"); print("secs",round(time.time()-t,1))
