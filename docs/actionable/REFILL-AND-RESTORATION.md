# Refill and range restoration — consolidated state

**Owner of this file: whoever picks it up next.** It is written to be executed COLD, by a thread with
no memory of the 2026-08-04/05 sessions. Every claim below is marked ✅ verified in-repo, ⛔ retracted,
or ❓ unverified. **Do not promote a ❓ to a premise without running the check named beside it.**

Companion files: `JIT-DEPTH-GUARANTEE.md` (JIT depth is a SEPARATE mechanism — see §6),
`QUEUE.md` rows E48, E64–E69 (this file supersedes their prose; their status markers stay in QUEUE).

---

## 1. The question, stated so it cannot drift

> **Is restoring the range's volatile:USD balance profitable to whoever does it, unaided?**

If YES, an external arbitrageur closes every imbalance for free and no mechanism is needed.
If NO, the protocol must execute restoration itself, and the only remaining question is funding.

⛔ **THIS FRAMING IS STALE, AND IT HAS BEEN SINCE 2026-08-15 (recorded 2026-08-28). THE OWNER ALREADY
DECIDED THE OTHER BRANCH, AND THE DECISION IS IN THE CODE, NOT ONLY IN A THREAD.** `SwapLib.sol:2755`:
> *"**THE SKEW IS NOT A SPREAD PAID TO ARBERS. IT IS THE ATTRIBUTION KEY FOR A REBALANCE WE PERFORM
> OURSELVES** (owner, 2026-08-15). An AMM's spread exists to PAY EXTERNAL ARBITRAGEURS to push the
> pool back to target — that is the entire economic function of the curve. **We restore 1:1 from the
> INSIDE via Curve**, so there are no arbers to compensate and nothing the spread would be funding."*
⇒ **The YES branch is not wanted even if it is true.** Letting a third party close the imbalance hands
them value that the design intends for LPs. So "is it profitable to whoever does it?" cannot gate the
work: **we do it either way.** That is why this question *"has been asked three times and answered
zero times"* — answering it changes nothing we build.
⭐ **THE QUESTION THAT ACTUALLY GATES THE WORK, RESTATED:** *with what capital do WE restore, and what
triggers it?* §2's boundary already answers the first in the negative (**not** uncommitted basket
dollars — that is QU!D holders' capital), which leaves LP capital and the range's own inventory.
🔴 **AND HERE IS THE GAP, MEASURED 2026-08-28: THE ATTRIBUTION HALF IS LIVE AND THE REBALANCE HALF IS
NOT.**
| half | state |
|---|---|
| **Charge + credit** — `retainSkewPremium` withholds `premium = amount·skew/1e18` and routes it to LPs via `creditSkewPremium` | ✅ **LIVE, on every swap** |
| **The rebalance it attributes** — "restore 1:1 from the INSIDE via Curve" | ⛔ **NOT BUILT ON THE RANGE PATH.** `ICurvePool(...).exchange` has exactly three call sites, ALL in `LevMath` (`:553` etherFi weETH→WETH, `:729`/`:730` stable↔USDC) — the LEVERAGE path. **Zero on the range path.** `refillNeeded` has no caller. |
⇒ **WE CHARGE THE ATTRIBUTION KEY FOR A REBALANCE NOBODY PERFORMS.** That is the finding this file
should lead with, and it is sharper than "restoration may be unprofitable": the premium is being
collected and credited on every swap for work that is not being done.
⚠️ **CONSEQUENCE FOR `RestoreProfitability.t.sol`: IT MEASURES THE WRONG ACTOR.** It prices a THIRD
PARTY restoring, which the 2026-08-15 decision says is not the intended path. Under the decided
design there is no third-party edge to compute — the edge IS the skew premium, already credited to
LPs. ⛔ **AND ITS CURRENT NUMBER IS A CONSTANT, NOT A MEASUREMENT:** its 300 bps shortfall equals
`UNKNOWN_VARIANCE_SKEW = 3e16 = 3%` **exactly** (`49,958 × 0.97 = 48,459.26`, to the cent), because
σ² is 0 in that fixture and §E278's guard (landed 2026-08-26) deliberately resolves an unmeasured
variance to the CEILING on the sell leg. **It is reporting a policy constant.** To get a real number
the fixture needs the three preconditions established in SPRINT §E306: a pinned feed, ≥3 repacks with
MOVING samples, and non-zero flow.

**This has been asked three times and answered zero times.** Twice it was answered with an argument;
once by citing E25's "0 bps across 300k volume" — **which does not answer it**, because E25 measured a
BALANCED range under ORDINARY flow, and the question is about the dislocation present in an IMBALANCED
range. Reusing that measurement here is the specific error this file exists to stop.

