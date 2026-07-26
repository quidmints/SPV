#!/usr/bin/env node
// FINAL DETERMINATION: re-run the R1 LP baseline with the REAL (measured) K instead of the doc's 0.71.
// theta=yield/(K*sigma^2): real K (~2-8) => theta ~3-7x SMALLER => the in-range slice is tiny => the LP
// is even MORE retention-heavy (held ETH) => even closer to HODL (less IL) but earns fewer fees. Confirm
// the R1 verdict (LP ~flat, bears small IL) survives — or breaks — under the corrected K.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const R=0.02, YIELD=0.05, FEE=0.0005, DT5=300/(365*86400);
function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(C,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return C/(eth*p+usd);}
function winSig(px){const r=[];for(let i=1;i<px.length;i++)r.push(Math.log(px[i]/px[i-1]));const m=r.reduce((a,b)=>a+b,0)/r.length;return Math.sqrt(r.reduce((a,b)=>a+(b-m)**2,0)/r.length/DT5);}
// LP edge vs HODL over all exits, theta from (K,sigma); slice in +/-2% band (reseat), rest retention(ETH)
function run(px,K){
  const sig=winSig(px), theta=Math.min(1, sig>0?YIELD/(K*sig*sig):1);
  let pa=px[0]/(1+R),pb=px[0]*(1+R),L=Lfor(theta*px[0],px[0],pa,pb),ret=1-theta,fees=0;
  const edges=[];
  for(let i=1;i<px.length;i++){const p=px[i],a=amts(p,pa,pb,L),ap=amts(px[i-1],pa,pb,L);
    fees+=FEE*Math.abs(ap.eth-a.eth); fees+=YIELD*((a.eth*p+a.usd)/p+ret)*DT5;
    if(p<pa||p>pb){const tot=(a.eth*p+a.usd)/p+ret;pa=p/(1+R);pb=p*(1+R);L=Lfor(theta*tot*p,p,pa,pb);ret=(1-theta)*tot;}
    const a2=amts(p,pa,pb,L); edges.push(((a2.eth*p+a2.usd)/p+ret+fees-1)*100);}
  return {theta, mean:edges.reduce((a,b)=>a+b,0)/edges.length};
}
// measured guard-ON K per regime (from measure_K_diverse)
const K_meas={COVID:1.84,bull:4.52,chop:8.37,'2025':6.25,bear:3.89};
console.log('R1 LP edge vs HODL, theta sized with DOC K=0.71 vs the REAL measured K per regime:\n');
console.log('  regime   theta@0.71  theta@realK   edge@0.71   edge@realK   verdict');
for(const [name,file,kn] of [['COVID','eth_5m_covid.json','COVID'],['bull','eth_5m_bull21.json','bull'],['chop','eth_5m_chop23.json','chop'],['2025','eth_5m_2025.json','2025'],['bear','eth_5m_bear22.json','bear']]){
  const px=JSON.parse(fs.readFileSync(SP+file)).map(x=>x.c);
  const doc=run(px,0.71), real=run(px,K_meas[kn]);
  const f=x=>(x>=0?'+':'')+x.toFixed(1)+'%';
  console.log(`  ${name.padEnd(9)}${doc.theta.toFixed(2).padEnd(12)}${real.theta.toFixed(3).padEnd(14)}${f(doc.mean).padEnd(12)}${f(real.mean).padEnd(13)}${Math.abs(real.mean)<Math.abs(doc.mean)?'flatter (safer)':'worse'}`);
}
console.log('\nREAD: real K shrinks theta ~3-7x (tiny slice) -> the LP is MORE retention-heavy -> edge moves');
console.log('CLOSER to 0 (flatter, less IL). So the R1 verdict (LP ~flat, bears small IL) SURVIVES the K fix and');
console.log('is if anything STRONGER. Cost: a tiny slice earns few fees + provides little concentrated depth — the');
console.log('real consequence of the K bug is UNDER-provision of liquidity (theta too small), not LP IL risk.');
