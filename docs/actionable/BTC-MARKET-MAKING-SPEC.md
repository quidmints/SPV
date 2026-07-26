# BTC market-making — "the well": native-BTC swap deliverability

> ✅ **PHASE 0 BUILT (verify before re-reading as open).** The §6 core — inventory-skew as a swap-time price offset
> + the adaptive EWMA-of-flow target + the virtual reservoir — is **implemented**: `SwapLib.sellSkew`/`wellSkew`
> (`SwapLib.sol:420-453`), the swap-flow `Flow` EWMA + retained-scarcity backing (`Core.sol:143-232`), the primary
> reservoir-refill "pump" (`Vault.sol:722-729`), and the `Aux` skew view for the RFQ/solver taker-limit
> (`Aux.sol:633`), with tests (`Alles.t.sol testSkewBarrierRamp_ConvexCapAndMonotone`,
> `testGrindRemoval_DrainPaysRetainedSkewPremium`). The convex-→linear A-S skew, thin-band, and grind-removal
> proofs landed (commits `72398d1`/`bf99351`/`7a65ae2`/`5be0e8a`). The permissionless swap-in **refill bonus**
> (`payRefillBonus`) is wired (`bacfb6a`).
>
> **STILL OPEN (the deferred-to-scale layers, unbuilt):** §4 non-custodial rebalancer *relocation* (hop-initiated
> splice; the central lev-rebalancer `LevManager.rebalanceMany` exists but is a different job); §5 the **MM RFQ
> interface** (Bebop-shaped firm quotes) + on-chain HTLC MM settlement primitive; §7 the leverage↔well **native-mode
> router coupling**. Read the sections below only for these remaining items.

Status: **DESIGN, scoping Phase 0 (2026-07-12).** This is the pump that keeps the pool able to deliver **native
LN BTC** to swap-out users under sustained one-way flow. It is **ORTHOGONAL to leverage** (see §7 + the leverage
collateral route in `LEVERAGE-COLLATERAL-ROUTE-SPEC.md`) — do not entangle them.

> Design law for everything below: **nothing rigid — every parameter is a live function of state, self-adjusting.**
> No hardcoded spreads, thresholds, or targets that governance must hand-tune. The market sets them.

---

## Launch scope — ship TODAY without a gaping hole (read first)

**The well (skew + MM refill + non-custodial rebalancer, §2–§5) is DEFERRED to the scale stage.** At launch it
*cannot* drain (low volume), and a short pool **degrades gracefully** (#23/#60: fair-share / wait / take USD), not
catastrophically. Shipping without it is safe **iff we don't foreclose it**.

**Ships today (minimal):** the current native-BTC rails — **LN swap-in**, LN + on-chain swap-out, LP channel
inventory, the existing splice-in rebalancer, **oracle pricing (already non-toxic** — no stale price to arb, the
ETH `SwapLib:373` "never the reserve" boundary is the pattern). Plus, as the one cheap thing worth building now,
the **read-only inventory + flow instrument** (§6a) — the LP-dashboard signal AND the early-warning that tells us
*when* to build the well. No money-path change.

**Deferred to scale (build BEFORE drain, not after):** skew curve, MM RFQ, dual settlement, centralized
non-custodial rebalancer. MM relationships bootstrap slowly ⇒ *start them early (business, not code)*.

**Non-foreclosure guarantees (why now leaves no hole):** (1) 2-of-2 MuSig2 channels already keep custody LP-side ⇒
the non-custodial rebalancer is a later *addition*, not a migration; (2) the oracle swap-rate is a *modifiable
function* ⇒ the skew term drops in later (identity/0 at launch), no rewrite; (3) the **non-toxicity boundary is a
design law** (never route refill through the passive band — ETH already codes it) so we can't build it toxic by
accident; (4) the instrument gives **lead time** to see drain trending before it bites.

**THE foresight decision to make at launch (the only real gaping-hole candidate): on-chain swap-in.** Swap-in is
**Lightning-only** today; on-chain (regular) BTC is accepted only on swap-*out*. So a user/MM with on-chain BTC
**cannot sell it in** without converting to LN first — an on-ramp limit from day 1 (most retail holds on-chain
BTC) *and* the exact primitive on-chain MM refill needs. Retrofittable, but decide now: **LN-only on-ramp (accept
the friction) vs. build on-chain swap-in (the taproot-HTLC swap-in) before launch.**

**What "the toxic thing Uniswap does" means:** a constant-product AMM keeps inventory full by letting arbitrageurs
trade against its **stale price** — LVR (Loss-Versus-Rebalancing); the pool stays stocked but its LPs *pay* via
adverse selection. We refuse it (oracle pricing ⇒ no LVR), so the skew is how we buy the same rebalancing from
**benign** arbers (paid for real scarce BTC) instead of extracting it from our LPs. **We are a clean native-BTC
Uniswap; ETH's well is Uniswap itself (a *taker*, toxicity borne by Uniswap's LPs — `SwapLib:373`); #67 (levered
USD-deliverability) is a *separate*, later layer that rides on top — not this well.**

