# Leveraged-LP analysis on real ETH history. NOT to reduce IL — to (a) measure the
# amplified-LVR externality on the SHARED surplus (is ring-fencing needed, and how much),
# accounting for the fact that leverage UNWINDS in stress, and (b) show an LP what
# leverage does to their own P&L vs unleveraged. Reuses sim.py's surplus model
# (LVR_t = K*theta*min(r^2, band^2), band-exit capped).
import json, math, time, statistics
ser=json.load(open("eth_daily.json")); px=[p for _,p in ser]; ts=[t for t,_ in ser]
r=[math.log(px[i]/px[i-1]) for i in range(1,len(px))]; N=len(r)
def yr(i): return int(time.gmtime(ts[i+1]/1000).tm_year)
YEARS=sorted(set(yr(i) for i in range(N)))
sigma=math.sqrt(statistics.pvariance(r)*365)

# QU!D-accurate knobs (IL-CERT): K=0.71 measured, +/-2% band, certified theta ~0.33,
# venue yield ~6%, fees ~2%, BOLD borrow rate ~7%.
K=0.71; BAND=0.02; THETA=0.33; Y=0.06; F=0.02; RATE=0.07; S0=0.03
def lvr(i): return K*min(r[i]*r[i], BAND*BAND)   # per unit in-range notional, band-capped

# ---- leverage "aliveness": a Trove at Lx is liquidated when price falls ~1/L from its
#      entry peak; it re-levers once price reclaims that peak. Captures unwind-in-stress.
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

# ============ 1) THE LEVERAGED LP'S OWN P&L (vs unleveraged) ============
# Return ON EQUITY per day = L*(LP daily return) - (L-1)*borrow. LP daily return =
# Y/365 + F*THETA/365 - lvr.  A >1/L drawdown wipes the equity (liquidation), then re-enter.
def lp_pnl(L):
    by={y:0.0 for y in YEARS}; liqs={y:0 for y in YEARS}; eq=1.0; pk=px[0]; liqdd=1.0/L
    for i in range(N):
        p=px[i+1]
        if L>1 and p<=pk*(1-liqdd):           # liquidated
            by[yr(i)]-=eq; liqs[yr(i)]+=1; eq=1.0; pk=p; continue
        if p>pk: pk=p
        d=L*(Y/365+F*THETA/365-lvr(i))-(L-1)*RATE/365
        eq+=d; by[yr(i)]+=d
    return by, liqs

print(f"days={N}  ann.vol={sigma:.0%}   (K={K}, band={BAND:.0%}, theta={THETA}, y={Y:.0%}, f={F:.0%}, borrow={RATE:.0%})")
print("\n=== 1) LEVERAGED LP own P&L, return-on-equity by year (negative year = -100% means wiped) ===")
hdr="  year |"+"".join(f"{('L='+str(L)):>10}" for L in [1,2,3,5]); print(hdr)
pnls={L:lp_pnl(L) for L in [1,2,3,5]}
for y in YEARS:
    row=f"  {y} |"
    for L in [1,2,3,5]:
        by,liqs=pnls[L]; tag="*" if liqs[y] else " "
        row+=f"{by[y]:>9.0%}{tag}"
    print(row)
print("  (* = at least one liquidation that year; L=1 is unleveraged baseline)")
tot={L:sum(pnls[L][0].values()) for L in [1,2,3,5]}
print("  full-history sum:"+"".join(f"{tot[L]:>9.0%} " for L in [1,2,3,5]))

# ============ 2) THE SHARED-SURPLUS EXTERNALITY (is ring-fence needed?) ============
# Baseline surplus vs surplus with a leveraged cohort adding (L-1)*LEV_E extra in-range
# notional (the amplification), SOCIALIZED into the shared surplus. Two assumptions:
#   sticky  = amplification always on (upper bound)
#   fragile = amplification follows alive(L) (unwinds in stress; the realistic case)
LEV_E=0.10  # leveraged equity = 10% of backing
def surplus(extra):
    S=S0; mn=S; by={y:0.0 for y in YEARS}
    for i in range(N):
        th=THETA+extra(i)
        d=Y/365+F*th/365-K*th*min(r[i]*r[i],BAND*BAND)
        S+=d; mn=min(mn,S); by[yr(i)]+=d
    return S,mn,by
base=surplus(lambda i:0.0)
print("\n=== 2) SHARED-SURPLUS externality of a leveraged cohort (LEV_E=10% of backing) ===")
print(f"  baseline (no leverage):           finalS={base[0]:>7.1%}  minS={base[1]:>7.1%}")
for L in [2,3,5]:
    al=alive(L)
    stick=surplus(lambda i:(L-1)*LEV_E)
    frag =surplus(lambda i:(L-1)*LEV_E*al[i])
    on=sum(al)/len(al)
    print(f"  L={L}: sticky minS={stick[1]:>7.1%} | fragile minS={frag[1]:>7.1%} "
          f"(amp ON {on:.0%} of days)  vs base minS={base[1]:.1%}")
# worst-year drain attributable to the cohort (fragile)
print("\n  fragile worst-year surplus delta vs baseline (the externality that lands on others):")
for L in [2,3,5]:
    al=alive(L); frag=surplus(lambda i:(L-1)*LEV_E*al[i])
    deltas={y:frag[2][y]-base[2][y] for y in YEARS}
    wy=min(deltas.items(),key=lambda kv:kv[1])
    print(f"  L={L}: worst-year externality {wy[0]}: {wy[1]:+.1%} of backing")
