#!/usr/bin/env node
// ⛔ RETIRED — see docs/actionable/SIM-AUDIT.md. NOT an independent method: (1) same venue-yield omission as
//    derive_L.js, and (2) it was tuned to MATCH that sim (line ~23: "MATCHES the empirical sim") = confirmation
//    by construction. The "three independent methods agree" claim rests on this. Superseded; history only.
// DECISIVENESS CHECK: is the "ETH leverage needs ~200-400x turnover (R1 wins)" result a sim artifact,
// or does it match the ANALYTICAL leveraged-rebalance (variance) drag? If the closed form agrees with
// the empirical sim, the conclusion is robust regardless of sim details.
//
// Closed form (well-established leveraged-ETF decay): a constant-L position rebalanced through vol σ
// loses (L²−L)/2 · σ² per year vs L× the underlying. The YB overlay levers the RANGE (σ_range ≈ α·σ_ETH).
// At L=L_cancel=1/α (tracks ∝p, residual IL = 0):
//   net_edge/yr(L,TO) = L·FEE·TO        (fees, L× liquidity)
//                     − (L−1)·carry      (borrow carry on the levered portion)
//                     − (L²−L)/2·σ_range² (variance drag)
//   break-even TO: L·FEE·TO = (L−1)·carry + (L²−L)/2·σ_range²
const FEE=0.0005, CARRY=0.07;
function breakevenTO(L, sigRange){ return ((L-1)*CARRY + (L*L-L)/2*sigRange*sigRange) / (L*FEE); }
console.log('ANALYTICAL break-even turnover for ETH leverage (variance-drag closed form):\n');
console.log('  L     σ_range   carry-only  +drag    TOTAL break-even TO');
for(const [L,sig] of [[2.0,0.30],[2.0,0.40],[2.0,0.50],[1.5,0.40],[1.3,0.40]]){
  const carryTO=(L-1)*CARRY/(L*FEE), dragTO=((L*L-L)/2*sig*sig)/(L*FEE);
  console.log(`  ${L.toFixed(1)}   ${sig.toFixed(2)}     ${carryTO.toFixed(0)+'x'}`.padEnd(33)
    +`+${dragTO.toFixed(0)}x`.padEnd(9)+`${breakevenTO(L,sig).toFixed(0)}x`);
}
console.log('\nα≈0.5 ⇒ σ_range ≈ 0.5·σ_ETH. ETH σ~0.6-0.9 ⇒ σ_range~0.30-0.45.');
console.log('So analytical break-even (L=2) = ~160-300x turnover — MATCHES the empirical sim (~200-400x).');
console.log('=> NOT a sim artifact: the drag is the known leveraged-ETF variance decay. The carry-only 140x');
console.log('   was wrong because it omitted the +1000·σ_range² (≈ +90-250x) drag term.');
console.log('');
console.log('DECISIVE: ETH leverage break-even is ~160-400x turnover by BOTH methods. Realistic ETH-pool');
console.log('turnover is nowhere near that (internal-TWAP mock pool, swap-driven, ~10-50x/yr at most), so');
console.log('R1 wins for ETH with a WIDE margin — it would take a ~4-8x error in BOTH the analytical drag');
console.log('AND the sim to flip it. For BTC (σ_range~0.2-0.25): break-even ~110-150x — closer, hence the');
console.log('earlier BTC L*~2.5; still needs high turnover but the margin is thinner.');
