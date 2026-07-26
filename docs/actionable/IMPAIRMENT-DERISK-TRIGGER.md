# Down-Side ETH-Crash Tail — "hold-down" is negative-skew, not safe

**Status:** analysis / design note. Subject: **ETH (base-asset) price crashes** and whether the built "hold-down" design survives one that doesn't recover. The `_growShort` down-side short is REMOVED (§1); the built design is "up-lever + hold-down." This note argues hold-down is **not** the safe/clean choice its framing implies (§3), names the one regime where it fails (§4), and states the real fork with the "better than YB" product as the centerpiece (§5).

*(Scope note: protocol/credit impairment of a wrapped LST — e.g. weETH breaking its peg — is a **separate** problem, orthogonal to ETH price, and is not this doc's subject. See the footnote.)*

---

## 1. Context — what was removed, and the design that stands

The parallel thread removed the entire `_growShort` down-side short subsystem (uncommitted working tree as of 2026-07-24):

- **`LevMath`:** `bidirTargetBps`, `shortTargetBps`, `shortTargetLive`, `runShort` / `_growShort` / `_closeShort` → replaced by `ilTargetBps` (up-side IL target only; returns **0** at/below entry).
- **`LevManager` / `BtcLevManager`:** `_maybeShort`, `_shortTargetLive`, `shortVenue` / `_lpShortVenue` / `pinShortVenue` / `wbtcShortOptIn`.
- **Tests:** `ShortSizingBound.t.sol` deleted; `LevYbPnl` / `LevYbReal` / `VBtcLevFeeLane` trimmed.

Their own comment in the working tree (`LevMath.ilTargetBps:104-107`):

> *"at/below entry → no UP-SIDE IL → no up-side overlay. (There IS down-side IL below entry — the band over-holds the falling asset — but a long LP does NOT hedge it: the up-side-only LP just HOLDS long through the fall. Holding beats an LVR-leaking downside rebalance: down-side IL is impermanent and heals, so a below-entry short would realize the loss and forfeit the recovery. **Up-side-only is the design.**)"*

And `:108`: `if (pxNow <= entryPriceWad) return 0;` — target LTV = 0 at/below entry. So as price falls back to entry the position de-levers to zero, and below entry it just holds unlevered.

Correct on the modal path: on a round trip the delta-1 short underperforms holding the √p over-hold (which heals for free in the LVR-free band), and "hold" here isn't passive — it's *hold in the band*, which market-makes the inventory (buys dips, sells rips, banks fee/skew), harvesting volatility. It has **exactly one** failure regime (§4).

---

## 2. The two "better than YB" products (only one is built)

**What the other thread built (call it "up-lever + hold-down"):** delta-1 / IL-free / levered-fees on the up side; on the down side, de-lever to 0 and HOLD, letting the LVR-free band heal the impermanent IL. It beats YB by not rebalancing down at all — no LVR realized, no cross-subsidy, no funding, no liquidation risk on the way down. It's a long-biased "buy-the-dip-and-hold" thesis: it bets on recovery.

**The true YB competitor — different, and NOT built:** stay levered through the down-side, maintain delta-1 both ways, rebalance inside our band. That keeps YB's sustained-crash protection *and* the down-side levered fees, with the LVR kept in-pool instead of leaking to arbers — but it re-introduces funding cost + liquidation risk through the crash (you're holding debt into a falling market), and needs the levered de-lever routed through the band, not external SOR. **This is §5.**

| | **Up-lever + hold-down (BUILT)** | **Delta-1 both ways, internal (NOT built)** |
|---|---|---|
| Up side | levered, IL-free, fees | same |
| Down side | **hold**, IL heals on recovery | **stay levered**, delta-1, fees |
| Sustained ETH crash | over-holds (eats it, +EV if recovery) | delta-1 (bounded, neutral) |
| Liquidation/funding risk down | **none** | **yes** (like YB) |
| External leak | none | none (if routed through band) |
| Thesis | long-biased (recovery) | market-neutral tracker |

