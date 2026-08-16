# Swap routing: band first, 1inch for the remainder

Landed here (the isBTC-removal tree) rather than only on `main` because it lands in `LevMath`, which
this refactor is actively reshaping. Written 2026-08-16. Owner-directed. **Nothing below is
implemented.**

New file rather than an edit to `QUEUE.md`, deliberately: that file is being touched by more than one
thread and a merge conflict in the status list is worse than an extra document. The same items are
booked on `main` as **§V-ROUTE (§V-R1…§V-R11)**; reconcile there, do not duplicate.

---

## Why: the current route is 698 WETH deep

Measured live 2026-08-16, `CURVE_TRICRYPTO_USDC 0x7F86…829B`:

| coin | inventory |
|---|---|
| WETH | **698** |
| WBTC | **20.72** |
| USDC | $1.31M |

Against `SELL_SLIP_BPS = 100`, `get_dy` on the USDC→WETH leg:

| hop | effective px | slip | vs 1% floor |
|---|---|---|---|
| $10k | $1,894.96 | 0bp | fills |
| **$25k** | $1,919.28 | **128bp** | **reverts** |
| $100k | $2,033.20 | 730bp | reverts |
| $250k | $2,251.85 | 1,883bp | reverts |

With `MAX_LOOPS = 8` that caps an entire lever-up near **$80–160k**.

**The failure mode is the important part.** It is NOT a bad fill — the oracle floor prevents that.
It is that `openLev`/`rebalance` REVERT, so the hedge cannot be established and, worse, cannot TRACK
the band as `targetDebt = E0·soldFrac` grows. The LP goes progressively unhedged exactly while IL
accrues, while the accounting reads healthy because the debt it holds is the debt it was able to
take. Owner: *"it must never stop tracking like this."*

## The shape

```
  band fills what it can  →  1inch splits the REMAINDER  →  dedicated rails stay dedicated
```

1. **Band first.** Internal fill pays no external fee and no external spread, and the flow accrues
   to our own LPs. Aggregation belongs on the RESIDUAL, not on the whole order.
   ⚠️ Confirm how today's band-then-remainder split is actually expressed in `sorAuxSwapBody` /
   `Core.swap` before building on it — stated here as the shape to preserve, not as a verified
   description of current code.
2. **1inch for the remainder.** AggregationRouterV6 `0x111111125421cA6dc452d289314280a0f8842A65`
   (VERIFIED LIVE 2026-08-16, codesize 24,294). Pathfinder returns a WEIGHTED SPLIT across
   Uni V3/V4, Balancer, Curve and others in one atomic calldata — it does not mainline into a single
   venue. That is what makes the floor clearable at sizes no single pool can serve.
3. **Rails that must NOT be aggregated:**
   - `_wethToWeeth` — ether.fi `depositWETHForWeETH` mints at the fair rate, zero price impact.
   - weETH→WETH offramp — one deep Curve pool, floored against the ether.fi ratchet
     (+0.674 bps/day, monotonic, unmanipulable). No split exists to find; routing it externally adds
     a dependency and buys nothing.

## Call sites to convert — all four, or the BTC band keeps the defect

`LevMath._stableToWethSor`, `_wethToStableDex`, `_stableToWbtc`, `_wbtcToStable`.
The BTC pair draws on **20.72 WBTC** — thinner than the ETH leg, and it inherits the same floor.

## Two properties, both needed — one does not substitute for the other

- **AGGREGATION makes tracking DEEPER** (more venues, bigger clearable size).
- **PARTIAL FILL makes tracking ROBUST.** `SELL_SLIP_BPS` must bound the **price**, not the **size**.
  A $250k need against a venue that fills $25k within 1% currently reverts and delivers ZERO hedge;
  filling the $25k leaves the LP 10% hedged, and the accounting stays coherent because `_leverUpBuy`
  borrows and supplies the SAME reduced amount — debt and collateral move together, LTV stays valid.
  **1inch does NOT close this**: an API outage, a volatile block, or any size that cannot clear the
  floor still reverts the whole thing.
  ⛔ Do NOT implement partial fill by widening the floor — that is rule 4, a tolerance that hides the
  defect. Accept a SHORTFALL at a good price and re-target next tick: `targetDebt = E0·soldFrac` is
  recomputed every call and `RebalanceFailed(lp, ltvBps)` already exists as the signal, so a partial
  fill converges rather than drifts.

## Facts that survive from the cancelled on-chain-split design

