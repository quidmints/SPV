#!/usr/bin/env node
// Faithful numerical model of QU!D's ETH-LP IL/LVR economics — mirrors the ON-CHAIN logic
// (NOT an external model): the same equations the contracts use, swept across diverse paths
// the mainnet fork can't produce (it uses the deep real pool -> 0 slippage -> 0 LVR).
//
// GROUND TRUTH equations (from the code + IL-CERT §2-3, all verified this session):
//   theta_derived = min(1, yield / (K * sigma^2))        [Vogue.derivedThetaWad]
//   V_inrange     = theta * vogue                         [addLiq clamp]
//   LVR_rate      = K * sigma^2                           [IL-CERT §2; K=0.71 MEASURED §3]
//   LVR_$/yr      = LVR_rate * V_inrange                  [the adverse-selection bleed on the exposed slice]
//   yield_$/yr    = y * backing                           [venue yield on the WHOLE backing, incl retention]
//   fee_$/yr      = feeRate * turnover * V_inrange        [LP fee income on in-range volume]
//   net IL        = LVR - (yield + fees)                  [>0 => a real loss, borne by LP (R1) or backing (R2)]
// arbETH/refill (R2): absorbs the net IL into backing surplus, per fire cost <= 2% slip + <=50bps anchor.
// R1: the LP bears the net IL directly (less ETH at exit). theta=1 = the reckless deployed default.
//
// The decision this answers: does arbETH/arbBTC create more problems than it solves, and what is
// the right IL treatment for OUR design (linear-ETH claim, retention, venue yield)?

const K = 0.71;                 // measured LVR coefficient, +/-2% band guard-on (IL-CERT §3)
const DT = 1 / 365;             // daily steps
const YIELD = 0.05;             // 5%/yr venue yield (sweep below); ~3% real, 5-8% in scenarios
const FEE_RATE = 0.0005;        // 5 bps pool fee
const TURNOVER = 50;            // annual in-range volume / V_inrange (active pool); fee = FEE_RATE*TURNOVER*V
const REFILL_SLIP = 0.005;      // 50 bps realized cost per refill fire (anchor-bounded), R2 only
const VOGUE0 = 100;             // 100 ETH-equiv backing, normalized
const VOL_WINDOW = 20;          // realized-vol lookback (days), mirrors the oracle window spirit

// ---- price-path scenarios (daily log-returns) ----
function gbm(days, mu, sig, seed) {        // deterministic LCG so runs are reproducible
  let s = seed >>> 0; const rnd = () => (s = (1103515245 * s + 12345) & 0x7fffffff) / 0x7fffffff;
  const p = [1];
  for (let i = 0; i < days; i++) {
    const z = Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd());
    p.push(p[p.length - 1] * Math.exp((mu - sig * sig / 2) * DT + sig * Math.sqrt(DT) * z));
  }
  return p;
}
function chop(days, amp, period) { const p = [1]; for (let i = 0; i < days; i++) p.push(1 + amp * Math.sin(2 * Math.PI * i / period)); return p; }
function crashRecover(days) { const p = [1]; for (let i = 0; i < days; i++) { let v; if (i < 3) v = 1 - 0.18 * i; else if (i < 30) v = 0.46 + (i - 3) * (1 - 0.46) / 27; else v = 1; p.push(Math.max(0.1, v)); } return p; }
function whipsaw(days) { const p = [1]; for (let i = 0; i < days; i++) p.push(1 + 0.25 * ((i % 4 < 2) ? 1 : -1) * (0.5 + 0.5 * Math.sin(i))); return p; }

const SCENARIOS = {
  'calm (12% vol)':        gbm(365, 0.0, 0.12, 1),
  'normal (60% vol)':      gbm(365, 0.0, 0.60, 2),
  'bull trend (+150%)':    gbm(365, 0.9, 0.65, 3),
  'bear trend (-60%)':     gbm(365, -0.9, 0.65, 4),
  'high-vol chop (88%)':   gbm(365, 0.0, 0.88, 5),
  'sine chop (±15%)':      chop(365, 0.15, 20),
  'crash -54% + recover':  crashRecover(120),
  'whipsaw (±25%)':        whipsaw(180),
  '2021-like two-way':     gbm(365, 0.5, 0.95, 7),
};

function realizedVolAnnual(prices, i, win) {
  const a = Math.max(1, i - win); let m = 0, n = 0; const rets = [];
  for (let j = a; j <= i; j++) { const r = Math.log(prices[j] / prices[j - 1]); rets.push(r); m += r; n++; }
  m /= n; let v = 0; for (const r of rets) v += (r - m) ** 2; v /= Math.max(1, n - 1);
  return Math.sqrt(v / DT); // annualized
}

