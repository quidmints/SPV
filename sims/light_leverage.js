#!/usr/bin/env node
// Re-opening the SELF-CONTAINED make-whole (non-toxic: LP funds its own offset). The 2x reference
// designs (YB/amp/euler) immunize a volatile LP fully; QU!D's IL is SMALL, so a LIGHT offset may
// suffice — and light leverage is far from any liquidation. Liquidation needs price < MCR*(L-1)/L:
//   L=2.0 -> -45% | L=1.5 -> -63% | L=1.3 -> -75% | L=1.2 -> -82%.
// Measure how often each LEVERAGE level would have liquidated across real history (the danger), so we
// can see whether a LIGHT self-contained offset is effectively liquidation-safe in QU!D's regime.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const load=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const DT=1/365, BORROW=0.07, MCR=1.10;
function liquidates(P,R,LEV){
  let unitsETH=LEV, debt=(LEV-1)*P[0];                 // equity=P0, LEV*ETH collateral, (LEV-1) debt
  for(let i=1;i<P.length;i++){
    const coll=unitsETH*P[i]; debt+=BORROW*debt*DT;
    if(debt>0 && coll/debt < MCR) return true;
    if(i%R===0){ const eq=coll-debt; if(eq<=0) return true; unitsETH=(LEV*eq)/P[i]; debt=(LEV-1)*eq; }
  }
  return false;
}
console.log('Self-contained leverage liquidation frequency by LEVERAGE level (rebalance 30d, MCR 110%, carry 7%):\n');
console.log('asset  window   2.0x      1.5x      1.3x      1.2x');
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const P=load(file);
  for(const LEN of [90,180]){
    const row=[2.0,1.5,1.3,1.2].map(LEV=>{
      let n=0,L=0; for(let s=0;s+LEN<P.length;s+=7){n++; if(liquidates(P.slice(s,s+LEN+1),30,LEV))L++;}
      return (100*L/n).toFixed(0)+'%';
    });
    console.log(`${name}    ${LEN}d     `+row.map(x=>x.padEnd(10)).join(''));
  }
}
console.log('\nREAD: if 1.2-1.3x liquidates in ~0% of history, a LIGHT self-contained offset is effectively');
console.log('liquidation-safe even with a HARD-liq venue (no soft-liq needed) — non-toxic AND no cliff.');
console.log('OPEN: the P&L/IL-offset EFFECTIVENESS of light leverage depends on the mechanism (YB LevAMM');
console.log('curvature cancels IL; naive L*exposure just adds directional risk). That needs its own model — do NOT');
console.log('claim the offset works yet; this only settles that the LIQUIDATION objection does not apply to light leverage.');