---

## 2. What refill is NOT — four definitions ruled out, three by the owner

⛔ **Not re-pairing assets already held.** Pairing spare ETH against spare dollars we already hold just
makes the range smaller in one leg. If there is excess ETH beyond the dollars available to pair it, the
excess stays uncovered. That is a REBALANCE, and it shrinks the pool rather than refilling it.

⛔ **Not selling uncommitted basket dollars for out-of-range ETH.** Those dollars back QU!D. Spending
them to buy volatile converts stable backing into directional exposure using QU!D holders' capital.
It is a trade with someone else's money, not a refill. **This is the boundary that matters most.**

⛔ **Not #12's freed headroom.** (E67, owner-corrected.) I claimed E36's +60,000 of returned headroom
and E39's +32 ETH of range depth were "additional refill capacity". **#12 freed no dollars**: it stopped
the backing gate counting LP trading proceeds as basket commitments. `liquidTotal` never moved, only
`committedBoth` fell. **What grew is PERMISSION, not capital.** ❓ Whether deployable dollars sit behind
that permission was never checked — E39's `surplus/price` arithmetic assumes it does.

⛔ **Not the Lightning channel rebalancer.** See §5.

---

## 3. What the contracts actually do today ✅

All verified in-repo 2026-08-05, at these lines, AFTER the E68 skew change landed (`ca4d26e`):

| fact | where |
|---|---|
| The drain leg exempts a swap that ENDS at/above target | `evm/src/imports/SwapLib.sol:885` |
| The sell leg exempts a refill outright (`over == 0 ⇒ 0`) | `evm/src/imports/SwapLib.sol:1102` |
| The BTC swap-out records an OBLIGATION, recipient is the pool | `evm/src/imports/SwapLib.sol:1203` |

**Consequence, and it is the load-bearing one:** a swap that moves the range TOWARD target is charged
**zero premium on both legs**. Restoration is not deterred. **But exemption is not a reward** — the
restorer still pays gas and the ordinary LP fee and captures no premium, so "not deterred" and
"incentivised" are different states and only the first is implemented.

❓ **UNVERIFIED AND IMPORTANT: is `target = flowUsd` the right target at all?** It is a DEMAND proxy
(the flow EWMA), not a value-balance target. E54 has a derivation for this; **it has not been read by
anyone who then re-checked it.** If the target is wrong, every q in the system is wrong. *Check:* read
E54's derivation in `SwapLib.sol` around `sellSkew`, then ask whether a range at "correct" composition
but low flow reads as scarce.

✅ **ANSWERED 2026-08-28, AND MORE SHARPLY THAN THE CHECK ASKS — FROM THE SIGNATURE, NOT A FIXTURE.**
```solidity
function skewWad(uint poolVolUsd, uint flowUsd, uint sigmaSqWad, Risk memory rk, uint drainUsd6)
```
**There is no USD-side quantity in it.** `poolVolUsd` is `_skewBasis = POOLED()·base/1e30` — the
VOLATILE leg valued in dollars. `POOLED_USD`, the dollar leg, appears nowhere in the signature or the
body. ⇒ **COMPOSITION IS NOT AN INPUT TO THE SKEW.** The question "does a range at correct composition
but low flow read as scarce?" has no mechanism behind it in either direction: **the skew cannot see
composition at all.**
⇒ **What it actually prices is DEMAND AGAINST VOLATILE DEPTH:** scarce iff `flowUsd > inv1`, where
`inv1 = poolVolUsd − drainUsd6`. So a range whose volatile:USD ratio is badly wrong is quoted
**exactly as cheaply** as a perfectly balanced one, provided flow is low — which is precisely the
state a refill is supposed to correct.
🔴 **THAT IS THE FINDING FOR THIS FILE'S §1 QUESTION.** §3 already establishes restoration is *not
deterred* (a swap ending at/above target is charged zero on both legs) but *not rewarded*. Add this:
**the skew also does not PENALISE the imbalance it is meant to signal.** An imbalanced, low-flow range
is cheap to drain further. So "unaided restoration" gets no pull from the pricing layer in either
direction — there is nothing to arbitrage toward.
⚠️ **AND A THIRD ROUTE TO A VACUOUS SKEW READING FALLS OUT** (see SPRINT §E306): `skewWad` opens
`if (target == 0) return _maxWellSkew(σ², rk)`, which is SIZE-INDEPENDENT, and on ETH
(`spliceFloor == 0`) that is **ZERO**. **Measured from the production entry: an unseeded ETH range
quotes `AUX.wellSkew(...) == 0` at every size.** A range with real depth and real variance but no
flow prices at nothing.