- `SOR._tryPathsMatching` returns the FIRST path clearing `minOut`. It is a **fallback chain, never a
  splitter** — six registered paths are six attempts at the same size. **We have never had order
  splitting.** Do not call the SOR an aggregator.
- **An AMM swap does not partially fill**: feeding `amountIn` to a thin pool returns a bad price for
  the whole lot, not "as much as it could". Any split must divide the INPUT and check the floor on
  the COMBINED output — per-hop floors are what `6ddb094` already rejected one level down.

## Decisions, not defaults

1. **`rebalance` is permissionless.** With caller-supplied calldata an arbitrary caller passes an
   arbitrary target and payload. PIN the router to an allowlist or make the path keeper-only. An
   unpinned `call` on a permissionless entrypoint is a worse hole than the thin liquidity it fixes.
2. **Approvals** exact-amount per swap, zeroed after.
3. **Off-chain dependency**: failure moves from "reverts when the pool is thin" to "reverts when the
   API is down". The keeper already runs off-chain, so this is a smaller posture change than it
   sounds — but it is a change, and it is the owner's call.

## Interaction with THIS tree's refactor

1inch resolves routes off-chain, so a `bytes route` argument threads
`openLev`/`rebalance` → `_leverUpBuy` → `stableToColl` → the swap helper. That is a signature change
on two public entrypoints, propagating to the SPA and the Rust keeper.
**Sequence it AFTER the isBTC split settles**: `_stableToWbtc`/`_wbtcToStable` are the BTC-side twins
of the ETH legs, and if the split changes whether those live in one parameterised body or two
instances, the routing change would be written twice. Same argument `cf958b4` made for `repackNFT`.

## Verification gate — all four, none optional

- `forge build`
- `python3 tools/check-contract-sizes.py` — `LevMath` had 228 bytes of margin; this repo has shipped
  an undeployable `Core`
- full suite on a STABLE endpoint. ⚠️ ankr timed out mid-suite and publicnode 429s on 2026-08-15/16;
  endpoint noise produced 16 phantom failures in one run and moved the pass count 2,611 → 4,226 with
  no code change
- `python3 tools/check-client-abis.py` **AFTER a rebuild** — verified twice that it invents phantom
  ORPHANs against stale `evm/out` (it reported `netEquity` missing while live at `LevManager.sol:244`)

---

## What this does to `SOR-SIGNIFICANCE-DESIGN.md` — reduces it, does not replace it

`SOR._pickBestPath` (`:337`, still carrying its own `⚠️ PARTIAL` marker at `:360`) is doing TWO jobs,
and aggregation takes exactly one of them:

| the doc's objective | who owns it after this |
|---|---|
| 1. concentration-reduction — shed the over-weight stable | **OURS.** A basket-composition decision; 1inch does not know our weights or our depeg exposure. |
| 2. yield-preservation — don't drain a high-yield stable to rebalance | **OURS, AND STILL UNIMPLEMENTED.** `get_deposits` already returns `depsY` and it is passed to `calcFeeL1`, but NO term declines to drain a high-yield stable. The gap survives this refactor untouched. |
| 3. execution — least hops / least slippage | **DELEGATED to the aggregator.** A `keys.length` proxy cannot beat a router that splits across Uni/Balancer/Curve by marginal price. |

⇒ **Delete the `leastHopsIdx` / `leastHops` branch when the aggregator lands** — it becomes a worse
answer to a question we are no longer asking. What is left is a TWO-objective choice (concentration
vs yield), which is a simpler problem than the three-way tradeoff the doc was written against.

⚠️ **Do NOT read "1inch handles routing" as "the SOR objective is solved."** The router picks HOW to
execute; `_pickBestPath` picks WHICH STABLE to source from. Deleting the second along with the
first would hand basket composition to an external party that cannot see the basket.

---

## Venue priority: our own rails first, aggregator for the residual (owner, 2026-08-16)

⚠️ **PREMISE CORRECTION FIRST, because it sets the architecture: THERE IS NO ON-CHAIN PATHFINDER.**
1inch's route search runs on their servers and returns calldata. Nothing on-chain computes a split.
So the settlement guarantee CANNOT come from Pathfinder — it comes from our side of the call, and we
already have the piece that provides it: **the oracle floor**. Pathfinder proposes, our contract
disposes: output clears `TWAP × (10_000 − SELL_SLIP_BPS)/10_000` or the call reverts. That holds no
matter what route came back or how stale the quote is.

