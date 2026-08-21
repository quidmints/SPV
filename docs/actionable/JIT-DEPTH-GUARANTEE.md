# JIT depth-guarantee — deterministic swap impact → forbidden sandwich (Quid `_withdraw` TODO)

Status: **SPEC / actionable.** Grounds the Quid `_withdraw:393` TODO ("one function that does `_repack`… feeds `tryPair` by redeeming liquid QUID… JIT guarantee the dollars are there for any total size of swaps… so we know exactly how much it will move the price → MEV eliminated at the block guarantee"). Written against the real code, with the backing-invariant safety worked out. No code yet.

---

## 0. Why this is the MEV answer (Carbon "forbidden sandwich"), not a surge fee

Carbon DeFi's *forbidden sandwich* result: a sandwich is unprofitable exactly when the victim's **`minReturn` (slippage limit) is tight** — "minReturn is a perfectly serviceable answer to sandwich mitigation." A tight `minReturn` is only *safe to set* when the swap's **price impact is known in advance**.

The band's problem: impact is **not** known ahead of time — it depends on how much in-range USD/ETH depth happens to be there, which the wide ±2% band leaves mostly idle and which a large swap can exhaust (partial fill). So users must set a **loose** `minReturn` → sandwich room.

**The fix is not a fee, it's determinism.** If the band can *guarantee* the dollars for any swap size, the impact is a **known function of size**, the SPA/solver sets `minReturn` at that known impact, and any sandwich that pushes further **reverts the victim** → forbidden. Benign arb is untouched (price still moves with real flow; only the *uncertainty* is removed).

This supersedes the (rejected) post-repack surge and dynamic width:
- **surge fee** — narrow window, taxes rather than forbids, hurts benign arb. Dropped.
- **dynamic width** — moves idle liquidity around; doesn't make impact deterministic. Dropped.
- **JIT depth-guarantee** — makes impact deterministic → enables tight `minReturn` → forbids the sandwich, and simultaneously maximizes fee-earning liquidity (tight standing band + on-demand depth, nothing idle).

Not a substitute for the SPA's Flashbots-Protect (that covers retail-via-SPA); this is what covers **solver/aggregator flow** that never sees our mempool submission — the flow #72 is built to serve.

---

## 1. Existing pieces it composes from (no net-new minting)

- **`Quid.unwindForRedeem(usdWanted) → usdFreed`** (`Quid.sol:896`, `onlyUs`) — burns in-range band liquidity by the band's OWN USD/ETH ratio to release EXACTLY `usdWanted` USD (oracle-free). This is the **USD-OUT** primitive.
- **`Quid.addLiq(amount, price, …)`** (`Quid.sol:783`) — pairs USD+ETH back into the band (the **USD-IN** primitive), headroom-bounded by `surplus`/backing.
- **`Aux.redeem` / `BasketLib.redeemAsBody`** (`Aux.sol:872`, `BasketLib.sol:853`) — burns QUID, frees basket USD (mature-share priced, depeg-haircut). The **QUID→USD** primitive.
- **`matureSupply()`** (restored) — the senior, dollar-redeemable-now cohort; only mature QUID is redeemable at par (the "liquid QUID").
- **lev-keeper intent** (`lev_keeper.rs`) — the fleet signer that already drives `rebalance`/`protect`/`compound`; it holds/authorizes the QUID the guarantee redeems.

`tryPair` is NOT a new function — it's `Quid.outOfRange` (`:270`, places a single-sided USD position at a chosen distance — the USD-side-depth primitive the redeem feeds) / `addLiq` (the paired variant, volatile-in). Both are BTC-capable via `isBTC`/token. The guarantee is a thin driver over them: given a target USD depth, pull it from the cheapest source (idle band USD first, then `unwindForRedeem`'s inverse, then redeem liquid QUID) and place it via `outOfRange` — no net-new function, no net-new minting.

---

## 2. Mechanism

At swap time (`SwapLib.routeSwap`, the well path), before executing the swap against the band:
1. Compute the **USD depth needed** to fill `amount` at an impact ≤ a target bound (a pure function of size + current in-range depth).
2. If the band's in-range USD already covers it → proceed (common case, no JIT).
3. Else `tryPair(neededUsd)`:
   a. use idle/out-of-range band USD if any;
   b. else **redeem liquid (mature) QUID** held under the lev-keeper intent → basket USD → `addLiq` it into the band, JIT.
4. Now the fill's impact is a **known function of size** → the caller's `minReturn` (set by SPA/solver at that known impact) forbids any sandwich.
5. Post-swap, the JIT-paired depth unwinds back (the band returns to its tight standing size — nothing left idle).

**Deterministic-impact property:** because step 1–3 guarantee depth ≥ what `amount` needs, the executed price is `f(amount, guaranteedDepth)` — computable off-chain by the SPA/solver *before* signing → tight `minReturn`.

