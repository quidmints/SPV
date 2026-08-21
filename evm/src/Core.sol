
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Aux} from "./Aux.sol";
import {Quid} from "./Quid.sol";
import {Vault} from "./Vault.sol";
import {Basket} from "./Basket.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {OracleLib, RING} from "./imports/OracleLib.sol";
import {USDC} from "./imports/Interfaces.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";



// §E5 — the shared per-band premium sink (rule 2: ONE declaration, in the canonical file).
import {ILevEquity, IBand} from "./imports/Interfaces.sol";
// §E21: IERC20Min had TWO declarations (here and imports/ILevVenue.sol). One home now.
import {IERC20Min} from "./imports/ILevVenue.sol";
import {QuidLib} from "./imports/QuidLib.sol";

// §BANDBACKING-FOLD — `interface IBandBacking` DELETED FROM HERE, and it was declared TWICE: once
// above and once in Interfaces.sol, which standing rule 2 forbids and which the note above that
// second copy warns about explicitly ("a duplicate interface surfaces as forge's `Error writing
// output JSON`, NOT as a redeclaration error"). Both copies go with the contract: the band now
// calls `AUX` directly, which Core already holds as a concrete type.

/// @dev Live total leverage debt (USD 1e18) of a pinned LevManager — the debt-funded buffer that
///      `committedUsd18` subtracts from in-range USD to recover the pure equity claim (buffer == debt).

/// @dev Live total GROSS levered collateral in NATIVE units — the LOCKED-INVENTORY basis for the well skew's
///      scarcity term. POOLED_{ETH,BTC} already carries the full 2× gross buffer as tokenless band depth, so the
///      deliverable native reservoir = poolVol − gross (subtracting DEBT, ~1×, would leave one equity leg of
///      phantom inventory in the scarcity signal). Names differ per manager, hence two interfaces.

