"""Which half-life should the shed-rate estimator use? The contract's FLOW_DECAY is
48h, chosen for 'wide, manipulation-resistant memory' — never for this. Scan it."""
import csv, statistics as st
rows = list(csv.DictReader(open('analysis/rover/volume-180d.csv')))
series = {p: [float(r['vol_token0']) for r in rows if r['pool'] == p] for p in ('A','B')}

def ewma(v, hl_days, step=3):
    lam = 0.5 ** (step / hl_days); acc=None; out=[]
    for x in v:
        acc = x if acc is None else lam*acc + (1-lam)*x
        out.append(acc)
    return out

def score(s):
    """p10 mispricing = median/p10: how badly a flow-BLIND charge under-prices the
    worst decile. Lower is a tamer, more shippable curve; 1.0 would mean flow never
    varies (and the whole correction would be pointless)."""
    nz = sorted(x for x in s if x > 0)
    if len(nz) < 10: return None, None, None
    med, p10 = st.median(nz), nz[int(.1*len(nz))]
    return med/p10, max(s)/med, med

HLS = [0.5, 1, 2, 3, 5, 7, 10, 14, 21, 30]
print(f"{'half-life':>10} |" + "".join(f"{'pool '+p+' p10mis':>17}" for p in ('A','B')) + f"{'joint (max)':>14}")
print("-"*10 + "-+" + "-"*34 + "-"*14)
best=None
for hl in HLS:
    cells=[]; worst=0
    for p in ('A','B'):
        m,_,_ = score(ewma(series[p], hl))
        cells.append(f"{m:>16.1f}x"); worst=max(worst,m)
    flag = ""
    if best is None or worst < best[1]: best=(hl,worst); 
    print(f"{hl:>8.1f}d |" + "".join(cells) + f"{worst:>13.1f}x")
print(f"\nJOINT OPTIMUM: half-life {best[0]}d (worst-pool mispricing {best[1]:.1f}x)")
print(f"CONTRACT TODAY: FLOW_DECAY = 48h = 2.0d ->", end=" ")
w=max(score(ewma(series[p],2))[0] for p in ('A','B'))
print(f"worst-pool {w:.1f}x  =>  {w/best[1]:.1f}x WORSE than the optimum")
print("""
The 48h constant is not wrong for what it was chosen for (a manipulation-resistant
memory for the inventory target). It is wrong as a SHED-RATE estimator: too fast, so
it tracks the noise it was meant to resist and leaves the quiet-day tail unpriced.
Two registers, two jobs — the same struct/helpers can carry both.""")