YB itself (read from `yb-core/*.vy`): always-levered L=2, rebalanced by public `exchange` (arbers), solvency-bounded by `MIN/MAX_SAFE_DEBT` + the untradable-region guard; each `exchange` charges a fee to the LP and hands the divergence (LVR) to the external arber. Its thesis is doubled trading-fee income > LVR + funding — a disclosed bet, not a flaw.

---

## 3. Why hold-down is not the "safer, cleaner" product (counter-case, verbatim)

**"Hold-down is the safer, cleaner product" is false framing.** The full case:

**1. "Hold-down" is a short-volatility, negative-skew strategy wearing a conservative costume.** Praising the band for "harvesting vol" (buy dips, sell rips, bank fees) is praising it for being **short gamma** — the exact profile that prints smooth, steady returns right up until one gap move erases years of harvest. That's XIV, that's every short-vol blowup. A payoff that is *fine, fine, fine, ruinous* is not "safe" — it's ruin-with-a-delay. And it's worse than the textbook case, because below entry the band doesn't just hold the dip, it **over-holds** it — it keeps buying the falling asset. So the strategy is **long the dip with amplifying size into a crash**: negative skew *and* wrong-way gamma. Calling that "safer" inverts the word.

**2. "Do nothing" is a large hidden directional bet, mislabeled as neutral.** Every below-entry "hold" is an implicit *"I bet this recovers,"* and the over-hold **doubles down** on it. So the clean-sounding passive design is actually the *least* honest about its exposure: it takes a sizeable levered-long mean-reversion bet while marketing itself as taking none. Delta-1 is the one that's genuinely neutral and reason-about-able (linear payoff you can hedge). Hold-down hands the LP a **convex-the-wrong-way, path-dependent** payoff that's *harder* to model — which is the opposite of "clean." Hidden bets are how books blow up; explicit ones are how they don't.

**3. The tail isn't independent — it's correlated, and for a stablecoin it hits the thing you can least afford to lose: the backing.** Permanent-impairment / systemic-crash is exactly when *everything* is down, redemptions spike, and confidence is thin. In that moment hold-down leaves the pool sitting on an **over-concentrated, depreciating volatile bag** — precisely as redemptions pull at it. That's a run dynamic feeding forced sales at the worst prices, stressing `D ≥ S + L` and the peg **when it's most fragile**. "Safer for the LP" and "safer for the stablecoin" are different questions, and hold-down is arguably worse on the second. A hedge or a de-risk trigger would have trimmed the volatile *before* the run — keeping the backing liquid. For a peg issuer the cost of the tail isn't its dollar EV; it's **reputational ruin**, which is near-infinite. Weighting a near-infinite tail by "it's rare" is how you justify carrying it — until it arrives.

**4. The "cleaner" claim is mostly cosmetic.** Hold-down doesn't let you delete the leverage machinery — you *still* run the mandatory solvency de-lever to entry, the keeper, the venues, the reseat. You only dropped the below-entry leg. So the simplicity dividend is marginal, while the negative-skew exposure you took on is not. You paid almost the full complexity and bought yourself a fat tail.

