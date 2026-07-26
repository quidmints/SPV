# Audit TODO — surviving open / residual items

> **Pruned 2026-07-20.** The bulk of this ledger (rounding audit §1, immature-redeem drain §1c,
> modLP desync §2, vault-health single-key §4, backing-invariant §6, ether.fi offramp §7/§7b,
> openChannel replay §7, cross-chain containment §8, the LDK/P2WSH close model §9/§9b, and the
> §10 hop-swap vector sweep) has been **verified-resolved against the current tree** and removed.
> Confirming evidence (code + memory audit-pass entries):
>
> - **Governance ownership handoff (was HIGH):** `DeployL1_s` now **renounces** every admin key —
>   `Basket`→`Aux`→ownerless; `setBurnable`/`burnable` and the LINK maturity-bypass were **removed**
>   (pass #3); the only residual is the Link handoff below.
> - **Vault-health single-key `onReport` (was CONFIRMED HIGH):** the `vaultWatcher`/`onReport`
>   forwarder path is **RETIRED** — vault health is now permissionless on-chain via
>   `Aux.pokeVaultHealth` + `setVaultHealth(vault, blocked)` (bool only; the value-moving graded
>   haircut/`evac` was deleted). No off-chain key to compromise. (memory [[project-quid-cre-flow-sensor]])
> - **External-oracle cross-check (RISK-1):** `assetPriceFeed` (Chainlink ETH/USD + WBTC/USD) is
>   pinned-once and `getTWAPforAsset`/`twapAnchorBody` now **reverts on deviation** vs the internal
>   TWAP (`Aux.sol:203-215`). The internal-only-oracle manipulation gap is closed (also resolves the
>   MED "internal-only BTC TWAP").
> - **§10#2 `recordClose` over-mint (was CONFIRMED HIGH):** clamped (`deliveredSlice ≤ netDel`,
>   `claim6 ≤ swapUsdBtc`) + `checkBacking()` on the close path. (memory [[feedback-quid-only-minted-against-basket-dollars]])
> - **§10#1 swap-OUT non-atomicity:** the N-conf **burn-finality gate** `evm_final` is built + tested
>   (`quid-hop/src/swap.rs:77`, `finality_gate`); the on-chain swap-out rail (`deliverSwapOutOnchain`
>   / `SwapOutRequestedOnchain` / reversal via `settleSwapIn`) settles proceeds directly — the demo
>   pay-first shape is gone. (memory [[project-quid-swapout-lightning-gap]], [[project-quid-btc-swapin-atomicity-aave-cap]])
> - **Depeg par-exit (Finding 3):** `FeeLib.liveDepegBps` live-feed + `DepegCadence.t.sol`. **FeeLib
>   fee-drop & immature-redeem drain:** fixed. **BTC-leg fee model (§11):** resolved as
>   fee-into-close (#69 — hop-funded fee splice + `settleBtcFeesOwed`, keeping `pooled ≡ real sats`).
> - **BTC-channel model (§8/§9/§9b):** the whole P2WSH/`forceCloseByLP`/CLTV-refund analysis is
>   **superseded by taproot** — see `TAPROOT-CHANNELS-BUILD-SPEC.md` (M0–M9 + §10 audit + M11).
>
> Status legend: 🔴 not audited · 🟡 reviewed, not proven · 🟢 audited/verified.

---

## Still open (actionable)

- 🟠 **Link ownership → multisig/timelock before mainnet (deploy step).** `DeployL1_s` renounces
  `Aux`/`Basket`, but `Link` stays **deployer-owned** (it has the runtime owner-fns:
  `setForwarder`, `onGovernanceReport`). For production the operator must `transferOwnership(Link)`
  to a multisig/timelock. Known-but-unshipped; a pre-mainnet ops gate, not a code change.

- 🟡 **`Link.onGovernanceReport` arbitrary-call — latent, privilege-gated.** LINK can issue
  arbitrary whitelisted calls via a governance report (DON-forwarder gated). The LINK
  maturity-skip burner was removed (pass #3), but the arbitrary-call surface remains a latent
  foot-gun tied to the Link owner/forwarder trust above. (memory [[project-quid-cre-feed-trust-surface]])

- 🟡 **`settleSwapIn` not `nonReentrant` (LOW, defense-in-depth).** Replay-safe (`swapInUsed` set
  before the external call) + CEI-clean + `hopNode`-gated ⇒ not externally reachable, but adding
  `nonReentrant` would restore the "outer entry holds the lock" invariant for hop-forwarded
  named-stable tokens. No deadlock risk. Free hardening.

- ⚠️ **RISK-2 (by-design, watch) — bootstrap-year forward-yield over-mint.** The 1:1 cap is skipped
  for `currentMonth() < 12`; `avgYield` (which the forward-yield mint keys off) is grindable via a
  4626 share-price held past the averaging horizon. Accepted cold-start tradeoff; maturity-lock
  contains redeemability. Watch alongside the §6 backing invariant.

- 🧹 **Cleanup / dedup backlog (verify still applicable before acting).** Candidate dead code:
  `imports/Interfaces.sol` ICourt, `Basket.deployed`, `Aux.ghoBalance()`+IAux decl,
  `Aux.pathCount()`/`getPathEncoded()`, `BTCChannels.RefundTimelockNotElapsed`, unused consts
  (`Aux.SOURCE_MIN_OUT_BPS`/`BPS_DENOM`, `Vogue.RAY`, `BTCChannels.SELF_REFUND_MIN_SECS`), stale
  `forceCloseByLP` in `spa/abi.ts`. Dedup: `addLiq`/`_addLiqChannel` surplus-sizing → shared
  helper; `(POOLED_USD_ETH+POOLED_USD_BTC)*1e12` (≈9 sites) → `Core.committedUsd18()`;
  `_transferShares` inline bookmark → reuse `_refreshBookmarks`. (Some may already be removed by
  the taproot cleanup — re-verify no readers before deleting.)

- 🟡 **`repack` `myLiquidity` trusted-arg (upgrade to 🟢 with a test).** POOLED desync is
  structurally safe (mutated only from realized V4 `BalanceDelta`), but `repack`'s caller-supplied
  `myLiquidity` (onlyUs, from `poolStats`) could under-count if stale. Within the Vogue keeper
  trust boundary; add a `poolStats`-vs-arg assertion + a POOLED-equals-realized invariant test to
  close it out.

## Accepted / trust-bounded residuals (documented, won't-fix in code)

- **§9a `recordClose` co-signed STALE close.** The only recency proxy is `locktime==0`
  (co-signed vs unilateral, NOT current vs stale); a stale split both parties sign passes with zero
  EVM detection. LDK/taproot justice punishes only *unilateral* revoked broadcasts. `finalBalance`
  is **fully hop-trusted** here (same trust class as `settleSwapIn`) — documented, not coded.
- **RISK-3 cross-LP close fairness.** A too-low `finalBalanceSats` lets one closing LP over-attribute
  the shared `POOLED_BTC` proceeds. Solvency is protected (§10#2 clamp — no over-mint); *fairness* is
  inherent to the pooled model (per-LP delivery is only attributable at close via trusted
  `finalBalanceSats`). A real fix needs per-LP on-chain delivery tracking the pooled model doesn't
  support. Accepted.
- **BTC-share median staleness.** `WEIGHTS_btc`/`SUM_btc` aren't resynced when a voter's QUI matures
  out of the immature window (no transfer fires) → median drifts. `btcShareBps` is a **sizing cap
  only** (no value lever) and `_median` reads `supply` live, so drift is transient/self-correcting
  on churn. Accepted.

## Process
- CRE wasm's off-chain workflow only *proposes*; the on-chain receivers (`Link.onReport`,
  `Aux.pokeVaultHealth`/`setVaultHealth`) are the security surface and are tested. Audit the
  on-chain receivers as if the off-chain layer is hostile.
