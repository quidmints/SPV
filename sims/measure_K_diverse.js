#!/usr/bin/env node
// SCENARIO-DIVERSITY check on K (the user's critique): measure K = LVR_rate/sigma^2 across ALL 5
// real 5m regimes, guard-ON and OFF — instead of the single COVID window + the doc's fixed 0.71.
// If K varies wildly by regime, then ANY fixed K (0.71 or otherwise) baked into the theta-derived
// sims is suspect, and theta should be set from a LIVE/measured K, not a constant.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const R=0.02, STEP=300, YEAR=365*86400, PERIODS_YR=YEAR/STEP;
function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(C,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return C/(eth*p+usd);}
function sig2(px){let r=[];for(let i=1;i<px.length;i++)r.push(Math.log(px[i]/px[i-1]));const m=r.reduce((a,b)=>a+b,0)/r.length;return r.reduce((a,b)=>a+(b-m)**2,0)/(r.length-1)*PERIODS_YR;}
function poolSeries(spot,guard){
  if(!guard) return spot.slice();
  const out=[spot[0]], win=6;
  for(let i=1;i<spot.length;i++){let a=Math.max(0,i-win+1),tw=0,n=0;for(let j=a;j<=i;j++){tw+=spot[j];n++;}tw/=n;const prev=out[i-1],cap=prev*0.005;out.push(prev+Math.max(-cap,Math.min(cap,tw-prev)));}
  return out;
}
function lvr(spot,pool){
  let pa=pool[0]/(1+R),pb=pool[0]*(1+R),L=Lfor(1,pool[0],pa,pb);
  for(let i=1;i<pool.length;i++){if(pool[i]<pa||pool[i]>pb){const a=amts(Math.max(pa,Math.min(pool[i],pb)),pa,pb,L);const val=a.eth*pool[i]+a.usd;pa=pool[i]/(1+R);pb=pool[i]*(1+R);L=Lfor(val,pool[i],pa,pb);}}
  const pf=spot[spot.length-1],a=amts(Math.max(pa,Math.min(pool[pool.length-1],pb)),pa,pb,L),bundle=a.eth*pf+a.usd;
  const L0=Lfor(1,pool[0],pool[0]/(1+R),pool[0]*(1+R)),a0=amts(pool[0],pool[0]/(1+R),pool[0]*(1+R),L0);
  const hodl=a0.eth*pf+a0.usd;
  return Math.max(0,hodl-bundle);
}
console.log('K = LVR_rate/sigma^2 across 5 real 5m regimes (doc says ~0.71 guard-ON). Watch the SPREAD.\n');
console.log('  regime        sigma   K(guard OFF)   K(guard ON)');
const Ks=[];
for(const [name,file] of [['COVID','eth_5m_covid.json'],['bull21','eth_5m_bull21.json'],['chop23','eth_5m_chop23.json'],['2025','eth_5m_2025.json'],['bear22','eth_5m_bear22.json']]){
  const spot=JSON.parse(fs.readFileSync(SP+file)).map(x=>x.c);
  const T=(spot.length*STEP)/YEAR, s2=sig2(spot);
  const kOff=lvr(spot,poolSeries(spot,false))/T/s2, kOn=lvr(spot,poolSeries(spot,true))/T/s2;
  Ks.push(kOn);
  console.log(`  ${name.padEnd(13)}${(Math.sqrt(s2)*100).toFixed(0)+'%'}`.padEnd(22)+`${kOff.toFixed(2)}`.padEnd(15)+`${kOn.toFixed(2)}`);
}
const mn=Math.min(...Ks),mx=Math.max(...Ks),avg=Ks.reduce((a,b)=>a+b,0)/Ks.length;
console.log(`\nguard-ON K spread: ${mn.toFixed(2)} .. ${mx.toFixed(2)} (mean ${avg.toFixed(2)}) vs the doc's FIXED 0.71.`);
console.log(`=> K varies ${(mx/mn).toFixed(1)}x across regimes. A fixed K=0.71 mis-sizes theta in every regime`);
console.log(`   except where it happens to match. theta=yield/(K*sigma^2): too-low K => theta too BIG => the`);
console.log(`   LP over-exposed (more IL, more fees) than the sim assumed. So sims pinning K=0.71 are biased`);
console.log(`   toward a specific (and likely wrong) slice size. FIX: live K (measured per window) or sweep K.`);
