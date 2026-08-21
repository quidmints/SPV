#!/usr/bin/env node
// ⛔ RETIRED — see docs/actionable/SIM-AUDIT.md. This credits income as trading FEES ONLY (no venue yield,
//    the load-bearing term that scales with L) and charges raw carry. That misspecification produced the
//    bogus "needs ~300x turnover / R1 wide margin" verdict. Superseded by derive_L_corrected.js. Kept for
//    history only — do NOT cite its numbers.
// KEYSTONE: the leverage L that maximizes a YB-LP's net edge vs HODL-ETH. L_cancel=1/α (≈2) zeroes IL
// but pays max drag+carry; L_optimal balances (IL-offset gained) vs (drag+carry paid − fees gained).
// net_edge(L) = trackErr(L) [equity/HODL−1, net of carry+drag from the overlay] + FEE·turnover·L·t.
// Sweep L × turnover over real paths; report argmax L; look for a closed form (analog of θ=yield/Kσ²).
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const loadD=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const BORROW=0.07, DT=1/365, MCR=1.10, FEE=0.0005, ALPHA=0.5;
const rangeVal=(p)=>Math.pow(p,ALPHA);
function overlay(Pin,L,R){                       // equity over a normalized path at leverage L
  const P=Pin.map(x=>x/Pin[0]);
  let coll=L, debt=L-1, units=coll/rangeVal(P[0]);
  for(let i=1;i<P.length;i++){
    coll=units*rangeVal(P[i]); debt+=BORROW*debt*DT;
    if(coll-debt<=0||coll/debt<MCR) return null;     // liquidated
    if(i%R===0){const E=coll-debt; coll=L*E; debt=(L-1)*E; units=coll/rangeVal(P[i]);}
  }
  const pe=P[P.length-1]; const E=units*rangeVal(pe)-debt;
  return {trackErr:(E-pe)/pe, t:(P.length-1)/365};
}
function sigAnn(P){const r=[];for(let i=1;i<P.length;i++)r.push(Math.log(P[i]/P[i-1]));const m=r.reduce((a,b)=>a+b,0)/r.length;return Math.sqrt(r.reduce((a,b)=>a+(b-m)**2,0)/r.length/DT);}

console.log('L_optimal (argmax net edge vs HODL) by TURNOVER and vol. L_cancel=1/α=2.0.\n');
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const P=loadD(file);
  console.log(`=== ${name} (180d windows) ===`);
  console.log('  turnover   L*=argmax   net@L*    net@L=2   net@L=1(R1)');
  for(const TO of [20,50,100,200,400]){
    // for each L, mean net edge over windows
    const Ls=[]; for(let L=1.0;L<=2.6;L+=0.1) Ls.push(+L.toFixed(1));
    const meanNet={}; Ls.forEach(L=>meanNet[L]=[]);
    let sig=0,ns=0;
    for(let s=0;s+180<P.length;s+=14){
      const w=P.slice(s,s+181); sig+=sigAnn(w); ns++;
      for(const L of Ls){ const o=overlay(w,L,7); if(o) meanNet[L].push(o.trackErr + FEE*TO*L*o.t); }
    }
    const avg=L=>meanNet[L].length?meanNet[L].reduce((a,b)=>a+b,0)/meanNet[L].length:-1;
    let bestL=1,bestV=-1e9; for(const L of Ls){const v=avg(L); if(v>bestV){bestV=v;bestL=L;}}
    console.log(`  ${String(TO+'x').padEnd(11)}${bestL.toFixed(1).padEnd(12)}${(avg(bestL)*100).toFixed(1).padEnd(10)}%`.replace(/%$/,'')
      +`${(avg(bestL)*100).toFixed(1)+'%'}`.padEnd(0)+`   ${(avg(2.0)*100).toFixed(1)}%    ${(avg(1.0)*100).toFixed(1)}%`);
  }
  console.log('');
}
console.log('READ: L* rises with turnover (more fees ⇒ worth more leverage). At low turnover L*→1 (R1 wins: drag>fees).');
console.log('If L* tracks fee·turnover / (drag·σ²)-ish, that is the derived-L closed form (analog of θ). Compare L* to L_cancel=2.');
