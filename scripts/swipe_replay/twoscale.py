from fast import *
import fast
def decode2(path,start,prev,P,topn=3):
    """Option K2: score under each scale in P['KS'] and keep the per-word minimum."""
    ks=P.get('KS',(1.0,))
    allres={}
    for k in ks:
        r=decode(path,start,prev,{**P,'K':k},topn=8)
        for s,o in r:
            if o not in allres or s<allres[o]: allres[o]=s
    return sorted(((s,o) for o,s in allres.items()))[:topn]
def evaluate2(P,data=DATA,verbose=False):
    t1=t3=n=0
    for d in data:
        if d['want'] is None: continue
        n+=1; r=decode2(d['path'],d['start'],d['prev'],P); outs=[o for s,o in r]
        if outs and outs[0]==d['want']: t1+=1
        else:
            if d['want'] in outs: t3+=1
            if verbose: print("   miss:",d['want'],[(o,round(float(s),2)) for s,o in r])
    return t1,t1+t3,n
def run2(P,label="",verbose=False):
    t1,t3,n=evaluate2(P,verbose=verbose); s1,_,sn=evaluate2(P,SYN[:300])
    print(f"{label:70s} real {t1}/{n} top3 {t3}  synth {s1}/{sn}",flush=True)
if __name__=='__main__':
    for ks in ((1.0,),(1.0,0.86),(0.93,0.86),(1.0,0.9,0.82)):
        for wend,lam in ((1.2,0.3),(0.8,0.22),(0.6,0.22)):
            run2({**BASE,'KS':ks,'WEND':wend,'LAM':lam,'GRADED':1},f"KS={ks} WEND={wend} LAM={lam} graded")