---

## 4. The measurement — how far it got and exactly where it stopped

**Fixture: `evm/test/RestoreProfitability.t.sol`, committed `d8d1e45`. Runs green. Its RESULT is not
usable yet and the file says so in its own output.**

✅ **It reaches the state now** (this was the hard part and it silently failed twice before):
seed 400 ETH, drain in 40k steps until `inv < target` —
`inv 749,746 → 350,794 usd6` against `target 389,586`, and `wellSkew` goes `0 → 4,298,992` (WAD).
The scarce leg is live and observable.

⛔ **Two errors of mine were found inside this fixture; both are recorded in-file so they are not
repeated.** (1) **Direction inverted** — a stable→volatile BUY *drains* the range (it hands out ETH,
`inv` FALLS); I had every comment backwards. (2) **A zero skew reading that was the flush branch, not
an absent premium** — `target = flowEwmaUsd` GROWS with the very volume used to drive the drain, so
`inv >= target` held throughout and the fixture never entered the state it was measuring. It now logs
`inv`/`target` and exits INCONCLUSIVE rather than printing a number from a state it never reached.

🔴 **WHERE IT STOPS, AND THIS IS THE HANDOFF POINT:**
the restoring sell **succeeds**, the input **is consumed** (`WETH left = 0`), and the restorer
receives **ZERO** — measured across EVERY basket stable AND QUID, not just one guessed token.
**20 ETH went in; nothing came back in the same transaction.**

✅ **MEASURED 2026-08-05 — THIS IS NO LONGER A HYPOTHESIS, AND IT IS NOT "ASYNC SETTLEMENT".**
I first guessed async/obligation settlement by analogy with the BTC leg. **That guess was not
supported.** Three runs of the same fixture, varying ONLY `minOut`:

| `minOut` | outcome | what it proves |
|---|---|---|
| `0` | passes, delivers 0 | nothing — zero-delivery is INVISIBLE at minOut 0 |
| `0.9 × oracle` | **reverts `SlippageMaxS()`** | the swap's INTERNAL computed delivery is **< 90% of oracle** |
| `1` | **passes**, still delivers 0 | that internal delivery is **>= 1** |

**So the swap's own accounting says a non-zero amount was delivered, while the recipient's balances
across EVERY basket stable AND QUID say zero arrived.** Internal record and actual receipt disagree.

🔗 **THIS IS ALREADY A KNOWN FINDING — `BUILD-QUEUE-AND-107.md:1128`, S16 (`minOut=0` SILENT-LOSS):**
*"anvil e2e proved a swap consumed 1000 USDC + delivered 0 (status 1, NO revert because minOut=0)"*.
The restore path reproduces S16 exactly. **My fixture passed `minOut = 0` and so did the earlier
E69 runs, which is why two passes reported "zero edge" when the real state was "zero delivery".**

⚠️ **CONSEQUENCE FOR THIS FILE'S CENTRAL QUESTION: restoration is not merely UNPROFITABLE, it may be
BROKEN.** You cannot measure the edge on a path that consumes input and delivers nothing. **Fix or
explain the delivery gap BEFORE any pricing work here — a bps figure computed over a broken path is
worse than no figure.**

❓ **STILL UNKNOWN: where the proceeds go.** Candidates: a claim/obligation the restorer must redeem
separately, a stable outside `AUX.getStables()`, or genuine loss. *Check:* re-run with `-vvvv` and
read the ERC20 Transfer logs — that identifies the destination address directly and ends the guessing.

### 4a. The next concrete steps, in order

1. **Trace the ETH sell's settlement.** Entry is `swapToBody` (`SwapLib.sol:368`) → `_consumeVolInput`
   (`:527`) → `_finishSwap` (`:485`). Determine whether `_finishSwap` transfers to `r.recipient` or
   records a claim. **Run the fixture with `-vvvv` and read the actual transfer log** — do not infer
   it from the source alone; that is how the direction error above survived two passes.
2. **If it is a claim:** find the function that redeems it, call it in the fixture, and measure value
   received THERE.
3. **If it is a bug:** that is a far more serious finding than the pricing question and it outranks
   everything else in this file.
4. **Only then** compute `edge_bps = (received − size×oracle) / (size×oracle) × 10_000`. **The SIGN is
   the whole result.** Magnitude matters only if the sign is positive.

⚠️ **Do not quote an edge from this fixture before step 2 or 3 resolves.** A zero from a broken payout
path and a genuine zero edge print the identical line — the control fails, which is exactly
CLAUDE.md's *"would this measurement look the same if I were wrong?"*

