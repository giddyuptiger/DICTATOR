"""Two-set parameter sweep (0.1.120): every config is scored on both ground-truth
sets; a gain that shows on one set only is noise."""
from twoscale import *
from set118 import DATA118
import itertools
def ev(P,data):
    t1=n=0
    for d in data:
        if d['want'] is None: continue
        n+=1; r=decode2(d['path'],d['start'],d['prev'],P)
        if r and r[0][1]==d['want']: t1+=1
    return t1,n
SHIP={**BASE,'KS':(0.95,0.85),'WEND':0.6,'LAM':0.22,'LOC':'sum','TUN':0.85,'CW':0.25,'LENW':0.25,'GRADED':1}
if __name__=='__main__':
    print("BASE(0.1.116 params) A,B:",ev(BASE,DATA),ev(BASE,DATA118),flush=True)
    print("SHIP(0.1.119 params) A,B:",ev(SHIP,DATA),ev(SHIP,DATA118),flush=True)
    res=[]
    for KS,WEND,LAM,TUN,CW,SP in itertools.product(((1.0,0.86),(0.95,0.85),(0.92,0.8)),(0.8,0.6),(0.26,0.22),(0.65,0.85,1.0),(0.25,0.35),(0.6,0.3)):
        P={**BASE,'KS':KS,'WEND':WEND,'LAM':LAM,'LOC':'sum','TUN':TUN,'CW':CW,'LENW':0.25,'STARTPEN':SP,'GRADED':1}
        a,_=ev(P,DATA); b,_=ev(P,DATA118)
        res.append((a+b,a,b,KS,WEND,LAM,TUN,CW,SP)); print(res[-1],flush=True)
    res.sort(reverse=True)
    print("TOP")
    for r in res[:15]: print(r)
    for r in res[:4]:
        P={**BASE,'KS':r[3],'WEND':r[4],'LAM':r[5],'LOC':'sum','TUN':r[6],'CW':r[7],'LENW':0.25,'STARTPEN':r[8],'GRADED':1}
        s1,_,_=evaluate2(P,SYN[:300]); print("synth",r,s1,flush=True)