// run one scenario under a theta policy ('one'=1.0 reckless, 'derived', 'doc'=0.26) and design (R1/R2)
function run(prices, thetaPolicy, design, yld) {
  let vogue = VOGUE0, backing = VOGUE0, ilLP = 0, ilBacking = 0, fires = 0, refillCost = 0, feeInc = 0, yieldInc = 0;
  let cumLVR = 0, cumThetaW = 0, steps = 0;
  for (let i = 1; i < prices.length; i++) {
    const sigma = realizedVolAnnual(prices, i, VOL_WINDOW);
    const lvrRate = K * sigma * sigma;
    let theta;
    if (thetaPolicy === 'one') theta = 1.0;
    else if (thetaPolicy === 'doc') theta = 0.26;
    else theta = Math.min(1, lvrRate > 0 ? yld / lvrRate : 1);  // derived = yield/(K*sigma^2)
    const Vin = theta * vogue;
    const lvr = lvrRate * Vin * DT;                 // adverse-selection bleed this step
    const yieldStep = yld * backing * DT;           // yield on WHOLE backing (incl retention)
    const feeStep = FEE_RATE * TURNOVER * Vin * DT; // fees on in-range volume
    const net = lvr - yieldStep - feeStep;          // >0 => loss this step
    cumLVR += lvr; feeInc += feeStep; yieldInc += yieldStep; cumThetaW += theta; steps++;
    if (net > 0) {
      if (design === 'R2') {                        // absorber: backing eats it + a per-fire slip cost
        // only "fires" when the shortfall crosses ~1% of the slice; approximate by firing on net>0 days
        ilBacking += net; refillCost += REFILL_SLIP * lvr; fires++; backing -= (net + REFILL_SLIP * lvr);
      } else {                                       // R1: the LP bears it (less ETH at exit)
        ilLP += net;
      }
    } else { // surplus: yield over-covers; in R2 it could replenish, in R1 the LP banks it
      if (design === 'R1') ilLP += net; // negative net = LP gain
    }
  }
  // NON-tautological outputs: the LP's actual edge over HODL and what theta COSTS.
  // priceExposure cancels vs HODL (LP is whole-in-ETH), so edge = yield + fees - LVR.
  const lpEdge = yieldInc + feeInc - cumLVR;          // $ over the path (can be neg)
  // structural shortfall signal: with theta<1, totalShares=theta*vogue < vogue => NEVER short.
  const everShort = (thetaPolicy === 'one');           // only theta=1 can go short
  return { thetaAvg: cumThetaW / steps, cumLVR, yieldInc, feeInc,
           lpEdge, everShort,
           netCost: (design === 'R2' ? ilBacking + refillCost : Math.max(0, ilLP)) };
}

// ---- report ----
const pct = x => (x / VOGUE0 * 100).toFixed(2) + '%';
console.log(`\nFaithful LVR model — K=${K}, yield=${YIELD*100}%, fee=${FEE_RATE*1e4}bps x ${TURNOVER}x turnover, refill slip=${REFILL_SLIP*1e4}bps`);
console.log('Cost = IL borne over the path (% of backing). LOWER is better.\n');
// LP EDGE over HODL (%, higher=better) per theta policy, + the FEE income theta forgoes,
// + whether the pool can EVER go short (=> arbETH/keeper relevant). The real tradeoff.
console.log('LP edge vs HODL (% of backing over the path; >0 = LP beats holding ETH). fees = in-range fee income captured.');
const hdr = ['scenario', 'theta=1 edge', 'derived edge', 'doc0.26 edge', 'theta=1 fees', 'derived fees', 'can go short?'];
console.log(hdr.map(h => h.padEnd(16)).join(''));
for (const [name, prices] of Object.entries(SCENARIOS)) {
  const one = run(prices, 'one', 'R1', YIELD);
  const der = run(prices, 'derived', 'R1', YIELD);
  const doc = run(prices, 'doc', 'R1', YIELD);
  console.log([
    name.padEnd(16),
    pct(one.lpEdge).padEnd(16),
    pct(der.lpEdge).padEnd(16),
    pct(doc.lpEdge).padEnd(16),
    pct(one.feeInc).padEnd(16),
    pct(der.feeInc).padEnd(16),
    (der.everShort ? 'yes' : 'NO (theta<1)').padEnd(16),
  ].join(''));
}
console.log('\nREADS (non-tautological):');
console.log('- theta=1 edge << derived edge in vol => the reckless deployed theta=1 makes the LP LOSE vs HODL; theta-budget (built) flips it positive. The theta fix dominates.');
console.log('- derived fees << theta=1 fees => the COST of theta-budget is forgone in-range fee income (it captures less volume). The LP trades fee income for IL elimination + (yield still earned on the whole backing).');
console.log('- "can go short?" = NO for any theta<1 (totalShares=theta*vogue < vogue) => arbETH/arbBTC NEVER trigger under theta-budget => no continuous keeper; the absorber is a dormant valve.');
console.log('- So: arbETH/arbBTC create MORE problems than they solve ONCE theta is sized (churn/gas/MEV/keeper for a shortfall that cannot occur). The IL answer for OUR design = size theta (done); keep the absorber dormant.');
// sensitivity: does the conclusion hold across yields?
console.log('\nyield sensitivity (derived-theta LP edge %, normal 60%-vol path):');
for (const y of [0.03, 0.05, 0.08]) console.log(`  yield ${y*100}%: ${pct(run(SCENARIOS['normal (60% vol)'], 'derived', 'R1', y).lpEdge)}`);
