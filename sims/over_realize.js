#!/usr/bin/env node
// Does our setup OVER-REALIZE impermanent loss? Same +/-2% range, two cadences:
//   REPACK-on-exit (current: re-center every 2% move -> LOCKS IN each step)
//   RIDE-through   (never re-center -> IL stays IMPERMANENT, recovers on reversal)
// on REAL 5m windows. If repack >> ride on choppy/round-trip windows, we're realizing noise.
const fs=require('fs');
const SP='/tmp/claude-1000/-home-rico-projects/1f505948-253b-4400-a784-a1f0f9b9e1e5/scratchpad/';
const R=0.02;
function amts(P,pa,pb,L){const sp=Math.sqrt(Math.max(pa,Math.min(P,pb))),spa=Math.sqrt(pa),spb=Math.sqrt(pb);return{eth:L*(1/sp-1/spb),usd:L*(sp-spa)};}
function Lfor(C,p,pa,pb){const{eth,usd}=amts(p,pa,pb,1);return C/(eth*p+usd);}
const init=p0=>{const pa=p0/(1+R),pb=p0*(1+R),L=Lfor(1,p0,pa,pb),a=amts(p0,pa,pb,L);return{pa,pb,L,eth0:a.eth,usd0:a.usd};};

function repackIL(px){ // re-center on every exit
  let {pa,pb,L,eth0,usd0}=init(px[0]);
  for(let i=1;i<px.length;i++){ if(px[i]<pa||px[i]>pb){
    const a=amts(Math.max(pa,Math.min(px[i],pb)),pa,pb,L); const v=a.eth*px[i]+a.usd;
    pa=px[i]/(1+R);pb=px[i]*(1+R);L=Lfor(v,px[i],pa,pb);} }
  const pf=px[px.length-1],a=amts(Math.max(pa,Math.min(pf,pb)),pa,pb,L);
  return (eth0*pf+usd0)-(a.eth*pf+a.usd);   // realized IL vs initial-comp HODL
}
function rideIL(px){ // never re-center
  const {pa,pb,L,eth0,usd0}=init(px[0]); const pf=px[px.length-1];
  const a=amts(Math.max(pa,Math.min(pf,pb)),pa,pb,L);
  return (eth0*pf+usd0)-(a.eth*pf+a.usd);   // impermanent IL at withdrawal only
}
const f=x=>(x>=0?'+':'')+(x*100).toFixed(1)+'%';
console.log('window         move    REPACK-IL(current)  RIDE-IL(no recenter)  over-realization=repack-ride');
for(const [n,file] of [['COVID -41%','eth_5m_covid.json'],['bull +65%','eth_5m_bull21.json'],['chop -8%','eth_5m_chop23.json'],['2025 -19%','eth_5m_2025.json'],['bear -49%','eth_5m_bear22.json']]){
  const px=JSON.parse(fs.readFileSync(SP+file)).map(x=>x.c);
  const rp=repackIL(px), rd=rideIL(px);
  console.log(n.padEnd(14)+f(px[px.length-1]/px[0]-1).padEnd(8)+f(rp).padEnd(20)+f(rd).padEnd(22)+f(rp-rd));
}
console.log('\nREAD: "over-realization" = loss we LOCK IN by re-centering that RIDE keeps recoverable.');
console.log('Positive across chop/round-trips => we realize noise. (Trends: repack can BEAT ride by following the move,');
console.log('so the answer is ADAPTIVE off-chain timing — re-center on confirmed trend, ride the chop — not a fixed cadence.)');
