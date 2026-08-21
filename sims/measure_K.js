#!/usr/bin/env node
// Measure K (LVR coefficient, LVR_rate = K*sigma^2) from REAL 5m data, modeling QU!D's guard
// (30-min TWAP pin + 50bps/swap cap). Validate vs the doc: K~2.24 guard-OFF, ~0.71 guard-ON.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const C=JSON.parse(fs.readFileSync(SP+'eth_5m_covid.json')); // [{t,c}]
const spot=C.map(x=>x.c);
const R=0.02, STEP=300, YEAR=365*86400, PERIODS_YR=YEAR/STEP;
function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(C,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return C/(eth*p+usd);}

function sigma2_annual(px){let r=[];for(let i=1;i<px.length;i++)r.push(Math.log(px[i]/px[i-1]));
  const m=r.reduce((a,b)=>a+b,0)/r.length; const v=r.reduce((a,b)=>a+(b-m)**2,0)/(r.length-1); return v*PERIODS_YR;}

// pool price series: 'spot' (guard off) or 30m-TWAP capped 50bps/step (guard on)
function poolSeries(guard){
  if(!guard) return spot.slice();
  const out=[spot[0]]; const win=6; // 30 min = 6 x 5m
  for(let i=1;i<spot.length;i++){
    const a=Math.max(0,i-win+1); let tw=0,n=0; for(let j=a;j<=i;j++){tw+=spot[j];n++;} tw/=n;
    const prev=out[i-1]; const cap=prev*0.005; // 50bps/step
    out.push(prev + Math.max(-cap, Math.min(cap, tw-prev)));
  }
  return out;
}
// LVR of a +/-2% range (theta=1) rebalancing at poolPx, valued at spot; repack on exit
function lvr(pool){
  let pa=pool[0]/(1+R), pb=pool[0]*(1+R), L=Lfor(1,pool[0],pa,pb);
  for(let i=1;i<pool.length;i++){
    if(pool[i]<pa||pool[i]>pb){ const a=amts(Math.max(pa,Math.min(pool[i],pb)),pa,pb,L);
      const val=a.eth*pool[i]+a.usd; pa=pool[i]/(1+R); pb=pool[i]*(1+R); L=Lfor(val,pool[i],pa,pb); }
  }
  const pf=spot[spot.length-1];
  const a=amts(Math.max(pa,Math.min(pool[pool.length-1],pb)),pa,pb,L);
  const bundle=a.eth*pf+a.usd;
  // HODL of the initial in-range composition (eth0,usd0 at pool[0]) valued at final SPOT
  const a0=amts(pool[0],pa,pb,L); // not exact after repacks, approximate initial via value=1
  const eth0=amts(pool[0],pool[0]/(1+R),pool[0]*(1+R),Lfor(1,pool[0],pool[0]/(1+R),pool[0]*(1+R))).eth;
  const usd0=amts(pool[0],pool[0]/(1+R),pool[0]*(1+R),Lfor(1,pool[0],pool[0]/(1+R),pool[0]*(1+R))).usd;
  const hodl=eth0*pf+usd0;
  return Math.max(0,(hodl-bundle)); // IL as fraction of 1-unit capital
}
const T=(spot.length*STEP)/YEAR; // period in years
const s2=sigma2_annual(spot);
for(const [name,guard] of [['guard OFF (track spot)',false],['guard ON (30m TWAP + 50bps cap)',true]]){
  const pool=poolSeries(guard);
  const il=lvr(pool);
  const lvrRate=il/T;          // annualized LVR rate
  const K=lvrRate/s2;
  console.log(`${name.padEnd(34)} IL=${(il*100).toFixed(2)}% over ${(T*365).toFixed(0)}d  sigma=${(Math.sqrt(s2)*100).toFixed(0)}%  LVR_rate=${(lvrRate*100).toFixed(0)}%/yr  => K=${K.toFixed(2)}`);
}
console.log('\nDoc says K~2.24 guard-OFF, ~0.71 guard-ON. If ours land near those, the model + K are validated on real 5m data.');
