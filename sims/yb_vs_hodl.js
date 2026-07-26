#!/usr/bin/env node
// CORRECTED benchmark: a QU!D ETH LP is ALREADY an ETH holder → their alternative is HODL-ETH, not the
// unlevered LP. YB-LP at constant leverage k tracks value ∝ p^(k/2). At k=2 it tracks ETH EXACTLY:
//   YB-LP(k=2) value = HODL-ETH + fees − carry,  PATH-INDEPENDENT (no IL, no directional residual).
// So it is NOT a directional gamble — it is a pure fees-vs-carry deal. Viability gate = turnover.
const FEE=0.0005, BORROW=0.07;
console.log('YB-LP(k=2) vs HODL-ETH = fees − carry, PATH-INDEPENDENT (tracks ETH exactly, zero IL).');
console.log('Break-even: fee*turnover = carry  =>  turnover = carry/fee.\n');
console.log('  borrow(carry)   fee(bps)   break-even annual turnover');
for(const c of [0.03,0.05,0.07,0.10]) console.log(`  ${(c*100).toFixed(0)}%${' '.repeat(13)}${(FEE*1e4).toFixed(0)}${' '.repeat(9)}${(c/FEE).toFixed(0)}x`);
console.log('\nLIGHT k (<2): smaller carry ((k-1)*borrow) but a RESIDUAL IL remains (p − p^(k/2) > 0), which is');
console.log('itself IMPERMANENT (recovers on reversal; realized only on a mid-divergence exit). So light k is a');
console.log('PARTIAL hedge: less carry, less IL-elimination — it does NOT escape the turnover wall, it slides along it.');
console.log('\nVERDICT: YB-LP is NOT directional (I was wrong to call it so vs the unlevered LP — wrong benchmark).');
console.log('It is "ETH exposure + fees − carry", viable iff fees>carry iff turnover>~140x @ (5bps, 7%). The make-or-');
console.log('break for QU!D is therefore EMPIRICAL: does the vogue band turn over ~140x/yr? High-turnover => build it;');
console.log('low-turnover => carry eats the fees and an ETH holder is better off just holding (or unlevered R1).');
