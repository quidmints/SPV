# SOR objective — the per-reweigh significance-weighting design

**Status:** DESIGN. The committed `SwapLib._pickBestPath` (`ef0e756`) is a **binary gate** — a *partial
down-payment* on this, not the design. Marked `⚠️ PARTIAL` at the call site.

## What the SOR is
When the protocol must route a swap that touches the basket — a stable shed/rebalance, the `auxSwap` legs,
and (if leverage is ever built) the YB/zap **ETH-sourcing buy-leg** (the non-toxic revival of arbETH's
*mechanism*) — it picks **which stable to source/shed** and **via which path**. That choice trades off
three competing goals.

## The three competing objectives
1. **Concentration-reduction** — shed the stable the basket is most *over-weight* in, to pull weights toward
   target and cut single-stable depeg risk.
2. **Yield-preservation** — do **not** drain a *high-yield* stable just to rebalance; prefer to keep the
   good-yield stables and shed low-yield ones (protects `avgYield`).
3. **Execution** — least-hops / least-slippage for the swapper/protocol (cheapest fill, attracts volume).

## The design: per-reweigh SIGNIFICANCE comparison (NOT either/or, NOT one hardcoded priority)
For **each** reweigh, weigh the **significance** of each goal *at that moment* and let the **most-significant**
one set the policy for that reweigh:
- Basket already near target + a high-yield stable would be shed → **yield-preservation / execution** dominate
  (don't pay slippage or burn yield for a rebalance that isn't needed).
- Basket genuinely over-concentrated in one stable → **concentration-reduction** dominates (shed it even at
  some execution/yield cost, because the depeg-risk reduction is the significant thing right then).
- Two goals comparably significant → the tie-break order (likely execution last as the cheap default).

This is the case-by-case weighing the user described — **the priority itself is situational**, computed per
reweigh, not fixed in code.

## The open question the user owns: what does `calcFeeL1` actually measure?
`FeeLib.calcFeeL1` is **yield-vs-basket-average** (a drainage tax: `mine = yields[idx]/myDep` vs
`baseline = deps[0]/total`) — i.e. it encodes **yield-degradation**, *not* weight/concentration. But
`_pickBestPath` currently treats the highest-`calcFeeL1` pick as the **composition/drainage** signal. So the
two are conflated. Before building the significance-weighting, resolve: is the concentration signal a separate
**weight-vs-target** computation, with `calcFeeL1` supplying the **yield** axis? (Most likely yes — they're
two of the three axes.) This determines what feeds the significance comparison.

## The current binary gate (the down-payment) — what it does and doesn't
```solidity
// engages ONLY when calcFeeL1 > BASE + CONC_GATE_BPS(=2): otherwise fall back to fewest-hops
if (bestIdx != type(uint).max && bestFee <= FeeLib.BASE + CONC_GATE_BPS) bestIdx = leastHopsIdx;
```
- Handles **one** corner: "basket flat → optimize execution (fewest hops)."
- Does **not** weigh yield-preservation vs concentration by significance; does **not** vary the priority
  per reweigh; uses a hop-count proxy, not a real slippage quote.
- "Truer least-slippage" needs an off-chain quote + `minOut` (acknowledged in-code).

## Build plan (on-chain feasible — inputs all exist)
- **Concentration axis:** weight-vs-target per stable (basket holdings vs target weights).
- **Yield axis:** `calcFeeL1` / per-stable yield.
- **Execution axis:** hop-count (on-chain proxy) or off-chain quote + `minOut`.
- **Significance:** a per-axis magnitude (how far over-concentrated / how much yield at stake / how much
  slippage), normalized, with the max-significance axis selecting the policy — replacing the binary gate.

---

## Hardcoded SOR paths — TO BE PROVIDED
*(The user will supply additional SOR paths to hardcode here. Placeholder — do not invent them.)*

| # | path (source → … → output) | when it's the significant choice | notes |
|---|---|---|---|
| _pending_ | | | |
