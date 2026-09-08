#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────────────────────────
// HEAD-TO-HEAD: the shipped IL-protect overlay vs constant-2x (YieldBasis) vs plain LP vs HODL-ETH,
// over the REAL range geometry — a theta-throttled, repacking +/-0.2% concentrated position.
//
// WHY IT EXISTS. Nothing in the tree compares them. `LevYbPnl.t.sol` proves only that
// t = 1 - 1/sqrt(r) matches HODL *delta* at a point; `LevCascade.test_Economic_LeversToProvenIlTarget`
// proves the contract reaches that target; `sims/yb_vs_hodl.js` prices constant-k alone. This
// measures net edge = fees - carry - gas - slippage - residual IL, per unit equity, on one path.
//
// ⭐ SECTION (0) IS A CONTROL AND IT RUNS FIRST. It is a KNOWN POSITIVE, not a clean run:
//    frictionless synthetic paths where the answer is known in closed form. It has already caught
//    three modelling errors in this file (§MODEL-CORRECTIONS). Read its verdict before anything else.
//
// ── WHAT IS TRANSCRIBED FROM evm/src, WITH THE LINE THAT SAYS SO ────────────────────────────────
//   • target LTV = min(1 - sqrt(entry/px), 7500bps), ZERO at or below entry  LevMath.ilTargetBps:226
//   • LTV basis is debt/E0, E0 = entryEquity * LIVE px       LevBase._targetInputs:143, LevMath:398
//   • derived no-trade band, series-combined with headroom            LevMath.noTradeBandBps:180-206
//     g = basefee * GAS_REBALANCE(1_250_000) * ETH/USD                    LevBase.sol:72, LevMath:92
//   • K = kLvrWad = 1/(4*(2 - sqrt(P/Pb) - sqrt(Pa/P)))                        QuidLib.kLvrWad:132
//   • theta = rangeFeeYield / (K*sigma^2); >= 1 is a no-op   QuidLib.derivedThetaWad:224, applyTheta
//     rangeFeeYield = premiumEwma * 127 / POOLED_USD                  QuidLib:187, PREMIUM_ANNUALIZE
//     sigma^2 = annualized realized variance from the ring              Core.realizedVarianceWad:347
//   • range is +/-RANGE_DELTA and RECENTRES on repack; anchor is spot    SwapLib.sol:835, LevMath §C22
//   • the debt-funded buffer is DEPLOYED AS RANGE DEPTH, not held flat       RangeLib.levAddBuf:120
//   • collateral is weETH held at the venue (staked, not lent)                  LevManager.sol:36-38
//
// ── §MODEL-CORRECTIONS: three things this file got wrong, each caught by the control ────────────
//  1. 🔴 K IS ~125, NOT ~250,000. `kLvrWad` uses sqrt(P/Pb) where Pb is the UPPER bound, so that term
//     is 1/sqrt(1+d), NOT sqrt(1+d). Then 2 - 1/sqrt(1+d) - sqrt(1-d) ~= d, so K ~= 1/(4d): 125 at
//     RANGE_DELTA=20bps, 12.6 at the old +/-2%. The first draft mis-substituted and every band it
//     printed was ~12.6x too tight.
//  2. 🔴 THE LP FUNDS THE ETH LEG ONLY. `SwapLib.sizeBySurplus:2496` takes the paired USD from the
//     BASKET's surplus (`liquidTotal - committedBoth`), so a 1 ETH deposit becomes a position worth
//     ~2 ETH, half of it the basket's. Modelling the deposit as a 50/50 v2 position (the convention
//     `sims/strategy_compare.js` uses) halves the LP's entry delta and is wrong for this protocol.
//  4. 🔴 E0 IS NOT THE PINNED DEPOSIT. `RangeLib.reanchorIfReseated:256` writes
//     `q.entryEquity = netEquity(lp)`, and `LevBase._netEquityAt:717` defines that as
//     `collateral - debt/px`. The reseat fires "on any drift past RANGE_DELTA (20 bps)" (its own
//     comment), so E0 tracks net equity continuously; only `ilBasisPx` is pinned (§C19 forbids
//     re-basing THAT). An earlier draft pinned E0 for the whole window and reported a +7.39%
//     up-side over-hedge on the frictionless rally. Modelling the re-base cuts it to +2.58%.
//     ⇒ THE +7.47% CLOSED FORM IS RETRACTED. It was algebra over the wrong basis, and being
//       closed-form is exactly what made it convincing — the sim AGREED with it because the sim
//       shared the error. Two methods that share a premise are one method.
//  3. 🔴 A REBALANCE IS VALUE-NEUTRAL: `B += dD/P`, never `B = Dtarget/P`. The latter silently
//     discards the buffer's accumulated P&L and made the hedge look inert (edge identical to plain
//     LP, to the cent) on the frictionless control.
//
// ── §CLAIM-UNBUILT: the one economic input the CONTRACTS DO NOT YET DEFINE ──────────────────────
// `SwapLib.burnInRange:2425` sends the LP **volatile only**; the USD side is retired to the basket,
// and that file says the payout is unreachable in its own words: *"A positive usdOut RETIRES dollars
// (POOLED_USD and basketUsd both fall) and DELIVERS THEM TO NOBODY. The release is not the missing
// half; the DELIVERY is, and it is still not built."* So the LP's claim on its own sale proceeds is
// an OPEN HOLE, not a design to read off. Both readings are run:
//     proRata — LP wealth = its half of position value (what a normal LP gets)
//     ethOnly — LP wealth = its ETH count x price      (what the code sends TODAY)
// ⭐ Section (3) reports the gap. It is SMALL under the repack — a recentring range sits at its
//    centre, where the two coincide — and LARGE without it. That is a result, not an assumption.
//
// ── WHAT IS STILL A MODEL CHOICE ────────────────────────────────────────────────────────────────
//   · Fee income = in-range arb volume along the path + a swept NOISE turnover. No price series
//     contains the noise half, so it is swept and never assumed (`sims/lp_breakeven.js`).
//   · Carry and staking are flat annual rates (house convention: 7% / 5%).
//   · ⚠️ RESOLUTION IS THE BINDING LIMIT ON A +/-0.2% BAND. Daily bars cannot resolve it — the band
//     is exited every bar, so a daily walk sees ONE traverse where reality has many. Section (2)
//     CALIBRATES the effective LVR coefficient on 5-minute data; the daily sections inherit that
//     limitation and are labelled. Do not read a daily repack count as physical.
//
// Usage: node overlay_vs_yb.js [--turnover 100] [--fee 5] [--borrow 7] [--gwei 3] [--equity 100000]
// ─────────────────────────────────────────────────────────────────────────────────────────────────
'use strict';
const SWEEP_ONLY = process.argv.includes('--delta-sweep');
const fs = require('fs');
const path = require('path');
const ANALYSIS = path.join(__dirname, '..', 'analysis');
const arg = (k, d) => { const i = process.argv.indexOf('--' + k);
                        return i > 0 && process.argv[i + 1] !== undefined ? +process.argv[i + 1] : d; };

