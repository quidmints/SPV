# Round 6: economics under "NEVER liquidate" (protective force-unwind). This overturns
# lev_sim4: that model's dominant accretion term was the PENALTY HARVEST (+) collected when
# LPs got liquidated. If QU!D never lets them be liquidated, pen -> 0, AND the surplus now
# EATS the protective-unwind cost (it buys the dumped ETH at the stale-high TWAP lag on the
# would-be-liquidation days). So leverage stops being a profit center and becomes a PRICED PUT.
# This computes the net surplus impact and the break-even put premium (APR on leveraged equity).
import json, math, time
ser=json.load(open("eth_daily.json")); px=[p for _,p in ser]; ts=[t for t,_ in ser]
r=[math.log(px[i]/px[i-1]) for i in range(1,len(px))]; N=len(r)
YEARS=len(set(time.gmtime(ts[i+1]/1000).tm_year for i in range(N)))
K=0.71; BAND=0.02; F=0.02; RATE=0.07; SP_INT=0.75; SPREAD=0.0010; MCR=1.10

def alive(L):
    liq=(1.0/L)/MCR; out=[]; live=True; pk=px[0]
    for i in range(1,len(px)):
        p=px[i]
        if live:
            if p>pk: pk=p
            if p<=pk*(1-liq): live=False
        else:
            if p>=pk: live=True; pk=p
        out.append(1 if live else 0)
    return out

def run(E,L):
    Vt=L*E; dpf=(L-1)/L; al=alive(L); Nn=0.0; prev=1
    a=dict(interest=0.0, spread=0.0, cN=0.0, unwind=0.0)   # pen REMOVED (never liquidate)
    for i in range(N):
        ai=abs(r[i]); op=dv=0.0
        if al[i]==1 and prev==1 and Nn<Vt and ai<0.03: op=min((Vt-Nn)*0.05,Vt-Nn); Nn+=op
        elif Nn>0 and ai>0.05: dv=min(Nn,Nn*ai*2.0); Nn-=dv
        # protective unwind on a would-be-liquidation day: surplus absorbs the dumped ETH at the lag
        if prev==1 and al[i]==0:
            a['unwind'] -= Vt*min(ai,BAND)
        amp=Nn*dpf
        a['interest'] += Nn*dpf*RATE*SP_INT/365     # 75% borrower interest -> QU!D's SP (still earned)
        a['spread']   += op*SPREAD
        a['cN']       += F*amp/365 - K*amp*min(r[i]*r[i],BAND*BAND)
        prev=al[i]
    net=sum(a.values())
    prem = (-net/(E*YEARS)) if net<0 else 0.0   # APR on leveraged equity to break even
    return a, net, prem

print(f"NEVER-LIQUIDATE economics (pen=0, +unwind-absorption). {YEARS}y, RATE={RATE:.0%}, 75%->SP\n")
print(f"{'E':>6}{'L':>4} | {'int':>6}{'spr':>6}{'cN':>7}{'unwind':>8} | {'11y net':>9}{'breakeven put prem (APR/equity)':>32}")
for E in [0.05,0.10,0.20]:
    for L in [3,5]:
        a,net,prem=run(E,L)
        comp=f"{a['interest']*100:>5.1f}{a['spread']*100:>6.1f}{a['cN']*100:>7.1f}{a['unwind']*100:>8.1f}"
        print(f"{E:>6.0%}{L:>4} | {comp} | {net*100:>8.1f}%{prem*100:>28.1f}%")

print("\nReading: 'int' = 75% interest QU!D's SP still earns; 'unwind' = surplus eating the")
print("protective-unwind lag (replaces sim4's penalty HARVEST with a penalty-AVOIDANCE COST).")
print("Net<0 => leverage drains the surplus => the LP must pay that as a PUT PREMIUM (the last")
print("column, % APR on their equity) on top of borrow interest, or unleveraged LPs subsidize them.")
