#!/usr/bin/env node
// Measure α: the exponent in band-value ∝ p^α for QU!D's ±2% RESEAT-following concentrated band
// (arbed within the band per the correction — so it realizes the concentrated IL). Then L=1/α is the
// leverage that cancels the IL. α=0.5 = 50/50 full-range; a concentrated reseat band may differ.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const loadD=f=>JSON.parse(fs.readFileSync(SP+f)).data.map(d=>+d.PriceUSD).filter(p=>isFinite(p)&&p>0);
const R=0.02;  // ±2% band
function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(V,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return V/(eth*p+usd);}

// reseat-following band: value trajectory over a normalized path (p0=1, value0=1)
function bandValue(Pin){
  const P=Pin.map(x=>x/Pin[0]);
  let pa=1/(1+R), pb=1*(1+R), L=Lfor(1,1,pa,pb), val=1;
  const vals=[1];
  for(let i=1;i<P.length;i++){
    const a=amts(P[i],pa,pb,L); val=a.eth*P[i]+a.usd;
    if(P[i]<pa||P[i]>pb){ pa=P[i]/(1+R); pb=P[i]*(1+R); L=Lfor(val,P[i],pa,pb); } // reseat, preserve value
    vals.push(val);
  }
  return {P, vals};
}
// fit α = mean of  d log(val) / d log(p)  over steps where price moved
function fitAlpha(P,vals){
  let num=0,den=0;
  for(let i=1;i<P.length;i++){
    const dlp=Math.log(P[i]/P[i-1]); if(Math.abs(dlp)<1e-9) continue;
    const dlv=Math.log(vals[i]/vals[i-1]);
    num+=dlv*dlp; den+=dlp*dlp;     // regression slope through origin
  }
  return den>0? num/den : NaN;
}

// 1) clean monotonic: the cleanest α read
const up=[1]; for(let i=0;i<400;i++) up.push(up[i]*1.005);
{ const {P,vals}=bandValue(up); const a=fitAlpha(P,vals);
  console.log(`CLEAN +smooth path:  α = ${a.toFixed(3)}   ⇒  L=1/α = ${(1/a).toFixed(2)}   (final band value ${vals[vals.length-1].toFixed(3)} vs HODL ${P[P.length-1].toFixed(2)})`); }

// 2) real data: α distribution over rolling windows
console.log('\nReal-data α (regression d log V / d log p over rolling windows):');
console.log('  asset  90d-α   180d-α   ⇒ L=1/α (90d)');
for(const [name,file] of [['ETH','eth.json'],['BTC','btc.json']]){
  const Pf=loadD(file);
  const out=[90,180].map(LEN=>{
    const as=[]; for(let s=0;s+LEN<Pf.length;s+=14){const {P,vals}=bandValue(Pf.slice(s,s+LEN+1));const a=fitAlpha(P,vals);if(isFinite(a))as.push(a);}
    as.sort((x,y)=>x-y); return as[Math.floor(as.length/2)]; // median
  });
  console.log(`  ${name}    ${out[0].toFixed(3)}   ${out[1].toFixed(3)}    ${(1/out[0]).toFixed(2)}`);
}
console.log('\nREAD: if α≈0.5, L≈2 (YB default holds for QU!D). If the concentrated reseat band gives α≠0.5,');
console.log('the IL-cancelling leverage is L=1/α — set the product L from THIS, not the 50/50 assumption.');
console.log('(Light-leverage IL-offset uses L<1/α deliberately = partial offset, less drag/liq.)');