**Where this honestly lands** (so it's not just a flip): this does **not** resurrect the always-on `_growShort` — that one bled the round-trip premium on every recovering dip, which is a real cost, and the round-trip theorem still holds on the modal path. What the counter-case establishes is narrower and sharper: **"hold-down = safest" is false framing.** It's the *negative-skew* option — great in the 95% of regimes that mean-revert, ruinous in the 5% that don't, and the 5% is correlated with the exact scenario a stablecoin cannot survive twice. "Safe" and "clean" are doing PR work there. The genuinely safe design isn't naive-hold *or* always-on-short — it's **being explicit**: either delta-1 (own the neutrality) or a real, signal-gated de-risk on the impairment tail. Choosing to hold is defensible; calling it *safe* without pricing the tail is the part I'd retract.

---

## 4. The one edge case: an ETH crash that doesn't recover

Hold-down rests on *"down-side IL is impermanent and heals."* That word **impermanent** is doing all the work — and it's only true if ETH **comes back**. The single regime where it's false:

**A sustained, one-directional ETH re-rating with no recovery** — ETH craters and stays there (regime change / structural repricing). There, "hold" is strictly worse, and *doubly* so, because the LVR-free band doesn't just hold the dip — it **over-holds** it (buys more ETH all the way down). So you ride it down *and* you accumulated more of it on the way. "Impermanent loss" becomes permanent loss, amplified. Holding is worst precisely when the recovery bet loses.

**The right "something" is NOT the short we removed.** The old `_growShort` was an *always-on* partial hedge: to insure the rare permanent crash, it paid the round-trip LVR on **every ordinary dip that recovers** — it bled the premium in the common case to cover the tail. Bad trade for a long-biased book.

**And for ETH it is also NOT a triggered stop-loss.** You cannot tell a dip from a permanent re-rating ex-ante, and ETH has **no structural regime signal** — only its own price. A price-level trigger therefore whipsaws (it cuts at the bottom of a flash-crash that then recovers — *worse* than holding) and is late on the real ones. So a "smart stop-loss" for ETH is a mirage. That leaves the structural choice of §5.

Two things that make the edge case narrower than it first looks (but do not remove it):
- **"Hold" isn't passive.** It's *hold in the band*, which market-makes the inventory — buys dips, sells rips, banks fee/skew. So in **chop or sideways-then-recover**, hold-in-band is +EV; it *harvests* the volatility. Only a clean one-way descent with no oscillation and no return defeats it.
- **The one mandatory "something" is already kept:** the *levered* de-lever on the way down to entry (solvency — de-lever or get liquidated). Not optional; the design retains it. The thing being debated is purely the **unlevered, below-entry** leg, where there's no debt to defend and "cut vs hold" is a pure market call.

Note the tension between "it's rare, just hold" and §3: the tail is **rare but ruinous**, and correlated with the peg's worst moment. For a private hedge-fund LP "rare → hold" may be fine; for a **stablecoin backing engine** the ruinous-correlated-tail argument (§3.3) pushes the other way. That is the decision in §5.

---

## 5. ★ THE PRODUCT — delta-1 maintained through the down-side (the real "better than YB")

> **This is the thing that actually competes with YB, and the only real answer to an ETH crash.** Not hold-down (which sheds the down-side entirely), not `_growShort` (which exits the leverage and spot-shorts). The product is: **stay delta-1 both ways — including below entry — and do the rebalancing inside our own LVR-free band.** It is the *tail-free* option, bought at the price of re-accepting the funding + liquidation risk that hold-down deliberately shed.

### What it is
Above entry it's identical to today: lever up to delta-1 (`1 − √(entry/now)`), IL-free, levered fees. The change is **below entry**: instead of de-levering to 0 and holding the over-hold (hold-down), **keep the position levered and rebalance it to stay delta-1** — trim the over-hold as ETH falls, re-add as it recovers. The doubled liquidity stays deployed the whole way down, so it keeps earning trading fees, exactly as YB does.

### Why it beats YB (this is the edge)
YB is delta-1 both ways too — but its rebalance is the public `exchange`, so **arbers extract the LVR** on every rebalance: the price the LP pays to stay neutral leaks out to MEV. QU!D's band is **LVR-free by construction** (mock/onlyUs pool, reseated to a Chainlink tick, skew owned). So when *we* run the same delta-1 rebalance, the value **stays in-pool** — captured by our own LPs instead of bled to arbers. **Same delta-1 protection, same levered fee income, minus YB's structural leak.** A genuinely better product, not a slogan.

### Why it beats hold-down (no fat tail)
Delta-1 tracks ETH **linearly** — no over-hold, so no wrong-way gamma, no negative-skew tail. In the ETH-crash regime that ruins hold-down (§3–§4), delta-1 has already trimmed the exposure on the way down: **bounded loss, not amplified**. It is the *explicit, neutral* option the counter-case points to — you own the neutrality instead of hiding a levered-long mean-reversion bet inside "do nothing."

### What it costs (honest — this is precisely what hold-down shed)
Delta-1 is the **insurance side** of the same trade hold-down *sells*:
1. **Round-trip LVR premium.** On every ordinary dip that recovers, maintaining delta-1 realizes the sell-low/buy-high cost — the exact premium hold-down *collects*. Internal (accrues to our band, not arbers), but the delta-1 LP still pays it. This is the price of having no tail.
2. **Funding cost.** Staying levered below entry means carrying debt through a falling market — you pay borrow interest all the way down, where hold-down (debt = 0) pays none.
3. **Liquidation risk.** Holding debt into a crash means the keeper must de-lever *fast enough* to stay ahead of the LTV; a gap move that outruns it can liquidate. Hold-down deliberately eliminated this by de-levering to 0 by entry.

So the fork is exactly an **insurance trade**: *hold-down = sell vol* (collect the premium, carry the tail); *delta-1 = buy the flat* (pay the premium + funding + liquidation risk, no tail).

### What it is NOT
Not `_growShort`. That one de-levered to **0** and then **spot-shorted the unlevered equity into the shared band** — killing the levered fee income, cross-subsidizing other LPs (breaks R1), and taking a directional spot bet. Delta-1-maintained **keeps the leverage on** (fees keep flowing) and rebalances the *levered* position through the band — a **capital-structure difference**, not the removed mechanism.

### Engineering delta from what's built
- **Target:** below entry, `ilTargetBps` returns 0 (`LevMath:108`). The product instead returns a **nonzero delta-1-maintaining target** below entry — the `√(entry/now) − 1` offset, but applied to the *levered* position, not a spot short.
- **Rebalance routing:** the levered de-lever currently uses external SOR (`deleverRepay` → `sorSelfFunded`). For the LVR to stay **in-pool** it must **route through the band** (`swapTo`) first, SOR only on overflow — mirroring how `_growShort` already band-sold.
- **Keeper:** must manage leverage safely through a crash — de-lever cadence tuned to stay ahead of the LTV, a liquidation buffer, and the JIT-lock / dwell damping already in place.
- **Risk knobs:** a max-leverage-below-entry cap plus a hard de-risk floor bound the liquidation tail.

**Decision:** build this if "better than YB" means the **neutral, tail-free tracker** — accepting the funding/liquidation risk hold-down shed as the deliberate price of removing the tail. If instead you want the **long-biased buy-the-dip** book, hold-down (built) already is that, and this stays unbuilt. These are the two honest ends; pick which LP you're selling to.

---

## 6. The delta-1 product is NOT `_growShort` revived

| | `_growShort` (removed) | Delta-1-maintained (§5) |
|---|---|---|
| Below-entry capital structure | de-lever to **0**, then spot-short unlevered equity | **stay levered**, rebalance the levered position |
| Fee income below entry | killed (liquidity pulled out) | **kept** (doubled liquidity stays deployed) |
| Counterparty of the sell | shared band → **cross-subsidy** (breaks R1) | the position's own debt/collateral; rebalance routed through band |
| Nature | directional spot short | maintain neutrality (delta-1) |
| Trigger | always-on below entry | continuous target, like the up-side |

The short's apparatus (`bidirTargetBps` / `shortTargetBps` / `_maybeShort` / `runShort` / `shortVenue`) stays **deleted**. The delta-1 product is a *capital-structure choice* (keep leverage on below entry vs. clamp to 0), not a re-wiring of the removed short.

---

## 7. Open — the decision, and the build if taken

- **The decision is §5:** hold-down (negative-skew, cheap, fat-tailed, long-biased) vs. delta-1-maintained (neutral, priced, tail-free, YB-competitor). This is a product/risk call — which LP you serve — not a code task. For a stablecoin backing engine, §3.3 pushes toward delta-1; for a long-biased book, hold-down already ships.
- **If delta-1 is taken:** the build is the §5 "engineering delta" — nonzero below-entry target, band-routed levered de-lever, keeper tuned to stay ahead of LTV through a crash, max-leverage + de-risk-floor risk knobs. Fork-prove: delta-1 held both ways, LVR captured in-pool (not leaked), bounded loss on a sustained crash, no liquidation under a bounded gap.

---

*Footnote — out of scope: LST/wrapper credit impairment.* A wrapped staking token (weETH) can **break its peg to ETH independently of ETH's price** (slashing / protocol insolvency) — a distinct, orthogonal risk that does nothing for the ETH-price tail this doc is about. It is **not** part of the hold-down-vs-delta-1 decision. Written up separately in **`LST-PEG-MONITOR.md`**.
