# LST (weETH) Peg-Break — verified containment; no reactive monitor

**Status:** analysis. **Conclusion up front:** the reactive de-risk monitor first sketched here is **over-engineering — don't build it.** Verified against code: Mode-1 (discount) is already contained; Mode-2 (slashing) is per-LP *isolated* on the leverage side and *socialized-but-bounded* on the plain side; and because the plain-side loss lands on the share price with **no first-out advantage**, a reactive trigger can neither out-run nor recover it. The **only** real lever is an optional **ex-ante cap on the weETH venue share** — a config/judgment decision, not a subsystem.

Separate subject from the ETH-crash tail (`IMPAIRMENT-DERISK-TRIGGER.md`); orthogonal to ETH price.

---

## 1. Two failure modes

- **Mode 1 — market discount, intrinsic intact (common, healing).** weETH's *secondary* price dips below its ETH backing. Drivers: withdrawal-queue congestion; **leverage-loop unwind** (weETH looped as collateral → mass de-lever → forced selling into thin depth → discount → more liquidations, reflexive).
- **Mode 2 — intrinsic loss (rare, permanent).** The ETH backing itself is impaired: **slashing** (weETH is a *restaking* token → EigenLayer **AVS slashing** on top of ordinary staking slashing, a larger/newer surface), or **exploit/insolvency**.

---

## 2. History (to Jan-2026 knowledge cutoff; can't confirm anything more recent)

- **stETH, June 2022** — canonical. During Celsius/3AC it hit ~0.93–0.95 vs ETH; pre-Shapella there was *no redemption path*, so a **pure liquidity discount** amplified by leveraged unwinds. Intrinsic never broke; re-converged fully once withdrawals went live (April 2023). **Mode 1.**
- **ankrETH, Dec 2022** — an actual **exploit** crushed the peg. **Mode 2.**
- **Post-Shapella** LST discounts are rare/shallow — redemption arbitrage floors them.
- **weETH itself** — minor volatility discounts, no major weETH-specific depeg or slashing as of cutoff. Novel risk vs. stETH = the restaking slashing surface, so far unrealized.

Lesson: nearly every LST "depeg" in history was a *temporary liquidity discount that healed* — a discount-triggered cut would have whipsawed you out at the bottom of stETH-June-2022.

---

## 3. How QU!D values weETH — intrinsic

`LevManager.weethValueUsd:290-291` = `getEETHByWeETH(units) × getTWAPforAsset(WETH)`; same `getEETHByWeETH` anchor in `Rover:20,149,650-653` and `Vault:58,372,423`. Deliberately not the thin-pool market price. Consequences:
- **Mode 2 auto-marks-down** — valuation *is* the rate, so a `getEETHByWeETH` drop hits the books immediately; no valuation gap.
- **Mode 1 is invisible** to the books (still marked at intrinsic) but the intrinsic is **realizable via redemption** (ether.fi instant-redeem ~intrinsic−0.3%, `Vault:58`, + buffer cap/DEX/queue fallback, task #38). So Mode 1 is a bounded deliverability/timing sliver, not a solvency hole.

---

## 4. Verified containment (the core finding)

**Leverage side — per-LP ISOLATED.** `LevManager` is *"a per-LP, isolated, weETH-collateral leverage overlay… isolated liquidation (that LP only, never the basket)… own liquidation, never socialized"* (`:68-77`, `:201`), on Morpho/Euler-native per-LP escrow. A levered LP's weETH impairment hits **only that LP**.

**Plain side — value loss is SOCIALIZED.** The withdraw path is explicit (`Quid:572-575`): *"already IL-adjusted, since convertToAssets = pro-rata of vogueETH — the loss is socialized fairly via the share price, no first-out advantage."* `vogueETH()` sums all venues incl. the ether.fi/weETH slice (`Vault:423`); one share price. So a weETH value drop reduces `vogueETH` → every ETH LP's share drops pro-rata. The **"hard wall"** (`ethfiBacked`/offramp, `Quid:497-521`) is **exit-liquidity routing** (your withdrawal is *physically served* from your venue), **not** loss isolation.

**Mode 1 is handled** (`Vault:357-365`): the *"no cap — structural non-problem"* stance is about a **dead/manipulated pool** — Rover is fair-gated (`_nearFair`/`_fairMinOut`), unwinds without a counterparty, and *"degrades a venue-4 slice exactly like the plain ether.fi venue (instant-redeem / wait-NFT), **never into principal extraction**."* i.e. a discount/liquidity event realizes at intrinsic, no principal loss.

**Mode 2 on the plain side is the one uncontained-by-that-reasoning risk:** it socializes across all ETH LPs, **bounded** by the weETH venue share (default 5-way `VENUE_SPLIT` ≈ ~20%) — but **concentratable**, since sizing is *"depositor self-selection"* with **no cap**. Because it socializes, an LP piling into `VENUE_ROVER` raises **everyone's** slashing exposure — a real cross-subsidy / R1 wrinkle. Note `Vault:357`'s reasoning covers *manipulation/liquidity*, **not** this intrinsic-slashing socialized tail.

---

## 5. Why a reactive monitor is the WRONG tool (don't build it)

Because the plain-side loss lands on the share price with **no first-out advantage** (`Quid:574`):
1. A **discrete slash is already realized** the instant `getRate` drops — evacuating weETH→WETH afterward just converts an already-marked-down asset, for no benefit, at a cost.
2. You **can't escape by exiting** — the share price already reflects it for everyone, by design. So a reactive de-risk gives no LP an edge.
3. A **fast exploit** outruns any poke (exit liquidity gone; `getRate` can even lag an unbacked-mint drain).

A reactive trigger only helps if you can out-run or recover a loss; here you can do neither. The elaborate `getRate`-drop → block → evac design (earlier draft of this doc) is dropped.

---

## 6. The only real lever — optional ex-ante weETH venue-share cap

If the restaking-slashing tail is a concern, the robust control is **ex-ante**, not reactive: **cap the weETH (`VENUE_ROVER`) share of vogueETH.** This:
- **Bounds** the socialized Mode-2 loss (a total weETH failure caps at cap% of ETH backing), and
- **Neutralizes the concentration externality** (stops one LP's `VENUE_ROVER` concentration from raising the diversified LPs' slashing exposure).

It is a **config/judgment decision, not a build** — a number, plus enforcing it at the venue-selection/deposit path. Whether it's worth adding at all is a call on how much you trust EigenLayer AVS slashing; the **diversified default (5-way split) already does most of the work**, and `Vault:357`'s "no cap" is defensible *for the manipulation risk it reasoned about* — the open question is only the intrinsic-slashing socialized tail it didn't.

---

## 7. Optional — transparency (not machinery)

Surface weETH `getRate` / market-discount health to the LP (extend the existing dashboard stress-test, #25) so a depositor can *choose* to steer away from `VENUE_ROVER` or exit. Informational; no on-chain subsystem.

---

## 8. Decision & non-items

**The one decision:** cap the weETH venue share, or not? (A judgment on EigenLayer AVS slashing; diversified default already bounds it to ~20%.) That is the whole actionable surface.

**Explicitly NOT open (don't re-raise):**
- A reactive `getRate`-poke / weETH→WETH evac subsystem — over-engineering; can't out-run or recover a socialized, already-marked-down slash (§5).
- Mode-1 handling — already contained (`Vault:357`, Rover fair-gating, redeem-at-intrinsic).
- Instant-redeem buffer sizing — done + self-degrading (task #38).
- Leverage-side weETH — already per-LP isolated (`LevManager`).