---

## 3. Backing-invariant safety (the money-path)

The one thing that must hold: **`tryPair` never creates USD the basket doesn't back.**
- Redeeming mature QUID **burns** that QUID (supply ↓ by the redeemed face) and frees the **exact** basket USD backing it (mature-share priced, `redeemAsBody`). So `redeem → addLiq` is **backing-neutral**: `S` drops, band USD rises by the same backed dollars; `D ≥ S + L` is preserved.
- `unwindForRedeem` moves USD that's already in-band; also neutral.
- The lev-keeper's QUID is **its own** (or the LP's opted-in, same as `protectFromQuid`) — never minted for this. No unbacked/transient mint (consistent with the "QUID only minted against basket dollars" law).
- Atomicity: the redeem→pair→swap→unwind must be ONE tx (the swap's own tx), so a revert unwinds all of it; no standing JIT float.

**Fork to confirm before wiring:** whose mature QUID funds the JIT pair —
- **(A) lev-keeper-prefunded reserve** (keeper holds a mature-QUID buffer, redeems from it) — simplest, deterministic, but ties up keeper capital; or
- **(B) per-swap opt-in LP QUID** (like `protectFromQuid`) — no standing capital, but needs the LP to have opted in + hold mature QUID at swap time (liveness risk).

Recommendation: **(A)** for the guarantee (must be always-available), with (B) as an optional top-up. This is the one design decision that gates implementation.

---

## 4. The `_withdraw` folding (the rest of the TODO)

> ✅ **STATUS CORRECTED 2026-07-27 (MISS 1): ALL THREE ARE BUILT.** This section had marked them TODO
> long after they shipped, which is why MISS 1 kept resurfacing. Verified in `Quid.sol`:
> 1. **Compound the QD** — BUILT. `_settlePending` is called with `mintRecipient == 0`, so the USD fee
>    leg accrues to `usd_owed` (a deferred, unrealized claim — no mint) and is realized only on a FULL
>    exit. The code carries the `§4.1 COMPOUND-not-transfer` marker.
> 2. **Cover open levers first** — BUILT. `_withdraw` fires `closeLevFor` + `_reconcileLev` when the ask
>    exceeds the LP's free depth (`amount > plainNet(pooled, levPooled)`), i.e. #109's auto-de-lever.
>    (7 `closeLevFor` / 8 `_reconcileLev` references.)
> 3. **CEI-ordering fix** — BUILT on the main path: `LP.pooled -= amount; lpShares -= amount;` (`:562`)
>    precedes the `_burnInRange` send (`:566`), so state is decremented before the external call.
>
> The section is kept for its DESIGN rationale (Quid:419 cites §4.1 for live semantics); only the
> status was wrong.

Independent of the JIT core, three `_withdraw` (`Quid.sol:403`) changes from the TODO:
1. **Compound the QD, don't transfer it** — `_settlePending` (`:340`) currently `QUID.mint(recipient, usdR)` for the USD-fee leg. On a **partial** withdraw, compound `usdR` into the remaining position (mirror the token leg's `LP.pooled += tokR`) instead of minting out; only mint-out the fee on a **full** exit. (Money-path: compounding = not realizing the mint, strictly conservative.)
2. **Cover open levers first** — before the free-ladder burn, ensure the LP's open lev (`levPooled[msg.sender]`) is settled/covered (today the withdraw only *caps* at `pooled − levPooled`; the TODO wants it to actively cover/close first so a withdrawing LP can't strand a lever).
3. **CEI-ordering fix** — today native-ETH sends (`_burnInRange(…recipient)` `:455`, `_sendETH` `:473`) precede `LP.pooled/lpShares -= amount` (`:485`). Restructure to **debit `amount` first, send, then re-credit any undelivered shortfall** (`LP.pooled += shortfall`) — so a re-entrant sees the debited per-LP state. (Cross-contract reentrancy is bounded today because Aux doesn't read the lagging per-LP state, but this removes the smell without a shared guard that could break the V4 `unlock` callback.)

---

## 5. Build order
1. Confirm the §3 fork (A vs B). ← gates everything.
2. `_withdraw` CEI fix + compound-QD + cover-levers (self-contained, testable in isolation).
3. `tryPair(neededUsd)` + the swap-time hook in `routeSwap`, reusing `unwindForRedeem`/`addLiq`/`redeemAsBody`.
4. Fork-test: deterministic-impact invariant (a fixed-size swap moves price by the predicted amount regardless of pre-swap band depth) + backing-invariant preserved across `tryPair` + a forbidden-sandwich test (a sandwich around a tight-`minReturn` swap reverts the victim, nets the attacker ≤0).

Every step lands against a **committed, fork-testable** tree — not blind.
