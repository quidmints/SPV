# One engine, two share tokens: the state inventory for the Core+Vogue fold

Owner-directed 2026-08-16. **Not implemented.** This is the measured state map for the fold, so the
next session moves state rather than re-deriving what to move.

## The shape (owner's words, restated)

> "vogue and core are merging into one so they can't have one erc20 inside of themselves, they talk
> to two of those which are the shares (internal balances) in band POOLED_BTC or POOLED_ETH"
> — and "the remaining totalSupply being outOfRange".

| contract | owns |
|---|---|
| **Engine** (Core + Vogue merged) | `POOLED_ETH` / `POOLED_BTC`, `POOLED_USD_*`, both observation rings, skew, settlement, band bounds |
| **vETH** (share token) | every per-LP ETH position, in-range AND out-of-range |
| **vBTC** (share token) | the same for the BTC band |

⚠️ **This inverts the earlier VEth fold, and both were right at the time.** Folding `VEth` INTO the
band manager was correct while the manager was PER-ASSET. Once one engine serves BOTH bands the share
face has to come back out — **one contract cannot have two `balanceOf`s.**

## Why the share face cannot inherit a stock ERC-20

`balanceOf(user)` returns `autoManaged[user].pooled` — **the balance IS the LP position**, and
`_transferShares` moves position state (fee bookmarks, lev slice), not a number. Inheriting
solmate/OZ would add a SECOND balance source to keep in sync with `pooled`: precisely the drift class
this refactor has been deleting. The share token keeps a hand-rolled balance and that is correct.
Only the allowance machinery is stock, and it is not worth a base class for that alone.

## `totalSupply` spans BOTH position kinds

Today `totalSupply() => lpShares`, which counts the **in-range** book only. The owner's constraint is
that the remainder is the out-of-range book:

```
totalSupply = lpShares                    // in-range, against POOLED
            + Σ selfManaged[id].amt       // out-of-range boundary orders
```

⚠️ A boundary order is NOT band depth — it sits wholly outside the active range (`sizeOorUsd`
enforces this, symmetrically since the ordering flag went). So the two terms are disjoint by
construction and cannot double-count. Anything that reads `totalSupply` as "depth in the band" must
be re-checked against that.

## State to MOVE, measured (from `Vogue`)

**Per-LP — goes to the share token:**

| state | shape | note |
|---|---|---|
| `autoManaged` | `mapping(address => Types.Deposit{pooled, usd_owed, fees_tok, fees_usd})` | `pooled` IS `balanceOf` |
| `lpShares` | `uint` | the in-range half of `totalSupply` |
| `selfManaged` + `ID` | `mapping(uint => Types.SelfManaged{created, owner, lower, upper, amt})` | the out-of-range half |
| `feesPerShare`, `bookmark` | `uint` | trading-fee accrual |
| `venueFeesPerShare`, `venueBm` | `uint`, `mapping` | venue-yield accrual |
| `levPooled`, `levBuf`, `levBufferUsd` | `mapping`s | per-LP lev slices |
| `totalLevPooled`, `totalBuffer` | `uint` | their totals |
| `pinnedRecipient`, `pendingRecipient`, `recipientUnlockAt` | `mapping`s | 🔴 KEEP — see below |
| `lastDepositBlock` | `mapping` | anti-same-block |

**Band-level — goes to the engine:** `UPPER_PRICE`, `LOWER_PRICE`, `LAST_REPACK`, `USD_FEES`.

**The share face itself** (moves wholesale): `asset`, `totalSupply`, `balanceOf`, `approve`,
`transfer`, `transferFrom`, `allowance`, `decimals`, `max{Deposit,Mint,Withdraw,Redeem}`, `preview*`,
`convertTo{Assets,Shares}`, `deposit`, `mint`, `redeem`, `withdraw`.

## 🔴 Do NOT delete `pinnedRecipient` while moving it

It looks like deletable ceremony and is not. `BTCChannels.sol:477-496`: the contract cannot see WHO
was paid, only how much reached the committed script. Unbinding it lets an LP route a withdrawal to
a script != `btcRecipientOf`, making `_lpFinalBalance` read 0 ⇒ `delivered = shrinkSats` ⇒
**over-claim of the SHARED swap-out proceeds pool (cross-LP theft)**. ibiza analysed and rejected
exactly this. It is one source of truth for cooperative-close attribution AND the splice path.

## Order of operations

1. **Merge `VogueLib` ∥ `BtcVaultLib`** into ONE band library (8 pairs: `addLiq`/`addLiqChannel`,
   `sizeOutOfRange`/`outOfRangeBtc`, `pullBody`/`pullBtc`, the four `levAdd*`/`levAdd*Btc`,
   `rebalanceBody`×2). ~1,256 lines → ~700. **This is the precondition** — without it the engine
   cannot fit, because the merge only works if one implementation serves both bands.
   ⚠️ NOT into `VaultLib`: that is ETH **venue custody** (`vogueETH`, `offrampBody`,
   `supplyVenueBody`, `waitNft`, `withdrawETH`), a third concern with no BTC counterpart. Folding
   the band pair into it re-fuses what `Vault` was split apart to separate.
2. **Extract the share face** out of `Vogue` into `vETH`, carrying the per-LP state above.
3. **Merge the remains of `Vogue` into `Core`** — by then it is band bounds + fee accumulators.
4. **Mirror for BTC**: `vBTC` already exists as a contract; give it the same face and per-LP state.

## The size arithmetic, current

| | bytes |
|---|---|
| `Vogue` | 21,902 |
| `Core` | **10,260** (was 15,339: SafeCallback, PoolManager, PoolKey, the v4 identity layer and one of two rings all removed) |
| sum | **32,162** vs the 24,576 limit ⇒ **over by 7,586** |

⚠️ Any plan computed from `main`'s old numbers (`24,386 + 24,025`, over by 23,835) is STALE by
~16KB. The gap is now roughly what the share-face extraction plus the library merge should free.