### 4b. Why the blocker matters even before the bps is known

**An arbitrageur that cannot receive proceeds atomically cannot arb.** If restoration settles
asynchronously, the external-arb path is blocked on MECHANICS before pricing is even reached. That
would support "the executor must be us" on grounds independent of any pricing argument — but it is
downstream of step 1, so it is a ❓ until then.

---

## 5. The Rust side — what exists, what it does, what it is not ✅

⛔ **I twice said "there is refill/JIT machinery in Rust but it is not wired." BOTH HALVES WERE WRONG.**
Recorded because the shape of the error matters: I grepped `JIT` and `flash`, found nothing, and
asserted absence — after having already found the relevant code earlier in the same conversation.

| module | what it actually is | wired? |
|---|---|---|
| `quid-hop/src/rebalancer.rs` | **Lightning channel liquidity** — splices on-chain BTC into the hop↔LP channel when `next_outbound_htlc_limit_msat` falls below the per-swap ceiling. Its "imbalance" is CHANNEL OUTBOUND DIRECTION, an unrelated quantity from the range's volatile:USD composition. | ✅ live — `rebalance_capacity_tick` at `quid-bridge/src/vault.rs:665`, PHASE C of `run_vault_open_orchestrator` |
| `quid-bridge/src/lev_keeper.rs` | **THE RELEVANT PRIOR ART.** `compound_pays_for_itself(pending, gas_price) → pending/2 >= gas_price × COMPOUND_GAS` at `:280`. Its own comment: *"This is what makes the keeper subsidy-free."* | ✅ live — called at `:433` |
| JIT, anywhere in Rust | **does not exist** — no match in `quid-hop/src` or `quid-bridge/src` | — |

### 5a. Why `lev_keeper` changes the design, and it is the most useful thing in this file

Three properties, all read from the source:

1. **The tip is capped at BOTH `gasprice × COMPOUND_GAS` AND half the harvest**, so the contract
   structurally cannot overpay the cranker.
2. **Deferral is free and self-improving** — *"the fee stays pending and folds in later — a bigger
   crank, or when the LP acts."* A skip is not a failure; the accrual grows and the work becomes MORE
   economic over time.
3. **It is a GATE, not a GUARANTEE.**

**(3) retires a blocker I had wrongly imposed.** I gated the refill on proving
`premium collected >= repair cost` globally — a claim that is hard to establish and probably FALSE in
some states, which would have stalled the work or pushed it toward a subsidy. **The pattern needs no
such proof:** gate each repair on `skewPremiumCum/2 >= gasprice × REPAIR_GAS` and DEFER when it does
not clear. Subsequent imbalancers keep accruing premium until it does.

This is also why the owner's *"why should it need funding at all?"* is right: it is **pre-funded** by
the premium already taken from whoever caused the imbalance — never new capital, never basket dollars.

⚠️ **INHERITED HAZARD, ALREADY BITTEN ONCE (E46).** `COMPOUND_GAS` drifted out of sync with its
Solidity twin (140k vs 200k). Every LP whose `pending/2` fell in the gap passed the gate and was tipped
BELOW actual cost — **a silent subsidy**. Any `REPAIR_GAS` constant must be kept in sync with its
Solidity counterpart and **that sync must be TESTED, not commented.**

---

## 6. Scope boundaries — three things that are NOT this file

- **JIT depth** is a separate mechanism (flash-and-unwind within one tx to serve a fill) and has its
  own spec, `JIT-DEPTH-GUARANTEE.md`. Conflating it with durable refill is part of why the 2026-08-04
  thread went in circles. ❓ The JIT-ratio hypothesis is untested.
- **The skew formula** is being handled separately (E68 landed at `ca4d26e`; the κ=1000× structural
  leak and the remaining constants are open there, not here).
- ❓ **OPEN 17 (swap/redeem parity)** gates how much any of this matters: *if a drainer can simply
  redeem instead of swapping, the skew's magnitude is moot and the whole exercise re-prices a path
  nobody is forced to take.* ❓ **OPEN 14 (cross-asset coupling)** and the WETH borrow rate are also
  untested. **None of these have been checked.**

---

## 7. If you read only one thing

The fixture exists and reaches the right state. It stops at one unknown: **where do the ETH sell's
proceeds go?** Answer that (§4a step 1, with `-vvvv`, reading the transfer log rather than the source)
and the profitability question resolves immediately after. Everything else here is context for
interpreting that number once you have it — and §5a is the design you probably want regardless of how
it comes out.
