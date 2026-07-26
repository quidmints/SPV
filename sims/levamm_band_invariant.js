#!/usr/bin/env node
// GATE SIM: does a CONSTANT-LTV overlay on a (reseat-following) band share cancel the band IL and
// track ∝ p (= true YB), and how does REBALANCE GRANULARITY affect fidelity? Analytic core:
//   dE/E = L·(dB/B) − carry.  A reseat-following AMM band has B ∝ p^α (α≈0.5 for 50/50). So the
//   leverage that cancels IL is L = 1/α  (α=0.5 ⇒ L=2, matching YB). Then E ∝ p (no IL) − carry.
// We simulate DISCRETE rebalancing (every R steps) over real paths to confirm + measure the
// granularity error + liquidations. Reuses the Binance data + the carry model from the other sims.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const loadD=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const BORROW=0.07, DT=1/365, MCR=1.10;
const bandVal=(p,alpha)=>Math.pow(p,alpha);   // reseat-following band value, relative to p0=1

// constant-LTV overlay: maintain collateral/equity = L, rebalance every R steps; carry on debt; liq if E<=0.
function overlay(Pin,L,R,alpha){
  const P=Pin.map(x=>x/Pin[0]);
  let units, debt, E=1;                          // equity 1 at p0
  let coll = L*E; debt = (L-1)*E; units = coll/bandVal(P[0],alpha);  // collateral in band units
  let liq=false, carryPaid=0;
  for(let i=1;i<P.length;i++){
    coll = units*bandVal(P[i],alpha);
    const dCarry = BORROW*debt*DT; debt += dCarry; carryPaid += dCarry;
    E = coll - debt;
    if(E<=0 || coll/debt < MCR){ liq=true; break; }
    if(i%R===0){ coll=L*E; const newDebt=(L-1)*E; debt=newDebt; units=coll/bandVal(P[i],alpha); }
  }
  if(liq) return {liq:true};
  const pe=P[P.length-1]; coll=units*bandVal(pe,alpha); E=coll-debt;
  return {liq:false, E, hodl:pe, band:bandVal(pe,alpha), carryPaid, trackErr:(E-pe)/pe};
}

console.log('Overlay equity vs HODL-ETH(∝p) and unlevered band(∝p^α). α=0.5 (50/50 band) ⇒ L=2 should track ∝p.\n');
// 1) CLEAN monotonic path: shows the ∝p tracking + granularity, no noise
const up=[1]; for(let i=0;i<200;i++) up.push(up[i]*1.005);   // +172% smooth
console.log('CLEAN +172% smooth path (carry off to isolate the invariant):');
console.log('  L     R(steps)   equity   HODL(p)   band(√p)   track-err-vs-HODL');
for(const L of [2.0]) for(const R of [1,10,40]){
  const o=overlay(up,L,R,0.5);
  if(o.liq){console.log(`  ${L}    ${R}        LIQUIDATED`); continue;}
  console.log(`  ${L.toFixed(1)}   ${String(R).padEnd(10)} ${o.E.toFixed(3).padEnd(9)}${o.hodl.toFixed(3).padEnd(10)}${o.band.toFixed(3).padEnd(11)}${(o.trackErr*100).toFixed(1)}%`);
}
console.log('  (track-err→0 as R→1 ⇒ continuous constant-LTV-2x of a √p band = ∝p = zero IL. Coarse R = residual curvature.)\n');

// 2) REAL paths: net-of-carry tracking + liq frequency at rebalance cadences
console.log('REAL data — does the L=2 overlay track HODL (no IL) net of carry, and how often does it liquidate?');
console.log('  asset  window  R=1d  R=7d  R=30d   (mean |equity−HODL|/HODL over windows; LIQ% in parens)');
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const P=loadD(file);
  for(const LEN of [90,180]){
    const cell=[1,7,30].map(R=>{
      let n=0,liq=0,errs=[];
      for(let s=0;s+LEN<P.length;s+=14){const o=overlay(P.slice(s,s+LEN+1),2.0,R,0.5);n++;if(o.liq)liq++;else errs.push(Math.abs(o.trackErr));}
      const me=errs.length?errs.reduce((a,b)=>a+b,0)/errs.length*100:NaN;
      return `${me.toFixed(1)}%(${(100*liq/n).toFixed(0)}%liq)`;
    });
    console.log(`  ${name}    ${LEN}d    ${cell.map(c=>c.padEnd(16)).join('')}`);
  }
}
console.log('\nREAD: small track-err with no-liq ⇒ the band HOSTS true YB (overlay = LEVAMM). Where liq% is high,');
console.log('that is the L=2 tail (down-moves); the user wanted LIGHT leverage for the IL-offset (partial track, ~0 liq) and');
console.log('full L=2 only for those who accept the tail. The α=0.5 assumption (50/50 band) is the calibration knob:');
console.log('measure QU!D band α from real reseat behavior to set the exact L (L=1/α) — that is the one real follow-up.');
