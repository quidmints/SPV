# Discussion digest — the AGREED design per item (consult BEFORE implementing anything)

Recovered from the full pre-compaction transcript (2026-07-21). **Read the relevant entry here before touching any
item in BUILD-QUEUE-AND-107.md.** Purpose: honor what we actually agreed, never re-derive from code and over-correct.
`L<n>` = session JSONL line.

## ★ DECAY / baseRate — the correction that triggered this digest
TWO separate, INTENTIONALLY un-tied decay registers — do NOT unify them:
- **`FLOW_DECAY` = 48h half-life** (`Core:156`, `0.5^(1/2880)`) — drives the well's swap-flow EWMA (inventory-skew target). Comment is explicit: "UN-TIED from Aux BR_DECAY (12h) — the flow target wants a wider window." Keep 48h.
- **`BR_DECAY` = 12h half-life** (`Aux._touchBaseRate`→`FeeLib.touchBaseRate`) — the outflow-fee baseRate. Already CLAMPED at MAX_FEE-equiv (commit `582f708`) so decay matches docs; saturates the 30bps cap after ~0.6% of supply (largely inert). The 12h is intentional + doc-matched, NOT a stale bug.
- **The real decay ask** = ADAPTIVE decay + a **manipulation floor = one `uint` minimum half-life** the adaptive decay can never fall below (L563 "it's just a constant… One uint. Nothing more"; L7035). For the congestion/refill-bonus path: "make the bonus decay/cap under congestion so it's never worth warring when blockspace is scarce." Part of the Echidna stress-block work. Floor value not yet specified.
- **DO NOT** resync 48h↔12h (over-correction trap). Decay work = leave both as-is + build the adaptive-with-floor register for the refill/congestion path.

## Cross-cutting USER CORRECTIONS (honor verbatim, do not re-derive)
1. **It IS a full 2×** (L3645/3648): assume the LP brought equal-value vBTC as the dollars.
2. **"THERE IS NO BORROW ONCE"** (L3751): the 2× fold is multi-hop deposit→borrow→swap; make it explicit in code.
3. **Verify venue claims against REAL venue contracts, not our comments** (L3918/3948): "check euler, not midnight/morphov2 comments."
4. **"there is no GOV"** (L3659): strip GOV/hook gating from `closeLevFor`; fix stale "no-ops till acquirer" comment.
5. **Acquirer decided-gone** (L280/287): it's regular non-band LPs / explicit non-LP swap-in. proceeds-repay de-lever is FINE; only freed-USD-as-new-band-depth is forbidden (#67). Check swap-in role absorbed before deleting.
6. **θ sizes the wrong risk-bearer** (L6636/6658): IL never touches backing; don't throttle refill as if minting covers IL. But KEEP `deltaTok` — reduce the clamp/rescale dance, not the variable. (θ-base fix = c48ea01, DONE.)
7. **"price will never 4x"** (L6062): within realistic moves 2× runs BELOW full IL-neutral — reconsider if the IL target earns its complexity; cross-check the YieldBasis vyper reference in the projects folder.
8. **"revert #102" was WRONG** (L586-605): the array widening IS the fix (done, uint[15], `9633064`). Don't revert.
9. **surplus is NOT withdrawable at will** (L838): only borrow-cost + QUI redemption. surplus = excess over redeemable-today matureBalance + de-band clawback from BOTH POOLED_USDs.
10. **manipulation floor is trivial** (L563): one uint, don't over-engineer.
11. **"Do not mention YB anywhere; remove '#107' from comments"** (L729).
12. **mint ≠ redeem valuation** (this session): mint over-mints at 1:1 (par); redeem values one basket share (min($1,solvent/mature)) to absorb the over-mint. illiquid is temporary (thaws over the forward tenor) — depositor path correctly excludes it. #9 was INVALID.

