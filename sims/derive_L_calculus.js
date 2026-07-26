#!/usr/bin/env node
// ⚠️ FORMULA SOUND, RUN RETIRED — see docs/actionable/SIM-AUDIT.md. L* = ½+(r_pool−r_borrow)/σ_c² is correct
//    (the optimization the paper left open). But this run feeds r_pool = FEE·TO (fees ONLY) — the venue-yield
//    omission. Fed r_pool = fees+venue, the turnover-dependence evaporates and "L*>1 only above ~300x" is false.
//    Keep the formula; do NOT cite the table. Superseded by derive_L_corrected.js.
// CALCULUS-derived continuous L* (not a regime threshold), grounded in Egorov YB.pdf.
//
// FROM THE PAPER (Eq 6,10,11): δV*/V* = L·δV_c/V_c  ⇒  V* ∝ V_c^L. Cryptoswap liquidity V_c ∝ √p,
//   so V* ∝ p^(L/2). At L=2 ⇒ V* ∝ p (IL eliminated). [WHY L=2: it's the L that makes the exponent 1.]
// FROM THE PAPER (Eq 12, generalized): a position holds L× its equity in liquidity (V_c = L·V*, Eq 1)
//   so earns L·r_pool; debt d = V*(L−1) (Eq 7) so pays (L−1)·r_borrow; releverage loss r_loss(L).
//   APR(L) = L·r_pool − (L−1)·r_borrow − r_loss(L).
// r_loss(L) = the constant-leverage VARIANCE drag = ½·L·(L−1)·σ_c²  (σ_c = LP-token/collateral vol).
//   [This is exactly the paper's "releverage losses"; the paper measures it ≈2·r_pool(xy=k) at L=2,
//    i.e. ½·2·1·σ_c² = σ_c² ≈ 2·r_pool — a calibration of σ_c, not a new assumption.]
//
// MAXIMISE:  d/dL [ L·r_pool − (L−1)·r_borrow − ½L(L−1)σ_c² ] = r_pool − r_borrow − ½(2L−1)σ_c² = 0
//   ⇒  L* = ½ + (r_pool − r_borrow)/σ_c²      ← the continuous optimal leverage (analog of θ=yield/Kσ²)
// Clamp to [1, 2]: L<1 is "hold extra USD" (= R1 for an asset-holder); L>2 over-shoots past ∝p.
const FEE=0.0005, RB=0.07;
function Lstar(rpool, sigC){ const raw=0.5 + (rpool-RB)/(sigC*sigC); return Math.max(1, Math.min(2, raw)); }
console.log('Continuous L* = clamp(1,2, ½ + (r_pool − r_borrow)/σ_c²).  σ_c ≈ 0.5·σ_asset (LP-token vol).\n');
for(const [name,sigA] of [['ETH',0.80],['ETH(calm)',0.50],['BTC',0.55],['BTC(calm)',0.40]]){
  const sigC=0.5*sigA;
  console.log(`${name} (σ_asset ${(sigA*100).toFixed(0)}%, σ_c ${(sigC*100).toFixed(0)}%):`);
  console.log('  turnover   r_pool   raw L*    clamped L*');
  for(const TO of [20,50,100,200,400,800]){
    const rp=FEE*TO; const raw=0.5+(rp-RB)/(sigC*sigC);
    console.log(`  ${String(TO+'x').padEnd(11)}${(rp*100).toFixed(0)+'%'}`.padEnd(20)+`${raw.toFixed(2)}`.padEnd(10)+`${Lstar(rp,sigC).toFixed(2)}`);
  }
  // turnover where L* crosses 1 (leverage starts) and 2 (full YB):
  const toL1=(1-0.5)*sigC*sigC/FEE + RB/FEE, toL2=(2-0.5)*sigC*sigC/FEE + RB/FEE;
  console.log(`  → L*>1 (leverage worth it) above ${toL1.toFixed(0)}x;  L*=2 (full YB) above ${toL2.toFixed(0)}x turnover.\n`);
}
console.log('READ: L* is CONTINUOUS in (r_pool, σ_c) — not a threshold. For ETH (high σ_c) L* sits at the lower');
console.log('clamp (=1, R1) until ~300x turnover — matching the empirical sim (200-400x) AND the variance-drag');
console.log('triangulation (160-320x). THREE methods now agree, and the formula is the one the paper itself');
console.log('LEFT OPEN ("borrow rate / L should be optimized ... future work"). For BTC the crossover is lower.');
console.log('SAME shape as θ*=yield/(K·σ²): both are exposure-sizers = clamp(rate-excess / variance). Both were');
console.log('mis-FIXED (K=0.71 for θ; L=2 / L*-threshold for leverage) — fix BOTH with live σ² + measured loss-coeff.');
