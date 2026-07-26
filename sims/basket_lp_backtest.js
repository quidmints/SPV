#!/usr/bin/env node
// REAL-DATA backtest of QU!D's ETH-LP IL — ALL-ENCOMPASSING definition:
//   IL = HODL_value - LP_bundle_value, the full COMPOSITION DIVERGENCE (the pool sells the
//   LP's ETH as price rises / accumulates it as it falls, so the LP holds a worse bundle than
//   just holding ETH). REALIZED at WITHDRAWAL — so we report the distribution over ALL
//   withdrawal days, because timing is the whole point (withdraw at a diverged moment -> eat it).
//
// OUR system: LP deposits ETH; basket supplies VIRTUAL USD (no debt) to pair theta*E in a +/-2%
// band; (1-theta)*E sits in RETENTION (holds ETH = HODL, NO IL). Band repacks on +/-2% exit
// (manip-guarded in prod; daily cap here). theta = min(1, yield/(K*sigma^2)) [our formula].
// LP is whole-in-ETH: the band's divergence is borne by BACKING (R2) or the LP (R1).
// Bundle value tracked CONTINUOUSLY (no per-step loss summation — that was the v1/v2 bug).

const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const load=(f,from)=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>({t:d.time.slice(0,10),p:+d.PriceUSD})).filter(d=>d.t>=from&&isFinite(d.p)&&d.p>0);
const ETH=load('eth.json','2019-01-01'), BTC=load('btc.json','2019-01-01');
const K=0.71,R=0.02,FEE=0.0005,DT=1/365,VOLWIN=20;

function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(C,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return C/(eth*p+usd);}
function rvol(P,i){const a=Math.max(1,i-VOLWIN),r=[];for(let j=a;j<=i;j++)r.push(Math.log(P[j]/P[j-1]));const m=r.reduce((x,y)=>x+y,0)/r.length;return Math.sqrt(r.reduce((x,y)=>x+(y-m)**2,0)/Math.max(1,r.length-1)/DT);}

// Walk the path; return per-day LP edge vs HODL (%) AND the cumulative backing-IL (R2).
function walk(P, pol, yld){
  let pa=P[0]/(1+R), pb=P[0]*(1+R);
  let theta=1, L=Lfor(theta*P[0], P[0], pa, pb);   // band capital = theta*1ETH worth (USD) at p0
  let retEth=(1-theta);                             // retention in ETH
  let extraEth=0;                                   // accumulated fees+yield in ETH (R1 also -= IL realized)
  let backIL_usd=0;
  const edges=[];
  for(let i=1;i<P.length;i++){
    const p=P[i], pp=P[i-1];
    const a=amts(p,pa,pb,L);                        // band composition at new price (clamped inside)
    const aPrev=amts(pp,pa,pb,L);
    // fee on ETH traded through the band this step
    extraEth += FEE*Math.abs(aPrev.eth-a.eth);
    // yield on whole backing (band value + retention), in ETH
    const bandVal=a.eth*p+a.usd;
    extraEth += yld*((bandVal/p)+retEth)*DT;
    // repack on band exit: realize + re-center + re-size theta
    if(p<pa||p>pb){
      const sig=rvol(P,i);
      theta = pol==='one'?1: pol==='doc'?0.26: Math.min(1, sig>0?yld/(K*sig*sig):1);
      const totalEth = bandVal/p + retEth;          // total wealth in ETH after the band's move
      pa=p/(1+R); pb=p*(1+R);
      L=Lfor(theta*totalEth*p, p, pa, pb);
      retEth=(1-theta)*totalEth;
    }
    // record LP edge vs HODL at THIS day (a possible withdrawal): bundle - HODL, in ETH terms
    const a2=amts(p,pa,pb,L);
    const lpEth = (a2.eth*p+a2.usd)/p + retEth + extraEth;  // LP total in ETH-equiv (R2: whole + extras)
    edges.push((lpEth-1)*100);                       // % vs HODL of 1 ETH
    // R2 backing IL accrues the divergence the band can't return as ETH (tracked for the R2 column)
    backIL_usd += Math.max(0, (aPrev.eth - a.eth>0? (aPrev.eth-a.eth)*0 : 0)); // (see note) kept 0; R2 cost is the bundle gap below
  }
  return edges;
}

function windows(d,len,step){const o=[];for(let s=0;s+len<d.length;s+=step)o.push(d.slice(s,s+len).map(x=>x.p));return o;}
function stat(a){a=[...a].sort((x,y)=>x-y);return{mean:a.reduce((x,y)=>x+y,0)/a.length,p5:a[Math.floor(a.length*0.05)],p50:a[Math.floor(a.length*0.5)],min:a[0],max:a[a.length-1]};}
const f=x=>(x>=0?'+':'')+x.toFixed(1)+'%';

// ---- SELF-TESTS (must pass or every number is suspect) ----
(function(){
  const flat=Array(366).fill(2000); const eFlat=walk(flat,'one',0.05); const sFlat=stat(eFlat);
  // round trip up 50% and back: concentrated+repack realizes some loss, but a HODLer is flat -> LP should be modestly NEGATIVE, not catastrophic
  const rt=[2000]; for(let i=0;i<60;i++) rt.push(rt[i]*1.01); for(let i=0;i<60;i++) rt.push(rt[rt.length-1]*0.99);
  const eRt=stat(walk(rt,'one',0.05));
  // pure +100% smooth trend over a year: HODLer doubles; a +/-2% LP sells ETH early -> big underperformance vs HODL
  const tr=[2000]; for(let i=0;i<365;i++) tr.push(tr[i]*Math.pow(2,1/365));
  const eTr=stat(walk(tr,'one',0.05));
  console.log(`SELF-TESTS: flat final≈${eFlat[eFlat.length-1].toFixed(3)}% (exp ~0, yield+ )  roundtrip final ${eRt.min.toFixed(1)}..${eRt.max.toFixed(1)}%  smooth+100% trend final ${stat(walk(tr,'one',0.05)).min.toFixed(1)}%`);
})();

for(const [name,data] of [['ETH',ETH],['BTC',BTC]]){
  const wins=windows(data,365,30);
  console.log(`\n===== ${name} (${data[0].t}..${data[data.length-1].t}, ${wins.length} rolling 1y windows) =====`);
  console.log('IL = HODL - LP bundle, realized at withdrawal. Edge vs HODL over ALL withdrawal days in each window.');
  console.log('policy           mean edge   p5 edge(bad exit) worst-day   avg theta');
  for(const pol of ['one','doc','derived']){
    // for each window, the LP edge distribution over withdrawal days; take the window-mean and the bad-exit tail
    const means=[],p5s=[],mins=[]; let th=0,nw=0;
    for(const w of wins){ const e=walk(w,pol,0.05); const s=stat(e); means.push(s.mean); p5s.push(s.p5); mins.push(s.min);
      // avg theta proxy via final recompute omitted; approximate by policy
    }
    const lab=pol==='one'?'θ=1 (deployed)':pol==='doc'?'θ=0.26':'derived';
    console.log(lab.padEnd(17)+f(stat(means).mean).padEnd(12)+f(stat(p5s).mean).padEnd(18)+f(stat(mins).min).padEnd(12));
  }
}
console.log('\nREAD: "worst-day" = if the LP is forced to withdraw at the worst moment in the window (your point). Compare θ=1 vs derived: does sizing θ meaningfully cut the bad-exit tail, or is even derived still deep negative (=> the ±2% band itself / R1 is the problem and R2/backing-absorb or a wider band is needed)?');
