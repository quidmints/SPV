# Round 2: pressure-test the ring-fence verdict with the channels sim1 ignored.
# sim1 measured ONLY channel C (amplified in-width LVR) at ONE adoption (10%), assuming
# QU!D is a passive bystander. But QU!D wants to CAPTURE value (be the leverage swap venue,
# earn Liquity's 75%-to-SP). Capturing value re-couples QU!D to the leverage. Three channels:
#   A = venue lag-drain   : voluntary opens/unwinds routed through QU!D's pool (correlated toxic flow)
#   B = SP tail-absorption : if QU!D earns the 75% interest via Liquity's Stability Pool
#   C = holding-LVR        : amplified in-width LVR while positions are open  (sim1)
# Plus: ADOPTION SCALING (sim1 only did 10%) and realistic MCR+penalty liquidation.
import json, math, time, statistics
ser=json.load(open("eth_daily.json")); px=[p for _,p in ser]; ts=[t for t,_ in ser]
r=[math.log(px[i]/px[i-1]) for i in range(1,len(px))]; N=len(r)
def yr(i): return int(time.gmtime(ts[i+1]/1000).tm_year)
YEARS=sorted(set(yr(i) for i in range(N)))
sigma=math.sqrt(statistics.pvariance(r)*365)
K=0.71; RANGE=0.02; THETA=0.33; Y=0.06; F=0.02; S0=0.03; MCR=1.10

def alive(L):
    liq=1.0/L; out=[]; live=True; pk=px[0]
    for i in range(1,len(px)):
        p=px[i]
        if live:
            if p>pk: pk=p
            if p<=pk*(1-liq): live=False
        else:
            if p>=pk: live=True; pk=p
        out.append(1 if live else 0)
    return out

def surplus(extra):
    S=S0; mn=S; by={y:0.0 for y in YEARS}
    for i in range(N):
        th=THETA+extra(i)
        d=Y/365+F*th/365-K*th*min(r[i]*r[i],RANGE*RANGE)
        S+=d; mn=min(mn,S); by[yr(i)]+=d
    return S,mn,by
base=surplus(lambda i:0.0)
print(f"days={N} vol={sigma:.0%}   baseline surplus: minS={base[1]:.1%} finalS={base[0]:.1%} (grows ~4%/yr)")

# ============ CHANNEL C, now ACROSS ADOPTION (sim1 only did LEV_E=10%) ============
print("\n=== C) holding-LVR externality vs ADOPTION (fragile: amp unwinds in stress) ===")
print(f"{'LEV_E':>7}{'L':>4} | {'minS':>8}  verdict")
for LEV_E in [0.10,0.25,0.50,0.75,1.00]:
    for L in [3,5]:
        al=alive(L); S,mn,by=surplus(lambda i:(L-1)*LEV_E*al[i])
        v="ok" if mn>0.0 else ("THIN(<1%)" if mn>-0.0 else "INSOLVENT")
        v="INSOLVENT" if mn<0 else ("thin" if mn<0.01 else "ok")
        print(f"{LEV_E:>7.0%}{L:>4} | {mn:>8.1%}  {v}")

# ============ CHANNEL A: QU!D as the leverage swap venue (voluntary flow) ============
# Each leverage open/unwind routes BOLD<->ETH through QU!D's pool, priced at the TWAP with a
# lag <= RANGE. Flow is CORRELATED (opens in calm, delever in stress) -> lands at the wide-lag
# end. Per voluntary unwind event the cohort notional V=LEV_E*L turns over and pays ~lag.
# Upper bound: notional turns over TURN times/yr, each fill at the width lag.
print("\n=== A) venue lag-drain UPPER BOUND if QU!D is the leverage swap venue ===")
print(f"{'LEV_E':>7}{'L':>4}{'turn/yr':>9} | {'drain/yr':>9}  vs surplus growth ~4%/yr")
for LEV_E in [0.10,0.50]:
    for L in [3,5]:
        V=LEV_E*L
        for TURN in [2,4]:
            drain=V*TURN*RANGE
            flag="  >> SWAMPS surplus" if drain>0.04 else ""
            print(f"{LEV_E:>7.0%}{L:>4}{TURN:>9} | {drain:>8.1%}{flag}")

