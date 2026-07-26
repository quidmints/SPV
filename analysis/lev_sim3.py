# Round 3: the 4626-as-collateral fork. Using the QU!D ETH-LP *vault share* as Trove
# collateral COLLAPSES the isolation that made the existing-V2 passthrough safe. Now the
# leveraged position IS a real QU!D LP position, so channels A/C are INTERNAL by construction
# (not optional), and liquidation FORCES a pool withdrawal -> reflexive drain in crashes.
import json, math, time, statistics
ser=json.load(open("eth_daily.json")); px=[p for _,p in ser]; ts=[t for t,_ in ser]
r=[math.log(px[i]/px[i-1]) for i in range(1,len(px))]; N=len(r)
def yr(i): return int(time.gmtime(ts[i+1]/1000).tm_year)
YEARS=sorted(set(yr(i) for i in range(N)))
K=0.71; BAND=0.02; THETA=0.33; Y=0.06; F=0.02; S0=0.03; MCR=1.10

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

# 4626 collateral: leveraged position is REAL QU!D LP. Surplus sees:
#  + amplified FEES on the bigger in-range (leverage helps in calm)
#  - amplified LVR (band-capped)
#  - on liquidation: SP seizes the qETH-LP share -> redeems it -> FORCED pool withdrawal of L*E,
#    sold into the guarded pool at that day's lag = pure drain, no offsetting fee (channel A internal)
def surplus4626(E,L,route_liq=True,cap=None):
    al=alive(L); S=S0; mn=S; by={y:0.0 for y in YEARS}; prev=1
    eff=lambda a: (L-1)*E*a if cap is None else min((L-1)*E*a, cap)
    for i in range(N):
        amp=eff(al[i]); th=THETA+amp
        d=Y/365 + F*th/365 - K*th*min(r[i]*r[i],BAND*BAND)
        if route_liq and prev==1 and al[i]==0:
            wd=L*E if cap is None else min(L*E, cap+E)
            d-= wd*min(abs(r[i]),BAND)
        prev=al[i]; S+=d; mn=min(mn,S); by[yr(i)]+=d
    return S,mn,by

print("baseline surplus minS=3.0% finalS=42.1% (grows ~4%/yr)\n")
print("=== 4626-collateral: surplus survival, INTERNAL coupling vs the external-collateral case ===")
print(f"{'equity E':>9}{'L':>4} | {'4626 minS':>11}{'external minS':>14}  forced-wd cost")
for E in [0.05,0.10,0.20,0.35]:
    for L in [3,5]:
        s4=surplus4626(E,L,True); se=surplus4626(E,L,False)
        tag="  INSOLVENT" if s4[1]<0 else ("  thin" if s4[1]<0.01 else "")
        print(f"{E:>9.0%}{L:>4} | {s4[1]:>11.1%}{se[1]:>14.1%}  {se[1]-s4[1]:>6.1%}{tag}")

print("\n=== same, WITH a hard cap on socialized leverage notional (cap = % of backing) ===")
print(f"{'equity E':>9}{'L':>4}{'cap':>6} | {'minS':>8}")
for E in [0.20,0.35]:
    for L in [5]:
        for cap in [0.10,0.25,0.50]:
            s4=surplus4626(E,L,True,cap=cap)
            print(f"{E:>9.0%}{L:>4}{cap:>6.0%} | {s4[1]:>8.1%}{'  INSOLVENT' if s4[1]<0 else ''}")

print("\n=== worst-year forced-withdrawal drain (the reflexive crash hit), 4626, by year ===")
for E in [0.10,0.20]:
    for L in [5]:
        al=alive(L); prev=1; wy={y:0.0 for y in YEARS}
        for i in range(N):
            if prev==1 and al[i]==0: wy[yr(i)]+= (L*E)*min(abs(r[i]),BAND)
            prev=al[i]
        w=max(wy.items(),key=lambda kv:kv[1])
        print(f"  E={E:.0%} L={L}: worst-yr forced-withdraw drain {w[0]}: {w[1]:.1%} of backing"
              f"   (single-cascade notional pulled = {L*E:.0%} of backing)")
