#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// KERNEL SHAPE — the "measure before landing" SwapLib.sol:766-771 asks for.
//
// The question: SwapLib prices scarcity as  Γ·σ²·κq/(κ−q)  — A–S §2.2's LINEAR
// premium times an ad-hoc log-barrier. The docblock says a horizon proportional
// to the imbalance was "CONSIDERED AND IS NOT SAFE AS STATED" because it makes
// the premium ∝ q², citing 0505a993's refutation of §E287.
//
// This harness tests whether that refutation transfers. It does not assume it.
//
// ⛔ NOTHING BELOW IS TRUSTWORTHY UNLESS SECTION 0 PASSES. The controls
//    reproduce numbers PUBLISHED BEFORE THIS FILE EXISTED (§E274's crossing,
//    §E289's refactor claim). If a control fails, every downstream figure is an
//    artifact of my model, not a fact about the code. That rule is
//    §HARNESS-RETRACTIONS, written after four numbers from a previous harness
//    of mine had to be withdrawn.
// ─────────────────────────────────────────────────────────────────────────────
const WAD = 1e18;
const SKEW_UNFILLABLE = 1.0;              // SwapLib: skew > 1e18 ⇒ premium exceeds the trade
const GAMMA_OLD  = 3e16  / WAD;           // the inherited value (= MAX_WELL_SKEW, circular)
const GAMMA_DER  = (48 * 3600) / (365 * 24 * 3600); // FLOW_HALFLIFE/365d (SwapLib:771)
const KAPPA      = 1.0;                   // KAPPA_WAD = 1e18

const fmt = (x, d = 6) => (x === Infinity ? '    inf ' : x.toFixed(d));
const bps = x => (x * 1e4);

// ── the code's kernel, transcribed from SwapLib.sol:1571-1592 ───────────────
// qBar(q0,q1) = k*[ k*ln((k-q0)/(k-q1)) - D ] / D    (mean of k*q/(k-q) over D)
function qBarPole(q0, q1, k = KAPPA) {
  const kq1 = k - q1;
  if (kq1 <= 0) return Infinity;                 // kMinusQ1 == 0 => type(uint).max
  if (q1 === q0) return k * q0 / (k - q0);       // the D->0 branch: the point rate
  const d = q1 - q0;
  const lnTerm = k * Math.log((k - q0) / kq1);
  return lnTerm > d ? k * (lnTerm - d) / d : 0;
}
// ── the A-S 2.2 kernel with the horizon DERIVED rather than fixed ───────────
// tau = I/F.  I = q*target.  target = flowEwma + redeemEwma ~= F*T_flow.
// => tau = q*target/(target/T_flow) = q*T_flow.  Premium = g*s2*tau*q = G*s2*q^2,
// with G = g*T_flow -- THE SAME 5.48e15 THE CODE ALREADY SHIPS. Only the power
// of q differs. Mean of q^2 over the drain:
function qBarSquare(q0, q1) {
  if (q1 === q0) return q0 * q0;
  return (q1 ** 3 - q0 ** 3) / (3 * (q1 - q0));
}
const skew = (G, sig2, qbar) => (qbar === Infinity ? Infinity : G * sig2 * qbar);