/// @notice Two V4 pools (ETH/USD and BTC/USD) with INDEPENDENT USD
/// accounting. A swap in the ETH pool that inflates the ETH-side dollar
/// balance does NOT affect the BTC pool's dollars (and vice-versa). The
/// per-pool USD slice is bounded by a single safety invariant —
/// POOLED_USD + POOLED_USD ≤ current basket TVL — enforced
/// inline in _handleDelta on every USD add. BTC's share of the total is
/// demand-driven within that ≤TVL invariant (no separate allocation cap).
/// mockUSD_ETH and mockUSD_BTC stay as separate mocks because each pool
/// can have its own out-of-range positions (limit orders) — those are
/// not in POOLED_USD_{ETH,BTC} (which is the active in-range slice).
contract Core {

    /// Per-pool oracle rings — the engine now lives in OracleLib (delegatecall),
    /// so the structs come from there. The scalar trio is grouped per pool so
    /// the helpers take one `ObsState storage` ref (IS_BTC-dispatched via
    /// `_obsState`). These were never read externally; only POOLED_* getters
    /// (kept) are.
    /// §ISBTC-SPLIT — ONE RING PER INSTANCE, AND THE SELECTORS ARE GONE WITH THE SECOND COPY.
    /// This held BOTH bands' rings and picked between them on every access, so each deployed
    /// instance reserved TWO `Observation[65535]` arrays and used exactly one. The `obsState` /
    /// `observations` helpers existed only to make that choice; with one of each there is nothing to
    /// choose, so the fields are read directly.
    OracleLib.ObsState internal obsState;
    OracleLib.Observation[RING] internal observations;

    // §V4-CUT — `VANILLA_ETH`/`VANILLA_BTC` DELETED. Write-only: assembled at setup for a pool
    // that `initPool` stopped creating, then read by `_key()`, which had no callers.

    // §V4-CUT — `POOL_ID_VANILLA_*` DELETED. Their last external reader was the protocol-fee
    // monitor, retired with the fee switch we no longer touch; `_poolId()` is gone too.

    /// @notice In-range USD slice held against the ETH/USD pool. Sum of
    /// this plus POOLED_USD is the total in-range USD; out-of-range
    /// USD lives in mockUSD_ETH/mockUSD_BTC respectively.
    /// @notice §#12 — BASKET-SUPPLIED quoting depth (6-dec, shared across both bands). The split
    ///         #12 is named for: `POOLED_USD_*` track what is IN each CURVE (they move on every
    ///         swap); this tracks what the BASKET actually CONTRIBUTED (it moves ONLY when the
    ///         basket adds or removes depth via `addLiq`/burn — never on a swap).
    ///         `committedUsd18` is derived from THIS, so the backing gate stops counting an LP's
    ///         sale proceeds as a basket commitment.
    /// §ISBTC-SPLIT — one instance, one asset. Was basketUsd/basketUsd.
    uint public basketUsd;
    uint public POOLED_USD;
    /// @notice In-range USD slice held against the BTC/USD pool.
    uint public POOLED;

    /// @notice Committed BASKET USD (both pools, 18-dec) — the single `committed ≤ TVL` term + LP surplus sizing.
    /// The full-2× band holds the LP's equity AND a debt-funded buffer in ONE `POOLED_USD_*` slice (no separate
    /// counter). The buffer's USD equals the LP's OWN debt exactly (gross−net = debt/px ⇒ bufUsd = debt), so the
    /// pure equity claim is `in-range USD − leverage debt`, with the debt read LIVE from the pinned LevManagers.
    /// Live (not a stale segregation counter) so accrued borrow interest shrinks committed the instant it accrues —
    /// correctly, because the levered LP's real equity is collateral−debt and DOES shrink with interest (the lost
    /// value went to the venue, not the basket, so total claims stay ≤ backing). Reading debt live keeps the
    /// "committed == in-range USD − live debt" fold identity drift-free BY CONSTRUCTION (no counter to desync —
    /// see BufferSwapDrain.t.sol). Floored PER BAND so ETH debt never eats BTC equity. Centralized ×1e12 scale.
    /// §#12: committed is the BASKET's contribution net of live leverage debt — NOT the curve
    /// inventory. A swap moves `POOLED_USD_*` but not `basketUsd`, so it no longer moves committed.
    /// §ISBTC-SPLIT — THE SUM MOVED TO THE SHARED ACCOUNTANT, AND IT HAD TO.
    /// This was `_bandEquityUsd18(false) + _bandEquityUsd18(true)` — one contract adding up both
    /// bands because one contract WAS both bands. With two instances neither can see the other, and
    /// two instances each gating against the FULL TVL would DOUBLE-COMMIT the same backing without
    /// reverting. `Aux` holds the joint figure; each instance pushes only its own.
    function committedUsd18() public view returns (uint) {
        return AUX.committedTotal();
    }

    /// @notice Push THIS instance's equity to the shared accountant. PUSH, not pull, and at the
    ///         moment the equity changes — a sum of per-band figures is only meaningful if every
    ///         term is on the same clock, which is §A.16b one level up. A lazy pull would let the
    ///         bound pass against a total that was never simultaneously true.
    /// @dev    §BANDBACKING-FOLD — reports to `AUX` DIRECTLY. The band talks to Aux; there is no
    ///         intermediary contract holding two numbers on their behalf.
    function _reportEquity() internal { AUX.report(_bandEquityUsd18()); }

    /// @dev One pool's equity USD (18-dec): its in-range USD less that pool's live leverage debt, floored at 0.
    function _bandEquityUsd18() internal view returns (uint) {
        // §E60 — COUNT OUT MOCK THAT HAS LEFT THE ALLOWED HOLDER SET. Once the v4 protocol fee is
        // targeted at our key AND collected, the cut is transferred to a recipient outside
        // {poolManager, Core}: MEASURED $120 of mockUSD on $120,000 of volume, up to 10 bps of
        // throughput indefinitely. Those dollars are gone from the band but `basketUsd*` still
        // claims them, so every LP claim and the backing gate would price against backing that is
        // no longer there. Subtracting the dust is what makes "committed" mean committed.
        // §E253-mock — THE DUST SUBTRACTION IS DELETED, AND IT HAD BEEN A NO-OP SINCE THE v4 CUT.
        // It subtracted `mockUSD.totalSupply() - balanceOf(Core)`: value stranded IN THE POOLMANAGER
        // during a v4 swap. There is no PoolManager, nothing ever mints the mocks (their `mint` is
        // gated to Core and Core never calls it), so `totalSupply` is permanently 0 and the term was
        // `base6 - 0` on every call. The comment above it described a REAL measurement ($120 of
        // mockUSD on $120,000 of volume) of a mechanism that no longer exists.
        uint pooled18 = basketUsd * 1e12;   // §#12: BASKET contribution
        uint debt18 = _levDebtUsd18();
        return pooled18 > debt18 ? pooled18 - debt18 : 0;
    }

    /// @notice THIS instance's NET equity USD (18-dec). Was `btcBandEquityUsd18`, which existed so
    ///         `SwapLib._sharedScarcityWad` could subtract one band from the total to learn what the
    ///         OTHER holds. That subtraction now lives in `BandBacking.otherThan`, derived from the
    ///         SAME total the solvency bound uses — so the amplifier and the gate cannot disagree
    ///         about the denominator, which two independent computations eventually would.
    function bandEquityUsd18() external view returns (uint) { return _bandEquityUsd18(); }

    /// @dev That pool's total leverage debt (18-dec), read live from the pinned LevManager (0 if unset). The
    ///      The BTC manager (`LEV_MANAGER`) lives on the Vault; the ETH one lives on the ETH-VENUE
    ///      contract, reached via `BAND.EV()` — the same indirection `QuidLib` uses.
    ///      FAIL-SAFE: `totalDebtUsd` iterates the open-LP book (external venue reads); a revert there must NOT
    ///      brick `committedUsd18` (the backing gate on every swap/mint/redeem). On failure we subtract 0 debt,
    ///      which only RAISES committed ⇒ a STRICTER gate + LOWER redeemable — conservative, never over-issue.
    ///      Mirrors `bandETH`'s try/catch over the same LevManager reads.
    function _levDebtUsd18() internal view returns (uint) {
        if (address(BTCVAULT) == address(0)) return 0;
        address mgr = BAND.levManager();
        if (mgr == address(0)) return 0;
        try ILevEquity(mgr).totalDebtUsd() returns (uint d) { return d; } catch { return 0; }
    }


    /// @notice Net BTC the pool has delivered to swap-out buyers, in sats —
    /// `+= sats` on a USD→BTC swap (BTC sold out), `−= sats` on a BTC→USD
    /// swap-in (refill), `−= delivered` when an LP closes (settled out). The
    /// @notice Sum of UNDELIVERED on-chain swap-out obligations, in 6-dec USD.
    /// `+= usd` at requestSwapOutOnchain (the swapper's payment, owed to whichever
    /// LP delivers), `-= usd` at deliverSwapOutOnchain (paid exact to that LP) or
    /// at settleSwapIn reversal (obligation cancelled). This is the ONLY
    /// proceeds-side counter: per-channel exit P&L settles EXACTLY at delivery
    /// (the recorded per-obligation usd), so there is no global delivered/proceeds
    /// pool, no rate, and no clamp — and thus no cross-channel proceeds race.
    /// It exists solely as the swap-in solvency-gate denominator: a swap-in may
    /// draw at most the FREE reserve `POOLED_USD − pendingSwapOutUsd`, so
    /// undelivered proceeds owed to LPs can never be drained out from under them.
    /// INVARIANT: every `+= x` is matched by a `-= x` on BOTH the deliver and the
    /// reverse path, and `x` never exceeds the USD actually pulled into the pool.
    uint public pendingSwapOutUsd;

    // ─────────────────────────────────────────────────────────────────────
    // Adaptive inventory-skew inputs — the swap-flow EWMA.
    //
    // The skew curve (SwapLib.skewWad) prices scarce volatile inventory UP on the
    // swap-OUT (well) path, re-admitting the BENIGN inventory-rebalancing arber that
    // oracle-only pricing killed alongside toxic LVR (a swap must never price off the oracle alone:
    // that is a free option to the taker and the LVR it feeds is exactly what the band fee exists to price).
    // Its adaptive TARGET = "the buffer needed to serve normal flow" is an EWMA of
    // two-sided swap volume — decayed exactly like the Aux.BaseRate register (same
    // FeeLib.decPow half-life), NO governance constant, the market's own volume sets
    // it. Bumped by every swap's USD notional in _handleSwap (band + well both route
    // through it). Read DECAYED via flowEwmaUsd(). One register per pool.
    struct Flow { uint128 vol; uint64 ts; }   // vol: 6-dec USD EWMA · ts: last touch
    Flow internal _flow;   // §ISBTC-SPLIT: one per instance
    /// §SLOP — A 30-LINE DOC BLOCK STOOD HERE FOR STATE THAT NO LONGER EXISTS, and its last four
    /// lines were attached to the WRONG CONSTANT. Removed, with what it actually said recorded once:
    ///   • `§E55 — the SLOW half of the adaptive flow estimate`: described `_flowSlowBTC`/
    ///     `_flowSlowETH`. Both are DELETED, and so is `FLOW_SLOW_N`, the ratio constant the text
    ///     names (zero live references, verified comments-stripped).
    ///   • `DEAD SLOTS, DELIBERATELY RETAINED` (twice): the slow-leg and realized-LVR padding, kept
    ///     because `Core`'s state ORDER IS LOAD-BEARING. That retention was RECLAIMED 2026-08-16
    ///     once both absolute readers were shown gone -- so the block argued for keeping something
    ///     that had already been removed, in the same breath as recording its removal.
    ///   • `@dev The slow register's half-life as a MULTIPLE of the fast one (48h x 7 ~ 14 days)`,
    ///     sitting DIRECTLY ABOVE `FLOW_DECAY`. It documented `FLOW_SLOW_N`, so a reader took it as
    ///     `FLOW_DECAY`'s doc and would conclude the 48h constant is a 14-day one.
    ///   • `flowEwmaUsd` takes the MIN of the two` -- FALSE. `flowEwmaUsd()` returns
    ///     `_decayed(_flow)`; there is no second leg to take a min against.
    /// WHY THIS MATTERED BEYOND TIDINESS: `DrainAtomicity._flowTs` called slot 263 "formerly
    /// `_flowSlow*`" ON THE STRENGTH OF THIS BLOCK. It is `_prem`, the premium EWMA. A stale
    /// declaration doc propagated into a test's belief about which register it was pinning, and a
    /// raw-slot read that names the wrong variable still passes.
    /// ⇒ §E55's REAL conclusion, which IS worth keeping: the `min(fast, slow)` could never bind.
    /// `_bumpFlow` added the full notional to BOTH legs and these are decaying SUMS, so a slower
    /// decay retains MORE ⇒ `slow >= fast` at every ratio ⇒ the min was identically the fast leg.
    /// That is why one register is correct, and why no third decay constant is needed.
    uint internal constant FLOW_DECAY   = 999759352855809024; // per-min → 48h half-life (0.5^(1/2880)). The well's flow-EWMA / inventory-skew target wants a wide, manipulation-resistant memory. (The Aux redeem-fee `baseRate`, a separate 12h register, was REMOVED — QU!D has no peg-arb loop; this 48h flow decay is unrelated and stays.)
    uint internal constant FLOW_MAX_MIN = 525600000;          // decay-exponent cap (Liquity)

    /// @notice Retained band market-making premium per pool, as a DECAYED EWMA (6-dec USD) — the
    ///         θ NUMERATOR source (#107/D3). Deliberately the SAME `Flow` struct, the SAME
    ///         `FLOW_DECAY` (48h) and the SAME read/bump helpers as the swap-volume register:
    ///         premium accrues on exactly the same swap events and wants exactly the same memory,
    ///         so a THIRD decay constant would be an unjustified magic number. (This does NOT
    ///         re-tie the 48h flow window to the 12h `BR_DECAY` — those stay un-tied by design;
    ///         this is a SECOND consumer of the 48h window, not a merge of two windows.)
    Flow internal _prem;   // §ISBTC-SPLIT: one per instance

    /// @dev ONE decay implementation, shared by both EWMA registers (was duplicated between
    ///      `_bumpFlow` and `flowEwmaUsd`). Decay the stored value over elapsed whole minutes.
    function _decayed(Flow storage f) internal view returns (uint) {
        return _decayedBy(f, 1);
    }

    /// @dev `slowN`-fold slower decay: the SAME curve evaluated over `mins/slowN`, so the half-life
    ///      is `slowN ×` the fast one. One decay implementation, one constant, an integer ratio.
    function _decayedBy(Flow storage f, uint slowN) internal view returns (uint) {
        if (f.ts == 0) return f.vol;
        uint mins = (block.timestamp - f.ts) / 60 / slowN;
        return Math.mulDiv(f.vol, FeeLib.decPow(FLOW_DECAY, mins, FLOW_MAX_MIN), 1e18);
    }

    /// @dev Decay-then-add into an EWMA register. Saturates at uint128 (unreachable in practice).
    function _bumpEwma(Flow storage f, uint usd6) internal {
        uint v = _decayed(f) + usd6;
        f.vol = v > type(uint128).max ? type(uint128).max : uint128(v);
        f.ts  = uint64(block.timestamp);
    }

    /// @notice Fold a swap's USD notional into this pool's flow EWMA. Called only from _handleSwap.
    function _bumpFlow(uint usd6) internal {
        _bumpEwma(_flow, usd6);
    }


    /// @notice This pool's decayed swap-flow EWMA (6-dec USD) — the adaptive
    ///         normal-flow buffer the skew target is built on. Pure decay of the stored
    ///         register to now; NO governance constant.
    /// §E55 — ADAPTIVE, AND THE ADAPTIVITY IS IN THE `min`, NOT IN A TUNED DECAY. A single fitted
    /// half-life is a guess: too fast and the estimator tracks the noise it was built to resist, too
    /// slow and it misses a regime change. Taking the MIN of a fast and a slow register is
    /// self-correcting in the direction that matters — when flow COLLAPSES the fast leg drops at
    /// once and we price the scarcity immediately (conservative); when flow SPIKES the slow leg
    /// lags, so **a transient burst is never mistaken for durable shed capacity** until it persists.
    /// It is also manipulation-resistant by construction: lifting this number requires sustaining
    /// fake flow across the SLOW window, not one block. (Same shape as `min-of-two-prices`.)
    function flowEwmaUsd() public view returns (uint) {
        return _decayed(_flow);
    }

    /// @notice This pool's decayed RETAINED-PREMIUM EWMA (6-dec USD) — the band's realized
    ///         market-making earnings over the trailing ~48h window. θ's numerator (#107/D3):
    ///         the compensation the band actually receives for bearing IL. Reserve `avgYield` is
    ///         deliberately NOT part of this — that number sizes how much QUI to mint up front and
    ///         has nothing to do with how big the band should be (user, 2026-07-26); the dollar leg
    ///         earns the reserve baseline whether it is banded or idle (`spec.md`), so reserve yield
    ///         is not marginal compensation for IL risk and must not inflate the risk budget.
    function premiumEwmaUsd() public view returns (uint) {
        return _decayed(_prem);
    }

    /// @notice Aggregate leverage claim on this pool (6-dec USD) — the well's
    ///         DISTINCT "leverage demand" signal. Levered LPs both lock current volatile
    ///         (shrinking deliverable inventory) AND will draw/return it (raising demand),
    ///         so it enters the skew scarcity on BOTH sides. Reuses the live
    ///         LevManager debt total already read for committedUsd18 — no new aggregate.
    function levClaimUsd6() public view returns (uint) {
        return _levDebtUsd18() / 1e12;
    }

    /// @notice This pool's aggregate levered GROSS collateral in NATIVE units (wei for ETH, sats for BTC), read
    ///         live from the pinned LevManager (0 if unset). The well skew's LOCKED-INVENTORY basis: POOLED_{ETH,
    ///         BTC} already pairs in the full 2× gross buffer as tokenless band depth, so the true deliverable
    ///         reservoir is `poolVol − gross`. Kept NATIVE (not USD) so SwapLib converts it with the SAME
    ///         `base`/1e30 scale it already applies to poolVol — one price, one unit. DISTINCT from the debt basis
    ///         (`levClaimUsd6`, ~1×), which stays on the demand/target side of the skew (the net-equity leg
    ///         self-heals via bounded de-lever, so only the debt leg is an uncovered forward claim on the reservoir).
    ///         FAIL-SAFE: a revert in the venue-iterating read must not brick the swap; on failure returns 0 (the
    ///         skew merely relaxes toward the base oracle curve — the pricing signal, not a hard backing gate).
    /// @notice This band's risk profile for the skew cap: the settlement-window fraction of a year
    ///         and the on-chain splice floor. Returned as a PAIR so `SwapLib` needs no asset flag.
    function riskParams() external view returns (uint confFracWad, uint spliceFloor) {
        return (CONF_FRAC, SPLICE);
    }

    function levGrossNative() public view returns (uint) {
        if (address(BTCVAULT) == address(0)) return 0;
        return BAND.levGrossNative();
    }

    /// @notice Annualized realized variance (WAD) of this pool's oracle — the well
    ///         skew's live-vol steepness input (steeper premium in higher vol, matching a
    ///         native-BTC MM's real cost). Thin pass to QuidLib (identical to Quid's own
    ///         `realizedVarianceWad`); exposed here so the skew reads ONE source for both
    ///         pools regardless of which band contract drives the swap. Fails-open to 0
    ///         (insufficient history) ⇒ no steepening, base convex curve still applies.
    /// @notice §E59 — annualized realized tick variance (WAD), read DIRECTLY from the observation
    ///         ring. Was a round trip (Core → QuidLib → back into Core) sampling `observe` on a
    ///         wall-clock grid; that grid was the bug — `observe` INTERPOLATES between stored points
    ///         and linear interpolation has zero second derivative, so any stretch quieter than the
    ///         sample interval measured EXACTLY 0 however far price moved. One hop now, one source.
    ///         **0 means UNKNOWN (too few real updates), NEVER "calm"** — `SwapLib._maxWellSkew`
    ///         charges the ceiling on it and theta fails open, and both readers agree on that.
    function realizedVarianceWad() external view returns (uint) {
        // 9 ring points → 8 returns.
        // §TICK-REMOVAL — THE 1e10 WENT WITH THE TICKS, AND THE UNITS ARE UNCHANGED. It was never
        // a tuning constant: a tick is 1 bp, so tick²→relative² is 1e-8 and WAD is 1e18, giving
        // exactly 1e-8 × 1e18 = 1e10. `ringVariance` now returns (WAD relative return)² per second,
        // i.e. relative²·1e36, so ONE division by 1e18 lands on WAD relative variance — same
        // magnitude, same meaning ⇒ Γ (`MAX_WELL_SKEW`) needs NO recalibration.
        uint v = Math.mulDiv(OracleLib.ringVariance(observations, obsState, 9),
                            31536000, 1e18);          // per-sec → annualized
        // §E88 — ZERO IS NOW RESERVED FOR "UNMEASURED", AND ONLY THAT.
        //
        // It used to mean TWO things at once: *"the ring is unpopulated, we have not measured"* AND
        // *"we measured, and it is genuinely zero"*. Downstream (`skewWad`/`sellSkew`) reads `σ² == 0`
        // as UNMEASURED and conservatively charges the ceiling — correct for the first meaning,
        // WRONG for the second, because a genuinely calm market has genuinely low adverse selection
        // and should be charged accordingly, not the 3% maximum.
        //   No threshold on σ² can separate them: it is an IDENTIFIABILITY problem, not a tuning one
        //   — the same one E56 hit when a zero flow-EWMA could not tell a DEAD pool from a NEW one.
        //   The fix there was a SECOND, independent signal already in storage, and it is the same
        //   here: the ring's own `cardinality` says whether we have looked, which no value of the
        //   variance itself can. A populated ring that computes a true zero returns 1 wei, so the
        //   two states are distinguishable downstream at ZERO extra storage, calls, or gas on the
        //   money path, and the E59 sentinel keeps its exact meaning for the case it was written for.
        if (v == 0 && obsState.cardinality >= 2) return 1;
        return v;
    }

    /// @notice (well) Cumulative scarcity-premium the skew has RETAINED as backing, per
    ///         pool — the withheld fraction of a swap-out's USD when the pool is BTC/ETH-scarce
    ///         (the swapper pays above oracle for scarce inventory; the difference is
    ///         retained for LPs). ⚠️ HISTORICAL NOTE: this said the premium "STAYS in the basket as pure LP
    ///         backing (NAV)" — true pre-§E5, and the source of the §E42 leak. §E5 made it an LP CLAIM
    ///         (`creditSkewPremium`), and §E42-netting moves its BACKING into the POOLED mirror to match, so
    ///         it is no longer quoted as QU!D redeemability. Tracked + evented here so the LP-retained skew profit is
    ///         auditable P&L — the running total the fleet's self-funding JIT refill captures FOR the LPs.
    ///         (The old swapper-facing refill BONUS was REMOVED: refill is a self-funding fleet op — JIT
    ///         Morpho-flash BTC → creditSwapIn → repay, gas via #87 — so paying a separate bonus to the refiller
    ///         was redundant; the premium accrues to LPs directly, no payout.)
    ///         Units = the swap-out's USD driving amount for that pool (6-dec).
    uint public skewPremium;
    event SkewPremiumRetained(uint256 premiumUsd, uint256 cumulative);

    /// @notice Record a scarcity-premium retained on a swap-out. Called by the well swap
    ///         bodies (SwapLib.creditSwapOutBody in the Vault context, swapToBody in Aux) — same
    ///         onlyUs seam as Core.swap. No-op on a flush pool (premium == 0).
    function recordSkewPremium(uint256 premiumUsd) external onlyUs {
        if (premiumUsd == 0) return;
        uint256 cum;
        // §E5 — the counters below are an AUDIT RECORD (asserted by
        // testGrindRemoval_DrainPaysRetainedSkewPremium); the CREDIT is what actually reaches LPs.
        // Without it the premium accrues to basket backing, which prices QU!D and not LP shares.
        skewPremium += premiumUsd; cum = skewPremium;   // §ISBTC-SPLIT: both arms were identical
        // ONE call site, dispatched by address: `Quid` and `Vault` expose the same
        // `creditSkewPremium` signature, so this is a single encode instead of one per branch.
        BAND.creditSkewPremium(premiumUsd);
        // §E42-netting — PUT THE BACKING WHERE THE CLAIM IS. The credit above creates an LP claim;
        // these are the dollars that back it, and until now they were the ONLY fee whose backing
        // stayed in general basket assets. Every other fee leaves its backing in the POOLED mirror
        // on purpose (BtcLib:56 — "the sats stay in POOLED by design: the guard exists so
        // creating the CLAIM does not remove its BACKING"), and `redeemableBody` nets that mirror.
        // MEASURED (§E42, 6 x 500 USDC): swappers paid 3,000.000000 into the basket while the
        // mirror rose only 2,993.999901 — the 6.000099 gap was the premium, quoted as QU!D
        // redeemability while owed to LPs. Folding it in closes the gap AT SOURCE, so redeemable
        // needs no premium-specific subtraction and no claimed/unclaimed counter to keep in sync:
        // the mirror already falls as LPs draw. Symmetric across both bands via IS_BTC.
        POOLED_USD += premiumUsd;
        // Also fold it into the decaying RATE register (#107/D3). The cumulative counters above
        // are monotonic totals — useless as a yield; θ needs a rate, which is what this provides.
        _bumpEwma(_prem, premiumUsd);
        emit SkewPremiumRetained(premiumUsd, cum);
    }

    // payRefillBonus REMOVED (2026-07-22): the swap-in refill no longer pays the refiller a bonus. Refill is a
    // self-funding fleet op (JIT Morpho-flash BTC → creditSwapIn → repay; gas via #87 peel-WETH), so the
    // drainer's retained skew premium accrues to LPs as backing (skewPremium* above) instead of being drawn out
    // and paid to a refiller. The skewPremium counters are now a pure LP-retained-profit record, never decremented.

    /// @notice Refund a swap's UNFILLED input remainder (amount − consumed) to the swapper. An inventory-
    ///         bounded partial takes the full input up front but only `consumed` drives the swap; this returns
    ///         the difference so the swapper never overpays for a partial (mirror of the vBTC partial-burn).
    ///         Real stable from Aux via AUX.take (checkBacking = solvency). onlyUs — the swap bodies route
    ///         through Core since Core is `us`; the retained scarcity premium is NOT refunded.
    function refundUnfilled(address token, uint amount, address to) external onlyUs {
        if (amount != 0 && to != address(0)) AUX.take(to, amount, token, 0);
    }

    // §ISBTC-SPLIT — ONE PAIR PER INSTANCE. Four mocks existed because one contract hosted two
    // pools; an instance hosts one band, so it needs one volatile mock and one USD mock.

    /// §ISBTC-SPLIT — WHAT THIS INSTANCE IS. Not a parameter threaded through every call: an
    /// IMMUTABLE the contract holds about itself. That distinction is the point of the split — a
    /// runtime boolean selecting between two behaviours IS the hand-rolled polymorphism being
    /// removed, whereas an instance knowing its own asset is what having instances MEANS.
    /// Use it ONLY where the asymmetry is REAL (ETH pays out ether; BTC settles via a Lightning
    /// cooperative close), never to pick between two paths that should have been one.
    /// §ISBTC-SPLIT — the volatile side's decimals (18 ether / 8 sats), fixed per instance. Held as
    /// a NUMBER because that is what actually differs; the mock deployer takes it directly instead
    /// of re-deciding from a flag.
    uint8 public immutable VOL_DECIMALS;
    /// §ISBTC-SPLIT — THIS BAND'S RISK PROFILE, resolved once at construction. `SwapLib` used to
    /// take a `bool isBTC` solely to choose between two constants; the instance owns which pair
    /// applies, so it hands over the NUMBERS. BTC locks capital through ~1hr of confirmations and
    /// pays an on-chain splice fee; ETH settles in ~one block with neither.
    uint public immutable CONF_FRAC;
    uint public immutable SPLICE;
    /// §ISBTC-SPLIT — THIS INSTANCE'S VOLATILE ASSET, resolved ONCE at setup. Three money-path
    /// sites read `IS_BTC ? address(AUX.WBTC()) : address(AUX.WETH())`, so each priced swap made an
    /// EXTERNAL CALL into Aux to look up a constant, then chose between two constants with a
    /// branch. Not immutable only because `AUX` is wired in `setup`, not in the constructor.
    address public ASSET;
    /// §ISBTC-SPLIT — THIS INSTANCE'S BAND MANAGER, through `IBand`. Every money-path `IS_BTC`
    /// branch below was `Core` reaching into one of two managers for the same fact and having to
    /// know which; the facts differ per band, so they live in the band. ETH is pinned at `setup`
    /// (Quid exists by then); BTC at `setBtcVault`, because `Vault` is deployed AFTER `Core` and
    /// takes its address at construction -- which is exactly why that setter already exists.
    IBand public BAND;

    /// §V4-CUT — THE BAND'S RANGE, now OURS to store. It used to live inside the v4 position, which
    /// is why re-ranging required burning and re-adding liquidity. With inventory held directly the
    /// range is a PRICING PARAMETER: moving it changes what we quote against, not what we hold.
    /// §DE-TICK — the band's bounds are PRICES (USD per volatile, WAD), not ticks. Under inventory
    /// the range is a pricing parameter, and a price bound is what every consumer actually wanted:
    /// the tick grid only ever existed so v4 could index many positions on a shared curve.
    /// §ONE-ANCHOR — was `LOWER_PRICE` + `UPPER_PRICE`. The two were ALWAYS
    /// `updateBounds(anchor, BAND_DELTA)` of one another -- `lower = p·(1−δ)`, `upper = p·(1+δ)`,
    /// symmetric about a SINGLE price -- so they were two slots holding one number, and two that
    /// could drift apart if anything ever wrote one without the other. The anchor is the spot at the
    /// LAST REPACK, not the live price, so it is still a snapshot; just one instead of two.
    /// Deriving is CHEAPER than storing: two `mulDiv`s beat a cold SLOAD, and a repack writes one
    /// slot instead of two.
    uint public BAND_ANCHOR;

    // §BANDBACKING-FOLD — `BACKING` DELETED. The shared accountant held the ONE thing two instances
    // still share (the joint committed equity the backing gate reads, and the cross-band input
    // `SwapLib._sharedScarcityWad` needs) — but that state now lives in `AUX`, which this contract
    // already holds and which owns the gate that consumes it. One fewer address to wire, one fewer
    // immutable, and one fewer constructor argument a deployer can get wrong.

    // §DE-TICK — `token1is()` DELETED with the state it exposed. No caller remained: leg ordering
    // is carried by `Delta`'s field NAMES and the OOR guard is symmetric, so there is no question
    // left for an external reader to ask.

    // ─── IS_BTC storage-ref selectors (EIP-170 dedup) ─────────────────
    // Each picks the per-pool slot/array so the swap/repack/delta/observation
    // bodies run ONE IS_BTC-parameterized path instead of mirrored ETH/BTC
    // branches. Value types can't be returned by storage ref, so the scalar
    // observation state is grouped in `_obsState` (ABI-preserving: the old
    // public obs getters were unread externally; only the array getters and
    // POOLED_* getters, which stay, are read by tests).
    // §V4-CUT — `_poolId()` DELETED: no callers. It selected between two ids of pools that are
    // never created.
    /// @notice DUST SWEEP — mock tokens held OUTSIDE the allowed set, which must never count
    ///         toward shares or P&L attribution.
    ///
    ///         The mocks are Core-minted and live in exactly two places: the PoolManager (as pool
    ///         reserves) and Core itself (transiently, between `take` and `burn`). They cannot
    ///         bootstrap outward — swapping this pool requires SETTLING one of them as input, and
    ///         only Core can mint them.
    ///
    ///         ONE path breaks that containment: a v4 PROTOCOL FEE. `Pool.sol` takes the protocol
    ///         slice OUT of the LP fee (`step.feeAmount -= delta`) and accrues it to
    ///         `protocolFeesAccrued[currency]` — OUR mock — and `collectProtocolFees` then does
    ///         `currency.transfer(recipient, …)`, making the collector the FIRST external holder.
    ///
    ///         Nothing in this system reconciles mock SUPPLY against `POOLED_*`, so such dust is
    ///         inert today and cannot trip any gate. This view exists so it is OBSERVABLE rather
    ///         than merely harmless: an external holder is the precondition for a direct swap on
    ///         our key that would bypass Core's `_handleDelta` mirror, and it is the quantity we
    ///         would owe if the fee is ever settled voluntarily at LP withdrawal.
    // §E60 — `externalMockDust` (the two-leg MONITOR) was DELETED from Core: with the count-out
    // landing in `_bandEquityUsd18`, keeping a second external for monitoring put Core 37 bytes
    // over EIP-170, and the production path must not pay for the observability one. Tests read the
    // mock addresses straight from storage (they already do for the fee flip) and compute it there.



    // §E253-mock — `mocks()` DELETED. Its only caller anywhere was a TEST
    // (`UnificationControls._mockDust`), and its own doc said it "EXISTS SO THE HARNESS STOPS
    // READING RAW SLOTS" — a production getter kept alive to serve a harness, measuring a quantity
    // that is structurally zero. The harness's own comment already conceded the mechanism was gone:
    // "no pool of ours exists, the approvals to the PM were deleted, and nothing can transfer a mock
    // there." Deleting the mocks deletes the reason the getter existed.
    // §ISBTC-SPLIT — THESE WERE `if (IS_BTC) x; else x;`: BOTH ARMS IDENTICAL. An earlier pass
    // collapsed POOLED/POOLED_USD to one field per instance but left the selector standing over
    // arms that no longer differed, so the branch cost bytecode and gas to decide nothing. The
    // Math.min floors are the real content and are unchanged.
    // ⛔ `_addPooledUsd` / `_subPooledUsd` / `_addPooledTok` / `_subPooledTok` ARE DELETED — four
    // one-line wrappers over two plain state variables, with FIVE call sites between them.
    //
    // They earned their keep while the pooled state was PER-ASSET: `POOLED_ETH`/`POOLED_BTC` and
    // `POOLED_USD_ETH`/`POOLED_USD_BTC` meant every touch had to select an arm, and a helper was
    // the place that selection lived. The v4 cut collapsed each pair to ONE variable, so the
    // wrappers now select between nothing — they are a name in front of `+=`. Inlined, each site
    // reads as what it is and there is one less layer between the assertion and the assignment.
    //
    // ⚠️ THE CLAMPS MOVED WITH THEM, DELIBERATELY, AND THEY ARE NO LONGER DECORATIVE. `-= Math.min(a, X)`
    // now sits at the two subtraction sites. While the v4 pool leg existed it was redundant: flash
    // accounting required deltas to net at unlock, so an inconsistent subtraction REVERTED and the
    // clamp never bound. That cross-check is gone with the pool, which makes the clamp the only
    // thing between an accounting error and a silently wrong `POOLED` — and a clamp does not
    // announce itself. Keeping it is correct for now; it is ALSO the thing to revisit first if
    // pooled state ever disagrees with the basket (see §V4-REMOVAL-POOLED-STATE).

    Aux AUX; Basket BASKET; Vault BTCVAULT;

    /// @notice BtcVault — the BTC LP/swap side, regrouped out of Quid/Aux.
    /// Pinned once (post-deploy, like Quid's btcChannels) since BtcVault is
    /// deployed after Core. Read for `totalShares()` (the BTC
    /// shortfall trigger) and admitted to `onlyUs` so it can drive the BTC
    /// pool (modLP / repack / collectFees / draw / dec / swap).
    
    
    error BtcVaultPinned();
    // BTCVAULT is pinned in its OWN setter, not setup(), because Vault is deployed AFTER Core
    // (Vault takes Core's address at construction, so it can't exist when setup() runs). The
    // one-shot pin makes a re-point impossible even before ownership is renounced — defence in
    // depth on the deploy path; a generic "already-set" error would also work, but the specific
    // one is self-documenting at the revert site.

    function setBtcVault(address b) external {
        require(msg.sender == DEPLOYER, "403");   
        if (address(BTCVAULT) != address(0)) 
            revert BtcVaultPinned();
        BTCVAULT = Vault(payable(b));
        // §ISBTC-SPLIT: the BTC instance's band manager IS the Vault, and this is the first moment
        // it exists (Vault takes Core's address at construction, so it cannot be pinned in setup).
        if (address(BAND) == address(0)) BAND = IBand(b);   // §ISBTC-ZERO: the second pin, no flag needed
    }
    /// @notice Public linkage getter — the deploy-finalize assert cross-checks
    ///         Core's BTC-vault pin against Aux's owner-set view.
    function btcVault() external view returns (address) { return address(BTCVAULT); }

    /// @notice The MONOTONIC retained-premium counter for one pool (6-dec USD). §E56 — its value is
    ///         not the point; being CUMULATIVE is. A decayed EWMA cannot tell a DEAD pool from a NEW
    ///         one (both read 0), and `sellSkew`'s refusal must treat those oppositely. A pool that
    ///         has never traded cannot have accrued any premium, so this disambiguates them.
    /// @dev    Dispatched HERE rather than read as two public getters from `SwapLib`: the two-branch
    ///         read cost SwapLib 87 bytes it does not have (measured, -87 over EIP-170), and Core has
    ///         the margin. Same trade as E32 — put the code where the room is.
    function skewPremiumCum() external view returns (uint) {
        return skewPremium;
    }

    /// @notice BTC band theta-numerator: the native IL-bearing backing = aggregate locked sats (lpShares,
    ///         net) + gross debt-funded buffer (totalBuffer). The BTC analogue of (bandETH + totalBuffer)
    ///         on ETH. ONE source of truth for BOTH the LP-add clamp (BtcLib._thetaClampBtc) and the
    ///         reseat clamp (QuidLib.addLiq IS_BTC) so they throttle on the SAME real capital -- NEVER the
    ///         disjoint WBTC-donation `bandBTC` pool (that mis-base collapsed the band whenever donations were
    ///         thin, the opposite of what scarcity should do). 0 if no BTC vault wired.
    function btcThetaBacking() external view returns (uint) {
        return address(BTCVAULT) == address(0) ? 0 : BTCVAULT.totalShares() + BTCVAULT.totalBuffer();
    }

    /// @dev §CORE-ONLYUS — THE CHECK IS A `private view`; THE MODIFIER STAYS THE GATE. A modifier
    ///      body is INLINED AT EVERY USE SITE (18 here), so three SLOADs + a revert string inline
    ///      cost 18 copies. One routine + 18 calls instead: **907 bytes** (24,472 → 23,565), taking
    ///      `Core`'s EIP-170 margin from 104 to **1,011** — it sat at 28 and was FROZEN for
    ///      additions, which is why §E42's premium fix had to route via `Aux.ethVenue()`.
    ///      Semantics identical: the check still runs before every guarded body, at every site.
    ///      (CLAUDE.md 8c, measured independently on `BTCChannels` by a concurrent thread.)
    ///      VERIFIED against a same-worktree control, only this change differing: both arms
    ///      4,400 passed / 1 failed / 2 skipped — the failure pre-existing, the skips environmental.
    /// §DEDUP-BAND — ONE field for the band manager. A second field holding the same address is
    /// the shape CLAUDE.md records as having planted three bugs in the EthVenue split: the call
    /// site reads correctly while the ASSIGNMENT points somewhere else.
    ///   • BTC: `setup(v4, 0, …)` pinned `BAND` to the **ETH** band manager, so the BTC engine's
    ///     `onlyUs` admitted a FOREIGN band. `Quid` holds ONE `Core` handle (`:57`) and no BTC-core
    ///     reference, so it never used that privilege — an unexercised grant, which is the kind that
    ///     survives review because nothing fails when you remove it and nothing fails when you don't.
    /// ⇒ `BAND` is THIS instance's band manager on BOTH: ETH `BAND = v4`, BTC `BAND = Vault` (pinned
    ///   in `setBtcVault`). Gating on it is identical for ETH and strictly TIGHTER for BTC.
    function _onlyUs() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(BAND)
             || msg.sender == address(BTCVAULT), "403");
    }

    modifier onlyUs { _onlyUs(); _; } bytes internal constant ZERO_BYTES = bytes("");

    /// @notice The deployer — the ONLY address that may run `setup`/`setBtcVault`, the authority-wiring pins
    ///         that admit BAND/AUX/BASKET/BTCVAULT into `onlyUs`. Captured at construction so a hostile
    ///         party can't FRONT-RUN an un-pinned wiring call in the deploy window and inject a malicious
    ///         `onlyUs` member (Core isn't Ownable; this is the immutable analog of the owner-gate the
    ///         siblings Basket.setBtcVault / Aux.setEthVenue already carry).
    address immutable DEPLOYER;
    /// §ISBTC-SPLIT — `isBtc` is instance identity and is set ONCE, here. Two instances are
    /// deployed: one ETH, one BTC. Nothing downstream may change it, which is why it is immutable
    /// rather than a settable flag — a settable one would reintroduce the runtime selector.
    /// §ISBTC-ZERO — THE FLAG IS GONE. `bool isBtc` was never the thing this contract needed; it
    /// was a proxy the constructor immediately expanded into four facts. Those facts are now passed
    /// DIRECTLY, so there is nothing left to select at runtime and nothing to get wrong at a call
    /// site. `VOL_DECIMALS` is READ FROM THE ASSET rather than passed, because the token already
    /// knows (WETH 18, WBTC 8) -- one fewer number a deployer can mistype.
    /// @dev §RISK-IS-ONE-PROFILE — `confFrac_` and `splice_` were TWO loose numbers and are now one
    ///      `SwapLib.Risk`. They are not independent: every deploy passes either
    ///      `(ETH_CONF_FRAC_WAD, 0)` or `(CONF_FRAC_WAD, SPLICE_FLOOR)`, and `SwapLib` already
    ///      declares exactly those two pairings as `ethRisk()` / `btcRisk()`. Two parameters that
    ///      always co-vary are one parameter wearing a disguise, and the disguise is what lets a
    ///      deployer pair ETH's one-block settlement window with BTC's 0.2% splice floor — a
    ///      mispricing no compiler could object to. As a profile that combination cannot be spelled.
    ///      ⚠️ NOT derived from the asset here, deliberately: Core would have to ask which asset it
    ///      is, and inferring it from `VOL_DECIMALS` (8 vs 18) is the same class of mistake as
    ///      reading a stable's decimals off its slot index. The profile is deploy-time
    ///      CONFIGURATION, which is the one place a per-instance constant honestly belongs.
    constructor(address asset_, SwapLib.Risk memory risk) {
        DEPLOYER = msg.sender;
        ASSET        = asset_;
        VOL_DECIMALS = IERC20Min(asset_).decimals();
        CONF_FRAC    = risk.confFracWad;
        SPLICE       = risk.spliceFloor;
    }

    /// @param _aux              Aux (settlement adapter)
    /// @param _basket           Basket (settlement target)
    /// @param seedPrice         This band's reference price at deploy (WAD USD per unit volatile),
    ///                          read from the REAL on-chain pool by the DEPLOYER and passed in.
    function setup(address _band, address _aux, address _basket, uint seedPrice)
        external { require(msg.sender == DEPLOYER, "403");   
        // auth-wiring pin (deployer only) anti-frontrun
        require(address(AUX) == address(0), "!");   // §DEDUP-BAND: was `BAND`, which is gone

        // §E253-mock — the two `mock` ERC20s are no longer deployed. They were the v4 pool's two
        // currencies; with no PoolManager nothing mints, holds or moves them.
        
        AUX = Aux(payable(_aux));
        // §ISBTC-ZERO: the BAND is whatever the deployer pins here. The ETH band (Quid) exists by
        // now; the BTC band (Vault) is deployed AFTER Core and pins later via `setBtcVault`, so a
        // zero here is not an error -- it is the second-pin case, and no flag distinguishes them.
        if (_band != address(0)) BAND = IBand(_band);
        BASKET = Basket(_basket);

        // Both reference pools' live ticks are read in ONE library call so they
        // reflect a single consistent block snapshot, and the four mock approvals
        // ride along — see `OracleLib.prepRefs`. Every byte of that was deploy-time
        // code sitting in Core's RUNTIME against a hard EIP-170 deficit.
        // The ref-pool direction probes come back from the same call: they are pure
        // reads of the ref keys, so computing them HERE only put `Currency.unwrap`
        // in Core's runtime twice. `AUX.WBTC()` is queryable because AUX was wired
        // above, and is passed in so OracleLib need not import Aux for one getter.
        // §V4-CUT — THE REFERENCE READ MOVED OUT OF CORE. `prepRefs` is a read of pools we do NOT
        // own, and its result is needed exactly ONCE, to seed the ring. Keeping it here forced Core
        // to hold an `IPoolManager` and two `PoolKey`s for a deploy-time lookup -- which is why this
        // contract still looked "responsive to the PoolManager" long after it stopped trading on it.
        // The DEPLOYER does the lookup (`OracleLib.prepRefs`) and passes the price. The ONGOING
        // v3/v4-vs-Chainlink cross-check lives where the GUARD lives, not in the band engine.

        // §V4-CUT — ONE INSTANCE, ONE RING, ONE LINE. `_initPool` is gone: it existed to assemble a
        // lex-sorted PoolKey, initialise a v4 pool and record its id, and none of that happens any
        // more. `VANILLA_*`, `POOL_ID_VANILLA_*` and the ordering flag were write-only vestigia of a
        // pool that is never created. Seeding the ring from the reference price is the whole job.
        OracleLib.seedRing(obsState, observations, seedPrice);
    }

    /// @notice Draw down the BTC pool's committed USD side when an on-chain
    ///         swap-out delivery pays the LP its exact proceeds. `usd6` is 6-dec.
    function drawPooledUsdBtc(uint usd6) external onlyUs {
        // FAIL-LOUD, not silent-clamp: the sole caller (BtcLib.settleDelivered) mints QUI for the FULL
        // `exactUsd` it draws here, so a `Math.min` under-draw would leave that excess QUI unbacked. The
        // request/gate invariant (exactUsd ≤ pendingSwapOutUsd ≤ POOLED_USD) makes this subtraction never
        // underflow in correct operation; checked math reverts the whole settlement if a future change breaks
        // it — the draw and the mint can never disagree by construction.
        POOLED_USD -= usd6;
    }

    /// @notice Record a new undelivered on-chain swap-out obligation's USD
    ///         (at requestSwapOutOnchain). The matching `subPendingSwapOut` fires
    ///         on EITHER delivery (paid to the LP) or reversal (settleSwapIn).
    function addPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd += usd6;
    }

    /// @notice Clear an obligation's USD when it is delivered (paid exact to the
    ///         LP) or reversed. FAIL-LOUD, matching its sibling `drawPooledUsdBtc`
    ///         above — the two take the same argument in the same transaction
    ///         (`BtcLib.sol:85-86`) and must not disagree on discipline.
    ///         Every clearing path subtracts EXACTLY what its request added:
    ///         delivery is one-LP-per-slice with the swapId consumed
    ///         (`BTCChannels._settleSwapOutSlice`), and the de-lever split is a
    ///         partition — `Vault.sol:539` hands `resize` the remainder
    ///         `exactUsd - delevUsd` with `delevUsd` clamped to `[0, exactUsd]`,
    ///         so the round-UP at `SwapLib.sol:1456` moves the SPLIT POINT and
    ///         never the total. A clamp here could only hide a reserve that was
    ///         already understated — which silently overstates free USD and lets
    ///         the pool commit capacity it owes. Checked math surfaces that.
    function subPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd -= usd6;
    }

    // ─── External entrypoints — same surface as before, parallel BTC ──
    /// @notice Fused modLP — IS_BTC selects which pool. `delta` is the
    /// volatile-side change (ETH amount for ETH pool, BTC sats for BTC).
    /// @notice full-2× band op. The debt-funded buffer leg folds into POOLED_USD_* like any in-range USD;
    ///         committedUsd18 recovers equity by subtracting min(live debt, pooled buffer). No separate buffer
    ///         param — the old `levUsd` slot was a no-op post-fold and has been removed.
    /// §V4-CUT — the band TAKES WHAT IT IS GIVEN. `_modLP` computed a liquidity amount for a tick
    /// range and handed it to `poolManager.modifyLiquidity`, which decides how much of each leg that
    /// range can absorb at the current price — so a caller could get back an unplaceable remainder.
    /// Inventory has no range to fit: both legs enter in full.
    /// ⚠️ BEHAVIOUR CHANGE, STATED RATHER THAN SLIPPED IN. `sent` was the REFUND of what the range
    /// could not place; it is now always 0 because nothing is refused. A caller that credits the
    /// refund back is consistent (there is nothing to credit), but one that reads a zero refund as
    /// "the add failed" would be wrong — that is the line to check when wiring callers.
    /// ⚠️ `spotPrice` and the tick bounds are unused; they stay only until the callers are
    /// updated in this same cut.
    /// §DE-TICK — the price and tick arguments are GONE, not ignored. They described where in a v4
    /// range the liquidity had to land; inventory has no range to fit, so carrying them would cost
    /// calldata on every call to describe a placement that no longer happens.
    /// 🔴 §E231-MODLP-DIRECTION — THE ARGUMENTS ARE SIGNED, AND THAT IS THE FIX.
    ///
    /// This took `uint delta, uint deltaUSD` and built `Delta(-int256(deltaUSD), -int256(delta))`:
    /// **both legs ALWAYS negative, i.e. always ENTERING.** A removal had no way to say so, so every
    /// caller that BURNS depth was accounted as if it were ADDING it — `POOLED` grew on a withdraw.
    /// Measured: `testDepositImmediateWithdraw` deposits 10 ETH, withdraws 5, and asserts
    /// `pooledBeforeWithdraw - POOLED()`; POOLED came back at 1.509e19, HIGHER than before, so the
    /// subtraction underflowed. The test is right and the accounting was wrong.
    ///
    /// ⚠️ THE DIRECTION WAS LOST IN THE V4 CUT, and the header it left behind says so without
    /// noticing: *"the band TAKES WHAT IT IS GIVEN"*. While v4 existed, `modifyLiquidity` RETURNED
    /// signed deltas — the pool told us which way value moved. The cut replaced that return with a
    /// hand-built `Delta` and hardcoded the sign to "enters", which is correct for the deposit path
    /// the author was looking at and silently wrong for the two burn paths.
    ///
    /// ⇒ Callers now pass the sign, under the SAME convention `Delta` and `swap` already use —
    /// **positive LEAVES the pool, negative ENTERS it**. That is this file's own stated rule
    /// ("SIGN CARRIES DIRECTION … one value, one meaning — no companion flag that can disagree with
    /// it"), and following it deletes the negation here rather than adding a boolean beside it.
    function modLP(int256 delta, int256 deltaUSD, address sender)
        public onlyUs returns (uint sent) {
        Delta memory d = Delta(deltaUSD, delta);
        _handleDelta(d, true, deltaUSD == 0, sender, address(0), true);
        sent = 0;   // nothing is refused, so nothing comes back
    }

    /// @notice Fused outOfRange. Action enum differentiates ETH vs BTC.
    /// §V4-CUT — NO UNLOCK, NO CUSTODIAN. The caller now passes the token AMOUNT it placed rather
    /// than v4's liquidity encoding, so there is nothing to decode and nothing to ask the
    /// PoolManager for: the amount settles against our own inventory through `_handleDelta`,
    /// exactly like a swap.
    /// ⚠️ `inRange = false` IS PRESERVED AND IS LOAD-BEARING: an out-of-range order must not move
    /// `POOLED_*`, which tracks the ACTIVE band. Dropping it would let a resting boundary order
    /// inflate the in-range inventory every LP claim is priced against.
    /// SIGN CARRIES DIRECTION: `amount > 0` OPENS the order (tokens ENTER the band ⇒ negative delta,
    /// per `_handleDelta`'s rule that positive LEAVES); `amount < 0` CLOSES it. One value, one
    /// meaning — no companion flag that can disagree with it, and no call site where the size says
    /// one thing and the direction another.
    /// ⇒ THIS WAS THE LAST `poolManager.unlock` AND THE LAST `_modifyLiquidity`. With it gone the
    /// band's tokens are ours, custody and accounting are one thing again, and the transitional
    /// divergence marked in `swap` is CLOSED.
    function outOfRange(address sender, int amount, uint /*lower*/, uint /*upper*/, address token)
        public onlyUs returns (uint tokOut) {
        // Single-sided by construction: a boundary order rests entirely on one side of spot, so the
        // amount belongs to the volatile leg when `token == 0` and to the USD leg otherwise.
        // §DE-TICK: `token == address(0)` IS the volatile side; the ordering flag only decided
        // which slot that landed in, and both readers compensated. Now it lands in `vol`.
        Delta memory d = token == address(0)
            ? Delta(0, -amount)
            : Delta(-amount, 0);
        _handleDelta(d, false, false, sender, token);
        int256 t = d.vol;
        tokOut = t > 0 ? uint(t) : 0;
    }

    /// @notice §E258 — settle ONE filled boundary order, both legs, at the order's own price.
    /// @dev    `inRange = true` HERE, where `outOfRange` passes false, and the difference is the
    ///         point. A resting order is deliberately kept out of `POOLED_*` so it cannot inflate
    ///         the in-range depth every LP claim is priced against. Filling it is the moment its
    ///         funded side JOINS that depth and the other side leaves it — exactly what a swap
    ///         does — so it settles on the in-range path, and the two states stay disjoint with no
    ///         window in which the order counts twice.
    ///         `token` is `address(0)`: a fill's USD leg is either taken into the pool or paid out
    ///         through `AUX.take`, and only the burn branch reads a payout token.
    function settleOor(address owner, int256 usdDelta, int256 volDelta) external onlyUs {
        _handleDelta(Delta(usdDelta, volDelta), true, false, owner, address(0));
    }

    /// @notice The most resting orders one swap will execute before it stops and leaves the rest to
    ///         the poke. ⚠️ NOT A TUNING KNOB — it is the anti-griefing bound: without it anyone can
    ///         rest a crowd of cheap orders in the path and charge the next swapper for all of them.
    uint private constant MAX_FILLS_PER_SWAP = 4;

    /// @notice Fused swap — IS_BTC selects which V4 pool. The shortfall signal is
    ///         ASYNC per-pool (in-frame refill is unsafe — re-enters Aux on
    ///         half-settled backing); BTC emits a hop request (we don't mint WBTC).
    /// @dev    §SCRUB: this said "ETH emits ETHRefillRequest (keeper → refillETH buys back from free
    ///         surplus)". BOTH are deleted -- this same file records "REMOVED: refillETH() /
    ///         ETHRefillRequest — the eager, permissionless ETH-pool [...]". The BTC hop request is
    ///         real and stays; the ETH half named an event no contract emits and a function no
    ///         contract declares, which is how a reader concludes the ETH shortfall path is wired.
    function swap(address sender,
        bool inputIsUsd, address token, uint amount)
        onlyUs public returns (uint out) {

        // ═══════════════ §V4-CUT — SETTLE AT ORACLE, BOUNDED BY INVENTORY ═══════════════
        // No unlock, no callback, no curve traversal, no price discovery. ONE price for the whole
        // size. The skew is deliberately NOT folded into this rate: we restore 1:1 from the inside
        // via Curve, so there is no arbitrageur to pay a spread to — the skew is the ATTRIBUTION KEY
        // for the realised restoration cost (BatchLedger), never a charge applied here.
        //
        // UNITS — CHECKED, NOT ASSUMED, because a 1e12 slip here mis-scales every swap.
        // `BasketLib.getPrice` output, the observation ring's stored `lastPrice`, and
        // `AUX.getTWAPforAsset` are ALL the same basis: WAD USD per unit volatile. The ring stores
        // `getPrice`'s output and `twapBody` reads the ring, so the TWAP substitutes directly where
        // `getPrice(getSlot0())` used to sit. `BasketLib.convert` carries the 6↔18 bridge and is the
        // SAME conversion `routeSwap` already uses — deriving a second one here is how the §A.50/C2
        // asymmetry happened.
        //
        // SIGN CONVENTION — DERIVED from the two consumers so the legs cannot silently invert:
        //   • the old `out` was `forOne ? amount1 : amount0` ⇒ THE LEG THE USER RECEIVES IS POSITIVE;
        //   • `_settleUsdSide` reads `usdDelta = _t1 ? amt0 : amt1` ⇒ with `_t1`, USD is leg 0.
        //   ⇒ POSITIVE = leaves the pool (we pay out) · NEGATIVE = enters the pool (we take in).
        //   `forOne` is zeroForOne: pays leg 0, receives leg 1.
        //
        // ⚠️ `spotPrice` IS NOW UNUSED. It carried the packed band ticks for the price limit —
        // a bound that existed because crossing the band edge cost ZERO and bricked the band
        // (`PooledUsdRepackMatrix::testMatrix_S6`). The inventory bound below replaces it with a
        // PHYSICAL limit, and an edge that does not exist cannot be crossed. The parameter stays
        // only until `BasketLib.routeSwap`'s call site is updated in the same cut.
        // OWN FRAME (`via_ir = false`). The fill's locals -- price, leg ordering, inventory bound,
        // partial-fill re-derivation -- are computed in `_fillDelta` and only a struct pointer and
        // `out` come back. Inlining them here blows the stack at `_handleDelta`, twice measured.
        // This is the same idiom `_handleDelta`'s own settle legs use ("each leg settles in its own
        // frame -- legacy stack, no via_ir crutch"). Do not inline for readability; it will not compile.
        uint px = AUX.getTWAPforAsset(ASSET, 1800);
        Delta memory delta;
        (delta, out) = _fillDelta(inputIsUsd, amount, px);

        // 🔴 THE THREE LINES BELOW LIVED IN `_handleSwap`, WHICH THIS CUT DELETED. Moving the seam
        // without carrying the body left `swap` computing a delta and doing NOTHING with it — no
        // settlement, no observation, no flow bump — and it compiled. Recorded because "the seam is
        // one statement" was true of the SOURCE of the delta and false of everything downstream.

        // (1) OBSERVATION. `_writeObservation` took a sqrt-price only because v4's API handed one
        // over; the ring has stored PLAIN PRICE since §TICK-REMOVAL, and we now HAVE the price, so
        // it goes in directly with no conversion. This is the whole of the oracle repoint.
        _observeIfSourced();   // §E222: an independent OBSERVATION -- never `px`, which READ this ring

        // (2) SETTLEMENT. Without this `POOLED_*` never moves and nobody is paid.
        _handleDelta(delta, true, false, sender, token);

        // (3) FLOW EWMA — LOAD-BEARING, AND ITS ABSENCE WOULD HAVE BEEN SILENT. `flowEwmaUsd` decays
        // with no replenishment if this is missing, and flow IS the `target` in `skewWad`/`sellSkew`.
        // At `target == 0` `sellSkew` RETURNS 0, so every sell goes exempt from the imbalance charge
        // — looking exactly like a skew that simply never fires. Every band and well swap routes
        // through here, so this remains the ONE bump point.
        {
            int256 usdLeg = delta.usd;
            uint usd6 = uint(usdLeg < 0 ? -usdLeg : usdLeg);
            if (usd6 != 0) _bumpFlow(usd6);
        }

        // (4) §E258 — EXECUTE THE RESTING ORDERS THIS MOVE CROSSED. Under v4 the PoolManager did
        // this as part of any swap through the range; `FixedRateFill` has one price and no
        // traversal, so without this a boundary order is an option its owner must exercise rather
        // than the limit order it was sold as. It runs AFTER settlement so the fills price against
        // inventory this swap has already moved, and it is capped inside the band — see
        // `BandLib.sweepOor` for why that cap makes the permissionless poke a liveness requirement.
        BAND.sweepOor(px, MAX_FILLS_PER_SWAP);

        // Per-pool shortfall arb. Threshold (1%) and trigger logic are
        // identical across pools; only the remediation differs. Both
        // sides bootstrap symmetrically: at deploy POOLED_X = 0 and
        // totalSharesX = 0, so the trigger naturally doesn't fire until
        // LPs join via modLP (which grows both in lockstep).
        // GROSS fee depth on both sides: for BTC, totalShares is NET, so add the levered buffer
        // (totalBuffer) to match POOLED (gross, includes the buffer) — keeps the shortfall
        // comparison gross-to-gross (unchanged behavior). ETH: bandETH(net) vs totalShares(net) already balanced.
        uint totalSharesPool = BAND.sharesForShortfall();
        // BOTH sides compare REAL inventory, never just the in-pool token.
        // ETH = bandETH() (in-range POOLED + AAVE/ether.fi venue
        // retention + idle). BTC has no yield-venue, but the protocol still HOLDS
        // off-pool WBTC (swept donations + swap deltas, accrued in bandBTC), so
        // the BTC analogue is POOLED + bandBTC. Comparing raw POOLED
        // over-fired the shortfall arb on off-range retention (lpShares > POOLED
        // by construction) — requesting a hop-source of BTC the protocol already
        // holds. Adding bandBTC is monotone-safe: it can only SHRINK the measured
        // shortfall, never grow it, and suppressing a "shortfall" we can cover from
        // our own WBTC is correct (no need to source what we already hold).
        // BTC IL-protect: totalShares includes each LP's LEVERED slice (levPooled), and its backing is
        // ALREADY inside POOLED — `syncLev` pairs the net-equity as deltaBTC into POOLED in lockstep
        // with levPooled (QuidLib.levAddNetBtc/levAddBufBtc), so the lev slice is monotone-neutral here.
        // (The ETH branch is NET-vs-NET: bandETH() adds the lev book's NET equity (totalNetEquity, the
        // debt-funded buffer half offset by the LP's borrow) and totalShares() is NET, so no gross term is added
        // here — POOLED, by contrast, DOES include the lev slice gross (levAddBtc pairs the gross buffer in),
        // so BTC alone needs the +totalBuffer above to keep totalShares's comparison gross-to-gross.)
        uint pooledTok = BAND.realInventory();
        // The load-balance (the shortfall arb/refill this swap would trigger) is the
        // SWAPPER's to consent to — it routes through the SOR / hop and can add MEV/slippage
        // to their own fill, and the LP-side analysis says firing it on every wiggle realizes
        // impermanent loss. So it only fires if `sender` has NOT opted out (default = consent,
        // preserving behavior; the SPA exposes a toggle). Symmetric for WETH and WBTC.
        if (pooledTok < totalSharesPool && !loadBalanceOptOut[sender]) {
            uint shortfall = totalSharesPool - pooledTok;
            if (shortfall * 100 >= totalSharesPool) {
                // BTC: route to the hop — real-BTC delivery on L1, consuming NO
                // basket stables (the legitimate delivery rail). ETH: nothing. A
                // surplus-funded ETH refill would buy ETH for a shortfall that is
                // usually impermanent, realizing that IL onto the SHARED backing —
                // compensating the flow at every LP's expense (toxic). Real ETH
                // demand is met fairly at withdrawal: convertToAssets pays each LP
                // pro-rata of bandETH, so the IL is socialized via the share price,
                // never patched from surplus.
                BAND.onShortfall(sender, shortfall);   // ETH: a deliberate no-op -- see IBand
            }
        }
    }

    /// @notice Per-swapper consent to LOAD-BALANCING (the shortfall arb/refill a swap triggers,
    ///         for BOTH the WETH and WBTC pools). Stored opt-OUT: default (false) = consented =
    ///         behavior unchanged; a swapper calling setLoadBalanceConsent(false) makes their
    ///         own swaps NOT trigger the load-balance (no MEV/slippage on their fill, and they
    ///         don't fund the basket's rebalancing). Per-address + persistent (set once via the
    ///         SPA), so no swap-signature change. Only affects msg.sender's own swaps.
    mapping(address => bool) public loadBalanceOptOut;
    function setLoadBalanceConsent(bool consent) external { loadBalanceOptOut[msg.sender] = !consent; }

    // REMOVED: refillETH() / ETHRefillRequest — the eager, permissionless ETH-pool
    // refill from basket surplus. It was toxic (spent the SHARED safety margin to
    // chase a usually-impermanent shortfall, realizing IL at every LP's expense) AND
    // griefable (no access control, magnitude-only 1% gate, so anyone could force the
    // speculative buy) AND redundant (TWAP pricing needs no pre-balanced inventory; LP
    // exits read pro-rata of bandETH at withdrawal). The fair model is the redemption
    // path (BasketLib._depegLoss: pro-rata, no first-out-at-par); withdrawal now matches
    // it (see Quid._withdraw). BTC keeps its hop delivery rail (Aux.btcShortfall).

    /// @notice Fused repack — replaces separate repack/repackBTC. Pass
    ///         IS_BTC=true to repack the BTC/USD pool, false for ETH/USD.
    /// §V4-CUT — REPACKING MOVES NO TOKENS. Once liquidity settles against inventory, the range is
    /// a PRICING PARAMETER, not a custody boundary: the band holds what it holds, and re-ranging
    /// only changes the bounds we price against. So this stores the new range and returns zeros for
    /// every delta — there is nothing to burn and nothing to re-add.
    /// ⚠️ `POOLED_*` IS NOT ZEROED HERE ANY MORE. `_handleRepack` used to clear it and rebuild from
    /// the re-added position, which was correct while the position WAS the inventory. Zeroing it now
    /// would delete the band's holdings on a bookkeeping operation.
    /// Fees return 0 because there is no v4 accrual to harvest: the 420 ppm is charged in the fill
    /// and compounds into `POOLED_*` at swap time.
    /// §DE-TICK — the four dead parameters are GONE, not widened. `myLiquidity` and the old bounds
    /// described a v4 position being burned and re-added; there is no burn. Keeping them as ignored
    /// arguments would cost calldata on every repack to describe an operation that no longer happens.
    /// §V4-CUT — RETURNS THE PRICE ALONE. The old tuple was
    /// `(price, fees0, fees1, delta0, delta1)`; v4 collected the fees and reported the deltas, and
    /// with the collector gone all four were hard-coded ZERO. Callers destructured them, reordered
    /// them by token identity, and fed them to `feeIncrements` -- arithmetic on constants. Also
    /// absorbs `reseat`, whose body was identical.
    /// @dev §ONE-ANCHOR — takes the ANCHOR, not the two bounds it implies. The caller computed those
    ///      as `updateBounds(spotPrice, BAND_DELTA)` and already held `spotPrice`, so passing the
    ///      pair meant sending a derived value and reconstructing its source. Reconstructing it as
    ///      the midpoint would be LOSSY: `p·(10000±δ)/10000` truncates on each leg, so the recovered
    ///      anchor drifts a wei and every bound derived from it drifts with it. One argument, exact,
    ///      and the derivation lives in exactly one place.
    function repack(uint anchorPrice) public onlyUs returns (uint price) {
        BAND_ANCHOR = anchorPrice;
        price = AUX.getTWAPforAsset(ASSET, 1800);
        _observeIfSourced();   // §E222: `price` is RETURNED for pricing; the ring records an independent read
    }

    // §V4-CUT — `reseat` DELETED: it had become BYTE-IDENTICAL to `repack` above. Both stored the
    // new bounds, read the TWAP and wrote an observation. They were distinct while v4 hosted the
    // band -- `repack` adjusted an existing position, `reseat` tore one down and rebuilt it at a new
    // range -- and that difference lived entirely in the `modifyLiquidity` calls both have lost.
    // Two names for one behaviour is drift waiting to happen; one behaviour gets one name.

    /// §V4-CUT — NOTHING TO COLLECT. This drained v4's fee accrual into `feesPerShare` before every
    /// bookmark update, as anti-dilution: v4 fees sat OUTSIDE `POOLED_*`, so NAV did not reflect them
    /// and a depositor arriving in the same block as a large swap would capture fees they had not
    /// earned. Under compounding the 420 ppm lands in `POOLED_*` AT SWAP TIME, and shares are minted
    /// against `_pricingBacking()` which includes it — so a new depositor buys in at the fee-inclusive
    /// price and dilutes nobody. **The protection now holds BY CONSTRUCTION rather than by a pre-mint
    /// drain**, and the window this guarded closes on its own.
    /// ⚠️ Returns (0,0) rather than being deleted only while its callers still destructure the pair;
    /// the JIT branches in `QuidLib`/`BtcLib` go with it in the caller pass.
    function collectFees() public view onlyUs returns (uint, uint) {
        return (0, 0);
    }

    // §V4-CUT — `_key()` DELETED: no callers. It returned the PoolKey of a pool never created.

    /// §V4-CUT — the pair travels as ONE memory pointer, not two stack values. `BalanceDelta` was a
    /// SINGLE PACKED int256; two `int256` parameters added a stack slot per call site and blew the
    /// limit (`via_ir = false`). CLAUDE.md's remedy verbatim: locals into struct fields, because one
    /// memory pointer costs less stack than two values. Do NOT "simplify" it back — it will not compile.
    /// §DE-TICK — THE FIELDS ARE NAMED FOR WHAT THEY HOLD, not for a token ordering. `amt0`/`amt1`
    /// mirrored Uniswap's LEX-ORDERED currency0/currency1, so every producer encoded the legs by
    /// `token1isVol` and every consumer decoded them by it again -- an encode/decode pair around a
    /// struct WE own, with no external ordering left to agree with. Worse, the flag derives from the
    /// lex order of freshly-deployed MOCK addresses, so it varied with deployment nonce: the same
    /// code could put the USD leg in either slot on two different deploys. Naming the fields makes
    /// the ordering question unaskable.
    struct Delta { int256 usd; int256 vol; }

    function _handleDelta(Delta memory d, bool inRange, 
        bool keep, address who, address token) internal {
        _handleDelta(d, inRange, keep, who, token, false);
    }

    /// `addLiq`). Swap/collect/reseat legs pass FALSE, so a swap moves mirror
    /// (`POOLED_USD_*`) without moving the basket's contribution (`basketUsd`)...
    /// the USD leg keeps its own frame (it is the big one, and `_poolUsdInRange` 
    /// sits under it). Net stack pressure FALLS: each leg 
    /// used to take `amt0` AND `amt1` and re-derive which was which.
    function _handleDelta(Delta memory d, bool inRange, bool keep,
        address who, address token, bool basketLeg) internal {
        _settleUsdSide(d.usd, inRange, keep, who, token, basketLeg);
        int256 tokDelta = d.vol;
        if (tokDelta > 0) {
            uint tokAmount = uint(tokDelta);
            if (inRange) POOLED -= Math.min(tokAmount, POOLED);   // clamp: see the note at the deleted helpers
            // ⚠️ THE `!IS_BTC` GUARD STAYS: ETH pays out real ether here, BTC settles by Lightning
            // cooperative close, not an on-chain transfer. One of the four known-REAL asymmetries.
            if (who != address(0)) BAND.deliverVolatile(tokAmount, who);   // BTC: no-op (LN close)
        } else if (tokDelta < 0) {
            uint tokAmount = uint(-tokDelta);
            if (inRange) POOLED += tokAmount;
        }
    }

    /// @dev USD-leg of _handleDelta. delta>0 → take+burn; delta<0 → mint+settle and
    ///      (in-range) pool it under the backing invariant.
    ///      ⚠️ This used to say "under the BTC share cap" — a comment describing PAST state. The
    ///      `btcShareBps` median-vote cap was REMOVED in §H (2026-07); see `SwapLib.sol:1304`.
    ///      There is NO per-band cap and NO fixed ETH/BTC split: the ONLY shared bound is the SUM
    ///      (`committedUsd18() <= haircutTvl`), so either band may draw the whole free surplus if
    ///      the other is not using it. Neither side is limited to a share, still less to the
    ///      MINIMUM of the two.
    /// §V4-CUT — the mock ERC20 and the PoolManager settle are GONE; the ACCOUNTING is not.
    /// `_mockUsd.mint/burn` + `usdCurrency.take/settle` existed ONLY to satisfy v4's requirement that
    /// a pool trade real ERC20 CURRENCIES. The USD leg has no real token, so one was minted and
    /// burned purely for the type system — a shadow of a movement that happens elsewhere
    /// (`AUX.take` below is where the payout actually lands). Removing it cannot move value.
    /// `_poolUsdInRange`, `AUX.take`, the 6-dec basis and the §A.50/C2 conversion are UNCHANGED —
    /// that fix is about DECIMALS and has nothing to do with v4.
    function _settleUsdSide(int256 usdDelta, bool inRange, bool keep,
        address who, address token, bool basketLeg) private returns (uint usdAmount) {
        if (usdDelta > 0) {
            usdAmount = uint(usdDelta);
            if (inRange) _poolUsdInRange(usdAmount, false, basketLeg);
            if (!keep && token != address(0))
                // §A.50/C2: `usdAmount` is the 6-dec mockUSD leg, but `AUX.take` wants the payout
                // token's NATIVE units (`BasketLib.sol:620-628`; the two callers that already convert
                // are `SwapLib.sol:1170` and `:1222`). The CREATE side of the same position already
                // scales (`QuidLib.sol:662`), so without this the round trip was ASYMMETRIC and an
                // 18-dec redeemer was paid 1e12x too little. `minOut` cannot catch it: `Core.swap`
                // returns the 6-dec delta, a different basis than delivery.
                AUX.take(who, BasketLib.from6(usdAmount, token), token, 0);
        } else if (usdDelta < 0) {
            usdAmount = uint(-usdDelta);
            if (inRange) _poolUsdInRange(usdAmount, true, basketLeg);
        }
    }

    /// @dev In-range USD pooling (own frame — keeps _settleUsdSide off the stack limit). The full-2× buffer is
    ///      NOT split off here anymore: the WHOLE `usdAmount` moves POOLED_USD_*, and committedUsd18 recovers the
    ///      equity claim by subtracting live leverage debt. The ≤TVL backing gate is checked against that live
    ///      EQUITY (`committedUsd18`), so the debt-funded buffer consumes no basket-USD headroom — exactly as
    ///      the old `_LEV` segregation did, but drift-free.
    function _poolUsdInRange(uint usdAmount, bool mint, bool basketLeg) private {
        if (mint) {
            (uint[15] memory _d, ,, uint depegLoss) = AUX.get_deposits();
            // Depeg-at-par fix: gate against the SOLVENCY haircut — par TVL minus the LIVE depeg loss (the
            //   PERMANENT value loss of a depegged stable). NOT the deliverability haircut (illiquidLoss): that is
            //   the normal, ever-present lending-utilization slice (own − withdrawable-now; the GHO reserve sits
            //   ~78% utilized at rest), which is SOLVENT and only defers per-redemption — subtracting it here
            //   would treat routine utilization as a backing loss and block the band from committing at all
            //   (proven: it reverts test_BankRun / RedeemConservation with no depeg). Redeem subtracts illiquid to
            //   DEFER a single withdrawal; the standing solvency gate must not. depegLoss == 0 in normal
            //   operation ⇒ byte-identical to the old par gate; it only tightens under an ACTUAL depeg.
            uint haircutTvl = _d[14] > depegLoss ? _d[14] - depegLoss : 0;
            POOLED_USD += usdAmount;
            if (basketLeg) basketUsd += usdAmount;   // §ISBTC-SPLIT: both arms were identical
            // 🔴 §BACKING-DEAD — THE PUSH THAT MAKES THE GATE BELOW MEAN ANYTHING. `_reportEquity`
            // existed, was documented as PUSH-not-pull, and HAD NO CALLERS -- so
            // `BandBacking.committedOf` was never written, `total()` was permanently 0, and this
            // `require` compared `0 <= haircutTvl`: ALWAYS TRUE. The bound that stops both bands
            // over-committing the same basket could not bind. It must run BEFORE the require, so
            // the gate sees THIS band's new equity, and the sibling's last pushed figure.
            _reportEquity();
            require(committedUsd18() <= haircutTvl, "backing");
        } else {
            uint pooledPre = POOLED_USD;
            POOLED_USD -= Math.min(usdAmount, POOLED_USD);   // clamp: see the note at the deleted helpers
            // §#12/E28-r — PROPORTIONAL, not first-out. A burn releases a MIX: the band's USD leg
            // holds basket dollars AND the LP-owned increment, and modifyLiquidity returns them in
            // the band's CURRENT ratio. The old `-= min(usdAmount, basket)` drained the basket leg
            // FIRST, so on a partial exit `POOLED_USD - basketUsd` (the increment `_pricingBacking`
            // now reads as LP backing) grew by the whole released basket slice — phantom backing
            // paid to whoever withdrew next. Measured on a FULL exit: basket floored to 0 against a
            // 25.200001 residue, leaving that entire residue mispriced as LP equity.
            //
            // 🔴 §E230-PHANTOM — THE `if (basketLeg)` GUARD IS DELETED FROM THIS BRANCH, AND ITS
            // ABSENCE IS THE WHOLE FIX. The guard is CORRECT on the mint arm above: dollars arriving
            // from a swapper are not basket-owned, so they must not grow the basket's claim. It is
            // WRONG here, because a burn does not get to choose which dollars leave. The USD leg is
            // one undivided balance; when `usdAmount` leaves it, basket dollars and the LP increment
            // leave in the band's CURRENT ratio no matter who took them. Gating the release on
            // `basketLeg` meant a SWAP drained `POOLED_USD` while `basketUsd` stood still.
            //
            // MEASURED (BackingGateSplit, and reproduced independently): across eight 1-ETH swaps
            // `committed` never moved -- 188,375.647057 every iteration -- while `POOLED_USD*1e12`
            // fell 1,882.965293 per swap, so the gap grew linearly and the phantom equalled EXACTLY
            // the swapper's USDC out. Headroom eroded at the same rate, making OverCommitted a
            // matter of volume: 63,625.456 / 1,882.965 ≈ 34 swaps.
            //
            // ⇒ IT DROVE `basketUsd` ABOVE `POOLED_USD`, WHICH IS NOT A TOLERANCE QUESTION BUT AN
            // IMPOSSIBLE STATE: the basket cannot own more of the USD leg than the leg contains, and
            // `_pricingBacking` reads `POOLED_USD - basketUsd` as LP backing, so the surplus was
            // phantom in the other direction from the one E28-r fixed. Same defect, same remedy,
            // one arm further along -- which is why the fix is to DELETE a condition rather than add
            // a clamp. A clamp here would have pinned the symptom (`basketUsd = min(basketUsd,
            // POOLED_USD)`) and left the divergence generating it (standing rule 17).
            //
            // ⚠️ The gate only began refusing this because it was FIXED: `_reportEquity` had no
            // callers, so `total()` was 0 and the require compared `0 <= haircutTvl` -- always true.
            // The drift had been accumulating silently the whole time; arming the bound exposed it.
            uint b = basketUsd;
            uint out_ = pooledPre <= usdAmount ? b   // whole leg left: basket leaves with it
                      : Math.mulDiv(b, usdAmount, pooledPre);
            basketUsd = b - out_;               // §ISBTC-SPLIT: both arms were identical
            // The burn side moves equity DOWN. Reporting here keeps the accountant on the same
            // clock as the mint side -- a sum of per-band figures is only meaningful if every term
            // is current (§A.16b one level up), which is why this is a push at the moment of change.
            _reportEquity();
        }
    }

    /// @notice The venue just SETTLED `lpOwned6` as the band's remaining LP-owned USD leg — it paid the
    ///         rest out in QU!D, so the BASKET now owns that slice of the mirror. Re-anchors `basketUsd*`
    ///         to `POOLED_USD_* - lpOwned6` instead of leaving it to whatever the burn happened to release.
    /// @dev    WHY THIS EXISTS. `POOLED_USD_* - basketUsd*` is the number `_pricingBacking` reads as LP
    ///         equity, so it must equal what the venue actually still owes. It cannot, if both sides move
    ///         independently: the venue pays a SHARE-proportional slice (`served/lpShares`) while the burn
    ///         removes a LIQUIDITY-proportional one (`served/bandEth`), and the two differ by exactly the
    ///         amount the band's own trading has skewed it away from 1:1. Measured on the LVR probe with a
    ///         367.9-ETH band against 400 shares: 636.44 USD of a 60,000 increment, 8 bps of LP value,
    ///         evaporating into an accumulator nobody reconciled. Netting it here makes the identity exact
    ///         rather than approximately right, and it is the BASKET's leg that moves because the QU!D was
    ///         minted against basket backing.
    /// @dev    The floor is not a safety clamp: `lpOwned6 > POOLED_USD_*` means the venue believes it owes
    ///         more LP-owned dollars than the curve mirror holds, which the SUBTRACTION would silently wrap.
    function absorbPaidUsd(uint lpOwned6) external onlyUs {
        uint pooled = POOLED_USD;
        uint base = pooled > lpOwned6 ? pooled - lpOwned6 : 0;
        basketUsd = base;                           // §ISBTC-SPLIT: both arms were identical
    }

    /// @dev Token-leg (ETH or BTC) of _handleDelta. delta>0 → take+burn (ETH pays
    ///      real ETH out); delta<0 → mint+settle and (in-range) pool it.
    /// §V4-CUT — same removal as the USD leg, and the SAME reason it is safe: the comment below
    /// already said the real ETH payout was SEPARATE from the mock burn ("the burned mockETH is
    /// matched by real ETH paid out"). `BAND.takeETH` is where value moves; the mock was a shadow.
    /// ⚠️ THE `!IS_BTC` GUARD STAYS AND IS **NOT** IS_BTC-DRIFT TO BE DELETED LATER: ETH pays out real
    // §DE-TICK — `_settleTokSide` FOLDED INTO `_handleDelta`. With `d.vol` naming the leg there was
    // no selection left to make, so the frame held six lines and a `token1isVol` read. The `!IS_BTC`
    // guard it carried moved with it, unchanged: ETH pays out real ether, BTC settles by Lightning
    // cooperative close. That is one of the four known-REAL asymmetries -- see CLAUDE.md.


    /// §V4-CUT — THE LAST TWO v4 READS, NOW ANSWERED FROM OUR OWN STATE.
    /// These asked Uniswap's singleton for the spot price and the position's size. We hold both now:
    /// the price is the oracle the fill settles at, and the "position" is the band's own inventory.
    /// `liquidity` reports `POOLED` — the band's volatile holding — because that is what the callers
    /// actually want (how much depth is there), and it was only ever v4 liquidity units because v4
    /// was the custodian.
    /// ⚠️ The tick bounds are ignored: with inventory held directly there is no per-range position to
    /// look up. Callers passing (0,0) already relied on that.
    /// 🔴 §V4-CUT — THE RETURN IS A PLAIN PRICE NOW, NOT A SQRT PRICE, AND THE NAME SAYS SO.
    /// It used to be `slot0.spotPrice`. It is now the oracle price the fill settles at. I first
    /// changed the VALUE while keeping the NAME and TYPE, which left every sqrt-space consumer
    /// (`SwapLib.updateTicks` → `TickMath.getTickAtSqrtPrice`, `SwapLib.soldFractionWad`) computing
    /// garbage with nothing reverting. Renaming turns that silent wrong answer into a COMPILE ERROR
    /// at every call site — which is the only honest way to hand this over.
    /// ⚠️ Consumers must be moved to PRICE SPACE, not handed a reconstructed sqrt: the sqrt source is
    /// gone, so reconstructing one would be inventing a number to feed math that should not need it.
    /// §DE-TICK — NO PARAMETERS, NO int24, NO uint160. The tick bounds were ignored (there is no
    /// per-range position to look up), `currentTick` was always 0, and `uint160` was only ever
    /// `spotPrice`'s width — a price has no reason to be 160 bits, and every consumer was paying
    /// a cast for it. Plain `uint` throughout.
    /// §BOOTSTRAP — RETURNS THE RING'S `lastPrice`, NOT AN 1800s TWAP. Reading a 30-minute average
    /// here was wrong on three counts, and the third broke the deploy outright:
    ///   • SEMANTICS: `poolStats` is the band's CURRENT price and inventory. A TWAP is a different
    ///     quantity, and the consumers that need one ask for it BY NAME (`getTWAPforAsset`) -- the
    ///     swap path already does, so nothing loses manipulation resistance here.
    ///   • COST: it made a frequently-read `view` perform an external CALL into Aux for a number
    ///     this contract already has in its own storage.
    ///   • BOOTSTRAP: at deploy the ring holds ONE observation stamped `now`, so a read 1800s back
    ///     has no history and reverts `twap: pre-history`. That is what `Quid.setup` hit, and it
    ///     took every fixture's setUp down with it.
    /// `lastPrice` is seeded from the reference pool in `OracleLib.initPool` and updated by every
    /// observation write, so it is defined from the first block and never needs history.
    function poolStats() public view returns (uint priceWad, uint liquidity) {
        priceWad = obsState.lastPrice;
        liquidity = POOLED;
    }


    // §V4-CUT — `_writeObservation(spotPrice)` DELETED HERE: it had no callers left. It existed
    // to convert v4's sqrt-price once, at the write, so the ring stored plain price. Nothing hands
    // us a sqrt-price any more -- every live write goes through `_writeObservationPrice` with a
    // price the band already has -- so the conversion had nothing to convert. It was the last
    // `BasketLib.getPrice` consumer on the write path, and the last place a sqrt-price could enter
    // storage.

    /// @dev §V4-CUT — the fill, in its OWN FRAME so `swap` stays under the stack limit.
    ///      Settles AT ORACLE against inventory: one price, no traversal, no discovery.
    ///      UNITS: `px` is WAD USD per unit volatile — the SAME basis as `BasketLib.getPrice`, the
    ///      observation ring's stored price, and `getTWAPforAsset`. `convert` carries the 6<->18
    ///      bridge and is the same conversion `routeSwap` uses; a second one here is how the
    ///      §A.50/C2 asymmetry happened.
    ///      SIGN: positive leaves the pool, negative enters it. `forOne` pays leg 0, receives leg 1.
    function _fillDelta(bool inputIsUsd, uint amount, uint px)
        private view returns (Delta memory d, uint out) {
        // §DE-TICK — THE CALLER SAYS WHICH SIDE IT IS PAYING, rather than handing over v4's
        // `zeroForOne` for us to re-derive. That derivation was `token1isVol ? forOne : !forOne`
        // against a `zeroForOne` the caller had itself built from `token1isVol` -- two flips that
        // CANCELLED for both values of the flag, so the pair only ever transported `forVolatile`.
        out = BasketLib.convert(amount, px, inputIsUsd);
        // 🔴 FIRM QUOTE (owner) — THE IMBALANCE CHARGE IS IN THE PRICE, NOT TRUED UP AFTERWARDS.
        // We feed 1inch / Khalani, so the counterparty is a SOLVER that has ALREADY committed a
        // price to its end user. There is nobody to bill later and no relationship to bill through,
        // so a quote adjustable after the fact is unusable in a route. That killed estimate-plus-
        // true-up and `BatchLedger` with it — a contract DELETED, not added.
        // ⚠️ THIS IS NOT THE SPREAD THAT WAS REMOVED. The skew was rejected as compensation paid to
        // arbitrageurs we do not need, and that reasoning still holds — we restore 1:1 ourselves.
        // What is charged here is OUR COST OF DOING THE TRADE, recovered on a price we commit to.
        // Same formula, different economic role.
        // DRAIN vs FILL: buying volatile drains the scarce side (`wellSkew`, A&S pole — you CAN run
        // out); selling into us grows inventory (`sellSkew`, linear — you cannot run out of surplus).
        out -= (out * (inputIsUsd
            ? SwapLib.wellSkew(address(this), px, amount)
            : SwapLib.sellSkew(address(this), px, amount))) / 1e18;
        // THE 420 PPM, CHARGED HERE BECAUSE v4 WAS CHARGING IT. `OracleLib:180` set `k.fee = 420` as
        // the POOL TIER; v4 collected it and `Collect` harvested it into `feesPerShare`/`USD_FEES`.
        // Deleting v4 deletes the collector, so without this the fill charges NOTHING: the LP fee
        // lane earns zero, and the anti-grinding bound `w >= 1 - fee/C` degenerates to w = 100%.
        // Retained in `POOLED_*`, which `Quid.sol:136` calls "principal + ALL compounded fees" —
        // so it DOES reach LP claims, by compounding rather than per-share accrual. That difference
        // is one of TIMING (holder at claim vs holder at swap) and is decided when `Collect` goes.
        out -= (out * 420) / 1_000_000;
        // BOUNDED BY WHAT WE HOLD. At oracle price with no curve, nothing else stops a drain: the
        // traversal used to run out of liquidity, this runs out of inventory. Partial fill, never a
        // revert — `minOut` upstream carries the caller's tolerance.
        uint held = inputIsUsd
            ? (POOLED)              // paying out volatile
            : (POOLED_USD);     // paying out USD
        if (out > held) {
            out = held;
            amount = BasketLib.convert(out, px, !inputIsUsd);   // re-derive input for a partial
        }
        d = inputIsUsd ? Delta(-int256(amount), int256(out))    // USD in, volatile out
                       : Delta(int256(out), -int256(amount));   // volatile in, USD out
    }

    /// §V4-CUT — THE ORACLE REPOINT, AND IT IS THIS SMALL. The ring has stored PLAIN PRICE since
    /// §TICK-REMOVAL; `getSlot0` only ever handed over a sqrt-price because that was v4's API, and
    /// the docblock above said so outright ("stays until the PM is ours"). The fill computes the
    /// price directly, so it goes straight in with NO conversion — no `getPrice`, no sqrt, no tick.
    /// ⚠️ `observe`, `ringVariance` and all ~54 `getTWAPforAsset` call sites are UNTOUCHED: the
    /// variance estimator was already price-based, so nothing downstream needs re-deriving.
    /// @notice The ring's INDEPENDENT observation source for THIS instance. `address(0)` = none,
    ///         and this instance then records NO observations at all.
    ///
    /// @dev §E222 — WHY THE RING NEEDED A SOURCE AT ALL. Both ring writes used to pass
    ///      `AUX.getTWAPforAsset(ASSET, 1800)`, which READS this ring via `twapBody`→`observe` and
    ///      then anchors to Chainlink. The ring therefore recorded a value derived from ITSELF plus
    ///      Chainlink: `twapResolve`'s deviation test and `BasketLib.isManipulated` were comparing
    ///      one source against a smoothed copy of itself. Nothing reverted — the guards still ran and
    ///      still computed; they had simply lost the ability to DISAGREE. Before the v4 cut the ring
    ///      recorded the POOL'S SPOT PRICE, a real observation of executed trades, with Chainlink as
    ///      the anchor checking it. Removing the AMM removed the observation, not the anchor.
    ///
    /// @dev ETH instance: 1inch's OffchainOracle. Aggregated spot across many venues, and verified
    ///      on-chain (not assumed) to DISAGREE with Chainlink — 0.08% on ETH/USD — which is exactly
    ///      what makes it a second source rather than an echo. A plain rate, so no `TickMath`.
    ///
    /// 🔴 BTC instance: DELIBERATELY UNSET, AND THE CHECK IS DELETED RATHER THAN POINTED AT A
    ///      WRAPPER. 1inch can only quote `getRate(WBTC, USDC)` — WRAPPED BTC — and there is no
    ///      wrapper-free BTC spot on-chain at all, because native BTC has no EVM presence. Observing
    ///      WBTC would import the wrapper's basis and, far worse, make a WBTC DEPEG
    ///      INDISTINGUISHABLE FROM BITCOIN MOVING: custodial failure arriving dressed as price, which
    ///      σ², the skew and liquidation would each read as a market event.
    ///      ⚠️ A WRONG GUARD IS WORSE THAN NO GUARD — a vacuous one reports nothing you can act on,
    ///      a wrong one reports something you WILL act on. With no source the ring is simply not
    ///      written, `ringVariance` returns 0, and §E213's sentinel prices unmeasured variance at the
    ///      CEILING. That is honest: we cannot observe BTC independently, so we do not pretend to.
    ///      ▶️ If a wrapper-free BTC source ever exists it is pinned HERE, and the check is written
    ///      against it fresh — never revived from history.
    address public observationSource;

    /// @dev The exact call to make on `observationSource`, pinned WITH it. Empty = no source.
    ///      Kept as calldata rather than a hardcoded selector because the read shape is the SOURCE's
    ///      (Curve takes a coin index, a feed takes none), and hardcoding one venue's shape is how a
    ///      rejected pool's index survives into its replacement.
    bytes public OBS_CALLDATA;


    function setObservationSource(address src, bytes calldata call_) external {
        require(msg.sender == DEPLOYER, "403");
        require(observationSource == address(0), "!");
        observationSource = src; OBS_CALLDATA = call_;
    }

    /// @dev THE READ MUST NOT BE ABLE TO HALT THE BAND. `ExternalTwap.oneInchRateWad` reverts on a
    ///      zero/failed read, and this sits on the SWAP path — using it directly would turn an
    ///      oracle outage into "every swap and repack reverts", trading a silent measurement fault
    ///      for a hard liveness one. So the call is a raw `staticcall` and ANY failure (revert, short
    ///      return, zero) simply SKIPS the write: the ring goes stale, σ² decays to unmeasured, and
    ///      the same §E213 sentinel prices at the ceiling. Degrade to unmeasured, never halt.
    ///      `getRate` is defined on RAW units (`dstRaw = srcRaw·rate/1e18`), so
    ///      `priceWad = rate · 10^srcDec / 10^dstDec`; USDC is 6-dec.
    function _observeIfSourced() internal {
        address src = observationSource;
        if (src == address(0)) return;
        // (§E232) CURVE'S ON-POOL EMA, NOT 1inch's AGGREGATOR — because the aggregator DOES NOT FIT
        // IN A BLOCK. `getRate` stood here and iterates all fourteen registered DEX oracles and
        // their connectors, so one "observation" was a full multi-venue aggregation: **31,722,803
        // gas against a 30M limit**, i.e. every swap and repack on this path exceeded an entire
        // block. `price_oracle(k)` is a single storage read of the pool's own EMA — a few thousand
        // gas — and returns a PLAIN WAD price, so there is nothing to decode and no scaling step to
        // get wrong.
        //
        // ⚠️ INDEX 1 IS DERIVED, NOT GUESSED. Curve prices coin `k+1` in units of coin 0, and this
        // pool's ordering was read from the chain: USDC=0, WBTC=1, WETH=2. So `price_oracle(1)` is
        // coin2/coin0 = **WETH in USDC**, which is already USD·1e18 — `VOL_DECIMALS` scaling would
        // DOUBLE-COUNT. A wrong index here reads WBTC/USDC and prices ETH at the BTC price, which is
        // why `CurveObserverIsCheapAndSane` asserts against Chainlink rather than trusting this note.
        //
        // ⚠️ AND THE INDEPENDENCE CLAIM IS WEAKER THAN 1inch's — SAY SO RATHER THAN INHERIT IT.
        // `ExternalTwap`'s header argues "correlated sources are one source" and that a single Curve
        // pool is one venue with one depeg mode, which is TRUE and is why 1inch was chosen. It is
        // also moot: an aggregation that cannot be called is not a source at all. This is one venue,
        // genuinely different in MECHANISM from Chainlink's pushed feeds (an on-pool EMA of executed
        // trades), and that is what the deviation test needs to mean anything.
        // 🔴 NO SOURCE IS PINNED (see `DeployLib`), so this body does not run today. The SELECTOR
        //    and any index belong TO THE CHOSEN SOURCE and must be decided WITH it — a pool index is
        //    meaningless without the pool, and carrying TriCrypto's `1` forward would silently price
        //    ETH as WBTC on any pool ordered differently. Left as a raw call so the next source
        //    supplies its own encoding rather than inheriting a rejected pool's.
        (bool ok, bytes memory out) = src.staticcall(OBS_CALLDATA);
        if (!ok || out.length < 32) return;
        uint priceWad = abi.decode(out, (uint));
        if (priceWad != 0) _writeObservationPrice(priceWad);
    }

    function _writeObservationPrice(uint price) internal {
        OracleLib.writeObservation(observations, obsState, price);
    }

    /// @notice §E63 — ONE observe, dispatched. These were TWO externals with IDENTICAL bodies
    ///         differing only in which ring they read, i.e. two selectors, two dispatch entries and
    ///         two copies of the call frame for one behaviour. The `_obs`/`_obsState` accessors
    ///         already exist to pick the ring, so the duality was paid for twice.
    /// @dev    This one clears the relocation threshold the other attempts did not (§E63): it
    ///         DELETES a surface rather than moving a small body, and moving small bodies out of
    ///         Core has measured WORSE three times (−73, −207, −471) because the caller pays the
    ///         call overhead. Not client-facing — `tools/check-client-abis.py` has zero references
    ///         to either name; the only callers are `SwapLib:104-105`.
    function observe(uint32[] calldata secondsAgos)
        external view returns (uint192[] memory) {
        return OracleLib.observe(observations, obsState, secondsAgos);
    }
}
