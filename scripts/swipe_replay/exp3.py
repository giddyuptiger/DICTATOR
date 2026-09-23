from twoscale import *
import twoscale, fast
from set118 import DATA118
from set120 import DATA120
SETS=[("A",DATA),("B",DATA118),("C",DATA120)]
SHIP={**BASE,'KS':(0.95,0.85),'WEND':0.6,'LAM':0.22,'LOC':'sum','TUN':0.85,'CW':0.25,'LENW':0.25,'GRADED':1}
TOP,BOT=79.0,187.0
def clamp(path,m): return [(x,min(max(y,TOP-m),BOT+m)) for x,y in path]
def ev(P,data,block=()):
    t1=n=0
    for d in data:
        if d['want'] is None: continue
        n+=1
        path=clamp(d['path'],P['CLAMP']) if 'CLAMP' in P else d['path']
        r=[(s,o) for s,o in decode2(path,d['start'],d['prev'],P,topn=6) if o not in block]
        if r and r[0][1]==d['want']: t1+=1
    return t1,n
def run(P,label,block=()):
    res=[ev(P,d,block) for _,d in SETS]
    tot=sum(r[0] for r in res); n=sum(r[1] for r in res)
    print(f"{label:48s} A {res[0][0]}/{res[0][1]}  B {res[1][0]}/{res[1][1]}  C {res[2][0]}/{res[2][1]}  all {tot}/{n}",flush=True)
BLOCK={"terry","abs","keys"}
run(SHIP,"SHIP (0.1.120)")
run(SHIP,"+ block terry/abs/keys",BLOCK)
run({**SHIP,'CLAMP':0.0},"+ clamp y to rows")
run({**SHIP,'CLAMP':10.0},"+ clamp y to rows+10")
run({**SHIP,'TOL':2.0},"+ endpoint tolerance 2.0")
run({**SHIP,'LAM':0.30},"+ LAM 0.30")
run({**SHIP,'CW':0.4},"+ CW 0.40")
run({**SHIP,'WEND':0.45},"+ WEND 0.45")
run({**SHIP,'CLAMP':0.0,'TOL':2.0},"+ clamp + tol",BLOCK)
run({**SHIP,'CLAMP':0.0,'TOL':2.0,'LAM':0.30},"+ clamp + tol + LAM .3",BLOCK)
run({**SHIP,'CLAMP':0.0,'TOL':2.0,'LAM':0.30,'CW':0.4},"+ clamp + tol + LAM .3 + CW .4",BLOCK)
run({**SHIP,'CLAMP':0.0,'TOL':2.0,'CW':0.4},"+ clamp + tol + CW .4",BLOCK)
