# QU!D SPA

Browser frontend for the SPV/evm contracts. Next.js 14 + ethers v6 + TailwindCSS.

## What it does

Five tabs that drive the merged-port contract surface in `../evm/src/`:

| Tab | Contract → call |
|---|---|
| **Mint** | `Basket.mint(pledge, amount, token, when)` after ERC20 approve to `Aux` (USDT reset-to-0 handled). `when = currentMonth + 1 + months`. |
| **ETH LP** | `Vogue.deposit(assets, receiver)` payable / `Vogue.withdraw(assets, receiver, owner)`. Reads `autoManaged(user)`. *(Stub — wiring next.)* |
| **Swap** | `Aux.swap(token, asset, forVolatile, amount, minOut)` — USD↔ETH and USD→BTC. The on-chain `asset` for the BTC direction is **lnBTC** (the V4 BTC pool's volatile leg, conceptually distinct from BitGo WBTC which is the Aux-internal SOR fallback inventory; same address pre-split). BTC→USD intentionally not supported (BTC inflows route through channel state changes). |
| **Redeem** | `Aux.redeem(amount)`; shows `Aux.redeemableAmount()` so the slider clamps client-side. |
| **BTC Channel** | `BTCChannels.openChannel(OpenParams, rawFundingTx, merkleProof)` — LP submits direct from this wallet (no stealth, no meta-tx). *(Stub — needs `bitcoinjs-lib` + mempool.space client.)* |

## Explicitly dropped vs `old/`

- **No Solana / Phantom / SPL.** No `@solana/web3.js`, `@coral-xyz/anchor`, `bs58`, `mongodb`.
- **No prediction market, stocks tab, evidence tab.** `Link.sol` exists on-chain for depeg detection but is not user-facing here.
- **No Uniswap V3 / Rover.** V4-only via Vogue.
- **No `leverETH` / `leverUSD` wait-path.** Removed from swap UI; the contract entrypoints exist but the SPA only does instant swaps.
- **No stealth address / EIP-5564 derivation.** msg.sender = LP everywhere.
- **No meta-tx / hosted relayer / `lpAuth` / `redeemBySig` / `setBtcRecipientWithSig`.** The contract surface for those wasn't merged in (see `MEMORY.md` → `project-quid-frontend-meta-tx-gap`); SPA submits everything direct from the user's wallet.

## Setup

```bash
cd SPV/spa
npm install   # or pnpm / yarn
npm run dev   # http://localhost:3000
```

The wallet auto-prompts to switch to Ethereum mainnet (`chainId 1`).
Fill in real addresses in `src/lib/chains.ts:CONTRACTS` after deploying
`SPV/evm/scripts/DeployL1_s.sol`.

## Stables list

11 entries, **BOLD last** (Liquity SP special-case at `stables[length-1]`):

```
USDC, USDT, PYUSD, GHO, RLUSD, USDG, DAI, USDS, USDE, AUSD, BOLD
```

DeployL1_s.sol currently puts AUSD last — that has to flip in the deploy
script to match the runtime expectation (see project memory).

## Status

- Scaffold + Mint + Redeem: **functional**.
- ETH LP, Swap, BTC Channel: **stubbed** with the exact calls they'll drive.

Build out order is whatever the next message says.
