#!/usr/bin/env node
// The financing venue sets the CARRY, and carry sets the YB-LP break-even turnover.
// Liquity Trove: collateral is IDLE -> carry = gross borrow rate.
// Lending market (Aave/Morpho/Euler): collateral SUPPLIED earns supply APY while backing the borrow
//   -> NET carry = borrow - supplyYield. Lower carry => lower break-even => YB-LP viable at less turnover.
const FEE=0.0005;
const rows=[
  ['Liquity Trove (idle collateral)', 0.070, 0.00],
  ['Aave/Morpho (ETH supply ~2%)',    0.055, 0.02],
  ['Euler / staked-ETH coll (~3.5%)', 0.055, 0.035],
  ['LST collateral (~4%) cheap borrow',0.045, 0.04],
];
console.log('YB-LP break-even turnover by FINANCING venue. carry = borrow - supplyYield; break-even = carry/FEE (5bps).\n');
console.log('  venue                                borrow   supplyYield   NET carry   break-even turnover');
for(const [name,b,s] of rows){
  const net=b-s;
  console.log('  '+name.padEnd(36)+(b*100).toFixed(1).padEnd(9)+(s*100).toFixed(1).padEnd(14)+(net*100).toFixed(1).padEnd(12)+(net/FEE).toFixed(0)+'x');
}
console.log('\nREAD: idle-collateral Liquity needs ~140x turnover; productive-collateral lending markets need ~90x');
console.log('-> ~30x (LST coll + cheap borrow). The financing venue can roughly HALVE the turnover the IL-offset');
console.log('needs to clear. So: lending markets >> Liquity for the YB-LP. Liquity stays as ONE opt-in venue (its');
console.log('redemption/BOLD mechanics suit some directional-zap users) but is the capital-INEFFICIENT choice.');
console.log('All venues share ~one interface: supply/borrow/repay/withdraw + health-factor (Liquity = open/adjust/');
console.log('close Trove, adapted to the same shape) -> one adapter set, LP-opt-in, reusing QU!D multi-venue pattern.');