## Per-item AGREED (selected — the ones with real discussion)
- **#1 θ-base** ✅ DONE (c48ea01). Base θ on native locked sats, not vogueBTC. Keep deltaTok.
- **#4 CAPO — CONTESTED.** Pre-compaction the user asserted Aave-v4 aToken/index is manipulable "the same way" (L744-748) and CAPO must wrap EVERY 4626 leg + re-verify Aave-v4. **BUT my fork test (AaveV4DonationProbe) PROVED the DONATION vector is immune (0 wei on 500 WETH).** RECONCILE: donation-immune is empirically proven; the user may have meant a different vector (index/rate manipulation, or the weETH LST price oracle = true "CAPO"). Probe the index-manip vector before finalizing scope. sUSDe is the one balanceOf-inflatable stable leg (fork-proven 100%).
- **#5 committedUsd18 (F2)**: apply `min(debt, recordedBufUsd)` BUT preserve the deliberate committed-identity **3+4 coupling** (L694) — don't break it.
- **#9** INVALID (see correction 12). **#10** matureSupply — digest lists as agreed fix but NO explicit user ratification; residual doubt (total-claims basis) → hold, confirm intent.
- **#11 vote-median**: lazy-resync on month-advance (user L7110 directly asked). Keep hunting the stale-cache-from-non-hooked-change class.
- **#12/#13 #54 H1/H2**: compute delevUsd on REALIZED freedSats; guard debt-stable presence. Folds into venue-repay clamp-before-forward hardening.
- **#23 calcFeeL1 yield-axis, MAX_FEE=30bps** — INTENTIONAL friction (memory fee-baserate-design). Don't "fix."
- **surplus** (L838/852): borrow-cost + QUI redemption ONLY; remove other uses only after all-sides edge/attack check.
- **R1 short**: band-first→SOR-overflow hybrid was DELIBERATELY landed (b204da0). Real gap = `recordSkewPremium` (levered LP pays A-S skew premium on band-sold slice → passive LPs). Don't just rip out the band route.
- **de-lever-into-pairing** (L280/6787/946): proceeds-repay (#54) non-toxic & necessary; freed-USD-as-new-depth toxic (#67). User pushed "look from all sides — it's probably necessary."
- **POOLED_USD efficiency** (L554/759): drop sum-cap, committedUsd18 counts shared pool ONCE. Median stays btcShareBps cap. DECIDED AGAINST repurposing median for single-sided-LP fee split.
- **Refill-bonus** (L7035/185): eliminate the race (atomicity + JIT-internalize + fair continuous A-S price), not win it. Thin band ⇒ bonus MORE necessary, DON'T drop payRefillBonus. atomic-flash-close UNVERIFIED — prove owed settles in one call before building.
- **Directional long >2×** (L7137): symmetric long+short opt-in. 2×-hardwire branch (cap==5000→IL-hedge; else directional, keeper=liq-guard). Keeper policy adaptive by mode (YB vs directional, not mixed). Less-churny setting for directional.
- **mature_quid_usd → FIXED HAIRCUT** (L502/6787): no secondary market; hardcoded conservative haircut for emergency unmatured liquidity, never a quote. Build the haircut path (Rust + on-chain protect). BTC keeper hardcodes 0 today.
- **Acquirer**: remove trait/legs/stub; audit ALL live stubs (needed→fulfil fully, unneeded→delete).
- **#84 keeper union** (L220/494/759): ONE unified ETH+BTC loop (already spawned separately at daemon.rs:451; gap is unification not spawning).
- **cascadeDeleverMany BTC** (L212/3705): genuinely absent for BTC; build the batch (mirror ETH rebalanceMany/cascadeDelever).
- **#107 θ-μ (D3)**: reserve avgYield → band realized fee yield (L3875 "reuse the machinery"). Not landed.
- **2× fold math** (L3645/3751): multi-hop fold explicit in code; negative carry at low volume (LP eats it), self-funds at volume via fees; final borrowed leg can pick a best-yield venue ≠ borrow venue (L3677, confirm).
- **vBTC+USD→WBTC lever** (L3576/3599): LP stakes vBTC + brings USD → SOR to WBTC → lever; native borrow-against-vBTC when the vBTC market is liquid (efficiency), USD→WBTC always (robustness, #74). Router = either/or, NOT combine.
- **Black Thursday** (L3875): de-lever trigger reads fast/spot or venue liquidation oracle NOT lagging TWAP; PROTECT_MARGIN(15%,LevMath:206) > worst-case reaction+inclusion move. Latency = single block.
- **Overlay committed-equity ratio** (L3775): LP/keeper-settable 0.25–1×, default full (1×, WBTC covers IL).
- **Deploy/ownership** (L5714/6073/6095): ANGEL transferFrom→0 in one statement (ctor does it), renounce once, no _transferOwnership, deployer-checked only in DeployL1_s, drop lamboHeld, remove onERC721/onERC20Received from Aux, pretend-execute on fork; L2 deferred.
- **Keeper gas (#103)**: Vogue.compound 140k/200gwei; Rover 600k(~560k+7%); Rust lev_keeper.rs:266 COMPOUND_GAS=140_000 MIRRORS Vogue — change both in lockstep.
- **Puppeteer e2e** (L6363): front-end fuzz ALL paths (happy+unhappy, "no permutation we didn't do") BEFORE Slither/Echidna.
- **ERC-7201/diamond** DECIDED AGAINST (no gas win). **Codebase-doc generator**: prototype on ONE contract for sign-off, then tree-wide.
- **#108/#109/#110/#104** all UNBUILT. #104 double-pay = last open question. #109 primitive built (closeLevFor), inline wiring into Vogue._withdraw deferred.

**Open questions to put to the user (don't guess):** #10 matureSupply intent; #4 CAPO scope reconciliation (fork-immune vs asserted); skip-the-IL-target consequences; surplus other-uses removal; whether _withdraw should auto-delever on-chain (#109/#35).
