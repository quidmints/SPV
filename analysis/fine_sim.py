import json, math
# Fine-grained QU!D pool LVR vs the spot-tracking full-width baseline.
# Models: pool price = 30-min TWAP (guard pins spot within 50bps of it),
#         concentrated v3 position width +/-2%, REPACK (re-center) on width exit.
# Measures realized IL (=LVR borne by the basket) and the effective K
# (K=0.125 == full-width/no-guard CPMM floor).

def load(fn):
    s=json.load(open(fn)); return [(t,p) for t,p in s]

def vfx(L, sp, sa, sb):           # v3 amounts at sqrtP within [sa,sb]
    sp=max(min(sp,sb),sa)
    x=L*(1.0/sp - 1.0/sb)         # ETH
    y=L*(sp - sa)                 # USD
    return x,y

def run(series, width=0.02, twap_win=6, guard_bps=50, repack_on_exit=True):
    px=[p for _,p in series]; n=len(px)
    # 30-min TWAP proxy: trailing mean of `twap_win` 5m closes (~30min)
    twap=[]
    for i in range(n):
        w=px[max(0,i-twap_win+1):i+1]; twap.append(sum(w)/len(w))
    # ---- guarded concentrated position tracking the TWAP ----
    Q=twap[0]; Pa=Q*(1-width); Pb=Q*(1+width)
    sp=math.sqrt(Q); sa=math.sqrt(Pa); sb=math.sqrt(Pb)
    L=1.0/( (math.sqrt(Q)-sa) + Q*(1.0/math.sqrt(Q)-1.0/sb) )  # so position value ~=1
    x,y=vfx(L,math.sqrt(Q),sa,sb)
    il_acc=0.0; max_dd=0.0; repacks=0
    x0,y0=x,y; Q0=Q
    for i in range(1,n):
        Qn=twap[i]
        # value before move (hold ref = keep x,y, mark at Qn)
        hold=x*Qn+y
        # rebalance position to Qn within width
        sqn=max(min(math.sqrt(Qn),sb),sa)
        xn,yn=vfx(L,sqn,sa,sb)
        posval=xn*Qn+yn
        il_acc += (posval-hold)      # <=0 ; the LVR drawn from the basket this step
        x,y=xn,yn; Q=Qn
        if il_acc<max_dd: max_dd=il_acc
        # repack when price exits the width: realize + re-center at Qn
        if repack_on_exit and (Qn<=Pa or Qn>=Pb):
            repacks+=1
            Pa=Qn*(1-width); Pb=Qn*(1+width)
            sa=math.sqrt(Pa); sb=math.sqrt(Pb)
            tot=x*Qn+y                 # current value
            # rebuild balanced position of same value at Qn
            L=tot/( (math.sqrt(Qn)-sa) + Qn*(1.0/math.sqrt(Qn)-1.0/sb) )
            x,y=vfx(L,math.sqrt(Qn),sa,sb)
    # ---- baseline: full-width CPMM tracking SPOT (no guard, no concentration) ----
    rv=sum((math.log(px[i]/px[i-1]))**2 for i in range(1,n))   # realized variance (spot, 5m)
    steps_per_year=365*24*12
    rv_ann=rv/n*steps_per_year
    # full-width CPMM IL over the SPOT path ~ sum r^2/8 (vs hold)
    il_fr_spot=sum((math.log(px[i]/px[i-1]))**2 for i in range(1,n))/8.0
    yrs=n/steps_per_year
    lvr_guard_ann = -il_acc/yrs            # annualized LVR fraction of position value
    lvr_fr_ann    =  il_fr_spot/yrs
    # express guarded LVR in K-units (K=0.125 == full-width CPMM on spot)
    Keff = 0.125 * (lvr_guard_ann/lvr_fr_ann) if lvr_fr_ann>0 else float('nan')
    return dict(days=yrs*365, vol=math.sqrt(rv_ann),
                lvr_guard=lvr_guard_ann, lvr_fr=lvr_fr_ann,
                Keff=Keff, maxdd=-max_dd, repacks=repacks, n=n)

print("=== STRESS WINDOW (COVID crash 2020-02-26..04-11, 5m) ===")
s=load("eth_5m_stress.json")
for width in [0.02, 0.01, 0.04]:
    r=run(s, width=width)
    print(f" width=+/-{width:.0%}  ann.vol={r['vol']:.0%}  "
          f"LVR_guard={r['lvr_guard']:.0%}/yr  LVR_fullrange_spot={r['lvr_fr']:.0%}/yr  "
          f"K_eff={r['Keff']:.3f}  maxDD={r['maxdd']:.1%}  repacks={r['repacks']}")
# guard OFF (pool tracks spot, not TWAP) — isolate the guard's contribution
def run_nogard(series, width=0.02):
    return run(series, width=width, twap_win=1)   # twap_win=1 -> Q=spot (no smoothing)
print("\n=== guard contribution: TWAP-pinned vs spot-tracking (width +/-2%) ===")
rg=run(s,width=0.02); rs=run_nogard(s,width=0.02)
print(f" TWAP-pinned (guard ON) : LVR={rg['lvr_guard']:.0%}/yr  K_eff={rg['Keff']:.3f}")
print(f" spot-tracking(guard OFF): LVR={rs['lvr_guard']:.0%}/yr  K_eff={rs['Keff']:.3f}")
print(f" guard damping factor = {rg['lvr_guard']/rs['lvr_guard']:.2f}x" if rs['lvr_guard']>0 else "")

print("\n=== CRASH DAY (2020-03-12 +/-1d, 1m) — does loss stay bounded? ===")
c=load("eth_1m_crash.json")
# 1m: 30-min TWAP = 30 periods; year steps = 365*24*60
def run1m(series,width=0.02):
    px=[p for _,p in series]; n=len(px)
    tw=[]; W=30
    for i in range(n):
        w=px[max(0,i-W+1):i+1]; tw.append(sum(w)/len(w))
    Q=tw[0];Pa=Q*(1-width);Pb=Q*(1+width);sa=math.sqrt(Pa);sb=math.sqrt(Pb)
    L=1.0/((math.sqrt(Q)-sa)+Q*(1.0/math.sqrt(Q)-1.0/sb)); x,y=vfx(L,math.sqrt(Q),sa,sb)
    il=0.0;mdd=0.0;rp=0
    for i in range(1,n):
        Qn=tw[i];hold=x*Qn+y;sqn=max(min(math.sqrt(Qn),sb),sa);xn,yn=vfx(L,sqn,sa,sb)
        il+=(xn*Qn+yn-hold);x,y=xn,yn
        if il<mdd:mdd=il
        if Qn<=Pa or Qn>=Pb:
            rp+=1;Pa=Qn*(1-width);Pb=Qn*(1+width);sa=math.sqrt(Pa);sb=math.sqrt(Pb)
            tot=x*Qn+y;L=tot/((math.sqrt(Qn)-sa)+Qn*(1.0/math.sqrt(Qn)-1.0/sb));x,y=vfx(L,math.sqrt(Qn),sa,sb)
    lo=min(px);hi=max(px)
    print(f" 1m candles={n}  intraday width {lo:.0f}..{hi:.0f} ({(lo/px[0]-1):.0%}..{(hi/px[0]-1):+.0%})")
    print(f" position cumulative IL over the crash day = {il:.2%} of position value  (maxDD {mdd:.2%}, repacks {rp})")
run1m(c,0.02)
