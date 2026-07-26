#!/usr/bin/env node
// CORRECT model of QU!D's make-whole gap — FLOW-driven, not price-path-driven (the virtual repack
// realizes NOTHING; only REAL ETH outflow via user swaps creates a gap).
//
//   The theta-slice's ETH is bought OUT by users at some price P_out (they pay USD in -> pool holds
//   theta*P_out dollars). The LP later withdraws wanting their ETH back at P_end. The pool's USD buys
//   only theta*P_out/P_end ETH -> SHORT by:  gap_eth = theta * max(0, 1 - P_out/P_end).
//   That gap = the realized IL = exactly "the ETH the pool sold that we must buy back" (the user's words).
//   make-whole USEFUL iff gap is MATERIAL (LP would feel R1) AND amortizable (gap/yield < ~2-3 yr).
//
// theta = derived from the window's realized vol (low vol -> HIGH theta -> bigger slice exposed).
// P_out = window MIN (upper-bound flow: assume the slice was swapped out near the local low — the
// worst, most make-whole-relevant case). We scan real ETH/BTC history for where this bites.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const load=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>({t:d.time.slice(0,10),p:+d.PriceUSD})).filter(d=>isFinite(d.p)&&d.p>0);
const K=0.71,YIELD=0.05,DT=1/365;
function winVol(P){const r=[];for(let i=1;i<P.length;i++)r.push(Math.log(P[i]/P[i-1]));const m=r.reduce((x,y)=>x+y,0)/r.length;return Math.sqrt(r.reduce((x,y)=>x+(y-m)**2,0)/r.length/DT);}

function eval_(P){
  const sig=winVol(P), theta=Math.min(1, sig>0?YIELD/(K*sig*sig):1);
  const Pout=Math.min(...P), Pend=P[P.length-1], P0=P[0];
  const rise=Pend/Pout-1;                                  // rally from the outflow low to exit
  const gap=theta*Math.max(0,1-Pout/Pend)*100;            // ETH shortfall % (make-whole cost)
  const amortYrs=(gap/100)/YIELD;
  return {sig,theta,rise:rise*100,netStartEnd:(Pend/P0-1)*100,gap,amortYrs};
}
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const D=load(file), P=D.map(x=>x.p), T=D.map(x=>x.t);
  console.log(`\n===================== ${name} =====================`);
  for(const LEN of [90,180]){
    const rows=[];
    for(let s=0;s+LEN<P.length;s+=7){const r=eval_(P.slice(s,s+LEN+1));r.start=T[s];r.end=T[s+LEN];rows.push(r);}
    // the DEFINITIVE useful set: gap material (>3%) AND amortizable (<2.5 yr of yield)
    const useful=rows.filter(r=>r.gap>3 && r.amortYrs<2.5).sort((a,b)=>b.gap-a.gap);
    const big=rows.filter(r=>r.gap>3 && r.amortYrs>=2.5);  // material but NOT amortizable (bull — can't help)
    console.log(`\n  ${LEN}d: ${rows.length} windows | make-whole USEFUL (gap 3%..${(2.5*YIELD*100).toFixed(0)}%, amortizable<2.5yr): ${useful.length} | material-but-too-big (>${(2.5*YIELD*100).toFixed(0)}%): ${big.length}`);
    console.log('  TOP useful windows (definitive situations where borrow-the-gap earns its keep):');
    console.log('  start..end             gap%   amortYrs  theta  sig  rise%(low->exit)  net%(start->exit)');
    for(const r of useful.slice(0,7)) console.log('  '+`${r.start}..${r.end}`.padEnd(23)+r.gap.toFixed(1).padEnd(7)+r.amortYrs.toFixed(2).padEnd(10)+r.theta.toFixed(2).padEnd(7)+(r.sig*100).toFixed(0).padEnd(5)+r.rise.toFixed(0).padEnd(17)+r.netStartEnd.toFixed(0));
  }
}
console.log('\nREAD: useful = a MILD-to-moderate rally in a LOW-VOL regime (high theta) — the slice that was');
console.log('swapped out cheap is now expensive to buy back, but the gap is small enough that yield amortizes it.');
console.log('Big violent rallies show up in "too-big" (gap>12.5%): material but UN-amortizable -> make-whole cannot help there.');