// ── parameters (house conventions: lvr_sim.js, carry_venue.js, lp_breakeven.js) ──────────────────
const FEE_      = arg('fee', 5) / 1e4;      // composite range fee
const TURNOVER_ = arg('turnover', 100);     // annual NOISE volume / TVL, on top of path arb volume
const BORROW_   = arg('borrow', 7) / 100;   // stable borrow (Morpho adaptive IRM, mid-cycle)
const YIELD_    = arg('yield', 5) / 100;    // ether.fi staking
const GWEI_     = arg('gwei', 3);
const SLIP_     = arg('slip', 5) / 1e4;     // realized aggregator slippage per rebalance
const EQUITY_   = arg('equity', 100000);    // USD of LP equity at entry — gas is ABSOLUTE, so this
                                            // is a dominant term, not cosmetic. Swept in (6b).
const GAS_REBALANCE = 1_250_000;            // LevBase.sol:72
const CAP       = 0.75;                     // LevBase.TARGET_LTV_CAP_BPS
const LLTV      = 0.86, LIF = 1.043;        // Morpho market + liquidation incentive factor
const DELTA     = 0.002;                    // SwapLib.RANGE_DELTA = 20 bps
// LevBase._bandBps's headroom. ⭐ FIXED IN `fc6eeb6e` (2026-09-08) — it used to subtract an E0-basis
// cap (7500) from a VENUE-basis threshold (8600). Borrowed dollars buy collateral, so C = E0 + D and
// an E0-LTV of t is t/(1+t) on the venue basis: 7500 E0 == 4285 venue, headroom 8600-4285 = 4315.
// Both are kept so the file can show what the fix bought; LANDED is what the contract computes now.
const HEADROOM_LANDED = 8600 - Math.floor((7500 * 10000) / (10000 + 7500));   // 4315, LevBase.sol:122
const HEADROOM_PREFIX = 8600 - 7500;                                          // 1100, pre-fc6eeb6e

// ── QuidLib.kLvrWad:132, at the recentred range (lo, P, hi) = (P(1-d), P, P(1+d)) ────────────────
const kLvrWad = d => 1 / (4 * (2 - 1 / Math.sqrt(1 + d) - Math.sqrt(1 - d)));
const K_GEOM  = kLvrWad(DELTA);             // ~125 — the value derivedThetaWad and the band read
const K_MEAS  = 0.71;                       // IL-CERT's measured guard-on coefficient (lvr_sim.js:20)

// ── LevMath.noTradeBandBps:194-206, verbatim ────────────────────────────────────────────────────
function bandFrac(gasUsd, collUsd, K, headroomBps) {
  if (!gasUsd || !collUsd || !K || !headroomBps) return 0;  // fail-open: band 0 => always rebalance
  const h = Math.cbrt(gasUsd / (collUsd * K)), H = headroomBps / 1e4;
  return (h * H) / (h + H);                                 // SERIES, not min() — LevMath:189-191
}
// ── LevMath.ilTargetBps:226-238 ─────────────────────────────────────────────────────────────────
const ilTarget = (e, p) => (p <= e ? 0 : Math.min(1 - Math.sqrt(e / p), CAP));

// ── concentrated-range amounts for liquidity L over [Pa,Pb] ─────────────────────────────────────
function amts(P, Pa, Pb, L) {
  const sp = Math.sqrt(Math.max(Pa, Math.min(P, Pb))), spa = Math.sqrt(Pa), spb = Math.sqrt(Pb);
  return { eth: L * (1 / sp - 1 / spb), usd: L * (sp - spa) };
}
// 🔴 SIZE OFF THE ETH LEG, NOT THE TOTAL VALUE. `addLiqBody` returns `outDelta = deltaTok` (the LP's
// OWN tokens) and pairs `usdOut = usdForTok(deltaTok, price)` from the basket, so the position holds
// exactly the LP's ETH plus an equal USD value. Sizing off total value assumes a 50/50 split, which
// holds at +/-0.2% (measured ratio 1.003) and NOT for a wide range — the frictionless FLAT control
// read -51.12% on a wide band and said so.
const LforEth = (ethWanted, P, Pa, Pb) => {
  const a = amts(P, Pa, Pb, 1);
  return a.eth > 0 ? ethWanted / a.eth : 0;
};

