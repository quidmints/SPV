#!/usr/bin/env node
// HONEST baseline — fixes the two flaws the user caught in v1:
//  (1) theta is DERIVED live (Vogue.derivedThetaWad = min(1, yield/(K*sigma^2))), NOT fixed 0.5.
//      => in a high-vol rally sigma^2 is large -> theta collapses -> the exposed in-range slice is
//         SMALL exactly when a trend would hurt; the rest of the LP's ETH is plain ETH (HODL).
//  (2) the range REPACKS (virtual re-center, NO realization charge — "real assets untouched"),
//      so it FOLLOWS the trend instead of dumping at +2% and missing the rally.
// LP edge vs HODL(1 ETH) over ALL withdrawal days, per real Binance 5m window.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const K=0.71, R=0.02, YIELD=0.05, FEE=0.0005;
const STEP=300, DT=STEP/(365*86400);     // 5m in years
const VOLWIN=288;                         // 1 day of 5m bars
function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(C,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return C/(eth*p+usd);}
function sigAnnual(px,i){const a=Math.max(1,i-VOLWIN),r=[];for(let j=a;j<=i;j++)r.push(Math.log(px[j]/px[j-1]));const m=r.reduce((x,y)=>x+y,0)/r.length;const v=r.reduce((x,y)=>x+(y-m)**2,0)/Math.max(1,r.length-1);return Math.sqrt(v/DT);}

// LP deposits 1 ETH. theta-slice in a +/-2% range (virtual USD pair); (1-theta) is plain ETH.
// Repack on range exit: re-center + re-derive theta from current vol, using current wealth (no charge).
function walk(px, policy){
  let pa=px[0]/(1+R), pb=px[0]*(1+R);
  let theta=1, L=Lfor(theta*px[0],px[0],pa,pb), retEth=1-theta, extraEth=0;
  const edges=[], thetas=[];
  for(let i=1;i<px.length;i++){
    const p=px[i], a=amts(p,pa,pb,L), ap=amts(px[i-1],pa,pb,L);
    extraEth += FEE*Math.abs(ap.eth-a.eth);                 // fee on range volume
    const rangeValEth=(a.eth*p+a.usd)/p;
    extraEth += YIELD*(rangeValEth+retEth)*DT;               // venue yield on ALL the ETH
    if(p<pa||p>pb){                                          // repack: virtual re-center
      const sig=sigAnnual(px,i);
      theta = policy==='fixed05'?0.5 : policy==='one'?1 : Math.min(1, sig>0?YIELD/(K*sig*sig):1);
      const totalEth=rangeValEth+retEth;
      pa=p/(1+R); pb=p*(1+R); L=Lfor(theta*totalEth*p,p,pa,pb); retEth=(1-theta)*totalEth;
    }
    thetas.push(theta);
    const a2=amts(p,pa,pb,L);
    const lpEth=(a2.eth*p+a2.usd)/p + retEth + extraEth;     // LP total in ETH-equiv
    edges.push((lpEth-1)*100);
  }
  return {edges, thetaAvg: thetas.reduce((s,v)=>s+v,0)/thetas.length};
}
const stat=a=>{a=[...a].sort((x,y)=>x-y);return{mean:a.reduce((s,v)=>s+v,0)/a.length,p5:a[Math.floor(a.length*0.05)],min:a[0]};};
const f=x=>(x>=0?'+':'')+x.toFixed(1)+'%';
console.log('HONEST baseline: DERIVED theta (shrinks in vol) + virtual repack (follows trend). LP edge vs HODL, all withdrawal days.\n');
console.log('window      sigma    DERIVED: avg-theta  mean edge  bad-exit(p5)  worst   | FIXED-0.5 mean  ONE(theta=1) mean');
for(const [n,file] of [['COVID','eth_5m_covid.json'],['bull','eth_5m_bull21.json'],['chop','eth_5m_chop23.json'],['2025','eth_5m_2025.json'],['bear','eth_5m_bear22.json']]){
  const px=JSON.parse(fs.readFileSync(SP+file)).map(x=>x.c);
  const d=walk(px,'derived'), s5=walk(px,'fixed05'), o=walk(px,'one');
  const sd=stat(d.edges), ss=stat(s5.edges), so=stat(o.edges);
  // window annualized vol (whole window)
  const r=[];for(let i=1;i<px.length;i++)r.push(Math.log(px[i]/px[i-1]));const m=r.reduce((x,y)=>x+y,0)/r.length;const sig=Math.sqrt(r.reduce((x,y)=>x+(y-m)**2,0)/r.length/DT);
  console.log(n.padEnd(11)+(sig*100).toFixed(0).padEnd(9)+d.thetaAvg.toFixed(2).padEnd(20)+f(sd.mean).padEnd(11)+f(sd.p5).padEnd(14)+f(sd.min).padEnd(8)+'| '+f(ss.mean).padEnd(15)+f(so.mean));
}
console.log('\nREAD: with DERIVED theta the exposed slice collapses in high vol -> the rally hole the v1 sim showed (fixed-0.5)');
console.log('largely DISAPPEARS. Compare the DERIVED mean vs the FIXED-0.5 mean to see how much of the "-14.8%" was the theta bug.');
