#!/usr/bin/env bash
# Faucet the e2e test account on the local anvil mainnet-fork. Uses DETERMINISTIC
# storage overrides (anvil_setStorageAt on the ERC20 balance slots) — robust, no
# dependency on a whale's fork-block balance (the Binance-8 impersonation approach
# failed: "transfer amount exceeds balance" on this block). For the non-BTC SPA
# walkthrough (mint/redeem/swap/LP). cast index computes the mapping slot.
set -euo pipefail
R=http://127.0.0.1:8545
ME=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266          # anvil acct[0] = the SPA wallet
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48        # balances mapping @ slot 9
DAI=0x6B175474E89094C44Da98b954EedeAC495271d0F         # balances mapping @ slot 2

cast rpc anvil_setBalance "$ME" 0x21e19e0c9bab2400000 --rpc-url "$R" >/dev/null   # 10k ETH
cast rpc anvil_setStorageAt "$USDC" "$(cast index address "$ME" 9)" "$(cast to-uint256 1000000000000)" --rpc-url "$R" >/dev/null            # 1,000,000 USDC (6dec)
cast rpc anvil_setStorageAt "$DAI"  "$(cast index address "$ME" 2)" "$(cast to-uint256 1000000000000000000000000)" --rpc-url "$R" >/dev/null # 1,000,000 DAI (18dec)

echo "faucet -> $ME"
echo "  USDC: $(cast call "$USDC" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$R")"
echo "  DAI : $(cast call "$DAI"  'balanceOf(address)(uint256)' "$ME" --rpc-url "$R")"
echo "  ETH : $(cast balance "$ME" --rpc-url "$R")"
