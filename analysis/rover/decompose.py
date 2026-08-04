"""CONTROL for "is Rover's loss volatility-driven or ratchet-driven?"

The A-S / sigma^2/8 family of skew formulas price the RANDOM component. weETH/WETH's fundamental
(`getRate()`) is MONOTONIC and deterministic -- it ratchets ~0.67 bps/day and never reverses. If the
loss is mostly ratchet, a variance-driven charge prices the wrong thing entirely.

Orthogonal split of the real 90-day path:
  ACTUAL      measured tick + rate path
  TREND-ONLY  tick and rate replaced by their least-squares lines -> pure drift, ZERO variance
  DETREND     drift removed from both, wiggle kept  -> pure variance, ZERO drift
"""
import csv, math, statistics as st, subprocess, sys, os

SRC = "daily-price-90d.csv"
Q = 2**96

rows = list(csv.DictReader(open(SRC)))
rows.sort(key=lambda r: -int(r["day"]))          # oldest first, same order replay.py uses
n = len(rows)
ticks = [int(r["tick"]) for r in rows]
rates = [int(r["rate"]) for r in rows]

def fit(y):
    xs = list(range(len(y))); mx = sum(xs)/len(xs); my = sum(y)/len(y)
    num = sum((x-mx)*(v-my) for x, v in zip(xs, y)); den = sum((x-mx)**2 for x in xs)
    m = num/den; return m, my - m*mx

mt, bt = fit(ticks); mr, br = fit([float(v) for v in rates])
print(f"tick drift {mt:+.4f} ticks/day   ({(1.0001**(mt*365)-1)*100:+.2f}%/yr)")
print(f"rate drift {mr/1e18*365/ (br/1e18) *100:+.2f}%/yr   ({(mr/br)*1e4:+.3f} bps/day)")
print()

def emit(name, tk, rt):
    path = f"/tmp/decomp-{name}.csv"
    with open(path, "w") as f:
        f.write("day,block,tick,sqrtPrice,rate,vol2000\n")
        for i, r in enumerate(rows):
            t = int(round(tk[i]))
            sq = int(math.sqrt(1.0001 ** t) * Q)
            f.write(f"{r['day']},{r['block']},{t},{sq},{int(rt[i])},{r.get('vol2000', 0)}\n")
    return path

variants = {
    "ACTUAL":     (ticks, rates),
    "TREND-ONLY": ([mt*i + bt for i in range(n)], [mr*i + br for i in range(n)]),
    "DETREND":    ([ticks[i] - mt*i for i in range(n)], [rates[i] - mr*i for i in range(n)]),
}
for name, (tk, rt) in variants.items():
    p = emit(name, tk, rt)
    print(f"===== {name} =====")
    sys.stdout.flush()
    subprocess.run([sys.executable, "replay.py", p])
    print()
