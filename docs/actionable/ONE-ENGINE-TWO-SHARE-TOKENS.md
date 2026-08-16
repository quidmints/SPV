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


## The eight pairs, classified (measured 2026-08-16)

`Types.BandCfg`/`Types.BandP` now serve both libraries, so the pairs differ ONLY in their bodies.
Diffing `levAddNet`∥`levAddNetBtc`, `levAddBuf`∥`levAddBufBtc`, `levAddGross`∥`levAddGrossBtc` and
`levBurnAll`∥`levBurnAllBtc` gives FOUR kinds of difference, and three are drift:

| difference | ETH | BTC | verdict |
|---|---|---|---|
| price sourcing | passed as a parameter | read internally from `c.asset` | **DRIFT** — unify on reading it |
| `modLP` call | direct `ICore.modLP` | extracted (`_modLpBufBtc`, `_burnLpBtc`) | **DRIFT** — legacy-stack management only |
| lev interface | `ILevEquity.netEquity` | `ILevEquityBtc.netEquity` | **DRIFT** — same member, two interfaces |
| **bookmark refresh** | done ELSEWHERE (`_refreshBookmarksLib`) | done INLINE in the lev legs | 🔴 **REAL — and the merge's whole risk** |

**THE BOOKMARK DIFFERENCE IS PLACEMENT, NOT A DEFECT — CHECKED, AND MY FIRST READING WAS WRONG.**
I initially recorded this as the merge's hard problem, on the reasoning that ETH moves the legs
without refreshing and would therefore credit fees on weight it never had. That is false:

| | ordering |
|---|---|
| **ETH** (`_doReconcile`) | `_settlePending` → move legs → **`_onExit`** ("refresh bookmarks, or clear the slot if fully exited") |
| **BTC** (`levAddNetBtc` / `levAddBufBtc`) | refresh **inline**, inside each leg |

Both end with the bookmark at the POST-MOVE weight, which is the invariant that matters:
`refreshBookmarks` sets `fees_tok = weight · accum`, and `pendingFor` credits `weight · fps − fees_tok`,
so a bookmark left at a stale weight would over-credit by `Δweight · fps`. ETH avoids that with ONE
refresh at the end; BTC with one per leg. Same result.

⇒ The merge picks ONE placement, and **the ETH form is strictly cheaper** — a single refresh per
reconcile instead of one per leg, on a path that can touch both legs. Keep `_onExit`-style
end-of-operation refresh and DELETE the inline BTC calls, which are then redundant rather than
load-bearing.

⚠️ **AND THE "REDUNDANT" CLAIM WAS ALSO WRONG — CHECKED.** `syncLevBTC` has NO end-of-operation
refresh: it settles, calls `levBurnAllBtc`, then `levAddGrossBtc`, and returns. **BTC genuinely
relies on the inline refreshes**, so deleting them without compensation would leave the bookmark at
a pre-move weight and over-credit by `Δweight · fps`.

⇒ **THE MERGE IS STILL SAFE, and here is the actual argument:** within ONE transaction
`feesPerShare` cannot move (it only advances on a swap/repack), so N intermediate refreshes and ONE
final refresh land on the SAME bookmark. The invariant is only ever "the bookmark ends at the
post-move weight". So the merge:

1. keeps the ETH placement (one refresh at end-of-operation),
2. **adds that refresh to `syncLevBTC`** — a one-line addition, not an assumption,
3. then deletes the inline BTC calls, which are at that point genuinely redundant.

⚠️ Pin it with a test regardless: move `pooled` AND `levBuf` in one transaction, assert
`pendingFor` is 0 immediately after. That is the invariant, and it holds for either placement.

⇒ **All four differences are mechanical**, and the merge is unblocked — but step 2 is NOT optional.


## 🔴 BOTH FOLDS ARE GATED BY EIP-170, AND THE GATE IS NOW MEASURED (2026-08-16)

Neither fold fits by concatenation. Merging as-is produces an UNDEPLOYABLE contract, and this
repo has already shipped a `Core` at −126 bytes with a fully green suite — the suite does not
catch it. `python3 tools/check-contract-sizes.py` is the gate.

| fold | sum | limit | over by |
|---|---|---|---|
| `Core` + `Vogue` | 32,000 | 24,576 | **7,424** |
| `LevManager` + `BtcLevManager` | 44,372 | 24,576 | **19,796** |

### The Core+Vogue fold is unblocked by ONE step, and it is sufficient

`Vogue` splits cleanly, measured by walking its function bodies:

| cluster | lines | functions |
|---|---|---|
| share / position — `_withdraw` 182, `_depositImpl` 82, `_outOfRange` 41, `compound`, `_settlePending`, `_onExit`, the 4626 + ERC-20 face | **539** | 34 |
| band — bounds, repack, theta, fee accumulators | **280** | 44 |

⇒ `Vogue` is **66% position machinery**. Moving that cluster into `Shares` frees proportionally
~14KB — comfortably more than the 7,424 needed — leaving a band-only `Vogue` of ~8KB. Then
`Core` 10,074 + band ~8,000 ≈ **18,000 < 24,576** and the fold fits with headroom.

**So the order is forced, and it is not a preference:** extract the share face FIRST, fold
second. Attempting the fold first cannot work at any level of care.

### The lev-manager fold needs ~19,800 bytes moved before it is expressible

`LevBase` (208 lines) and `LevVenueBase` (375) already exist as the shared bases, and the two
managers share SEVENTEEN function names (`debtUsd`, `netEquity`, `onMorphoFlashLoan`,
`ilTargetLtvBps`, `deliverableDollars`, `cascadeDelever*`, `openLpAt`, `protectFromQuid`, …).
But `LevManager` alone is 23,754 with 822 bytes of margin, so the merge needs the bodies in a
library before one contract can hold both. That is a larger extraction than the share face and
should follow it, not precede it.
