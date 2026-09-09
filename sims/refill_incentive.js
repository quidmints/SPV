#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// REFILL INCENTIVE — link 2 of the chain REFILL-START-HERE §5 says is unverified.
//
// The design: scarcity raises the charge (link 1, VERIFIED), the charge raises
// what an entrant earns (link 2, UNVERIFIED), and that pulls entry (link 3).
// §5 also names the failure mode: scarcity causes PARTIAL FILLS, so less flow,
// so LESS fee capture — a route by which the self-correction inverts.
//
// This measures link 2 and that failure mode. It does NOT measure link 3
// (whether a given yield actually attracts capital); that needs a supply
// elasticity this system has no data for, and asserting one would be a fit.
//
// ⛔ NOTHING BELOW IS ADMISSIBLE UNLESS SECTION 0 PASSES. Per §HARNESS-RETRACTIONS
//    the controls here are STRONGER than kernel_shape.js's: they reproduce
//    numbers this repo measured out of the REAL `skewWad` via
//    `test/SkewFloorAndSigmaFreeShare.t.sol`, not numbers from prose. If a
//    control fails, this file's kernel has drifted from the contract's.
// ─────────────────────────────────────────────────────────────────────────────

// ── constants, transcribed from SwapLib.sol / Types.sol ────────────────────
const FLOW_HALFLIFE   = 48 * 3600;
const GAMMA           = FLOW_HALFLIFE / (365 * 24 * 3600);  // 5.4795e-3
const KAPPA           = 1.0;
const ETH_CONF_FRAC   = 3.8e-7;      // ETH_CONF_FRAC_WAD, one block / one year
const DEPLETION_RATE  = 2.1e-4;      // DEPLETION_RATE_WAD, 210 ppm
const MIN_SWAP_SKEW   = 4.2e-4;      // MIN_SWAP_SKEW_WAD, 420 ppm

const bps = x => x * 1e4;
const pct = x => (x * 100).toFixed(2) + '%';

// qBar: the mean of kappa*q/(kappa-q) over the swap's own displacement (§E68/§E289).
function qBar(q0, q1, k = KAPPA) {
  const kq1 = k - q1;
  if (kq1 <= 0) return Infinity;
  if (q1 === q0) return k * q0 / (k - q0);
  const d = q1 - q0;
  const lnTerm = k * Math.log((k - q0) / kq1);
  return lnTerm > d ? k * (lnTerm - d) / d : 0;
}

// skewWad, ETH profile (spliceFloor 0), flush start so q0 = 0 and inv0 = target.
// skew = sigma2*(GAMMA*qBar + confFrac/8) + DEPLETION_RATE*(drained/inv0)
function skewWad(sigma2, q1, drainedFrac = q1) {
  if (q1 <= 0) return sigma2 * ETH_CONF_FRAC / 8;
  const kernel = GAMMA * sigma2 * qBar(0, q1);
  return kernel + sigma2 * ETH_CONF_FRAC / 8 + DEPLETION_RATE * drainedFrac;
}
// what a swapper actually pays: the producers floor the quote (SwapLib:1984, :2165)
const chargedRate = (sigma2, q1) => Math.max(skewWad(sigma2, q1), MIN_SWAP_SKEW);

