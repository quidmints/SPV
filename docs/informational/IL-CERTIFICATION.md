> ⚠️ STATUS (2026-08-01, re-verified against the contracts): OVERRULED as the IL-protect approach. "IL-certification" (LP holds a linear token-claim, basket θ-bounded surplus absorbs the LVR, no leverage needed) is a disproven hypothesis. The IL-protect is opt-in per-LP collateral leverage on external Euler/Morpho/Aave/Liquity, **UP-SIDE ONLY**.
>
> **The previous banner's "bidirectional (long above + short below entry)" was itself stale.** The short leg was REMOVED 2026-07-24 (`LevManager.sol:580-584`); the target returns zero at or below entry (`imports/LevMath.sol:109-125`).
>
> **Read every number below as off-basis.** All of it is keyed to a ±2% range. `SwapLib.RANGE_DELTA = 20` is **±0.2%** (`imports/SwapLib.sol:831-838`), so the K table in §3, the solvency table in §5 and the θ ≈ 0.25–0.40 target do not describe the deployed range. `IL-FINDINGS-2026-06.md` §4 already measured K at 1.84 guard-ON against the 0.71 claimed here, on the old basis. Treat this file as historical IL/LVR data, not as a live safety argument.
>
> `docs/actionable/LEVERAGE-ENGINE-SPEC.md` does not exist; the contracts are canonical. See memory `spv-informational-docs-diverge-from-code`.

# IL / LVR — economic certification (empirical backtest)

> **Status:** empirical backtest over real ETH history (2017-08 → 2026-06, 3215
> daily obs + 5m/1m for the COVID crash) plus a delivery-model check on real
> BTC/ETH hourly data. This is an *economic* assurance, **not** a formal proof and
> **not** a smart-contract audit. "Certified" means *survives the historical worst
> case with margin at θ ≤ ~0.3*, not *proven safe for all paths*.

## 1. Why a QU!D LP does NOT bear classic Uniswap IL (verified from code)

### The intuition first (concave claim vs linear claim)
**Impermanent loss is, precisely, the gap between a *concave* payoff and a *linear*
one.** A vanilla Uniswap LP deposits BOTH tokens and receives a **pool-share
claim** — a claim on a {token, USD} basket whose composition *slides with price*
(the constant-product curve sells the token as it rises, buys it as it falls). That
payoff is **concave**: at every price it is worth *less* than having just held the
initial tokens (HODL, a **linear** payoff). IL **is** that concave-minus-linear
gap. It is unavoidable *for a concave claim*.

**A QU!D LP never holds a concave claim.** It deposits ONE asset and is owed back
**that same asset, 1:1** — `LP.pooled` is denominated in ETH / sats, not in
pool-shares. That claim is **linear** (N units of the token, period). A linear
claim has the *same* payoff as HODL **by construction**, so the concave-minus-HODL
gap is **zero — there is no IL to bear.** This is the whole trick: we hand the LP a
linear, token-denominated IOU and keep the concave pool-share exposure off their
books entirely.

### But LVR doesn't vanish — it's *transferred*, not avoided
Someone still pays the cost of quoting two-sided liquidity against better-informed
flow (**LVR**); it can be *re-allocated* but never *avoided* (see the ratchet note
below). The V4 "liquidity" is **virtual** (mock token/USD); the LP's real asset
sits at a yield venue (ETH: Galaxy/Aave/ether.fi) or a Lightning channel (BTC), and
the paired **USD side is the *basket's* surplus, not the LP's.** When the curve
rebalances, the protocol reconciles that virtual book back to the LP's promised
**token count**, and the rebalancing cost lands on the **basket's
over-collateralization buffer**, not the LP. So the LVR is moved **LP → basket**.
That is *why* the LP's claim can stay linear: the basket's free surplus is the shock
absorber that eats the concavity. It holds while the buffer holds
(**buffer-conditional**; tail → last-out LPs take the residual). The two
asset-specific reconciliation mechanisms, both verified from code:

- **ETH (venue-custodied):** *(historical — the `arbETH`/`arbBody` surplus-funded
  buy-back described here was **removed**; the live design is R1 — the ETH LP bears
  its own IL via the share price (`convertToAssets` = pro-rata of `vogueETH`), and
  IL-protect is now opt-in per-LP leverage. See the banner.)* On exit `_withdraw`
  burned the in-range virtual liquidity, topped up from the venue, and called
  `arbBody` to **buy back any shed ETH at TWAP using the basket's free surplus**
  (`freeBackingUsdc = totalLiquid − committedSum`), so the AMM rebalancing loss
  (**LVR**) landed on the basket buffer rather than the LP — buffer-conditional, and
  now superseded.