// === SECTION 0 - CONTROLS ==================================================
let ok = true;
const check = (name, got, want, tol) => {
  const pass = Math.abs(got - want) <= tol;
  if (!pass) ok = false;
  console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}\n          got ${got}   want ${want}`);
};
console.log('=== SECTION 0 - CONTROLS (published numbers, predating this file) ===\n');

// C1 - E274 measured: under G=3e16 the kernel crosses SKEW_UNFILLABLE at
//      q >= 0.893 at 200% vol. 200% annualized vol => s2 = 4.0.
{
  const s2 = 4.0;
  const qbarNeeded = SKEW_UNFILLABLE / (GAMMA_OLD * s2);
  const qCross = qbarNeeded / (1 + qbarNeeded);
  check('C1  E274 crossing at 200% vol, G=3e16', +qCross.toFixed(4), 0.8929, 0.0002);
}
// C2 - E289: "at kappa = 1e18 every line below is the original".
{
  const a = qBarPole(0.30, 0.30, 1.0), b = 0.30 / (1 - 0.30);
  check('C2  E289 refactor is behaviour-preserving at k=1', a, b, 1e-12);
}
// C3 - the integral's D->0 limit must equal the point rate (the code's own
//      claim that the q1==q0 branch "IS the formula's own limit").
{
  const pt = qBarPole(0.5, 0.5), lim = qBarPole(0.5, 0.5 + 1e-9);
  check('C3  integral limit as D->0 equals the point rate', +lim.toFixed(6), +pt.toFixed(6), 1e-5);
}
// C4 - dimensional check: G*s2 must be dimensionless (a RATE). G is in YEARS,
//      s2 is annualized (per year).
{
  check('C4  G = 48h expressed in years', GAMMA_DER, 48 / (365 * 24), 1e-12);
}
console.log(`\n  => CONTROLS ${ok ? 'PASS - downstream numbers are admissible' : 'FAIL - STOP'}\n`);
if (!ok) process.exit(1);

// === SECTION 1 - the two shapes, side by side ==============================
console.log('=== SECTION 1 - POINT CHARGE vs SCARCITY (s2 = 0.64, i.e. 80% vol) ===');
console.log('    G = 5.48e15 (derived, as shipped) for BOTH. Only the q-power differs.\n');
console.log('      q        POLE kq/(k-q)     bps          q^2         bps       DECLINED?');
const sig2 = 0.64;
for (const q of [0.1, 0.3, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99, 0.999]) {
  const sp = skew(GAMMA_DER, sig2, qBarPole(q, q));
  const sq = skew(GAMMA_DER, sig2, qBarSquare(q, q));
  const dec = sp >= SKEW_UNFILLABLE ? '   POLE DECLINES' : '';
  console.log(`   ${q.toFixed(3)}   ${fmt(qBarPole(q, q), 4).padStart(11)}  ${fmt(bps(sp), 2).padStart(10)}   ${fmt(qBarSquare(q, q), 4).padStart(9)}  ${fmt(bps(sq), 2).padStart(9)}${dec}`);
}

// === SECTION 2 - where each kernel REFUSES to fill ==========================
console.log('\n=== SECTION 2 - THE DECLINE THRESHOLD (skew >= 1e18 => trade refused) ===\n');
console.log('   vol      s2      POLE declines at q >=     q^2 declines at q >=');
for (const vol of [0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0]) {
  const s2 = vol * vol;
  const qbN = SKEW_UNFILLABLE / (GAMMA_DER * s2);
  const qPole = qbN / (1 + qbN);
  const qSq = Math.sqrt(SKEW_UNFILLABLE / (GAMMA_DER * s2));
  console.log(`   ${(vol * 100).toFixed(0).padStart(4)}%   ${s2.toFixed(2).padStart(5)}         ${qPole.toFixed(4)}                ${qSq > 1 ? 'NEVER (bounded)' : qSq.toFixed(4)}`);
}
console.log('\n   The q^2 kernel is BOUNDED: max charge = G*s2 at q=1.');
for (const vol of [0.8, 1.5, 2.0, 3.0]) {
  console.log(`     ${(vol * 100).toFixed(0)}% vol => ceiling ${bps(GAMMA_DER * vol * vol).toFixed(1)} bps`);
}

// === SECTION 3 - REVENUE, which is the funding question ====================
// A pole does not collect infinity. It DECLINES, and a declined trade pays zero.
console.log('\n=== SECTION 3 - REVENUE ACTUALLY COLLECTED (declined trades pay 0) ===\n');
function revenue(kernelFn, G, s2) {
  let rev = 0, declined = 0, n = 0, revTail = 0, declTail = 0, nTail = 0;
  for (let q0 = 0.00; q0 < 0.98; q0 += 0.01) {
    for (const size of [0.005, 0.01, 0.02, 0.05, 0.10, 0.20]) {
      const q1 = Math.min(q0 + size, 0.9999);
      const s = skew(G, s2, kernelFn(q0, q1));
      n++;
      const tail = q0 >= 0.70;
      if (tail) nTail++;
      if (s >= SKEW_UNFILLABLE) { declined++; if (tail) declTail++; continue; }
      const r = s * size;                    // rate x trade size
      rev += r;
      if (tail) revTail += r;
    }
  }
  return { rev, revTail, pctDeclined: 100 * declined / n, pctDeclTail: 100 * declTail / nTail };
}
console.log('   vol      kernel     total rev    rev at q0>=0.70   %declined  %declined(tail)');
for (const vol of [0.6, 0.8, 1.5, 2.0]) {
  const s2 = vol * vol;
  const P = revenue(qBarPole, GAMMA_DER, s2);
  const Q = revenue(qBarSquare, GAMMA_DER, s2);
  console.log(`   ${(vol * 100).toFixed(0).padStart(4)}%     POLE       ${P.rev.toFixed(6).padStart(9)}     ${P.revTail.toFixed(6).padStart(9)}       ${P.pctDeclined.toFixed(1).padStart(5)}%      ${P.pctDeclTail.toFixed(1).padStart(5)}%`);
  console.log(`   ${(vol * 100).toFixed(0).padStart(4)}%     q^2        ${Q.rev.toFixed(6).padStart(9)}     ${Q.revTail.toFixed(6).padStart(9)}       ${Q.pctDeclined.toFixed(1).padStart(5)}%      ${Q.pctDeclTail.toFixed(1).padStart(5)}%`);
  console.log(`            => q^2/pole  ${(Q.rev / P.rev).toFixed(3)}x            ${(Q.revTail / P.revTail).toFixed(3)}x at the tail\n`);
}

// === SECTION 4 - IS THE PREMIUM FLAT ACROSS SIZE? ==========================
console.log('=== SECTION 4 - the refill thread\'s "4.2 bps FLAT across 100x of size" ===\n');
console.log('   Kernel charge (bps) at s2=0.64, sweeping size 100x from a NEAR-FLUSH range:\n');
console.log('     size(xtarget)     POLE bps        q^2 bps');
for (const size of [0.001, 0.003, 0.01, 0.03, 0.1]) {
  console.log(`     ${size.toFixed(3).padStart(9)}       ${bps(skew(GAMMA_DER, sig2, qBarPole(0, size))).toFixed(4).padStart(9)}     ${bps(skew(GAMMA_DER, sig2, qBarSquare(0, size))).toFixed(6).padStart(11)}`);
}
console.log('\n   Both kernels scale with size BY CONSTRUCTION. A charge that is FLAT across');
console.log('   100x is not this term at all -- `_maxWellSkew` (s2*confFrac/8) has NO q in it');
console.log('   and since E79 it ADDS as a floor. That is the only size-independent term here.');

// === SECTION 5 - ELASTIC DEMAND. SECTION 3 IS INVALID WITHOUT IT. ==========
// Section 3 totals revenue assuming every trade fills at ANY charge below a
// 100% haircut. That is not a market: at q=0.99 the pole quotes 3471 bps and
// NOBODY PAYS 34.7% to drain a range. An arbitrageur trades only while the
// mispricing they are capturing exceeds the charge. So sweep willingness W.
console.log('\n=== SECTION 5 - WITH ELASTIC DEMAND (fills only while charge <= W) ===\n');
console.log('   The question this actually answers: HOW FAR CAN THE RANGE BE DRAINED?\n');
console.log('   s2=0.64 (80% vol).  W = the most an arb will pay, in bps.\n');
console.log('     W(bps)    POLE stops at q     q^2 stops at q      pole rev   q^2 rev');
for (const Wb of [10, 25, 50, 100, 200, 400]) {
  const W = Wb / 1e4;
  const r = W / (GAMMA_DER * sig2);
  const qPole = r / (1 + r);
  const qSq = Math.sqrt(r);
  let rp = 0, rq = 0;
  for (let q0 = 0; q0 < 0.999; q0 += 0.005) {
    for (const size of [0.005, 0.01, 0.02, 0.05, 0.10, 0.20]) {
      const q1 = Math.min(q0 + size, 0.9999);
      const sp = skew(GAMMA_DER, sig2, qBarPole(q0, q1));
      const sq = skew(GAMMA_DER, sig2, qBarSquare(q0, q1));
      if (sp <= W) rp += sp * size;
      if (sq <= W) rq += sq * size;
    }
  }
  console.log(`     ${String(Wb).padStart(4)}       ${qPole.toFixed(4)}            ${qSq >= 1 ? 'FULLY DRAINABLE' : qSq.toFixed(4) + '         '}   ${rp.toFixed(5).padStart(8)}  ${rq.toFixed(5).padStart(8)}`);
}
console.log('\n   ⇒ THE POLE IS NOT A REVENUE DEVICE. IT IS A PRICE-BASED RESERVE.');
console.log('     It stops the drain by making the next slice unattractive, long before');
console.log('     SKEW_UNFILLABLE ever fires. q^2 is bounded, so above W~48bps it never');
console.log('     binds at all and the range drains to empty at a price arbs will pay.');

// === SECTION 6 - WHY A-S HAS NO BARRIER AND WE NEED ONE ====================
// A-S 2.2's premium is LINEAR in q and has no pole. Our tau = q*T_flow makes it
// q^2 -- still no pole. So where does a barrier come from at all?
// It is the BOUNDARY CONDITION A-S does not have: their market maker may hold
// NEGATIVE inventory (short) and rebalance in the outside market. Our range
// cannot: inventory is floored at ZERO and there is no outside rebalance
// (E276: "nothing currently pulls inventory back"). A premium derived under an
// unbounded-inventory assumption cannot price the last unit of a bounded one.
console.log('\n=== SECTION 6 - the barrier is a BOUNDARY CONDITION, not a fitted curve ===\n');
console.log('   A-S 2.2:  premium linear in q,  inventory unbounded (MM may go short)');
console.log('   ours:     inventory floored at 0, no outside rebalance venue');
console.log('   => the marginal value of the LAST unit diverges because it is the last one.');
console.log('      That is what q/(k-q) prices and what q^2 cannot. The pole is CORRECT;');
console.log('      "A-S 2.3 has a pole too" was the wrong justification for a right answer,');
console.log('      because 2.3 is the STATIONARY case and its pole sits at 2w = g^2 q^2 s2,');
console.log('      i.e. a location that MOVES WITH VOLATILITY. Ours is a constant.\n');
const SREF = 1.0;                                   // the vol at which k is calibrated
console.log('   If k inherited A-S 2.3\'s s-scaling (k = k_ref * s_ref/s):\n');
console.log('     vol      k(s)      pole sits at inv/target      drain stops at q (W=50bps)');
for (const vol of [0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0]) {
  const k = 1.0 * SREF / vol;
  const W = 50 / 1e4, s2 = vol * vol;
  // k*q/(k-q) = W/(G*s2)  =>  q = r(k)/(k+r), r = W/(G*s2)
  const r = W / (GAMMA_DER * s2);
  const qRaw = k * r / (k + r);
  // q is a FRACTION of target and cannot exceed 1. qRaw > 1 means the charge never
  // reaches W anywhere on the reachable range => fully drainable at this willingness.
  const q = qRaw >= 1 ? 'FULLY DRAINABLE' : qRaw.toFixed(4) + '        ';
  console.log(`   ${(vol * 100).toFixed(0).padStart(4)}%    ${k.toFixed(3)}          ${(1 - Math.min(k, 1)).toFixed(3).padStart(5)}                    ${q}`);
}
console.log('\n   ⇒ under A-S 2.3 scaling the reserve TIGHTENS as vol rises -- which is when');
console.log('     restoration is most expensive. Today k is CONSTANT, so the reserve is');
console.log('     loosest exactly when the refill can least afford to be called.');