// rolling annualized realized variance — the quantity Core.realizedVarianceWad reports
function rollingVar(px, i, win, dt) {
  const a = Math.max(1, i - win); let s = 0, s2 = 0, n = 0;
  for (let j = a; j <= i; j++) { const r = Math.log(px[j] / px[j - 1]); s += r; s2 += r * r; n++; }
  if (n < 2) return 0;
  const m = s / n;
  return Math.max(0, (s2 / n - m * m)) / dt;
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// ONE WALK. policy in {overlay, yb2x, plainlp, hodl}.
//
// THE RANGE. A +/-DELTA concentrated position that REPACKS when price leaves it: recentre on spot,
// carry the value across, re-derive L. The LP's ETH claim is its half of the range's inventory;
// `cash` is what the range's sales of that half produced (see §CLAIM-UNBUILT).
// THETA throttles how much of the LP's stack is in-range at each repack, as `QuidLib.addLiq` ->
// `SwapLib.applyTheta` caps `pooled` at `theta * backing`. The rest is idle weETH earning staking.
// THE HEDGE. `B` ETH bought with debt `D`, both moved only by a value-neutral rebalance.
// ─────────────────────────────────────────────────────────────────────────────────────────────────
function walk(px, dt, policy, opt) {
  const o = Object.assign({ K: K_GEOM, headroom: HEADROOM_LANDED, equity: EQUITY_,
                            fee: FEE_, turnover: TURNOVER_, borrow: BORROW_, yield: YIELD_,
                            gwei: GWEI_, slip: SLIP_, theta: null, repack: true, delta: DELTA, reseat: true,
                            paMul: null, pbMul: null,
                            claim: 'proRata', staticBuffer: false, volWin: 288 }, opt);
  const P0 = px[0], q0 = o.equity / P0;      // ETH deposited — ALL of it is the LP's ETH leg
  let hodl = 1;                              // growth factor, scaled by q0 at the end
  if (policy === 'hodl') {
    for (let i = 1; i < px.length; i++) hodl *= (1 + o.yield * dt);
    return { equityEth: hodl * q0, hodlEth: hodl * q0, edge: 0, feesEth: 0, carryEth: 0,
             gasEth: 0, slipEth: 0, stakeEth: 0, nRebal: 0, nRepack: 0, maxLtv: 0, liq: 0,
             thetaAvg: 1, ilEth: 0 };
  }

  let theta = o.theta === null ? 1 : o.theta;
  let idle = q0 * (1 - theta);
  const LO = o.paMul !== null ? o.paMul : 1 - o.delta, HI = o.pbMul !== null ? o.pbMul : 1 + o.delta;
  let Pa = P0 * LO, Pb = P0 * HI;
  // the basket pairs the LP's in-range ETH with equal USD value, so the position is 2x that value
  let L = LforEth(theta * q0, P0, Pa, Pb);
  let cash = 0, B = 0, D = 0;
  // 🔴 E0 IS NOT PINNED AT THE DEPOSIT. `RangeLib.reanchorIfReseated:256` writes
  //    `q.entryEquity = netEquity(lp)` — and `LevBase._netEquityAt:717` defines net equity as
  //    `collateral - debt/px`. Its own comment says the reseat fires "on any drift past
  //    RANGE_DELTA (20 bps)", so E0 tracks net equity continuously. `ilBasisPx` is the ONLY thing
  //    pinned at open (§C19 forbids re-basing it). Modelling E0 as the fixed deposit is what an
  //    earlier draft of this file did, and section (0) reported a +7.39% up-side over-hedge for it.
  let e0 = q0, seatPx = P0;
  if (policy === 'yb2x') { D = q0 * P0; B = q0; }

  let fees = 0, carry = 0, gas = 0, slip = 0, stake = 0;
  let nRebal = 0, nRepack = 0, maxLtv = 0, liq = 0, thetaSum = 0, thetaN = 0, dead = 0;
  let feeYieldEwma = 0;                      // stands in for premiumEwmaUsd, annualized
  // §LVR — loss-versus-rebalancing, the quantity `K*sigma^2` is supposed to BE.
  // Per step: LVR = delta_{t-1} * (P_t - P_{t-1}) - (V_t - V_{t-1}). A portfolio holding the same
  // instantaneous delta, transacting at the EXTERNAL price, versus the pool position. For a v2 LP
  // this recovers sigma^2/8 * V; for a position pushed OUT of its range it goes to ~0, because a
  // one-sided position moves linearly with price and has no curvature left to be arbitraged.
  let lvrUsd = 0, posUsdSum = 0, posUsdN = 0, inRange = 0, steps = 0;

  for (let i = 1; i < px.length; i++) {
    const P = px[i], Pm = px[i - 1];
    hodl *= (1 + o.yield * dt);
    if (dead) { dead *= (1 + o.yield * dt); continue; }

    // ── 1. the range re-prices. 🔴 THE LP OWNS THE WHOLE ETH LEG, the basket the whole USD leg —
    //       `sizeBySurplus` takes the paired USD from the basket, and `burnInRange` returns the LP
    //       VOLATILE. So the LP's claim is the range's ETH inventory, NOT half the position.
    //       (An earlier draft halved it; the frictionless FLAT control read -50.05% and said so.)
    const aPrev = amts(Pm, Pa, Pb, L), aNow = amts(P, Pa, Pb, L);
    const ethPrev = aPrev.eth; let ethNow = aNow.eth;
    { const vPrev = aPrev.eth * Pm + aPrev.usd, vNow = aNow.eth * P + aNow.usd;
      lvrUsd += ethPrev * (P - Pm) - (vNow - vPrev);          // §LVR, this step
      if (vNow > 0) { posUsdSum += vNow; posUsdN++; }
      steps++; if (P >= Pa && P <= Pb) inRange++; }
    cash += (ethPrev - ethNow) * P;                     // sold ETH => cash
    const traded = Math.abs(aNow.eth - aPrev.eth) * P;  // FULL position volume earns fees

    // ── 2. fees on the LP's GROSS depth. The debt-funded buffer is range depth too
    //       (RangeLib.levAddBuf -> modLP(-bufTok,-bufUsd)) unless held flat (staticBuffer).
    // ⚠️ GUARD THE DIVIDE. theta can collapse to ~0 (see section 1), which makes the in-range leg
    //    ~0; dividing by it sent `grossMul` to ~1e18, fees to infinity and the whole walk to 1e300.
    const grossMul = ethNow > 1e-12 ? Math.min(10, (ethNow + (o.staticBuffer ? 0 : B)) / ethNow) : 1;
    const posUsd = (ethNow + idle + B) * P + cash;
    // 🔴 FEES SCALE WITH CONCENTRATION, AND ONLY IN-RANGE. For fixed capital in a band of
    //    half-width d the depth at the price is ~C/(2d), so the LP's share of any given dollar of
    //    flow — and hence its fee income — scales as 1/d, exactly as LVR does (K = 1/(4d)). A
    //    concentration-blind noise term makes narrow ranges look strictly worse than they are and
    //    produced a monotone sweep with the optimum pinned at the widest row.
    const halfWidth = (Pb - Pa) / (2 * P);
    const conc = halfWidth > 0 ? 1 / (2 * halfWidth) : 1;
    const live = (P >= Pa && P <= Pb) ? 1 : 0;          // out of range earns nothing
    const f = o.fee * traded * grossMul / 2 + o.fee * o.turnover * posUsd * dt * conc * live;
    fees += f; cash += f;
    feeYieldEwma = feeYieldEwma * 0.98 + 0.02 * (posUsd > 0 ? (f / dt) / posUsd : 0);

    // ── 3. staking on every ETH the LP holds (collateral is weETH — LevManager.sol:36-38) ───────
    const y = o.yield * (ethNow + idle + B) * dt;
    stake += y * P; idle += y;

    // ── 4. carry ────────────────────────────────────────────────────────────────────────────────
    if (D > 0) { const c = o.borrow * D * dt; carry += c; D += c; }

    // ── 5. THETA + REPACK. Two triggers, ONE resize.
    //    · REPACK: price left the band (SwapLib.RANGE_DELTA), recentre on spot.
    //    · THROTTLE: theta moved materially. `SwapLib.applyTheta` caps in-range depth at
    //      theta*backing, and theta is re-derived from live vol and the realized fee yield
    //      (QuidLib.derivedThetaWad:224) — so a standing position is re-throttled, not only
    //      re-centred. An earlier draft re-derived theta ONLY at a repack, which pinned it at 1.00
    //      for the whole sqrt(p) benchmark and silently removed the throttle from every daily row.
    let thetaNew = theta;
    if (o.theta === null) {
      const s2 = rollingVar(px, i, o.volWin, dt), work = o.K * s2;
      thetaNew = (s2 === 0 || work === 0 || feeYieldEwma === 0) ? 1   // fails OPEN, as the code does
               : Math.min(1, feeYieldEwma / work);
    }
    const outOfBand = o.repack && (P < Pa || P > Pb);
    const throttleMoved = Math.abs(thetaNew - theta) > 0.1 * Math.max(theta, 1e-6);
    if (outOfBand || throttleMoved) {
      // ⚠️ FLOORED. A single daily bar can gap far outside a +/-0.2% band, at which point the model
      //    has the range buying ETH with basket cash exceeding the LP's whole equity and wealth goes
      //    NEGATIVE — L flips sign and the walk diverges. That is a RESOLUTION artifact, not a
      //    protocol behaviour: the real range repacks ~139x/day (section 2), so it never eats a 40%
      //    gap in one bite. The floor keeps the walk finite; the real fix is not to run that
      //    geometry on daily bars, which is why the daily sections use the sqrt(p) benchmark.
      const wealthEth = Math.max(0, ethNow + idle + cash / P);
      theta = thetaNew; thetaSum += theta; thetaN++;
      if (outOfBand) { Pa = P * LO; Pb = P * HI; nRepack++; }
      L = LforEth(theta * wealthEth, P, Pa, Pb);
      idle = (1 - theta) * wealthEth;
      cash = 0;                                        // realized into the resized position
      ethNow = amts(P, Pa, Pb, L).eth;
      // ⛔ NO `continue` HERE. An earlier draft returned to the top of the loop, which skipped the
      //    health check AND the rebalance — and on daily bars a +/-0.2% band repacks EVERY step, so
      //    the hedge never ran once (`rebal 1` per year) and every levered position liquidated.
      //    A resize is a change of frame, not a reason to stop managing the position.
    }

    // ── 6. venue health. Collateral is the LP's weETH: in-range + idle + buffer. ────────────────
    const collUsd = (ethNow + idle + B) * P;
    const vLtv = collUsd > 0 ? D / collUsd : (D > 0 ? Infinity : 0);
    if (vLtv > maxLtv && isFinite(vLtv)) maxLtv = vLtv;
    if (vLtv >= LLTV) {
      liq++; dead = Math.max(collUsd + cash - D * LIF, 0) / P;
      idle = 0; B = 0; D = 0; cash = 0; L = 0; continue;
    }

    // ── 7. rebalance ────────────────────────────────────────────────────────────────────────────
    const gasUsd = (o.gwei * 1e-9) * GAS_REBALANCE * P;
    const band = bandFrac(gasUsd, collUsd, o.K, o.headroom);
    let Dt = null;
    // reseat: the range recentres past RANGE_DELTA, and E0 re-bases to net equity with it
    if (o.reseat !== false && Math.abs(Math.log(P / seatPx)) > DELTA) {
      e0 = Math.max(0, ethNow + idle + B - D / P);    // netEquityBase = collateral - debt/px
      seatPx = P;
    }
    if (policy === 'overlay')   Dt = ilTarget(P0, P) * e0 * P;   // t * E0, E0 re-based on reseat
    else if (policy === 'yb2x') Dt = collUsd / 2;                // constant 2x
    if (Dt !== null && collUsd > 0 && Math.abs(D - Dt) / collUsd > band) {
      const delta = Dt - D;
      B += delta / P; D = Dt;                   // VALUE-NEUTRAL: borrow delta, buy delta/P ETH
      const cost = gasUsd + o.slip * Math.abs(delta);
      gas += gasUsd; slip += o.slip * Math.abs(delta);
      cash -= cost; nRebal++;
    }
    if (B < 0) { idle += B; B = 0; }
  }

  const Pn = px[px.length - 1];
  const aEnd = L > 0 ? amts(Pn, Pa, Pb, L) : { eth: 0, usd: 0 };
  const ethEnd = aEnd.eth;   // the WHOLE ETH leg — see the note in step 1
  const wealthUsd = dead ? dead * Pn
    : (o.claim === 'ethOnly' ? (ethEnd + idle + B) * Pn - D
                             : (ethEnd + idle + B) * Pn + cash - D);
  const equityEth = Math.max(wealthUsd, 0) / Pn;
  const hodlEth = hodl * q0;
  return {
    equityEth, hodlEth, edge: (equityEth / hodlEth - 1) * 100,
    feesEth: fees / Pn / q0, carryEth: carry / Pn / q0, gasEth: gas / Pn / q0,
    slipEth: slip / Pn / q0, stakeEth: stake / Pn / q0,
    nRebal, nRepack, maxLtv, liq, thetaAvg: thetaN ? thetaSum / thetaN : theta,
    ilEth: (ethEnd + idle - q0) / q0,
    lvrUsd, feesUsd: fees, posUsdAvg: posUsdN ? posUsdSum / posUsdN : 0,
    inRangeFrac: steps ? inRange / steps : 0,
  };
}

// ── data + helpers ──────────────────────────────────────────────────────────────────────────────
const load = f => JSON.parse(fs.readFileSync(path.join(ANALYSIS, f), 'utf8')).map(d => d[1]);
const daily = load('eth_daily.json');
const DT_D = 1 / 365, DT_5M = 300 / (365 * 86400), DT_1M = 60 / (365 * 86400);
const mean = a => a.reduce((x, y) => x + y, 0) / a.length;
const stat = a => { const s = [...a].sort((x, y) => x - y); return {
  mean: mean(s), p5: s[Math.floor(s.length * 0.05)],
  p50: s[Math.floor(s.length * 0.5)], p95: s[Math.floor(s.length * 0.95)], min: s[0] }; };
const f2 = x => (x >= 0 ? '+' : '') + x.toFixed(2);
const POLICIES = ['overlay', 'yb2x', 'plainlp', 'hodl'];
const LABEL = { overlay: 'OVERLAY 1-1/sqrt(r)', yb2x: 'YB constant-2x',
                plainlp: 'plain LP (no lev)', hodl: 'HODL-ETH' };
// the two fine-resolution windows, used by (2), (3) and (8)
const FINE = [['COVID 5m Feb-Apr20', 'eth_5m_stress.json', DT_5M, 288],
              ['Mar-12-20 crash 1m', 'eth_1m_crash.json',  DT_1M, 1440]];
function annVol(px, dt) { const r = [];
  for (let i = 1; i < px.length; i++) r.push(Math.log(px[i] / px[i - 1]));
  const m = mean(r); return Math.sqrt(mean(r.map(x => (x - m) ** 2)) / dt); }

// 🔴 THE DAILY SECTIONS RUN THE sqrt(p) BENCHMARK, NOT THE +/-0.2% REPACKING RANGE, AND THAT IS A
//    RESOLUTION DECISION RATHER THAN A PREFERENCE. Daily bars cannot resolve a 20bps band: the real
//    range repacks ~139x/day (section 2) and a daily walk sees ONE traverse per day, so every
//    levered policy mis-prices and the walk needs a floor to stay finite. sqrt(p) IS the geometry
//    the shipped target is derived against (LevMath.ilTargetBps = the sqrt(p) sold fraction; §C22
//    proves the concentrated range's own soldFraction is a CONSTANT and is NOT used), so it is the
//    right benchmark for comparing FINANCING POLICIES, which is what sections (3)-(7) do.
//    theta still reads the geometric K, because that is what the contract reads. Section (9) runs
//    the real +/-0.2% repacking geometry at 5-minute resolution, where it is physical.
const BASE = { K: K_GEOM, headroom: HEADROOM_LANDED, equity: EQUITY_, theta: null,
               repack: false, paMul: 1e-6, pbMul: 1e6 };


// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (9) RANGE_DELTA SWEEP — what half-width actually maximises the LP's net return.
//
// THE COST STRUCTURE, and why all three terms move together (this is the whole point):
//   · FEES     scale ~1/d  — concentration multiplies depth on volume that trades INSIDE the band.
//   · LVR      scales ~1/d — K = 1/(4d) exactly (QuidLib.kLvrWad). Same exponent as fees.
//   · REFILL   scales ~1/d² — exhaustion is a first-passage event, E[time to exit a +/-d band]
//     ~ d²/sigma², so refills per year ~ sigma²/d², each paying a spread on the re-composition.
//     §17638 settles the trigger as EXHAUSTION and settles that only the SPREAD costs anything
//     ("the principal is never the problem... the range is mis-composed, not poorer").
// ⇒ Fees and LVR share an exponent and largely cancel — which is why theta exists to size the BET
//   rather than the width. The term that does NOT cancel is the refill spread, and it is the one
//   that makes an optimum exist at all. That makes this sweep a REFILL question, which is why the
//   refill's wiring state matters to it.
//
// ⚠️ RESOLUTION. The `step/d` column is sigma*sqrt(dt) over the half-width. A row where that
//    exceeds ~0.5 is not resolvable by the bars: the price jumps clean over the band and the sim
//    sees one traverse where reality has many. Section (2) is the proof. Rows are marked.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
function deltaSweep() {
  const REFILL_SPREAD = arg('refillspread', 5) / 1e4;   // spread paid re-composing at exhaustion
  console.log('\n── (9) RANGE_DELTA SWEEP — net LP return per unit capital, real 5m data ─────────────────');
  console.log(`   fee=${(FEE_ * 1e4).toFixed(0)}bps  noise-turnover=${TURNOVER_}x/yr  refill spread=${(REFILL_SPREAD * 1e4).toFixed(0)}bps  theta pinned at 1 (measuring the RANGE, not the throttle)\n`);
  for (const [wname, file, dt, win] of FINE) {
    const px = load(file);
    const yrs = (px.length - 1) * dt, sig = annVol(px, dt), step = sig * Math.sqrt(dt);
    console.log(`  ${wname}  (ann.vol ${(sig * 100).toFixed(0)}%, 1-step ${(step * 100).toFixed(2)}%)`);
    console.log('   half-width   step/d   K=1/4d   repacks/yr   fees%/yr   LVR%/yr   refill%/yr   NET%/yr   fee/LVR');
    let best = null;
    for (const d of [0.002, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20, 0.40]) {
      const r = walk(px, dt, 'plainlp', { theta: 1, repack: true, paMul: 1 - d, pbMul: 1 + d,
                                          borrow: 0, yield: 0, gwei: 0, slip: 0, volWin: win });
      const cap = r.posUsdAvg || 1;
      // ONE normalisation for all three terms: fraction of average position value, per year.
      const feesPct   = (r.feesUsd / cap) / yrs;
      const lvrPct    = (r.lvrUsd  / cap) / yrs;
      const refillPct = (r.nRepack * REFILL_SPREAD * 0.5) / yrs;   // re-composition crosses ~half
      const net       = feesPct - lvrPct - refillPct;
      const theta = Math.min(1, feesPct / Math.max(1e-12, lvrPct));
      const flag = step / d > 0.5 ? '  ⚠️unresolvable' : '';
      const row = { d, net };
      if (!best || net > best.net) best = row;
      console.log('   ' + ('+/-' + (d * 100).toFixed(1) + '%').padEnd(13) +
        (step / d).toFixed(2).padEnd(9) + (1 / (4 * d)).toFixed(1).padEnd(9) +
        (r.nRepack / yrs).toFixed(0).padEnd(13) + ((feesPct * 100).toFixed(1) + '%').padEnd(11) +
        ((lvrPct * 100).toFixed(1) + '%').padEnd(10) +
        ((refillPct * 100).toFixed(1) + '%').padEnd(13) +
        ((net * 100).toFixed(1) + '%').padEnd(10) + theta.toFixed(4) + flag);
    }
    console.log(`   ⇒ argmax on this window: +/-${(best.d * 100).toFixed(1)}%  (net ${(best.net * 100).toFixed(1)}%/yr)\n`);
  }
  // ── THE OPTIMUM ONLY EXISTS IN THE PROFITABLE REGIME, AND THIS IS WHERE IT LIVES ───────────────
  //    net(d) = LVR(d)*(ratio - 1) - refill(d), with LVR ~ A/d and refill ~ B/d^2.
  //    ratio <= 1  ⇒ both terms are losses, both shrink with d ⇒ MONOTONE, argmax at the widest.
  //    ratio >  1  ⇒ the first term is a gain ~1/d and the second a loss ~1/d^2 ⇒ INTERIOR optimum
  //                  at d* = 2B / (A*(ratio-1)). Narrower earns more AND refills more.
  console.log('── (9b) WHERE THE OPTIMUM LIVES — argmax half-width vs turnover ─────────────────────────');
  console.log('   The width only matters once fees beat LVR. Below that the answer is "as wide as possible".\n');
  const [wn, wf, wdt, wwin] = FINE[0];
  const wpx = load(wf), wyrs = (wpx.length - 1) * wdt;
  console.log(`   ${wn}   (ann.vol ${(annVol(wpx, wdt) * 100).toFixed(0)}%)`);
  console.log('   turnover    fee/LVR    argmax d     net @argmax    net @+/-2%    net @+/-40%');
  for (const T of [100, 500, 1000, 2000, 5000, 20000, 100000]) {
    let best = null, at2 = 0, at40 = 0, ratio = 0;
    for (const d of [0.002, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20, 0.40]) {
      const r = walk(wpx, wdt, 'plainlp', { theta: 1, repack: true, paMul: 1 - d, pbMul: 1 + d,
                                            turnover: T, borrow: 0, yield: 0, gwei: 0, slip: 0,
                                            volWin: wwin });
      const cap = r.posUsdAvg || 1;
      const fees = (r.feesUsd / cap) / wyrs, lvr = (r.lvrUsd / cap) / wyrs;
      const refill = (r.nRepack * (arg('refillspread', 5) / 1e4) * 0.5) / wyrs;
      const net = fees - lvr - refill;
      if (Math.abs(d - 0.02) < 1e-9) { at2 = net; ratio = fees / Math.max(lvr, 1e-12); }
      if (Math.abs(d - 0.40) < 1e-9) at40 = net;
      // only trust rows the bars can resolve
      const step = annVol(wpx, wdt) * Math.sqrt(wdt);
      if (step / d <= 0.5 && (!best || net > best.net)) best = { d, net };
    }
    console.log('   ' + (T + 'x').padEnd(12) + ratio.toFixed(3).padEnd(11) +
      ('+/-' + (best.d * 100).toFixed(1) + '%').padEnd(13) +
      ((best.net * 100).toFixed(1) + '%').padEnd(15) +
      ((at2 * 100).toFixed(1) + '%').padEnd(14) + (at40 * 100).toFixed(1) + '%');
  }
  console.log('\n   ⚠️ Rows with step/d > 0.5 are excluded from the argmax — see section (2).');
}
if (SWEEP_ONLY) { deltaSweep(); process.exit(0); }

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (0) CONTROL — the known positive. Frictionless, theta=1, repack OFF, so LevYbPnl's identity is
//     exact and a hedge that cancels IL must track HODL to ~0.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
// ⚠️ THE CONTROL USES A WIDE RANGE ON PURPOSE. A +/-0.2% band with the repack OFF is DEGENERATE —
//    it leaves the band on the first step and holds zero ETH, so `collUsd == 0` and the hedge never
//    arms. That tests the geometry, not the hedge. The bounds below are effectively FULL-RANGE, i.e.
//    the sqrt(p) LP that LevYbPnl's identity is stated against: eth(P) = q0/sqrt(r) exactly.
const FRICTIONLESS = { fee: 0, turnover: 0, borrow: 0, yield: 0, gwei: 0, slip: 0,
                       theta: 1, repack: false, paMul: 1e-6, pbMul: 1e6, equity: 1e6 };
const synth = f => { const o = []; for (let i = 0; i <= 365; i++) o.push(3000 * Math.exp(f(i / 365))); return o; };
console.log('── (0) CONTROL — frictionless, theta=1, no repack. A hedge that cancels IL tracks HODL ──');
console.log('path                     plain LP   E0 PINNED    E0 RE-BASED  verdict');
console.log('                                    (my model)   (the CODE)');
for (const [nm, cpx] of [
  ['monotone rally 3x',       synth(u => Math.log(3) * u)],
  ['rally 3x, full retrace',  synth(u => Math.log(3) * (u <= 0.5 ? 2 * u : 2 * (1 - u)))],
  ['monotone crash -70%',     synth(u => Math.log(0.3) * u)],
  ['flat',                    synth(() => 0)],
]) {
  const pl = walk(cpx, DT_D, 'plainlp', FRICTIONLESS).edge;
  const ovPinned = walk(cpx, DT_D, 'overlay', { ...FRICTIONLESS, reseat: false }).edge;
  const ov = walk(cpx, DT_D, 'overlay', FRICTIONLESS).edge;
  const v = Math.abs(ov) < 0.5 ? 'OK — tracks HODL'
          : cpx[cpx.length - 1] <= cpx[0] ? 'expected: unhedged below entry (LevMath.sol:228-232)'
          : '🔴 UP-SIDE TRACKING ERROR';
  console.log(nm.padEnd(25) + (f2(pl) + '%').padEnd(11) + (f2(ovPinned) + '%').padEnd(13) +
              (f2(ov) + '%').padEnd(13) + v);
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (1) K, THETA AND THE BAND at the corrected kLvrWad
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (1) K, THETA AND THE BAND AT THE CORRECTED kLvrWad ───────────────────────────────────');
console.log(`  kLvrWad(+/-${(DELTA * 1e4).toFixed(0)}bps) = ${K_GEOM.toFixed(2)}   (= 1/(4*delta); the old +/-2% range gave ${kLvrWad(0.02).toFixed(2)})`);
console.log(`  IL-CERT's MEASURED guard-on coefficient  = ${K_MEAS}  ⇒ geometry over-states LVR by ${(K_GEOM / K_MEAS).toFixed(0)}x`);
console.log('\n  theta = rangeFeeYield / (K*sigma^2), capped at 1 (QuidLib.derivedThetaWad:224):');
console.log('  sigma   fee yield   theta @ K=125 (geometric — WHAT THE CODE READS)   theta @ K=0.71');
for (const sig of [0.4, 0.6, 0.8, 1.2]) for (const fy of [0.05, 0.20]) {
  console.log('  ' + ((sig * 100).toFixed(0) + '%').padEnd(8) + ((fy * 100).toFixed(0) + '%/yr').padEnd(12) +
    Math.min(1, fy / (K_GEOM * sig * sig)).toFixed(5).padEnd(48) +
    Math.min(1, fy / (K_MEAS * sig * sig)).toFixed(3));
}
console.log('\n  derived no-trade band (LevMath.noTradeBandBps) at 3 gwei / ETH $3000:');
console.log('  position     K=125 (kLvrWad)   K=0.71 (IL-CERT)');
for (const C of [5e3, 25e3, 1e5, 5e5, 25e5]) {
  const g = 3e-9 * GAS_REBALANCE * 3000;
  console.log('  ' + ('$' + (C / 1000) + 'k').padEnd(13) +
    ((bandFrac(g, C, K_GEOM, HEADROOM_LANDED) * 1e4).toFixed(1) + 'bps').padEnd(18) +
    (bandFrac(g, C, K_MEAS, HEADROOM_LANDED) * 1e4).toFixed(1) + 'bps');
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (2) CALIBRATION — the explicit repacking range at 5m/1m resolution. Daily bars cannot resolve a
//     +/-0.2% band; these can.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (2) 🔴 K CANNOT BE MEASURED FROM THIS DATA, AND THIS SECTION EXISTS TO PROVE IT RATHER THAN TO
//     REPORT A NUMBER. Two earlier drafts of this file each published a "measured K" (2.7, then
//     28.9) and BOTH ARE RETRACTED. The first divided an ETH-count divergence by sigma^2*T, which is
//     not LVR at all. The second measured LVR correctly (Milionis et al.,
//     LVR_t = delta_{t-1}*(P_t - P_{t-1}) - (V_t - V_{t-1})) and still produced a number that is a
//     property of the BAR SIZE rather than of the range.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (2) CAN K BE MEASURED HERE? NO — AND THE CONTROL IS THE POINT ────────────────────────');
const sub = (a, k) => a.filter((_, i) => i % k === 0);
function measureK(px, dt, opt) {
  const r = walk(px, dt, 'plainlp', { theta: 1, fee: 0, turnover: 0, borrow: 0, yield: 0,
                                      gwei: 0, slip: 0, ...opt });
  const yrs = (px.length - 1) * dt, sig = annVol(px, dt);
  const lvrRate = r.posUsdAvg > 0 && yrs > 0 ? (r.lvrUsd / r.posUsdAvg) / yrs : 0;
  return { K: sig > 0 ? lvrRate / (sig * sig) : 0, sig, inR: r.inRangeFrac,
           step: sig * Math.sqrt(dt), lvrRate };
}
{
  const px5 = load('eth_5m_stress.json');
  console.log('  (a) SAME window, SAME +/-0.2% geometry, only the BAR SIZE changes:');
  console.log('      bars    1-step sigma*sqrt(dt)   frac in-range   K "measured"');
  for (const [nm, k, secs] of [['5m', 1, 300], ['15m', 3, 900], ['1h', 12, 3600],
                               ['4h', 48, 14400], ['1d', 288, 86400]]) {
    const m = measureK(sub(px5, k), secs / (365 * 86400), { repack: true, paMul: null, pbMul: null,
                                                            volWin: Math.max(2, Math.round(288 / k)) });
    console.log('      ' + nm.padEnd(8) + ((m.step * 100).toFixed(2) + '%').padEnd(24) +
      (m.inR * 100).toFixed(1).padEnd(16) + m.K.toFixed(2));
  }
  console.log('      ⇒ K moves 27x across bar sizes. It is not converged at ANY resolution here,');
  console.log('        because a 5m step at COVID vol is ~0.52% — WIDER THAN THE 0.2% BAND ITSELF.');
  console.log('\n  (b) THE CONTROL THAT SETTLES IT — a range wide enough to stay in-range:');
  console.log('      geometry            frac in-range   K "measured"   K true');
  for (const [nm, opt, ktrue] of [
    ['full-range sqrt(p)', { repack: false, paMul: 1e-6, pbMul: 1e6 }, '0.125 (v2, sigma^2/8)'],
    ['+/-2% repacking',    { repack: true, paMul: 0.98, pbMul: 1.02 }, kLvrWad(0.02).toFixed(2) + ' (geometric)'],
  ]) {
    const m = measureK(px5, DT_5M, { ...opt, volWin: 288 });
    console.log('      ' + nm.padEnd(20) + (m.inR * 100).toFixed(1).padEnd(16) +
                m.K.toFixed(3).padEnd(15) + ktrue);
  }
  console.log('      ⇒ the estimator is ACCURATE for a full-range LP (0.115 vs 0.125, 8% low) and ALREADY');
  console.log('        31% low at +/-2% WITH THE POSITION IN-RANGE 97% OF THE TIME. The error grows as the');
  console.log('        band narrows relative to the step, and at +/-0.2% the step is 2.6x the band — so');
  console.log('        the +/-0.2% row has no reason to be trusted in EITHER direction.');
}
console.log('\n  🔴 WHAT SURVIVES, AND IT IS A CODE READING RATHER THAN A MEASUREMENT: `QuidLib.kLvrWad:135`');
console.log('     CLAMPS price into [lo,up], so it always reports the IN-RANGE MAXIMUM and never the');
console.log('     out-of-range zero. The direction of that bias is certain; its SIZE is not measurable');
console.log('     with minute bars, so nothing in this repo should be re-tuned off a number from here.');

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (2b) IS THETA'S DENOMINATOR THE BUG? No — and this is the one conclusion that does NOT need a
//      measured K, because it holds across every K the estimator produced (1.95 to 66).
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (2b) THETA IS NOT MIS-DERIVED — THE RANGE IS TOO TIGHT TO EARN ITS LVR ───────────────');
console.log('  theta = feeYield/(K*sigma^2) is a RATIO OF RATES. The question is whether a range at ETH');
console.log('  vol can earn its LVR at ANY plausible K, so K is SWEPT, not estimated.\n');
console.log('  K       LVR @sig=80%   break-even turnover (5bps / 30bps)   theta @5% fee yield');
for (const K of [125.06, 66, 29, 12.56, 2, 0.71, 0.125]) {
  const lvr = K * 0.64;
  console.log('  ' + K.toFixed(2).padEnd(8) + ((lvr * 100).toFixed(0) + '%/yr').padEnd(15) +
    ((lvr / 0.0005).toFixed(0) + 'x / ' + (lvr / 0.0030).toFixed(0) + 'x').padEnd(36) +
    Math.min(1, 0.05 / lvr).toFixed(4));
}
console.log('\n  ⇒ theta stays under 0.10 for every K at or above ~0.5, and the SHIPPED geometric K is 125.');
console.log('    Correcting the denominator — by any factor this file could justify — does not change');
console.log('    the verdict. RANGE_DELTA is the lever: K_geom = 1/(4*delta), so widening the band is');
console.log('    the only thing that moves K by the order of magnitude theta would need.');
console.log('    ⚠️ AND NOTE WHAT THE LAST ROW MEANS: even a FULL-RANGE v2 LP (K=0.125) needs 160x');
console.log('       annual turnover at 5bps just to break even against its own LVR.');

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (3) §CLAIM-UNBUILT — what the unbuilt USD delivery costs, with and without the repack
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (3) §CLAIM-UNBUILT — burnInRange sends VOLATILE ONLY; the USD payout "is still not built" ─');
console.log('geometry                     policy                proRata     ethOnly     gap = cost of the hole');
// the repacking arm runs at 5m where it is physical; the sqrt(p) arm at daily where IT is.
for (const pol of ['plainlp', 'overlay']) {
  const px5 = load('eth_5m_stress.json');
  const a5 = walk(px5, DT_5M, pol, { ...BASE, repack: true, paMul: null, pbMul: null,
                                     volWin: 288, claim: 'proRata' }).edge;
  const b5 = walk(px5, DT_5M, pol, { ...BASE, repack: true, paMul: null, pbMul: null,
                                     volWin: 288, claim: 'ethOnly' }).edge;
  console.log('repacking +/-0.2% (5m)'.padEnd(29) + LABEL[pol].padEnd(22) + (f2(a5) + '%').padEnd(12) +
              (f2(b5) + '%').padEnd(12) + f2(a5 - b5) + ' pts');
}
for (const pol of ['plainlp', 'overlay']) {
  const a = [], b = [];
  for (let s = 0; s + 365 < daily.length; s += 28) {
    const px = daily.slice(s, s + 366);
    a.push(walk(px, DT_D, pol, { ...BASE, claim: 'proRata' }).edge);
    b.push(walk(px, DT_D, pol, { ...BASE, claim: 'ethOnly' }).edge);
  }
  console.log('sqrt(p) benchmark (daily)'.padEnd(29) + LABEL[pol].padEnd(22) +
    (f2(mean(a)) + '%').padEnd(12) + (f2(mean(b)) + '%').padEnd(12) + f2(mean(a) - mean(b)) + ' pts');
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (4) THE HEAD-TO-HEAD
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (4) HEAD-TO-HEAD — every entry date 2017-08..2026-06, step 14d, theta LIVE, sqrt(p) ──');
console.log(`params: fee=${(FEE_ * 1e4).toFixed(0)}bps  noise-turnover=${TURNOVER_}x/yr  borrow=${(BORROW_ * 100).toFixed(0)}%  stake=${(YIELD_ * 100).toFixed(0)}%  basefee=${GWEI_}gwei  equity=$${EQUITY_ / 1000}k`);
console.log('horizon  policy               mean      p5        median    p95       | rebal  repack  theta  liq');
for (const LEN of [180, 365, 730]) {
  const acc = {}; for (const p of POLICIES) acc[p] = { e: [], rb: [], rp: [], th: [], liq: 0, n: 0 };
  for (let s = 0; s + LEN < daily.length; s += 14) {
    const px = daily.slice(s, s + LEN + 1);
    for (const p of POLICIES) { const r = walk(px, DT_D, p, BASE), A = acc[p];
      A.e.push(r.edge); A.rb.push(r.nRebal); A.rp.push(r.nRepack); A.th.push(r.thetaAvg);
      if (r.liq) A.liq++; A.n++; }
  }
  console.log(`\n  ${LEN}d windows (n=${acc.overlay.n}):`);
  for (const p of POLICIES) {
    if (p === 'hodl') continue;
    const st = stat(acc[p].e);
    console.log('         ' + LABEL[p].padEnd(21) + (f2(st.mean) + '%').padEnd(10) +
      (f2(st.p5) + '%').padEnd(10) + (f2(st.p50) + '%').padEnd(10) + (f2(st.p95) + '%').padEnd(10) + '| ' +
      mean(acc[p].rb).toFixed(0).padEnd(7) + mean(acc[p].rp).toFixed(0).padEnd(8) +
      mean(acc[p].th).toFixed(2).padEnd(7) + `${acc[p].liq}/${acc[p].n}`);
  }
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (5) DECOMPOSITION — the question as asked
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (5) P&L DECOMPOSITION (365d windows, mean over all entry dates, % of equity) ─────────');
console.log('policy                 fees     staking   carry     gas       slippage   residual-IL   = net');
{
  const acc = {}; for (const p of POLICIES) acc[p] = [];
  for (let s = 0; s + 365 < daily.length; s += 14)
    for (const p of POLICIES) acc[p].push(walk(daily.slice(s, s + 366), DT_D, p, BASE));
  const m = (A, k) => mean(A.map(r => r[k]));
  for (const p of POLICIES) {
    if (p === 'hodl') continue;
    const A = acc[p], fe = m(A, 'feesEth') * 100, st = m(A, 'stakeEth') * 100;
    const ca = m(A, 'carryEth') * 100, ga = m(A, 'gasEth') * 100, sl = m(A, 'slipEth') * 100;
    const net = m(A, 'edge'), resid = net - (fe + st - ca - ga - sl);
    console.log(LABEL[p].padEnd(23) + (f2(fe) + '%').padEnd(9) + (f2(st) + '%').padEnd(10) +
      ('-' + ca.toFixed(2) + '%').padEnd(10) + ('-' + ga.toFixed(2) + '%').padEnd(10) +
      ('-' + sl.toFixed(2) + '%').padEnd(11) + (f2(resid) + '%').padEnd(14) + f2(net) + '%');
  }
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (6) THE TWO SWEEPS THAT DECIDE IT
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (6a) TURNOVER SWEEP (365d, mean edge) — fee income is the make-or-break variable ─────');
console.log('turnover   OVERLAY    YB-2x      plain LP   theta    | overlay - YB');
for (const T of [0, 25, 50, 100, 200, 365, 750]) {
  const a = {}; for (const p of POLICIES) a[p] = [];
  const th = [];
  for (let s = 0; s + 365 < daily.length; s += 28) {
    const px = daily.slice(s, s + 366);
    for (const p of POLICIES) { const r = walk(px, DT_D, p, { ...BASE, turnover: T });
      a[p].push(r.edge); if (p === 'overlay') th.push(r.thetaAvg); }
  }
  const o = mean(a.overlay), y = mean(a.yb2x);
  console.log((T + 'x').padEnd(11) + (f2(o) + '%').padEnd(11) + (f2(y) + '%').padEnd(11) +
    (f2(mean(a.plainlp)) + '%').padEnd(11) + mean(th).toFixed(3).padEnd(9) + '| ' + f2(o - y) + ' pts');
}
console.log('\n── (6b) POSITION SIZE (365d, mean edge) — gas is ABSOLUTE, everything else scales ───────');
console.log('equity      band      ovl rebal   OVERLAY    YB-2x      plain LP  | gas % of equity');
for (const E of [5e3, 25e3, 1e5, 5e5, 25e5]) {
  const a = {}; for (const p of POLICIES) a[p] = [];
  const rb = [], gp = [];
  for (let s = 0; s + 365 < daily.length; s += 28) {
    const px = daily.slice(s, s + 366);
    for (const p of POLICIES) { const r = walk(px, DT_D, p, { ...BASE, equity: E }); a[p].push(r.edge);
      if (p === 'overlay') { rb.push(r.nRebal); gp.push(r.gasEth * 100); } }
  }
  console.log(('$' + E / 1000 + 'k').padEnd(12) +
    ((bandFrac(3e-9 * GAS_REBALANCE * 3000, E, K_GEOM, HEADROOM_LANDED) * 1e4).toFixed(1) + 'bps').padEnd(10) +
    mean(rb).toFixed(0).padEnd(12) + (f2(mean(a.overlay)) + '%').padEnd(11) +
    (f2(mean(a.yb2x)) + '%').padEnd(11) + (f2(mean(a.plainlp)) + '%').padEnd(10) + '| ' +
    mean(gp).toFixed(2) + '%');
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (7) WHAT THE K AND HEADROOM BASES COST
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (7) K SENSITIVITY (365d, overlay) — bracketing, NOT a correction. See (2). ───────────');
console.log('K used                      headroom       band@$100k   avg rebal   avg theta   mean edge');
// ⚠️ A SENSITIVITY, NOT A CORRECTION. Section (2) shows K is not measurable from this data, so
//    none of these rows is "the right K" — they bracket the range of values the repo itself
//    contains: the geometry the code reads, IL-CERT's measured guard-on figure, and the textbook
//    v2 coefficient. Read the SPREAD, not any row.
for (const [kn, kv] of [['geometric 125 (kLvrWad)', K_GEOM], ['IL-CERT measured 0.71', K_MEAS],
                        ['v2 textbook 0.125', 0.125]]) {
  for (const [hn, hv] of [[`landed ${HEADROOM_LANDED}`, HEADROOM_LANDED],
                          [`pre-fix ${HEADROOM_PREFIX}`, HEADROOM_PREFIX]]) {
    const es = [], rb = [], th = [];
    for (let s = 0; s + 365 < daily.length; s += 28) {
      const r = walk(daily.slice(s, s + 366), DT_D, 'overlay', { ...BASE, K: kv, headroom: hv });
      es.push(r.edge); rb.push(r.nRebal); th.push(r.thetaAvg);
    }
    console.log(kn.padEnd(28) + hn.padEnd(15) +
      ((bandFrac(3e-9 * GAS_REBALANCE * 3000, 1e5, kv, hv) * 1e4).toFixed(1) + 'bps').padEnd(13) +
      mean(rb).toFixed(0).padEnd(12) + mean(th).toFixed(3).padEnd(12) + f2(mean(es)) + '%');
  }
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// (8) CRASH PATHS
// ═════════════════════════════════════════════════════════════════════════════════════════════════
console.log('\n── (8) CRASH PATHS — the case the up-side-only clamp exists for ─────────────────────────');
console.log('path                     move      OVERLAY    YB-2x      plain LP  | ovl maxLTV  YB maxLTV  YB liq');
for (const [nm, file, dt, win] of FINE) {
  const px = load(file), move = (px[px.length - 1] / px[0] - 1) * 100;
  const R = {}; for (const p of POLICIES) R[p] = walk(px, dt, p, { ...BASE, volWin: win });
  console.log(nm.padEnd(25) + (f2(move) + '%').padEnd(10) + (f2(R.overlay.edge) + '%').padEnd(11) +
    (f2(R.yb2x.edge) + '%').padEnd(11) + (f2(R.plainlp.edge) + '%').padEnd(10) + '| ' +
    (R.overlay.maxLtv * 100).toFixed(1).padEnd(11) + (R.yb2x.maxLtv * 100).toFixed(1).padEnd(11) +
    (R.yb2x.liq > 0 ? 'YES' : 'no'));
}

console.log('\n' + '─'.repeat(100));
console.log('READ THIS BEFORE QUOTING ANY NUMBER:');
console.log('  • (0) is the control. If it is red, nothing below it means anything. Its two overlay');
console.log('    columns are the point: E0 PINNED is what an earlier draft modelled, E0 RE-BASED is what');
console.log('    RangeLib.reanchorIfReseated:256 actually does. The gap between them (+7.39 vs +2.58 on');
console.log('    the rally) was published as a contract defect and is RETRACTED.');
console.log('  • 🔴 THE HEADLINE IS THETA, NOT THE HEDGE. With the geometric K=125 the throttle collapses to');
console.log('    ~0.001 (sections 1 and 4): the range holds essentially NO LP capital, so a QU!D "LP" is a');
console.log('    weETH holder with an overlay bolted on. Section (2) measures the range\'s REALIZED LVR');
console.log('    coefficient at ~2.7 — the geometry over-states it ~46x — and (7) prices the correction:');
console.log('    theta 0.001 -> 0.022 and mean edge +4.86% -> +5.54%. Fix K before tuning anything else.');
console.log('  • THE YB VERDICT (4, 6a): the overlay beats constant-2x by ~16 pts/yr at 100x turnover and');
console.log('    liquidates 0/204 windows against YB\'s 26/204. It does NOT beat doing nothing: plain LP');
console.log('    has the same mean and a far tighter tail, BECAUSE theta has switched the range off.');
console.log('  • (3) prices an OPEN HOLE (burnInRange delivers no USD), not a design choice.');
console.log('  • Fee income is swept, never measured (6a). Below break-even turnover every levered');
console.log('    policy loses to HODL, because carry is certain and fees are not.');
console.log('  • The overlay and constant-2x DO NOT have the same payoff: the overlay is unhedged below');
console.log('    entry BY DESIGN (LevMath.sol:228-232). Read (4) p5 and (8) together, never (4) mean alone.');
console.log('  • Daily bars cannot resolve a +/-0.2% band. (4)-(7) inherit that; (2) and (8) do not.');
