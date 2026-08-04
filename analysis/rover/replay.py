"""
R11's replay, run over ROLLING windows so no single start point can flatter or damn the result.

A v3 position's holdings are a closed form of (band, liquidity, price), so given the real daily price
path this is exact arithmetic on measured data, not a model. What it separates -- and what every
earlier number in this thread conflated:

  LVR      position value vs holding the SAME composition, fees EXCLUDED
  FEES     the day's real pool volume x fee tier, credited ONLY while in range
           (Rover would be ~100% of in-range L: the rest of the pool is 0.000346 WETH-equiv)
  CADENCE  how often the band is re-placed at the live tick -- the thing being tested

Baselines: HOLD-MIX isolates adverse selection; HOLD-WETH is the actual decision counterfactual
(an idle WETH reserve, which is what Rover would replace).
"""
import csv, math, statistics as st, sys

Q, SPACING, FEE, P0 = 2**96, 10, 0.0005, 4000e18

def amounts(liq, sP, sL, sU):
    if sP <= sL: return liq * (sU - sL) * Q // (sL * sU), 0
    if sP >= sU: return 0, liq * (sU - sL) // Q
    return liq * (sU - sP) * Q // (sP * sU), liq * (sP - sL) // Q

def sqrt_at(t): return int(math.sqrt(1.0001 ** t) * Q)
def band(t):
    lo = (t // SPACING) * SPACING
    return sqrt_at(lo), sqrt_at(lo + SPACING)

def liq_for(value, sP, sL, sU, rate):
    a0, a1 = amounts(int(1e18), sP, sL, sU)
    per = a0 + a1 * rate // int(1e18)
    return 0 if per == 0 else int(1e18) * int(value) // per

def run(win, cadence):
    t0 = win[0]
    sL, sU = band(t0['tick'])
    liq = liq_for(P0, t0['sq'], sL, sU, t0['rate'])
    h0, h1 = amounts(liq, t0['sq'], sL, sU)
    fees, last, ir = 0, 0, 0
    for i, r in enumerate(win[1:], 1):
        if sL < r['sq'] < sU:
            fees += int(r['vol'] * FEE); ir += 1
        if cadence and (i - last) >= cadence:
            c0, c1 = amounts(liq, r['sq'], sL, sU)
            val = c0 + c1 * r['rate'] // int(1e18)          # re-centre is value-preserving (measured ~1bp)
            sL, sU = band(r['tick'])
            liq = liq_for(val, r['sq'], sL, sU, r['rate'])
            last = i
    e = win[-1]
    c0, c1 = amounts(liq, e['sq'], sL, sU)
    posNoFee = c0 + c1 * e['rate'] // int(1e18)
    pos      = posNoFee + fees
    mix      = h0 + h1 * e['rate'] // int(1e18)
    return pos, posNoFee, mix, int(P0), ir, h1 * t0['rate'] // int(1e18) / P0

rows = []
for r in csv.DictReader(open(sys.argv[1])):
    try: rows.append({'d': int(r['day']), 'tick': int(r['tick']), 'sq': int(r['sqrtPrice']),
                      'rate': int(r['rate']), 'vol': float(r['vol2000']) * (7200 / 2000)})
    except Exception: pass
rows.sort(key=lambda x: -x['d'])
W = 30
print(f"{len(rows)} daily samples; rolling {W}-day windows; position {P0/1e18:,.0f} WETH-equiv\n")
print(f"{'cadence':<16}{'n':>4}{'LVR only':>12}{'+fees vs MIX':>15}{'vs HOLD-WETH':>15}{'in-range':>10}")
print("-" * 72)
for cad, name in [(0, 'never (passive)'), (7, 'weekly'), (3, 'every 3 days'), (1, 'daily')]:
    lv, tot, vw, irs = [], [], [], []
    for s in range(0, len(rows) - W):
        win = rows[s:s + W + 1]
        pos, noFee, mix, weth, ir, _ = run(win, cad)
        ann = lambda a, b: ((a / b) ** (365 / W) - 1) * 100
        lv.append(ann(noFee, mix)); tot.append(ann(pos, mix)); vw.append(ann(pos, weth)); irs.append(ir)
    if not lv: continue
    print(f"{name:<16}{len(lv):>4}{st.median(lv):>11.2f}%{st.median(tot):>14.2f}%"
          f"{st.median(vw):>14.2f}%{st.median(irs):>8.0f}/{W}")
print("\n  LVR only     = adverse selection alone, fees stripped out")
print("  +fees vs MIX = what an LP actually nets against holding the same split")
print("  vs HOLD-WETH = the decision: better or worse than an idle WETH reserve")
print("  all figures are MEDIANS across the rolling windows, annualised")