// ══ SECTION 0 — CONTROLS ═══════════════════════════════════════════════════
let ok = true;
const check = (name, got, want, tol) => {
  const pass = Math.abs(got - want) <= tol;
  if (!pass) ok = false;
  console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}\n          got ${got}   want ${want}`);
};
console.log('=== SECTION 0 — CONTROLS (measured out of the real skewWad) ===\n');

// C1..C3 — the floor crossings measured by test_FloorReachIsAFunctionOfVolatilityNotAConstant.
function crossingBps(sigma2) {
  for (let b = 1; b <= 10000; b++) if (skewWad(sigma2, b / 10000) >= MIN_SWAP_SKEW) return b;
  return 10000;
}
check('C1 floor crossing @  30% vol (bps of target)', crossingBps(0.09), 6324, 2);
check('C2 floor crossing @  80% vol (bps of target)', crossingBps(0.64), 1891, 2);
check('C3 floor crossing @ 200% vol (bps of target)', crossingBps(4.00),  367, 2);

// C4..C5 — the sigma-free share measured by test_SigmaFreeShareOfTheChargeAcrossTheRange.
const sigmaFreeShareBps = (sigma2, q) =>
  Math.round(1e4 * (DEPLETION_RATE * q) / skewWad(sigma2, q));
check('C4 sigma-free share @ q=0.10, 80% vol (bps)', sigmaFreeShareBps(0.64, 0.10), 1004, 3);
check('C5 sigma-free share @ q=0.95, 80% vol (bps)', sigmaFreeShareBps(0.64, 0.95),  257, 3);

// C6 — §WASH retraction's published table: target 100 vs inventory 50 => q=0.5,
//      point-rate qBar = 1.0, skew 35.07 bps at 80% vol.
check('C6 point-rate skew at q=0.5, 80% vol (bps)', bps(GAMMA * 0.64 * qBar(0.5, 0.5)), 35.07, 0.02);

console.log(`\n  => CONTROLS ${ok ? 'PASS — downstream numbers are admissible' : 'FAIL — STOP'}\n`);
if (!ok) process.exit(1);

// ══ SECTION 1 — LINK 2: DOES AN ENTRANT'S YIELD RISE WITH SCARCITY? ════════
//
// THE PART THE PROSE OMITS: an entrant is not paid the yield they see on arrival.
// Entry does two things at once, both DILUTIVE:
//   (a) it adds inventory, which LOWERS q, which lowers the charge everyone pays;
//   (b) it adds depth, which RAISES the denominator the premium is spread over.
// `Quid.creditSkewPremium` -> `feeIncrements(0, p, lpShares + totalBuffer)` is
// the per-share accumulator, so (b) is exact and immediate.
// ⇒ The honest question is not "is the charge higher when scarce" (link 1, yes)
//   but "is the POST-ENTRY yield to the entrant higher when they enter scarcer".
console.log('=== SECTION 1 — the entrant is paid the POST-entry yield, not the one they see ===\n');

const SIGMA2 = 0.64;              // 80% annualized vol
const DEPTH  = 1.0;               // LP depth, normalized: depth == target == 1
const FLOW   = 1.0;               // gross flow per period, in units of target

// An entrant supplying `e` (as a fraction of target) into a range at scarcity q.
// Post-entry scarcity q' = max(0, q - e). Post-entry depth = DEPTH + e.
function entrantYield(q, e, flow = FLOW) {
  const qAfter = Math.max(0, q - e);
  const revenue = flow * chargedRate(SIGMA2, qAfter);
  return revenue / (DEPTH + e);
}

console.log('  entrant supplying 10% of target, at each arrival scarcity:');
console.log('   q      rate BEFORE   rate AFTER    entrant yield/period   vs q=0.05');
const E = 0.10;
const base1 = entrantYield(0.05, E);
for (const q of [0.05, 0.15, 0.25, 0.40, 0.55, 0.70, 0.85, 0.95]) {
  const y = entrantYield(q, E);
  console.log(`  ${q.toFixed(2)}   ${bps(chargedRate(SIGMA2, q)).toFixed(2).padStart(8)} bps  ` +
              `${bps(chargedRate(SIGMA2, Math.max(0, q - E))).toFixed(2).padStart(8)} bps  ` +
              `${bps(y).toFixed(3).padStart(12)} bps       ${(y / base1).toFixed(2)}x`);
}
console.log('\n  ⇒ LINK 2 HOLDS IN SIGN, and the floor is where it stops holding in MAGNITUDE:');
console.log(`     below q = ${(crossingBps(SIGMA2) / 1e4).toFixed(4)} the rate is the CONSTANT ${bps(MIN_SWAP_SKEW)} bps,`);
console.log('     so over that band an entrant\'s yield does not rise with scarcity at all —');
console.log('     it FALLS, purely from the dilution in (b). Scarcity communicates nothing there.\n');

// ══ SECTION 2 — THE FAILURE MODE §5 NAMES, PRICED ══════════════════════════
//
// A swap against short inventory takes a PARTIAL FILL and refunds the rest
// (REFILL-START-HERE §1, verified from code). So served flow is capped by
// inventory. Sizes are not observable here, so this sweeps the assumption
// rather than picking one: X ~ Exponential(mean m), served = E[min(X, I)]
//   = m*(1 - exp(-I/m)).  I = (1-q)*target.
console.log('=== SECTION 2 — partial fills: does served flow fall faster than the rate rises? ===\n');

const servedFlow = (q, m) => m * (1 - Math.exp(-(1 - q) / m));

for (const m of [0.05, 0.15, 0.40]) {
  console.log(`  mean swap size = ${pct(m)} of target:`);
  console.log('   q     served flow   rate        revenue      vs q=0.05');
  const r0 = servedFlow(0.05, m) * chargedRate(SIGMA2, 0.05);
  for (const q of [0.05, 0.25, 0.55, 0.75, 0.90, 0.95]) {
    const sf = servedFlow(q, m), r = sf * chargedRate(SIGMA2, q);
    console.log(`  ${q.toFixed(2)}  ${sf.toFixed(4).padStart(10)}   ` +
                `${bps(chargedRate(SIGMA2, q)).toFixed(1).padStart(7)} bps  ` +
                `${bps(r).toFixed(3).padStart(9)} bps  ${(r / r0).toFixed(2)}x`);
  }
  console.log('');
}

// ══ SECTION 3 — WHERE THE SELF-CORRECTION RUNS BACKWARDS ═══════════════════
//
// The inversion §5 fears is a region where LP revenue DECREASES in scarcity:
// there, being shorter earns LPs LESS, so entry is repelled exactly when it is
// needed. There are TWO such regions and they have different standing.
//
// ⛔ AN EARLIER DRAFT OF THIS SECTION REPORTED THE FIRST LOCAL DIP AS "THE PEAK"
//    AND GOT q = 0.0002 FOR EVERY SIZE — a number flatly contradicted by its own
//    Section 2 table. The dip is real; calling it the peak was the error. Kept as
//    a comment because it is the trap this file exists inside: a sweep that finds
//    the floor band and reads it as the scarcity price (REFILL-START-HERE §4.1).
console.log('=== SECTION 3 — the two regions where revenue FALLS as the range empties ===\n');

const cross = crossingBps(SIGMA2) / 1e4;

// REGION 1 — THE FLOOR BAND. Unconditional, and it needs no assumption about size.
// Below the crossing the rate is the CONSTANT 420 ppm, so revenue = servedFlow(q)
// * const, and servedFlow is strictly decreasing in q for EVERY size distribution
// with support above 0. ⇒ over this whole band, scarcity strictly REDUCES LP
// revenue. The correction does not merely fail to fire; it points the wrong way.
console.log(`  REGION 1 — THE FLOOR BAND, q < ${cross.toFixed(4)} at 80% vol.`);
console.log('    rate is CONSTANT here, so revenue tracks served flow alone, which only falls.');
console.log('    q      served(m=15%)   revenue     vs q=0');
for (const q of [0.0, 0.05, 0.10, 0.15, cross]) {
  const sf = servedFlow(q, 0.15), r = sf * chargedRate(SIGMA2, q);
  console.log(`   ${q.toFixed(4)}    ${sf.toFixed(5)}    ${bps(r).toFixed(4).padStart(8)} bps  ` +
              `${(r / (servedFlow(0, 0.15) * chargedRate(SIGMA2, 0))).toFixed(4)}x`);
}
console.log('    ⇒ STRICTLY DECREASING, for any size distribution. NOT distribution-dependent.');
console.log('    ⚠️ BUT READ THE MAGNITUDE, NOT THE SIGN: the fall is ~0.3% across the whole band.');
console.log('       The finding here is NOT a strong inversion — it is that the gradient is ~ZERO.');
console.log('       Scarcity carries essentially NO signal over this band, and what little it');
console.log('       carries points the wrong way. Section 1 is the same fact from the entrant\'s');
console.log('       side: post-entry yield is 3.818 bps at q=0.05, 0.15 AND 0.25 — identical.');
console.log(`    ⚠️ AND THE BAND IS THE WHOLE OPERATING RANGE ON A CALM TAPE: it is`);
console.log(`       q < ${(crossingBps(0.09)/1e4).toFixed(4)} at 30% vol and q < ${(crossingBps(4.0)/1e4).toFixed(4)} at 200% vol.\n`);

// REGION 2 — BEYOND THE GLOBAL PEAK. Conditional on the size distribution.
console.log('  REGION 2 — beyond the GLOBAL revenue peak. This one IS distribution-dependent.');
for (const m of [0.05, 0.15, 0.40]) {
  let best = -1, bestQ = 0;
  for (let b = 1; b <= 9990; b++) {
    const q = b / 1e4, r = servedFlow(q, m) * chargedRate(SIGMA2, q);
    if (r > best) { best = r; bestQ = q; }
  }
  const tail = servedFlow(0.99, m) * chargedRate(SIGMA2, 0.99);
  console.log(`    mean size ${pct(m).padStart(6)} of target -> revenue peaks at q = ${bestQ.toFixed(4)}` +
              `  (peak ${bps(best).toFixed(3)} bps, at q=0.99 ${bps(tail).toFixed(3)} bps` +
              `, ${((1 - tail / best) * 100).toFixed(0)}% below peak)`);
}
console.log('\n  ⚠️ REGION 2 IS A CONDITIONAL, NOT A VERDICT — the turning point is a property');
console.log('     of the SIZE DISTRIBUTION, which this system does not observe. What the sweep');
console.log('     establishes is that the inversion is not hypothetical: it exists for every');
console.log('     size in the plausible range, and WHERE it sits is an empirical question.');
console.log('  ⭐ REGION 1 CARRIES NO SUCH CAVEAT, which is why it is the load-bearing result:');
console.log('     it follows from the floor being a CONSTANT, and the floor is a constant by');
console.log('     declaration (`MIN_SWAP_SKEW_WAD`), not by calibration.');

// ══ SECTION 4 — THE COMPETITIVE BOUND ═══════════════════════════════════════
//
// OWNER, 2026-09-09: "an imbalance in the pool quantities shouldnt be a reason to
// deter swappers … no state of our pool ever should make uniswap more attractive."
//
// OUR EXECUTION HAS NO PRICE IMPACT. `Core:1022` — "SETTLE AT ORACLE, BOUNDED BY
// INVENTORY. No unlock, no callback, no curve traversal, no price discovery. ONE
// price for the whole size." So the swapper's ENTIRE cost with us is the skew.
// A CFMM's slippage, by contrast, is an artifact of the curve.
// ⇒ the comparison is: skew(q) bps   vs   feeTier + impact(size) bps.
// Rather than model v3 depth (which is a market fact, not ours), invert it: for
// any competitor all-in cost C, report the q at which WE become the worse venue.
console.log('\n=== SECTION 4 — at what scarcity does Uniswap become more attractive? ===\n');

const qOfCost = (sigma2, targetBps) => {          // smallest q whose charge exceeds targetBps
  for (let b = 1; b <= 9990; b++) {
    if (bps(chargedRate(sigma2, b / 1e4)) > targetBps) return b / 1e4;
  }
  return null;
};

console.log('  competitor all-in cost →   we lose above q =');
console.log('  (bps)          30% vol     80% vol    200% vol');
for (const C of [5, 7, 10, 15, 25, 50, 100]) {
  const f = v => { const q = qOfCost(v, C); return q === null ? '  never ' : q.toFixed(4).padStart(8); };
  console.log(`  ${String(C).padStart(4)}        ${f(0.09)}   ${f(0.64)}   ${f(4.0)}`);
}
console.log('\n  ⇒ READ IT AS: at 80% vol against a 7 bps venue, ANY scarcity past q≈0.30');
console.log('    makes us the dearer venue. That is inside the ordinary operating range,');
console.log('    not a tail — and the charge keeps rising without bound above it.');
console.log('\n  ⛔ AND THE POLE IS THE ISSUE, NOT THE LEVEL. The kernel is q/(κ−q) with');
console.log('    κ = 1e18, so the charge DIVERGES as inventory empties:');
for (const q of [0.90, 0.95, 0.98, 0.99]) {
  console.log(`     q=${q.toFixed(2)} → ${bps(chargedRate(SIGMA2, q)).toFixed(1).padStart(7)} bps at 80% vol`);
}
console.log('\n  ⭐ THE OBJECTIVE DECIDES THIS, AND IT IS NOT A PREFERENCE:');
console.log('     LP revenue = flow x charge. A charge above the alternative venue drives');
console.log('     flow to zero, so revenue does too. ⇒ the REVENUE-MAXIMISING charge is');
console.log('     BOUNDED BY THE COMPETITOR, and the bound is a market fact, not a policy');
console.log('     constant. Today the only bound is SKEW_UNFILLABLE = 100%.');
