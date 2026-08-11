for T in 0x3c8e63bd8da42fd7f8e36a0c22326dc9e7f4b7ac 0x8baa997e61c5dc9caf2c87535550e0c4011c9051 0xcc5fa250cbfa64669235756db3a160e18fdf71e2
do
  echo "$T"
  cast call $T 'symbol()(string)' --rpc-url $RPC 2>&1 | head -1
  cast call $T 'name()(string)' --rpc-url $RPC 2>&1 | head -1
  cast call $T 'decimals()(uint8)' --rpc-url $RPC 2>&1 | head -1
  cast call $T 'totalSupply()(uint256)' --rpc-url $RPC 2>&1 | head -1
done