---

## 0. Scope + the orthogonality that keeps this small

Two different BTCs, never conflated:
- **Native LN BTC** (channels; `Vault.autoManagedBTC[lp].pooled` sats) — what a swap-out user withdraws. **This
  doc.**
- **WBTC / stables** (on-chain; Uniswap + Morpho/Euler/Aave) — the leverage engine's collateral + borrow. Retail
  who don't want to be band LPs **lend here for yield; the borrower is the YB lever facility.** Self-served; NOT
  this doc.

**Leverage PREFERS native BTC** and draws/returns it through this well (see below); only the **WBTC fallback**
(DoS-resistance) is orthogonal. So the reservoir nets **swap-in ↔ swap-out ↔ native-leverage draw/return** — a
levered LP growing its hedge is a willing counterparty to a swap-out; de-levering, to a swap-in (internalization
#54). Crucially this flow runs through the **well (MM-fed, skew-priced), never the passive band**, so it is
non-toxic. Phase 0 still builds only the well — but designed so native leverage plugs in as another willing flow,
NOT excluded.

**Why native is preferred (avoid the round-trip bleed):** holding the hedge as WBTC and later delivering native
forces **WBTC→USD→native**, a spread/slippage loss on each crossing whose USD→native leg burns our own
well/skew (through the band it would be a literal IL-transfer to LPs). Native-throughout avoids it. WBTC is used
**only** when the well can't source native — always available on Uniswap ⇒ never a denial of service, at the cost
of that bleed.

Retail BTC holder has three non-overlapping choices: **band LP** (native, the well's inventory) · **Morpho/Euler
lender** (WBTC/stables, feeds leverage) · **levered band LP** (native band position + a *separate* WBTC overlay).

---

## 1. Problem

Oracle + mock-pool pricing deliberately kills **toxic LVR arb** — but with it, the **benign
inventory-rebalancing arb** too (oracle pricing leaves no spread to pay an MM for scarce BTC). So sustained
one-way flow (BTC drains in rallies) has **no market force to refill it**. The rebalancer
(`quid-hop/src/rebalancer.rs:8-15`) is a **pump with no well**: it splices the LP's *own wallet* BTC and treats
swap-out capacity as "sourced *transitively* by swap-ins" — under one-way demand there are no swap-ins to be
transitive from, and it just `warn!("FUND THE LP WALLET")`. Fix: **re-admit the benign arber** (price our real
inventory scarcity) **without the toxic one** (never a stale price to pick off).

---

## 2. Skew — one adaptive price surface

An inventory-holding maker quotes around a **reservation price shifted by inventory** (Avellaneda-Stoikov).
Oracle-only pricing is the anomaly; skew is *correct* pricing (it removes inventory-blindness, adds no risk).

**One surface, adaptive, consumed everywhere:**
> **skew(t) = f( live native-BTC inventory deviation from an adaptive target )**, applied as a price offset at
> **swap time**. It is simultaneously the regular-swap price, the pool's reservation price, and the RFQ
> taker-limit (§5). Build it **once**.

Adaptive shape (each requirement is a stress-test result — a rigid/flat version breaks):
- **Convex + self-scaling, not a fixed spread.** ≈0 near target (regular swappers pay ~oracle in the common
  case); rises **asymptotically** toward the drain edge — enough to cover a native-BTC MM's *real, live* cost
  (splice/on-chain fee estimate + capital-through-confirmation), which the curve reads from current feerate/vol,
  not a constant.
- **Target is adaptive**, not a governance number: e.g. an EWMA of recent two-sided swap volume (the buffer you'd
  need to serve normal flow), recomputed continuously. Inventory far below the adaptive target ⇒ steeper skew.
- **Bounded by a manip-resistant anchor** (TWAP-of-oracle) so oracle-lag can't be amplified into a toxic overpay
  at the edge.
- **The imbalance-causer pays**: the scarcity premium falls on the swap-out user draining a short pool, funding
  the swap-in MM; band LPs are pass-through-neutral. Balanced flow ⇒ skew≈0. Tail: "BTC at a small premium" ≫ "no
  BTC" ⇒ honors *swappers-first*.
- **Continuous** — a live function of inventory, present every tick, tiny, self-extinguishing (each rebalance
  shrinks it), so it converts a sudden deliverability **cliff** into a smooth, incentive-maximizing **ramp**.

### 2a. Skew vs repack — a separate surface on the same swap (IMPORTANT)
These are **orthogonal jobs on the same swap; neither is the other, and they must not fight:**

| | **Repack** (`Vogue._rebalance` → `V4.repack`, bumps `reseatEpoch`) | **Skew** (this doc) |
|---|---|---|
| Job | **Maximize LP fee-earning** by *recentering the concentrated-liquidity ticks around the active price* so depth sits where trading happens — **and, as a consequence, realizes the band's IL** at the reseat. | **Incentivize inventory rebalancing** by *offsetting the execution price* as a function of native-BTC inventory deviation. |
| Acts on | **Where** liquidity sits (tick range / concentration). | **The price** a swap executes at (a delta on top of the band price). |
| Cadence | Discrete (repack/reseat events; re-anchors `entrySqrtP`/`E0`). | **Continuous** — every swap reads live inventory. |
| Signal to MMs | none directly | a permanent, tiny **"come rebalance me"** the moment inventory drifts, **independent of the repack cycle**. |

So: **repack keeps the LPs' liquidity dense at the market to maximize fees (and books IL when it recenters);
skew is a separate, continuous price offset layered on the same swap to summon inventory.** A CEX MM watches the
skew, not the repack. They coexist because they touch different quantities — concentration (repack) vs. price
offset (skew). ⚠️ **Integration hazard:** the manip-guard recenter inside `_rebalance` must treat the skew offset
as a *deliberate inventory offset it does not erase*, while still killing *manipulative* offsets — otherwise the
recenter silently neutralizes skew.

---

## 3. Reservoir — VIRTUAL (the LP channels ARE the buffer), ONE skew-priced exchange

**The reservoir is virtual — there is NO standing protocol-held BTC/USD pile.** Native BTC already sits in LP
channels (`autoManagedBTC[lp].pooled`); a swap moves it between an LP's BTC and USD sides. **So the band LPs *are*
the reservoir** — their channel BTC oscillates with flow and holds it across time (which is what lets a 10am
swap-in net against a 2pm swap-out), and **skew pays them for that depth + timing risk** (what a market-making LP
is *for*). A separate pile would be **redundant with the inventory LPs already provide** and would re-introduce the
exact standing hot-wallet / capital / hedging / custody risk we avoid. This is the "nothing removed, implementation
consolidated" cut: the reservoir's *function* (buffer across time, net flows, refill target) is kept, built on
components that already exist.

> **Stress-tested — is a standing reservoir better than not having one? No.** The only thing a real pile adds is
> smoothing a demand *burst* (skew ≈0 through a spike). But convex skew already holds ≈0 near target and ramps to
> summon MMs *before* channels dry (the ramp is the early-warning), and MM RFQ fills the residual. Marginal
> burst-UX is not worth standing inventory risk; a *bounded, hedged* buffer can be added later if burst-UX ever
> proves to matter. **It is NOT load-bearing for correctness or never-stuck.**

**The consolidation:** swaps, native-leverage draw/return, and MM-RFQ fills are **the same primitive — a
skew-priced native-BTC↔USD exchange over the LP-channel buffer** — differing only in *initiator* (user / keeper /
MM) and *settlement rail* (LN `swap_in_api` / on-chain HTLC, §5). Build it **once**; RFQ = +firm quote, native
leverage = +keeper trigger, swap = bare call.

- **Nets swap-in ↔ swap-out** always; **also nets native-leverage draw/return when the leverage is in NATIVE
  mode** (§7 router). In native mode a levered grow draws native BTC from the well (counterparty to a swap-out)
  and de-lever returns it (counterparty to a swap-in) — internalization (#54); in WBTC mode leverage lives on
  Uniswap and only touches the well as an ordinary swap-out when the LP takes profit. So the netting is
  **conditional on the router**, not fixed either way.
- **The buffer is `Σ(autoManagedBTC.pooled − levPooledBTC)`** (deliverable channel BTC) + band USD — a **view**, no
  new pot. **Adaptive target** = EWMA-of-flow (§2); level = the deviation skew reads — one state, all consumers.
- **MM RFQ refills only the residual** the netting leaves, off the hot path (skew ramp gives MMs the early signal).
- **Never-stuck:** LP depth low ⇒ skew ramps (swap-out degrades to "wait / take USD", never fabricates BTC);
  swap-ins always accepted; a native-leverage grow that can't be sourced falls to the **WBTC branch** (§7) — the
  only thing that isn't this primitive. **Residual protocol inventory = only a transient in-flight-HTLC float**
  (§5), minimized by LN-zero-warehouse + on-demand matching — never a standing pile.

---

## 4. Non-custodial rebalancer — ONE binary, keys 100% LP-side

One operator binary services everyone (global view routes incoming MM BTC to the most-drained channel — a per-LP
rebalancer structurally can't). Per-LP today only because "only the initiator contributes inputs in the vendored
LDK" + BTC came from the LP wallet (`quid-lp-daemon.rs:56`) — **not** safety. Flip the BTC source to the reservoir
⇒ the hop initiates ⇒ one binary (LDK verified: `splice_channel(…,contribution)` signed per-party; simple-taproot
acceptor co-signs with zero inputs, `channel.rs:2116` — **no core LDK change**).

**Non-custody gate** = LP-side validating co-signer enforcing a **conservation invariant** (checks the *outcome*,
so it's complete — no permutation missed): (1) the LP's full claimable position is unchanged/improved, only the
counterparty contribution grows; (2) it lands in an LP-claimable output. Operator **fully untrusted** (worst case =
refusal), strictly ≥ today. **Not a new gate** — a third instance of the shipped `LpAuthResponder` (opens) /
`EvmObligationReader` (swap-out) "rebuild-from-own-view, never blind-sign" discipline. Authorization reuses the
lpAuth transport + an **NWC-style scoped budget** (deleted `nwc.rs`) as a QoS/fee bound — no Nostr. Liveness-only
SPOF: MMs still feed inventory via permissionless swap-in without the binary; LP keeps a self-serve `decide_splice`
fallback (shared module, not duplicated). Routing discretion runs a transparent most-drained-first policy.

---

## 5. MM interface — Bebop-shaped RFQ, dual (LN + on-chain) settlement

MMs plug in **permissionlessly**: an MM is a swap-in that watches skew (publicly readable from on-chain
inventory). Natural MM = a Lightning-liquidity / submarine-swap operator bridging our skew ↔ CEX BTC — **but MMs
may or may not hold BTC on Lightning; support both.**

> **We are NOT a Boltz dependency — we built the rails.** Our own `swap_in_api` HTLC *is* a submarine swap; our
> taproot HTLC scripts *are* the on-chain atomic-swap primitive. An MM uses **our** swap-in, not Boltz. Boltz is
> only **validation** (a live operator that independently ships dynamic-fee skew + Boltz-Pro refill ⇒ this is the
> required shape, not over-design) and a **calibration anchor** (~0.15% skew at moderate scarcity). Optionally a
> business partner to borrow its LP network for bootstrapping — a choice, never infrastructure we need.

- **Bebop shape** (`/quote`→`/order`, EIP-712 firm maker sig `toSign{maker_address, maker_nonce, taker/maker_token,
  amounts, receiver, expiry, packed_commands}`): adopt the API + a firm quote that **locks the skew for the
  delivery window** (removes the MM's settlement-latency slippage). Reuse quote-expiry shape from deleted
  `fiat_rates.rs` (`timestamp_ms`) + LN request/callback from `lnurl.rs`. MMs = makers, QU!D = taker (skew =
  willingness-to-pay). Exact fields: `docs.bebop.xyz/specs/rfq-api.json` at build.
- **MM has LN BTC** → submarine swap = **100% reuse of `swap_in_api` HTLC**; sats land directly as hop-side
  channel balance (**zero warehouse**). Primary path.
- **MM has on-chain BTC** → taproot-HTLC cross-chain swap (reuse taproot HTLC scripts + the existing swap-in EVM
  USD release). The one genuinely new settlement primitive. Bebop is EVM-only (no native-BTC leg) ⇒ the native
  leg is *our* HTLC.
- **Custody**: user/LP non-custody guaranteed (§4 invariant + atomic HTLC). Any BTC the protocol briefly holds
  pre-placement is *protocol* capital (enclave-keyed hop), an operational risk, not a user violation — minimized
  by LN-zero-warehouse + on-demand matching.

---

## 6. Phase 0 scope — against the Vogue band (adaptive)

**Goal:** the smallest change that makes MMs refill the well over the *existing* permissionless `swap_in_api`,
validating the economic hypothesis before any rebalancer/gate plumbing. Two pieces:

### 6a. Native-BTC inventory + adaptive target (read-only first)
- **Inventory** = aggregate deliverable native BTC = Σ `autoManagedBTC[lp].pooled` (band sats) **minus** committed
  `levPooledBTC` (withdrawal-excluded) + the reservoir balance. Add a live view (no state change yet).
- **Adaptive target** = EWMA of recent two-sided swap volume (the buffer needed to serve normal flow), updated on
  each swap. **No governance constant.**
- `deviation = (inventory − target) / target`, clamped; the single state both skew and the reservoir read.

### 6b. Skew offset at swap time (orthogonal to repack)
- BTC swaps price off `AUX.getTWAPforAsset(WBTC,1800)` inside the V4 band (`Vogue.sol:233` sqrtPrice, `:572` TWAP).
  **Instrument the swap-rate computation** (the USD↔native-BTC exchange applied on swap-out delivery / swap-in),
  **not** the band center: `effectiveRate = bandRate · (1 ± skew(deviation))`. This keeps skew a *price offset*
  layered on the swap, leaving **repack** free to own tick concentration + fee-max + IL (§2a).
- `skew(deviation)` = a convex curve whose steepness reads **live feerate/vol** (so the edge premium tracks real
  MM cost), **bounded** by a TWAP band. Sign: swap-out from a short pool pays up; swap-in to a short pool earns.
- **Manip-guard reconciliation**: mark the skew offset as a sanctioned inventory offset exempt from the
  `_rebalance` recenter; recenter still nulls manipulative offsets. (Pin at build — see §2a hazard.)

**What Phase 0 defers** (later phases, nothing cut): rebalancer relocation, non-custody gate, on-chain HTLC
settlement, RFQ API, and the leverage keeper-trigger onto the exchange. Phase 0 builds the **reservoir exchange +
skew** as the shared primitive (§3); native leverage plugs into it later as another initiator (§7), so the
exchange must be built exchange-generic (initiator-agnostic), NOT swap-specific. Gated on Phase 0 proving MMs
respond to the skew over the permissionless swap-in path.

### 6c. Adaptivity checklist (nothing rigid)
- target = EWMA(flow), not a constant · skew steepness = f(live feerate/vol), not a fixed bps · reservoir size
  self-scales to target · MM incentive emerges from live deviation · no per-asset hand-tuned thresholds. ETH band
  can reuse the identical skew surface (asset-agnostic); BTC is the acute case.

---

## 7. Coupling with leverage — an adaptive router (native mode couples; WBTC mode doesn't)

Leverage picks its borrow/hedge by a **condition-driven router** (`LEVERAGE-COLLATERAL-ROUTE-SPEC.md`), NOT a fixed
choice:
- **Native mode** — collateral vBTC, borrow through the (kept) **vBTC/USDC market** supplied by external lenders +
  a **bounded, capped basket-seed** (the *safe* internalise — hard-capped % of backing, gated; NOT the unbounded
  procyclical loan), hedge drawn **native from this well**. It **couples**: grow draws native (nets with a
  swap-out), de-lever returns native (nets with a swap-in), #54. Used only when the vBTC market has depth AND the
  well is flush.
- **WBTC mode** — collateral/borrow/hedge all WBTC, deep external markets. **Zero QD-backing exposure, does not
  compete for the well's native BTC**; touches the well only when the LP takes profit as native at exit (an
  ordinary swap-out). Small WBTC-close bleed. Always available ⇒ never-stuck floor + workhorse default.

So the well's netting with leverage is **conditional on the router** (§3): present in native mode, absent in WBTC
mode. **Delivery of a levered LP's equity is always native via the well, regardless of mode.** The key health rule:
**unbounded basket funding is rejected (procyclical — #67 covers only orderly de-lever, not gap-downs); only the
capped seed is allowed.**

## References
- Code: `Vogue.sol` (`:233` sqrtPrice, `:572` TWAP, `:939` `_rebalance`/repack/manip-guard, `:171` `reseatEpoch`),
  `Vault.sol` (`:168` `autoManagedBTC.pooled`, `:181` `levPooledBTC`), `BtcLevManager.sol` (`:41` vogueBTC WBTC-only),
  `quid-hop/src/rebalancer.rs`, `LpAuthResponder`, `EvmObligationReader`, `swap_in_api`, deleted `nwc`/`lnurl`/`fiat_rates`.
- Bebop: `docs.bebop.xyz` how-it-works / rfq-api `{quote,order}` / settlement-smart-contracts.
- Memory: [[project-quid-btc-market-structure]], [[reference-mock-quid-pool-no-external-lvr]],
  [[reference-quid-procyclical-intermediary-caution]], [[project-quid-taproot-channels-build]].
