#!/usr/bin/env node
// DEFINITIVE LevAMM P&L, fitted to QU!D (theta-slice in the vogue range + (1-theta) ETH retention).
// LevAMM power law: a constant-leverage-k LP position tracks value ∝ p^(k/2). k=1 -> p^0.5 (AMM, full
// IL); k=2 -> p^1 (tracks ETH, ZERO IL). We lever ONLY the in-range slice (the part with IL). Compare,
// per real window, the LEVERED-vs-UNLEVERED(R1) edge, net of carry on the borrowed (k-1) portion.
//   Levered edge - R1 edge  =  theta*(p^(k/2) - p^0.5) - carry
//   p^(k/2) - p^0.5 > 0 in a RALLY (p>1), < 0 in a CRASH (p<1). So leverage WINS up-paths, LOSES
//   down-paths, minus carry ALWAYS. Question: is it a free IL fix, or just a directional bet + deadweight?
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const load=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const K=0.71,YIELD=0.05,BORROW=0.07,DT=1/365;
function sigAnn(P){const r=[];for(let i=1;i<P.length;i++)r.push(Math.log(P[i]/P[i-1]));const m=r.reduce((a,b)=>a+b,0)/r.length;return Math.sqrt(r.reduce((a,b)=>a+(b-m)**2,0)/r.length/DT);}

function deltas(P,k){
  const sig=sigAnn(P), theta=Math.min(1,sig>0?YIELD/(K*sig*sig):1);
  const p=P[P.length-1]/P[0];                      // price multiple over the window
  const t=(P.length-1)/365;
  const carry=(k-1)*theta*BORROW*t;                // carry on the borrowed slice portion
  // levered slice minus unlevered slice (ETH-numeraire, both vs the same range):
  const offset=theta*(Math.pow(p,k/2)-Math.pow(p,0.5));
  return { delta:(offset-carry)*100, up:p>=1, p, theta, carryPct:carry*100 };
}
function stat(a){a=[...a].sort((x,y)=>x-y);return{mean:a.reduce((s,v)=>s+v,0)/a.length,p5:a[Math.floor(a.length*0.05)],p95:a[Math.floor(a.length*0.95)]};}
const f=x=>(x>=0?'+':'')+x.toFixed(2)+'%';
console.log('LEVERED-vs-R1 edge (theta*(p^(k/2)-p^0.5) - carry), per real window. >0 = leverage helps that LP.\n');
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const P=load(file);
  console.log(`=== ${name} ===`);
  console.log('  k     mean    up-window mean   down-window mean   p5(bad)   p95(good)');
  for(const k of [1.3,1.5,2.0]){
    const all=[],ups=[],downs=[];
    for(const LEN of [90,180]) for(let s=0;s+LEN<P.length;s+=7){
      const d=deltas(P.slice(s,s+LEN+1),k); all.push(d.delta); (d.up?ups:downs).push(d.delta);
    }
    const A=stat(all);
    console.log(`  ${k.toFixed(1)}   ${f(A.mean).padEnd(8)}${f(stat(ups).mean).padEnd(17)}${f(stat(downs).mean).padEnd(18)}${f(A.p5).padEnd(10)}${f(A.p95)}`);
  }
}
console.log('\nREAD: if up-window mean >0 and down-window mean <0 with |both| >> carry, leverage is a DIRECTIONAL BET');
console.log('(wins when ETH rises, loses when it falls), NOT a free IL fix. The overall mean reflects the sample\'s');
console.log('net drift (crypto trended UP historically -> positive mean = a paid-off long bet, NOT proof of IL-elimination).');
console.log('A direction-NEUTRAL LP should weight up/down equally: then mean -> ~ -carry (deadweight). Verdict below.');
