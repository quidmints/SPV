import json, math, time, statistics
ser = json.load(open("eth_daily.json"))
px = [p for _, p in ser]
ts = [t for t, _ in ser]
r  = [math.log(px[i]/px[i-1]) for i in range(1, len(px))]   # daily log returns
N  = len(r)
def year(i): return int(time.gmtime(ts[i+1]/1000).tm_year)

var_d = statistics.pvariance(r)
sigma = math.sqrt(var_d * 365)
print(f"days={N}  realized ANNUALIZED vol sigma={sigma:.1%}  worst 1d={min(r):.1%} best={max(r):.1%}")

# Lifecycle backtest. Backing normalized B=1. theta = in-width committed fraction.
# Per day:  surplus += yield(whole backing) + fees(in-width) - LVR(in-width)
#   LVR_t = K * theta * min(r_t^2, width^2)  (vs-holding drain; width-exit CAP via min)
#   K lumps 1/8 (CPMM floor) * concentration * (1/guard). K=0.125 == full-width.
# Insolvency = cumulative surplus < 0 (then LP haircuts begin).
def run(theta, K, y, f, width=0.04, S0=0.03):
    S = S0; minS = S0; yr_acc = {}
    for i in range(N):
        lvr = K * theta * min(r[i]*r[i], width*width)
        d = y/365 + f*theta/365 - lvr
        S += d
        if S < minS: minS = S
        yy = year(i); yr_acc[yy] = yr_acc.get(yy, 0) + d
    wy = min(yr_acc.items(), key=lambda kv: kv[1])
    return S, minS, wy

print("\n=== full-history net & worst year (S0=3% buffer) ===")
print(f"{'theta':>6}{'K':>7}{'y':>5}{'f':>5} | {'finalS':>8}{'minS':>8}  worst-yr")
for K in [0.125, 0.5, 1.0]:
  for y in [0.05, 0.08]:
    for f in [0.0, 0.04]:
      for theta in [0.5, 1.0]:
        S, minS, wy = run(theta, K, y, f)
        flag = "" if minS > 0 else "  INSOLVENT"
        print(f"{theta:>6}{K:>7}{y:>5.0%}{f:>5.0%} | {S:>8.1%}{minS:>8.1%}  {wy[0]}:{wy[1]:+.0%}{flag}")

print("\n=== MAX SAFE theta (surplus never < 0 over full history, S0=3%) ===")
print(f"{'K':>7}{'y':>6}{'f':>6} | {'theta_max':>10}   closed-form y/(K*sig^2 - f)")
for K in [0.125, 0.5, 1.0, 2.0]:
  for y in [0.05, 0.08]:
    for f in [0.0, 0.04]:
      best = 0.0
      for th in [i/100 for i in range(1, 101)]:
        if run(th, K, y, f)[1] > 0: best = th
      den = K*sigma*sigma - f
      cf = min(y/den, 1.0) if den > 0 else 1.0
      print(f"{K:>7}{y:>6.0%}{f:>6.0%} | {best:>10.2f}   cf~{cf:.2f}")

print("\n=== realized LVR rate at theta=1, by K (annualized) ===")
rv = sum(x*x for x in r)/N*365
for K in [0.125, 0.5, 1.0, 2.0]:
  print(f"  K={K:<5} LVR(theta=1) ~= {K*rv:.1%}/yr   vs yield 5-8%/yr, fees 0-4%/yr")
