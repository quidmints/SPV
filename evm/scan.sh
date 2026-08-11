#!/usr/bin/env bash
# usage: RPC=<endpoint> bash scan.sh
RPC="${RPC:?set RPC}"
PM=0x000000000004444c5dc75cB358380D2e3dE08A90
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
USDT=0xdAC17F958D2ee523a2206206994597C13D831ec7
FLOOR=21688329
Z=0x0000000000000000000000000000000000000000000000000000000000000000
HEAD=$(cast block-number --rpc-url $RPC 2>/dev/null)
echo "chain=$(cast chain-id --rpc-url $RPC 2>/dev/null) head=$HEAD"

for NAME in STEAK SKY
do
  if [ "$NAME" = STEAK ]; then
    HOOK=0x00000078BD49D5279a99b5F4011a5C61eE8caaC0
    ID=0xf32349cbc41fec9d3194f2b4e9ee72ded0bfda412427be9cb8a4087f74bdb065
    SLOT=0x33d45d331c8969f95aa10e26be8f4e03dde8dc8dc754fc95e7d1dc227d50a7d8
  else
    HOOK=0x0000005bb4DF4109bF356a585C8b8Ea70FCbAaC0
    ID=0xda85f9c1506a345d198019886cbecff4b77f5e6c5460d107d0e27faa4e0d89e7
    SLOT=0x6baf321dbaa4d4e1648794195248860d1921979562948eded940956269804ed3
  fi

  echo ""
  echo "=============================== $NAME"
  echo "hook      $HOOK"
  echo "codesize  $(cast codesize $HOOK --rpc-url $RPC 2>/dev/null)"
  echo "codehash  $(cast keccak $(cast code $HOOK --rpc-url $RPC 2>/dev/null) 2>/dev/null)"

  echo "-- deployment"
  cast call $HOOK 'owner()(address)' --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'pendingOwner()(address)' --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'poolManager()(address)' --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'factory()(address)' --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'maxGas()(uint32)' --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'maxMinDepositBlocks()(uint64)' --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'supportsInterface(bytes4)(bool)' 0x01ffc9a7 --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'supportsInterface(bytes4)(bool)' 0x5658f49e --rpc-url $RPC 2>&1 | head -1

  echo "-- pool"
  echo "distribution:"
  cast call $HOOK 'getDistribution(bytes32)((int24,int24,uint16)[])' $ID --rpc-url $RPC 2>&1 | head -3
  cast call $HOOK 'livePools(bytes32)(bool)' $ID --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'externalDepositsEnabled(bytes32)(bool)' $ID --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'totalShares(bytes32)(uint256)' $ID --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'minDepositBlocks(bytes32)(uint64)' $ID --rpc-url $RPC 2>&1 | head -1
  cast call $HOOK 'decimalsOffset(bytes32)(uint8)' $ID --rpc-url $RPC 2>&1 | head -1

  echo "-- core state"
  S0=$(cast call $PM 'extsload(bytes32)(bytes32)' $SLOT --rpc-url $RPC 2>/dev/null)
  echo "slot0raw  $S0"
  python3 -c "
v=int('$S0',16)
s=v&((1<<160)-1)
t=(v>>160)&0xFFFFFF
t=t-(1<<24) if t>=(1<<23) else t
print('slot0dec  sqrt=%d tick=%d protoFee=%d lpFee=%d price=%.8f'%(s,t,(v>>184)&0xFFFFFF,(v>>208)&0xFFFFFF,(s/2**96)**2))"

  echo "-- hook inventory"
  cast call $USDC 'balanceOf(address)(uint256)' $HOOK --rpc-url $RPC 2>&1 | head -1
  cast call $USDT 'balanceOf(address)(uint256)' $HOOK --rpc-url $RPC 2>&1 | head -1
  cast call $PM 'balanceOf(address,uint256)(uint256)' $HOOK $(cast to-uint256 $USDC) --rpc-url $RPC 2>&1 | head -1
  cast call $PM 'balanceOf(address,uint256)(uint256)' $HOOK $(cast to-uint256 $USDT) --rpc-url $RPC 2>&1 | head -1

  echo "-- vaults"
  for TOK in $USDC $USDT
  do
    V=$(cast call $HOOK 'vaults(bytes32,address)(address)' $ID $TOK --rpc-url $RPC 2>/dev/null | head -1)
    echo "token $TOK vault $V"
    if [ -z "$V" ]; then continue; fi
    if [ "$V" = "0x0000000000000000000000000000000000000000" ]; then continue; fi
    cast call $V 'symbol()(string)' --rpc-url $RPC 2>&1 | head -1
    cast call $V 'asset()(address)' --rpc-url $RPC 2>&1 | head -1
    cast call $V 'totalAssets()(uint256)' --rpc-url $RPC 2>&1 | head -1
    SH=$(cast call $V 'balanceOf(address)(uint256)' $HOOK --rpc-url $RPC 2>/dev/null | head -1)
    echo "hookShares $SH"
    cast call $V 'convertToAssets(uint256)(uint256)' $SH --rpc-url $RPC 2>&1 | head -1
    cast call $V 'maxWithdraw(address)(uint256)' $HOOK --rpc-url $RPC 2>&1 | head -1
    cast call $TOK 'allowance(address,address)(uint256)' $HOOK $V --rpc-url $RPC 2>&1 | head -1
  done

  echo "-- birth"
  LO=$FLOOR
  HI=$HEAD
  BASE=$(cast call $PM 'extsload(bytes32)(bytes32)' $SLOT --block $LO --rpc-url $RPC 2>/dev/null)
  if [ "$BASE" = "$Z" ]; then
    while [ $((HI-LO)) -gt 1 ]
    do
      MID=$(((LO+HI)/2))
      CUR=$(cast call $PM 'extsload(bytes32)(bytes32)' $SLOT --block $MID --rpc-url $RPC 2>/dev/null)
      if [ "$CUR" = "$Z" ]; then LO=$MID; else HI=$MID; fi
    done
    echo "pool init block $HI"
  else
    echo "pool init block: no archive state at floor"
  fi
  LO=$FLOOR
  HI=$HEAD
  CS=$(cast codesize $HOOK --block $LO --rpc-url $RPC 2>/dev/null)
  if [ "$CS" = "0" ]; then
    while [ $((HI-LO)) -gt 1 ]
    do
      MID=$(((LO+HI)/2))
      CUR=$(cast codesize $HOOK --block $MID --rpc-url $RPC 2>/dev/null)
      if [ "$CUR" = "0" ]; then LO=$MID; else HI=$MID; fi
    done
    echo "hook deploy block $HI"
  else
    echo "hook deploy block: no archive state at floor"
  fi
done
