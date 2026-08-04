"""E54 backtest: does FLOW or POOL SIZE predict what a trade costs us?

The derived formula charges q/flow; the current sell leg charges q/((V+D)/2), a
pool-size basis. They agree only if flow is proportional to pool size. This
measures whether that holds on real data — and if it does not, the ratio between
them IS the mispricing, day by day.
"""
import csv, statistics as st

rows = list(csv.DictReader(open('analysis/rover/volume-180d.csv')))
POOL_TVL = {'A': 1.0, 'B': 1.0}          # pool size is ~constant over the window
out = {}
for p in ('A', 'B'):
    v = [float(r['vol_token0']) for r in rows if r['pool'] == p]
    n = [int(r['n_swaps'])      for r in rows if r['pool'] == p]
    out[p] = (v, n)

print(f"{'pool':<6}{'days':>6}{'flow med':>12}{'flow p90':>12}{'flow max':>12}{'max/med':>10}{'zero days':>11}")
for p, (v, n) in out.items():
    nz = [x for x in v if x > 0]
    med = st.median(nz) if nz else 0
    p90 = sorted(nz)[int(.9*len(nz))] if nz else 0
    mx  = max(v) if v else 0
    print(f"{p:<6}{len(v):>6}{med:>12.3f}{p90:>12.3f}{mx:>12.3f}"
          f"{(mx/med if med else 0):>10.1f}x{len([x for x in v if x==0]):>10}")

print()
print("MISPRICING: a POOL-denominated charge is flat across all of this; a FLOW-denominated")
print("one moves with the row. The ratio is how wrong the pool basis is on that day.")
print(f"{'pool':<6}{'day':>6}{'flow':>12}{'flow/med':>10}{'pool-basis err':>16}")
for p, (v, n) in out.items():
    nz = [x for x in v if x > 0]
    med = st.median(nz)
    for label, day_idx in (('quietest', min(range(len(v)), key=lambda i: (v[i] if v[i] > 0 else 9e9))),
                           ('median  ', min(range(len(v)), key=lambda i: abs(v[i]-med))),
                           ('busiest ', max(range(len(v)), key=lambda i: v[i]))):
        f = v[day_idx]
        print(f"{p:<6}{day_idx*3:>6}{f:>12.3f}{(f/med):>10.2f}x{(med/f if f else 0):>15.1f}x")

print()
print("WHAT THIS MEANS FOR A FIXED TRADE q: cost ∝ q/flow. Charging q/pool instead is")
print("wrong by exactly (median flow / today's flow) — under-charging on quiet days")
print("(when shedding is SLOWEST and the trade is MOST expensive to absorb) and")
print("over-charging on busy days (when it is cheapest). It has the sign BACKWARDS.")
for p, (v, n) in out.items():
    nz = sorted(x for x in v if x > 0)
    med = st.median(nz)
    q1, q9 = nz[int(.1*len(nz))], nz[int(.9*len(nz))]
    print(f"  pool {p}: p10 flow={q1:.3f} → true cost {med/q1:6.1f}x the median; "
          f"p90 flow={q9:.3f} → {med/q9:5.2f}x. Pool basis charges the SAME on both.")