**Ordering — the band-first principle extended to every rail we own:**

1. **Our own pools first.**
   - ETH leg: weETH↔WETH on the ether.fi Curve pool. We have a fair-value anchor here (the ratchet,
     +0.674 bps/day, monotonic, unmanipulable), so routing it out pays a spread to reach liquidity we
     already have privileged access to.
   - BTC leg: our BTC Curve rail plus **Aave V3** for the WBTC side of IL-protect.
2. **Aggregator for the RESIDUAL only** — whatever our rails cannot absorb.

**Why this ordering and not "quote everything":** it degrades correctly. If the aggregator API is
down, the owned rails still fill what they can, and with partial fill (§V-R11) that is a REDUCED
hedge rather than NO hedge. Quoting everything and taking the best makes the aggregator a hard
dependency; checking our rails first makes it an enhancement.

### vBTC: CHECK THE MARKET'S LIQUIDITY, DO NOT ASSUME IT FROM THE DEPLOY CONFIG

The deploy script **CREATES** the vBTC Morpho market via `_mkMorphoVenue`. A market we create
ourselves **starts empty by construction** — there are no lenders until someone supplies it. Being
present in the deploy config is therefore NOT evidence that it can be borrowed from.

This is the same family as the on-chain fact measured 2026-08-16: **six** weETH/USDC 86% markets
exist on Morpho and **five hold $0.00M**. `fd1fd78` fixed the adjacent hazard (a wrong param now
REVERTS instead of silently creating an empty twin), but a CORRECTLY-specified market we
deliberately create is still empty until supplied — `fd1fd78` does not and cannot cover that.

⇒ **The router must read the vBTC market's actual liquidity before treating it as a venue.** Routing
into a market with no lenders is a revert at best and a stuck position at worst. Precondition, not
configuration.

### Limit Order Protocol IS relevant — do not dismiss it as "resting orders"

`outOfRange(...)` parks liquidity outside the current range so it fills when price arrives. That IS
a resting order, expressed as concentrated liquidity. The economics differ — ours earns fees while
waiting and is our own inventory, an LOP order rests off-book and costs nothing until filled — but
OOR depth the band cannot or should not carry is exactly what a limit order could carry instead.

### Fusion could invert the keeper dependency — worth evaluating, not yet verified

Fusion is a Dutch auction over an intent; resolvers compete to fill and pay the gas. Three
consequences if it holds up:
- **`lev_keeper.rs` stops being load-bearing.** Today it must be alive to rebalance. With an intent
  posted, whoever wants the fill executes it; the keeper becomes the backstop for "no resolver
  showed up" — a far better failure posture than "our daemon is down, so the hedge stops tracking".
- **The decay curve IS the floor.** Start the auction at TWAP and decay toward `TWAP × 0.99`.
  Anything fillable within our tolerance fills, and we never pick a venue or a size.
- **Fusion supports partial fills** — §V-R11 served by the protocol rather than by shortfall
  accounting we would have to write and reason about.
⚠️ UNVERIFIED: written from general knowledge, not from the live API (v6 needs a key not in this
tree). Confirm the auction/partial-fill semantics and the ERC-1271 signing path for a contract-held
intent before designing on it.

### Combine concentration and yield into ONE score — the quote is what makes it possible

Owner: shedding the over-weight stable is bad if it is the high-yield one. The doc's mode-switch
("most significant objective sets policy") is fragile exactly there — a slightly-over-weight,
strongly-high-yield stable flips behaviour on a threshold. Replace it with a single score:

    for each candidate source stable:
        score = expected_out_net_of_gas  +  λ·concentration_benefit  −  μ·yield_loss
    take the max

This is newly practical BECAUSE of the aggregator: today `_pickBestPath` proxies execution with
`keys.length` since it has no price, so execution can only ever be a tie-break. A real quote makes
all three terms DOLLARS, so they add. The threshold problem dissolves — a high-yield over-weight
stable simply scores worse than a low-yield over-weight one.

Pathfinder optimises NET OF GAS and returns an estimated gas figure, so the split/gas tradeoff is
internal to the router — the thing `keys.length` was approximating badly.

⚠️ COST TO WEIGH: scoring N candidates means N quotes per rebalance. Off-chain keeper work, cheap in
gas, real in latency and API rate limits ⇒ score only the plausible candidates (the two or three
most over-weight), not all eleven stables.
