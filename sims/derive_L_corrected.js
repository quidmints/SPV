#!/usr/bin/env node
// REMEDIATION of the overfit in derive_L.js. The keystone scored net_edge = trackErr + FEE*turnover*L
// ONLY — no venue yield (load-bearing, scales with L), raw 7% carry (not self-funded). That single
// misspecified objective drove the "R1 wins by a wide margin / ~300x turnover" verdict.
//
// FAITHFUL model (real 180d windows, constant-LTV range overlay = the validated host):
//   net_edge(L) vs HODL = trackErr(L) [equity/HODL, net of borrow drag in the overlay]
//                        + VENUE_YIELD * L * t        <-- the OMITTED term (L*ETH in the venue)
//                        + FEE * turnover * L * t      <-- fees (also scale with L)
//   carry lives inside trackErr (debt grows at BORROW); we sweep BORROW to model self-funded (SP / re-set
//   Liquity rate) vs raw. NO single verdict — report the SURFACE across (venue, carry, turnover) + the
//   YB(L=2)-R1(L=1) edge, so the answer is a sensitivity map, not one fragile number.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const loadD=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const DT=1/365, MCR=1.10, FEE=0.0005, ALPHA=0.5;
const rangeVal=p=>Math.pow(p,ALPHA);
function overlay(Pin,L,R,BORROW){
  const P=Pin.map(x=>x/Pin[0]);
  let coll=L, debt=L-1, units=coll/rangeVal(P[0]);
  for(let i=1;i<P.length;i++){
    coll=units*rangeVal(P[i]); debt+=BORROW*debt*DT;
    if(coll-debt<=0||coll/debt<MCR) return null;            // liquidated
    if(i%R===0){const E=coll-debt; coll=L*E; debt=(L-1)*E; units=coll/rangeVal(P[i]);}
  }
  const pe=P[P.length-1]; return {trackErr:(units*rangeVal(pe)-debt-pe)/pe, t:(P.length-1)/365};
}
function sigAnn(P){const r=[];for(let i=1;i<P.length;i++)r.push(Math.log(P[i]/P[i-1]));const m=r.reduce((a,b)=>a+b,0)/r.length;return Math.sqrt(r.reduce((a,b)=>a+(b-m)**2,0)/r.length/DT);}

for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const P=loadD(file);
  // realized vol + analytic IL hurdle (sigma^2/8 on the range's sqrt(p))
  let sig=0,ns=0,wins=[];
  for(let s=0;s+180<P.length;s+=14){const w=P.slice(s,s+181);sig+=sigAnn(w);ns++;wins.push(w);}
  sig/=ns; const hurdle=sig*sig/8;
  console.log(`\n=== ${name}  (${wins.length} real 180d windows, 2017-2026; mean sigma=${(sig*100)|0}%, IL_hurdle~sigma^2/8=${(hurdle*100).toFixed(1)}%/yr) ===`);
  console.log('  carry  venue  TO     L*    net@L1(R1)  net@L2(YB)   YB-R1   analytic(venue+fees-carry-hurdle)');
  const Ls=[];for(let L=1.0;L<=2.01;L+=0.1)Ls.push(+L.toFixed(1));
  for(const BORROW of [0.07,0.03]){           // raw Liquity-ish  vs  self-funded (SP / re-set rate)
   for(const VENUE of [0.03,0.05,0.08]){
    for(const TO of [20,50]){
      const mean={};Ls.forEach(L=>mean[L]=[]);
      for(const w of wins){for(const L of Ls){const o=overlay(w,L,7,BORROW);if(o)mean[L].push(o.trackErr+VENUE*L*o.t+FEE*TO*L*o.t);}}
      const avg=L=>mean[L].length?mean[L].reduce((a,b)=>a+b,0)/mean[L].length:-1;
      let bestL=1,bestV=-1e9;for(const L of Ls){const v=avg(L);if(v>bestV){bestV=v;bestL=L;}}
      const n1=avg(1.0),n2=avg(2.0);
      // analytic YB-R1: extra unit gets venue+fees-carry, minus the extra IL hurdle it must cancel
      const analytic=(VENUE+FEE*TO-BORROW)-hurdle;
      console.log(`  ${(BORROW*100).toFixed(0).padEnd(6)} ${(((VENUE*100)|0)+'%').padEnd(6)} ${(TO+'x').padEnd(6)} ${bestL.toFixed(1).padEnd(5)} `
        +`${(n1*100).toFixed(1).padEnd(11)} ${(n2*100).toFixed(1).padEnd(11)} ${((n2-n1)*100>=0?'+':'')+((n2-n1)*100).toFixed(1).padEnd(7)} ${(analytic*100>=0?'+':'')+(analytic*100).toFixed(1)}%`);
    }
   }
  }
}
console.log('\nREAD: L* and the YB-R1 column show WHERE leverage wins. Compare empirical YB-R1 to the analytic');
console.log('(venue+fees-carry-hurdle) column — if they track, the model is consistent. No single verdict:');
console.log('the answer is the surface. Self-funded carry (3%) + higher venue (8%) is where YB leaves R1.');