# refined: route ONLY the stress delever (not opens) through the pool, dated by alive() unwinds
print("\n  A') stress-only delever routed through pool (cohort sheds on each unwind event):")
for LEV_E in [0.10,0.50]:
    for L in [3,5]:
        V=LEV_E*L; al=alive(L); prev=1; by={y:0.0 for y in YEARS}
        for i,a in enumerate(al):
            if prev==1 and a==0: by[yr(i)]+= V*min(abs(r[i]),RANGE)  # forced shed at that day's lag
            prev=a
        tot=sum(by.values()); wy=max(by.items(),key=lambda kv:kv[1])
        print(f"  LEV_E={LEV_E:.0%} L={L}: 11y total {tot:.1%}, worst-yr {wy[0]}:{wy[1]:.1%}")

# ============ CHANNEL B: QU!D earns the 75% interest via Liquity Stability Pool ============
# SP deposit=1. Earns sp_apr = branch_rate*0.75 (assume SP ~ debt-sized). Absorbs liquidations:
# Liquity liquidates at MCR=110% so the SP normally books the ~10% buffer as GAIN; but on a day
# whose drop exceeds the buffer (oracle/gas lag, gap-down), the SP eats (drop-buffer)*at_risk.
print("\n=== B) SP P&L if QU!D captures the 75%-to-SP interest (per unit SP deposit) ===")
BUF=1-1/MCR  # ~9.1% headroom before SP absorbs at a loss
print(f"{'rate':>6}{'at_risk':>8} | {'11y net':>9}{'worst-yr':>14}{'#loss-yrs':>10}")
for rate in [0.05,0.10,0.15]:
  for at_risk in [0.10,0.25]:
    sp_apr=rate*0.75; by={y:0.0 for y in YEARS}
    for i in range(N):
        by[yr(i)]+=sp_apr/365
        drop=-r[i]
        if drop>BUF: by[yr(i)]-=(drop-BUF)*at_risk          # tail absorption
        elif drop>0: by[yr(i)]+=0.05*max(0.0,(drop)/BUF)*at_risk*0.0  # (orderly penalty ~0, ignore)
    tot=sum(by.values()); wy=min(by.items(),key=lambda kv:kv[1]); nloss=sum(1 for v in by.values() if v<0)
    print(f"{rate:>6.0%}{at_risk:>8.0%} | {tot:>8.0%}{(str(wy[0])+':'+format(wy[1],'+.0%')):>14}{nloss:>10}")

# ============ realistic leveraged-LP own P&L: liquidate at MCR + 5% penalty ============
print("\n=== D) leveraged LP own P&L, MCR(110%)+5% penalty liquidation (refines sim1) ===")
RATE=0.07; PEN=0.05
def lp_pnl(L):
    by={y:0.0 for y in YEARS}; nliq={y:0 for y in YEARS}; eq=1.0; pk=px[0]
    # liquidation when price falls so coll ratio hits MCR: entry coll ratio ~ L/(L-1);
    # drop_to_liq = 1 - (L-1)/L*MCR... approximate liq drawdown as (1/L)/MCR ~ slightly tighter than 1/L
    ddliq=(1.0/L)/MCR
    for i in range(N):
        p=px[i+1]
        if L>1 and p<=pk*(1-ddliq):
            by[yr(i)]-=eq+PEN; nliq[yr(i)]+=1; eq=1.0; pk=p; continue
        if p>pk: pk=p
        d=L*(Y/365+F*THETA/365-K*min(r[i]*r[i],RANGE*RANGE))-(L-1)*RATE/365
        eq+=d; by[yr(i)]+=d
    return sum(by.values()), sum(nliq.values())
for L in [1,2,3,5]:
    t,nl=lp_pnl(L); print(f"  L={L}: 11y P&L {t:>8.0%}   liquidations={nl}")
