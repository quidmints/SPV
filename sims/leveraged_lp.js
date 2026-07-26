#!/usr/bin/env node
// Does leverage rescue the LP's IL without endangering the protocol? NO — quantifies the danger.
// Self-contained 2x LP (YB-style) RELOCATES IL -> borrow carry + LIQUIDATION tail. Per QU!D's design
// a leveraged unwind/liquidation routes into the shared pool (the pool is the counterparty / shock
// absorber), so every liquidation detonates into shared backing. We measure how OFTEN that happens
// across real history, under two maintenance cadences. Conclusion: leverage on the protocol's books
// is unsafe at any cadence; the LP bears its own IL (R1) — forced by conservation + full backing
// (D>=S+L: there are no "free dollars" to make-whole; surplus is the shared safety margin, not a reserve).
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const load=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const DT=1/365, BORROW=0.07, MCR=1.10;   // 7% BOLD carry, 110% min collateral ratio
// 2x Trove over a window, rebalanced every R days; liquidates if coll/debt < MCR at any step.
function liquidates(P,R){
  let unitsETH=2, debt=P[0];                       // equity=P0 (1 ETH), 2 ETH collateral, 1 ETH debt
  for(let i=1;i<P.length;i++){
    const coll=unitsETH*P[i]; debt+=BORROW*debt*DT;
    if(coll/debt < MCR) return true;                // margin call -> forced unwind into the pool
    if(i%R===0){ const eq=coll-debt; if(eq<=0) return true; unitsETH=(2*eq)/P[i]; debt=eq; }
  }
  return false;
}
console.log('2x leveraged-LP liquidation frequency across real history (each liq = a forced unwind into shared backing):\n');
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const P=load(file);
  for(const LEN of [90,180]) for(const R of [7,30]){
    let n=0,L=0; for(let s=0;s+LEN<P.length;s+=7){n++; if(liquidates(P.slice(s,s+LEN+1),R))L++;}
    console.log(`  ${name} ${LEN}d window, rebalance every ${R}d: liquidated ${L}/${n} = ${(100*L/n).toFixed(0)}% of windows`);
  }
}
console.log('\nREAD: no cadence makes it safe (tighter R only trades liq-frequency for rebalance cost). Since a fully-backed');
console.log('stablecoin has no free dollars to absorb the unwind, protocol-level leverage is disqualified. Leverage, if an LP');
console.log('wants it, belongs ENTIRELY on the LP\'s OWN external book (their liquidation hits them, never the pool).');