- **BTC (channel-custodied):** the V4 BTC pool is one-directional — it only ever
  *sells* BTC (USD→BTC swap-out); BTC inflows arrive over **existing Lightning
  channels** via `settleSwapIn` (no new channel per swap; `openChannel` is only
  for LPs *locking* BTC to provide liquidity). Delivery is therefore purely
  **swap-out demand-driven**, tracked per-channel by `netDeliveredBtc` /
  `swapUsdBtc`. At close the LP gets its **un-delivered sats** back (full upside)
  **plus** `delivered × (swapUsdBtc/netDelivered)` as QUID — the realized proceeds
  for the BTC swap-outs actually took. A real-hourly delivery sim puts the BTC
  market-maker **above HODL** (+~670 bps at a 10 bps fee, robust across flow
  scenarios): fees exceed the flow-inventory cost. ⇒ **no continuous IL; the only
  exposure is flow inventory, offset by fees.**

Net: the LP holds **linear token exposure + yield/fees**, the same end-state
YieldBasis targets (linear exposure, no IL) **but without leverage** — we never
issue a concave pool-share claim, so there is nothing to lever back to linear, and
**no crvUSD / leverage / liquidation mechanism is introduced** (the YieldBasis
delta-hedge's ~40%-swing liquidation risk was evaluated and rejected as not worth
it). This is the same `LP.pooled`-in-token design used in `old/` — the changes
since are mechanical (accumulator-based fees, multi-venue, deliverability
deferral), not a new IL model.

### Limit orders / "ratchet" do NOT change this
A passive on-chain LP cannot *escape* LVR — **limit orders included; they suffer
the same adverse selection.** The boundary-order "ratchet" (peel in-range capital
into a one-sided order that re-arms on fill) was tested across GBM, OU,
real-data variance-ratio, real-data breakeven, and the BTC delivery model: its
spread-capture is **≈ 0** in every one. It is not the IL mechanism (`arbBody` /
flow-delivery is), it does not hedge IL (IL is accepted-unhedged by design), and
it earns nothing — so it is **removed** as inert machinery. The only real lever it
exposed (how much asset to put in-range vs hold at venue) is just a deposit-time
sizing choice, needing none of the boundary-order apparatus.

## 2. The sustainability inequality (ETH LVR sizing)
LVR is not an *avoidance* problem; it is a **sizing** problem for the ETH side
(BTC has no continuous LVR — it's delivery-based, §1):

```
yield_on(whole backing) + fees  ≥  LVR_rate · V_inrange
LVR_rate ≈ K · σ²            V_inrange = θ · backing
⇒  θ ≤ yield / (K·σ² − f)
```

`K` lumps `1/8` (CPMM floor) × concentration × (1/guard-damping) — the one number
that decides everything, so it was **measured**.

## 3. Measured K (fine-grained, COVID crash, 5m)
Pool pinned to the 30-min TWAP, ±2% range, repack-on-exit:

| range | K_eff (guard ON) | K_eff (guard OFF) | guard damping |
|---|---|---|---|
| ±1% | 0.99 | — | — |
| **±2% (current)** | **0.71** | **2.24** | **3.1× reduction** |
| ±4% | 0.47 | — | — |

The **manip guard (30-min TWAP pin + 50 bps/swap cap) cuts LVR 3.1×.** Wider range
→ lower K is the second lever.

## 4. Crash day holds
2020-03-12, ETH **−52% intraday** (1m sim): cumulative loss **−2.32% of position
value** (41 repacks). The ±2% range + repack-on-exit caps each traversal, so the
worst day in ETH history does not blow up the basket.

## 5. Solvency verdict (daily backtest, full history, K=0.71, 88% lifetime vol)
Surplus never goes negative for:

| range | yield 5% / 0% fees | yield 8% / 4% fees |
|---|---|---|
| **±2%** | **θ ≤ 0.26** | **θ ≤ 0.50** |
| ±4% | θ ≤ 0.40 | θ ≤ 0.87 |

**Target θ ≈ 0.25–0.40 for the ±2% range.** Worst year is 2021 (two-way bull vol),
not a crash.

## 6. Honest caveats
- Empirical, not formal; only the historical worst case survives with margin.
- The daily range-exit cap is calibrated to the 1m crash sim (−2.3%) — grounded,
  but treat θ conservatively (bias toward 0.25).
- Buffer-conditional: LP no-IL holds while basket free-surplus covers the
  buy-back; the tail haircut falls on last-out LPs.
- Says nothing about contract bugs — see the audit / static-analysis track.
- "fees offset IL" is **dead**: fees matter only at the full-range end; once
  concentrated, **yield** is the load-bearer and fees are margin.
