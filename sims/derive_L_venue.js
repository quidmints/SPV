#!/usr/bin/env node
// ⚠️ SUPERSEDED by derive_L_corrected.js — DO NOT TRUST THIS SIM'S NUMBERS. It uses mu=0 GBM, which
//    inverts the IL sign (a sqrt(p) LP looks GOOD when price falls, and zero-drift paths fall in median)
//    — so it prints L*=1 for the WRONG reason. Kept only as the diagnostic that located the real bug in
//    derive_L.js (no venue-yield term). The trustworthy version is derive_L_corrected.js (REAL 2017-2026
//    data + venue yield + self-funded carry + sensitivity surface): ETH→R1 across the surface, BTC→YB once
//    venue>=5%/self-funded. Analytic: YB-R1 ≈ (venue+fees-carry) - sigma^2/8 (ETH≈9.6%, BTC≈5.4% measured).
// CORRECTION to derive_L.js: the keystone OMITTED venue yield — the QU!D LP's load-bearing income.
// derive_L's net_edge = trackErr + FEE·turnover·L  (trading fees only, no venue yield, 7% carry charged raw).
// But the YB-QU!D position holds L× ETH IN THE VENUE, so it earns L× venue yield; and the borrow is
// (re-settable / SP-funded) so the carry is offset, not a raw 7% drag. Add those two terms and re-sweep L*.
//
//   net_edge(L) = trackErr(L) [tracks p, net of borrow+rebalance drag] + FEE·TO·L·t + VENUE·L·t
//
// Real historical series unavailable this session (scratchpad cleared) -> synthetic GBM at ETH/BTC vol.
// The point is STRUCTURAL (the venue term is purely additive and scales with L), so it does not hinge on
// the exact path. VENUE=0 reproduces derive_L (R1). Then sweep VENUE to show where L* leaves 1.
const DT=1/365, MCR=1.10, FEE=0.0005, ALPHA=0.5;
const bandVal=p=>Math.pow(p,ALPHA);
// deterministic LCG so the run is reproducible (no Math.random)
let _s=123456789; const rnd=()=>{_s=(1103515245*_s+12345)&0x7fffffff; return _s/0x7fffffff;};
const gauss=()=>{let u=0,v=0;while(u===0)u=rnd();while(v===0)v=rnd();return Math.sqrt(-2*Math.log(u))*Math.cos(2*Math.PI*v);};
function gbmPath(n,sig,mu){const P=[1];for(let i=1;i<n;i++)P.push(P[i-1]*Math.exp((mu-0.5*sig*sig)*DT+sig*Math.sqrt(DT)*gauss()));return P;}

function overlay(P,L,R,BORROW){               // equity over a normalized path at leverage L
  let coll=L, debt=L-1, units=coll/bandVal(P[0]);
  for(let i=1;i<P.length;i++){
    coll=units*bandVal(P[i]); debt+=BORROW*debt*DT;
    if(coll-debt<=0||coll/debt<MCR) return null;            // liquidated
    if(i%R===0){const E=coll-debt; coll=L*E; debt=(L-1)*E; units=coll/bandVal(P[i]);}
  }
  const pe=P[P.length-1]; const E=units*bandVal(pe)-debt;
  return {trackErr:(E-pe)/pe, t:(P.length-1)/365};
}

console.log('L* (argmax net edge vs HODL) — derive_L CORRECTED for venue yield.  L_cancel=1/alpha=2.0');
console.log('BORROW=7% raw carry kept (conservative; self-funded would help leverage MORE).\n');
for(const [name,sig,mu] of [['ETH',0.88,0.0],['BTC',0.55,0.0]]){
  console.log(`=== ${name}  (sigma=${(sig*100)|0}%, 200 synthetic 180d GBM paths) ===`);
  const paths=Array.from({length:200},()=>gbmPath(181,sig,mu));
  console.log('  venueYield   TO    L*=argmax   net@L*    net@L=2   net@L=1(R1)');
  for(const VENUE of [0.00,0.03,0.05,0.08]){
    for(const TO of [20,50]){
      const Ls=[];for(let L=1.0;L<=2.6;L+=0.1)Ls.push(+L.toFixed(1));
      const mean={};Ls.forEach(L=>mean[L]=[]);
      for(const P of paths) for(const L of Ls){const o=overlay(P,L,7,0.07); if(o) mean[L].push(o.trackErr+FEE*TO*L*o.t+VENUE*L*o.t);}
      const avg=L=>mean[L].length?mean[L].reduce((a,b)=>a+b,0)/mean[L].length:-1;
      let bestL=1,bestV=-1e9;for(const L of Ls){const v=avg(L);if(v>bestV){bestV=v;bestL=L;}}
      console.log(`  ${String((VENUE*100).toFixed(0)+'%').padEnd(13)}${String(TO+'x').padEnd(6)}${bestL.toFixed(1).padEnd(12)}`
        +`${(avg(bestL)*100).toFixed(1).padEnd(10)}${(avg(2.0)*100).toFixed(1).padEnd(9)}${(avg(1.0)*100).toFixed(1)}`);
    }
  }
  console.log('');
}
console.log('READ: VENUE=0 -> L*=1 (reproduces derive_L, R1). As venue yield rises, L* leaves 1 and heads to ~2,');
console.log('because the venue yield SCALES WITH L (L× ETH in the venue) and dwarfs the rebalance drag. The');
console.log('original "300x turnover needed" was an artifact of crediting only trading fees, not venue yield.');
