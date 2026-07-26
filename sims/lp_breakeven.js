#!/usr/bin/env node
// Is there a VIABLE in-range LP at all? LP net/yr (frac of capital) =
//   yield*(1-theta) + fee_rate*turnover*theta - K*sigma^2*theta   (linear in theta)
// => LPing (theta>0) BEATS just-hold-and-yield IFF  fee_rate*turnover > K*sigma^2 + yield.
// K=0.71 is the doc's GUARD-ON LVR coeff (2.24 guard-off). turnover = annual in-range volume / TVL.
const K=0.71, GUARD_OFF=2.24;
const fees=[0.0005,0.0015,0.0030];     // 5 / 15 / 30 bps (QU!D composite fee, capped 30bps)
const vols=[0.40,0.60,0.88];           // ETH realized vol regimes
const Y=0.05;                          // 5% venue yield
console.log('BREAK-EVEN turnover (annual volume / TVL) needed for in-range LPing to BEAT hold+yield.');
console.log('Lower = easier. Daily-volume=TVL is ~365x/yr (a very busy pool). QU!D internal flow is likely << that.\n');
console.log('fee     vol    K=0.71(guard-on)   K=2.24(guard-off)   LVR rate (K=.71)');
for(const f of fees) for(const s of vols){
  const need = (K*s*s + Y)/f;
  const needOff = (GUARD_OFF*s*s + Y)/f;
  console.log(`${(f*1e4).toString().padStart(2)}bps  ${(s*100)}%   ${('>'+need.toFixed(0)+'x').padEnd(18)} ${('>'+needOff.toFixed(0)+'x').padEnd(19)} ${(K*s*s*100).toFixed(1)}%/yr`);
}
console.log('\nFlip side: at a GIVEN turnover, the best LP net/yr vs just hold+yield (5%):');
console.log('turnover  fee=30bps,vol=60%   net   (LVR=25.6%/yr)');
for(const T of [10,50,100,200,365,1000]){
  const f=0.0030, s=0.60;
  const inRangeEdge = f*T - K*s*s;            // per unit theta
  const best = Math.max(Y, Y + 1*(f*T - K*s*s - Y)); // theta=1 if inRangeEdge>Y else theta=0(=Y)
  const useTheta = (f*T - K*s*s) > Y;
  console.log(`${(T+'x').padEnd(9)} in-range edge/yr ${((f*T-K*s*s)*100).toFixed(1)}%   LP best ${ (best*100).toFixed(1)}%  -> ${useTheta?'LP in-range (theta=1)':'JUST HOLD+YIELD (theta=0)'}`);
}
console.log('\nVERDICT: an in-range LP is viable ONLY above the break-even turnover. Below it the rational LP sets theta=0');
console.log('(holds ETH + earns yield, provides NO liquidity). So QU!D liquidity depth hinges entirely on REAL turnover.');
