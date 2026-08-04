
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Aux} from "./Aux.sol";
import {mock} from "./mock.sol";
import {Vogue} from "./Vogue.sol";
import {Vault} from "./Vault.sol";
import {Basket} from "./Basket.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {OracleLib} from "./imports/OracleLib.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {VogueLib} from "./imports/VogueLib.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
// §E5 — the shared per-band premium sink (rule 2: ONE declaration, in the canonical file).
import {ISkewSink, ILevEquity, ILevEquityBtc} from "./imports/Interfaces.sol";
// §E21: IERC20Min had TWO declarations (here and imports/ILevVenue.sol). One home now.
import {IERC20Min} from "./imports/ILevVenue.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

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
/// POOLED_USD_ETH + POOLED_USD_BTC ≤ current basket TVL — enforced
/// inline in _handleDelta on every USD add. BTC's share of the total is
/// demand-driven within that ≤TVL invariant (no separate allocation cap).
/// mockUSD_ETH and mockUSD_BTC stay as separate mocks because each pool
/// can have its own out-of-range positions (limit orders) — those are
/// not in POOLED_USD_{ETH,BTC} (which is the active in-range slice).
contract Core is SafeCallback {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    /// Per-pool oracle rings — the engine now lives in OracleLib (delegatecall),
    /// so the structs come from there. The scalar trio is grouped per pool so
    /// the helpers take one `ObsState storage` ref (isBTC-dispatched via
    /// `_obsState`). These were never read externally; only POOLED_* getters
    /// (kept) are.
    OracleLib.ObsState internal obsETH;
    OracleLib.ObsState internal obsBTC;
    OracleLib.Observation[65535] internal observationsETH;
    OracleLib.Observation[65535] internal observationsBTC;
    function _obsState(bool isBTC) internal view returns (OracleLib.ObsState storage) {
        return isBTC ? obsBTC : obsETH;
    }
    function _obs(bool isBTC) internal view returns (OracleLib.Observation[65535] storage) {
        return isBTC ? observationsBTC : observationsETH;
    }

    PoolKey VANILLA_ETH;
    PoolKey VANILLA_BTC;

    /// @notice PoolIds for the two VANILLA pools, computed once in the
    ///         constructor from the assembled PoolKeys. Used everywhere
    ///         a PoolId is needed (getSlot0, donate, etc.) — no runtime
    ///         .toId() recomputation.
    PoolId public POOL_ID_VANILLA_ETH;
    PoolId public POOL_ID_VANILLA_BTC;

    /// @notice In-range USD slice held against the ETH/USD pool. Sum of
    /// this plus POOLED_USD_BTC is the total in-range USD; out-of-range
    /// USD lives in mockUSD_ETH/mockUSD_BTC respectively.
    /// @notice §#12 — BASKET-SUPPLIED quoting depth (6-dec, shared across both bands). The split
    ///         #12 is named for: `POOLED_USD_*` track what is IN each CURVE (they move on every
    ///         swap); this tracks what the BASKET actually CONTRIBUTED (it moves ONLY when the
    ///         basket adds or removes depth via `addLiq`/burn — never on a swap).
    ///         `committedUsd18` is derived from THIS, so the backing gate stops counting an LP's
    ///         sale proceeds as a basket commitment.
    uint public basketUsdEth;
    uint public basketUsdBtc;
    uint public POOLED_USD_ETH;
    /// @notice In-range USD slice held against the BTC/USD pool.
    uint public POOLED_USD_BTC;
    uint public POOLED_ETH;
    uint public POOLED_BTC;

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
    function committedUsd18() public view returns (uint) {
        return _bandEquityUsd18(false) + _bandEquityUsd18(true);
    }

    /// @dev One pool's equity USD (18-dec): its in-range USD less that pool's live leverage debt, floored at 0.
    function _bandEquityUsd18(bool isBTC) internal view returns (uint) {
        uint pooled18 = (isBTC ? basketUsdBtc : basketUsdEth) * 1e12;   // §#12: BASKET contribution, not curve inventory
        uint debt18 = _levDebtUsd18(isBTC);
        return pooled18 > debt18 ? pooled18 - debt18 : 0;
    }

    /// @notice The BTC band's NET equity USD (18-dec): in-range BTC-pool USD less that pool's live leverage
    ///         debt. External read surface (monitoring / band-sizing probes); measures NET so the debt-funded
    ///         buffer is not counted as consuming basket-USD headroom.
    function btcBandEquityUsd18() external view returns (uint) { return _bandEquityUsd18(true); }

    /// @dev That pool's total leverage debt (18-dec), read live from the pinned LevManager (0 if unset). The
    ///      ETH manager (`LEV_MANAGER`) and BTC manager (`LEV_MANAGER_BTC`) both live on the Vault (`BTCVAULT`).
    ///      FAIL-SAFE: `totalDebtUsd` iterates the open-LP book (external venue reads); a revert there must NOT
    ///      brick `committedUsd18` (the backing gate on every swap/mint/redeem). On failure we subtract 0 debt,
    ///      which only RAISES committed ⇒ a STRICTER gate + LOWER redeemable — conservative, never over-issue.
    ///      Mirrors `vogueETH`'s try/catch over the same LevManager reads.
    function _levDebtUsd18(bool isBTC) internal view returns (uint) {
        if (address(BTCVAULT) == address(0)) return 0;
        address mgr = isBTC ? BTCVAULT.LEV_MANAGER_BTC() : BTCVAULT.LEV_MANAGER();
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
    /// draw at most the FREE reserve `POOLED_USD_BTC − pendingSwapOutUsd`, so
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
    Flow internal _flowBTC;
    Flow internal _flowETH;
    /// @notice §E55 — the SLOW half of the adaptive flow estimate. Same `Flow` shape, same
    ///         `FLOW_DECAY`, decayed at 1/`FLOW_SLOW_N` the rate ⇒ an N× longer half-life with
    ///         **NO THIRD DECAY CONSTANT** (this file already warns that one would be "an
    ///         unjustified magic number"). Only an integer ratio is added.
    Flow internal _flowSlowBTC;
    Flow internal _flowSlowETH;
    /// @dev The slow register's half-life as a MULTIPLE of the fast one (48h × 7 ≈ 14 days). Its
    ///      exact value is deliberately NOT load-bearing: `flowEwmaUsd` takes the MIN of the two,
    ///      so the slow leg acts only as a CEILING. Being roughly right is enough, and erring LONG
    ///      is safe — which is the property a single fitted half-life does not have.
    uint internal constant FLOW_SLOW_N = 7;
    uint internal constant FLOW_DECAY   = 999759352855809024; // per-min → 48h half-life (0.5^(1/2880)). The well's flow-EWMA / inventory-skew target wants a wide, manipulation-resistant memory. (The Aux redeem-fee `baseRate`, a separate 12h register, was REMOVED — QU!D has no peg-arb loop; this 48h flow decay is unrelated and stays.)
    uint internal constant FLOW_MAX_MIN = 525600000;          // decay-exponent cap (Liquity)

    /// @notice Retained band market-making premium per pool, as a DECAYED EWMA (6-dec USD) — the
    ///         θ NUMERATOR source (#107/D3). Deliberately the SAME `Flow` struct, the SAME
    ///         `FLOW_DECAY` (48h) and the SAME read/bump helpers as the swap-volume register:
    ///         premium accrues on exactly the same swap events and wants exactly the same memory,
    ///         so a THIRD decay constant would be an unjustified magic number. (This does NOT
    ///         re-tie the 48h flow window to the 12h `BR_DECAY` — those stay un-tied by design;
    ///         this is a SECOND consumer of the 48h window, not a merge of two windows.)
    Flow internal _premETH;
    Flow internal _premBTC;

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
    function _bumpFlow(bool isBTC, uint usd6) internal {
        _bumpEwma(isBTC ? _flowBTC : _flowETH, usd6);
        _bumpEwma(isBTC ? _flowSlowBTC : _flowSlowETH, usd6);   // §E55: the slow leg sees the same flow
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
    function flowEwmaUsd(bool isBTC) public view returns (uint) {
        uint fast = _decayed(isBTC ? _flowBTC : _flowETH);
        uint slow = _decayedBy(isBTC ? _flowSlowBTC : _flowSlowETH, FLOW_SLOW_N);
        return fast < slow ? fast : slow;
    }

    /// @notice This pool's decayed RETAINED-PREMIUM EWMA (6-dec USD) — the band's realized
    ///         market-making earnings over the trailing ~48h window. θ's numerator (#107/D3):
    ///         the compensation the band actually receives for bearing IL. Reserve `avgYield` is
    ///         deliberately NOT part of this — that number sizes how much QUI to mint up front and
    ///         has nothing to do with how big the band should be (user, 2026-07-26); the dollar leg
    ///         earns the reserve baseline whether it is banded or idle (`spec.md`), so reserve yield
    ///         is not marginal compensation for IL risk and must not inflate the risk budget.
    function premiumEwmaUsd(bool isBTC) public view returns (uint) {
        return _decayed(isBTC ? _premBTC : _premETH);
    }

    /// @notice Aggregate leverage claim on this pool (6-dec USD) — the well's
    ///         DISTINCT "leverage demand" signal. Levered LPs both lock current volatile
    ///         (shrinking deliverable inventory) AND will draw/return it (raising demand),
    ///         so it enters the skew scarcity on BOTH sides. Reuses the live
    ///         LevManager debt total already read for committedUsd18 — no new aggregate.
    function levClaimUsd6(bool isBTC) public view returns (uint) {
        return _levDebtUsd18(isBTC) / 1e12;
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
    function levGrossNative(bool isBTC) public view returns (uint) {
        if (address(BTCVAULT) == address(0)) return 0;
        if (isBTC) {
            address mgr = BTCVAULT.LEV_MANAGER_BTC();
            if (mgr == address(0)) return 0;
            try ILevEquityBtc(mgr).totalGrossCollateralBtc() returns (uint256 g) { return g; } catch { return 0; }
        }
        address m = BTCVAULT.LEV_MANAGER();
        if (m == address(0)) return 0;
        try ILevEquity(m).totalGrossCollateralEth() returns (uint256 g) { return g; } catch { return 0; }
    }

    /// @notice Annualized realized variance (WAD) of this pool's oracle — the well
    ///         skew's live-vol steepness input (steeper premium in higher vol, matching a
    ///         native-BTC MM's real cost). Thin pass to VogueLib (identical to Vogue's own
    ///         `realizedVarianceWad`); exposed here so the skew reads ONE source for both
    ///         pools regardless of which band contract drives the swap. Fails-open to 0
    ///         (insufficient history) ⇒ no steepening, base convex curve still applies.
    function realizedVarianceWad(bool isBTC) external view returns (uint) {
        return VogueLib.realizedVarianceWad(address(this), isBTC);
    }

    /// @notice §E59 — realized tick variance from the STORED observations (per-second, WAD) plus the
    ///         span it was measured over. Reads the RING, so it never sees `observe`'s interpolation
    ///         — the thing that used to manufacture zeros in any stretch quieter than the sample
    ///         grid. `span == 0` means NOT ENOUGH REAL UPDATES, which is UNKNOWN and NOT calm.
    function ringVarianceWad(bool isBTC, uint n)
        external view returns (uint varPerSecWad, uint spanSecs) {
        return OracleLib.ringVariance(_obs(isBTC), _obsState(isBTC), n);
    }

    /// @notice (well) Cumulative scarcity-premium the skew has RETAINED as backing, per
    ///         pool — the withheld fraction of a swap-out's USD when the pool is BTC/ETH-scarce
    ///         (the swapper pays above oracle for scarce inventory; the difference stays as
    ///         surplus basket backing). NOT segregated — it's fungible backing. The drainer's full USD enters
    ///         Aux; only the post-skew `consumed` is minted into POOLED, so the withheld premium STAYS in the
    ///         basket as pure LP backing (NAV). Tracked + evented here so the LP-retained skew profit is
    ///         auditable P&L — the running total the fleet's self-funding JIT refill captures FOR the LPs.
    ///         (The old swapper-facing refill BONUS was REMOVED: refill is a self-funding fleet op — JIT
    ///         Morpho-flash BTC → creditSwapIn → repay, gas via #87 — so paying a separate bonus to the refiller
    ///         was redundant; the premium accrues to LPs directly, no payout.)
    ///         Units = the swap-out's USD driving amount for that pool (6-dec).
    uint public skewPremiumBTC;
    uint public skewPremiumETH;
    event SkewPremiumRetained(bool indexed isBTC, uint256 premiumUsd, uint256 cumulative);

    /// @notice Record a scarcity-premium retained on a swap-out. Called by the well swap
    ///         bodies (SwapLib.creditSwapOutBody in the Vault context, swapToBody in Aux) — same
    ///         onlyUs seam as Core.swap. No-op on a flush pool (premium == 0).
    function recordSkewPremium(bool isBTC, uint256 premiumUsd) external onlyUs {
        if (premiumUsd == 0) return;
        uint256 cum;
        // §E5 — the counters below are an AUDIT RECORD (asserted by
        // testGrindRemoval_DrainPaysRetainedSkewPremium); the CREDIT is what actually reaches LPs.
        // Without it the premium accrues to basket backing, which prices QU!D and not LP shares.
        if (isBTC) { skewPremiumBTC += premiumUsd; cum = skewPremiumBTC; }
        else       { skewPremiumETH += premiumUsd; cum = skewPremiumETH; }
        // ONE call site, dispatched by address: `Vogue` and `Vault` expose the same
        // `creditSkewPremium` signature, so this is a single encode instead of one per branch.
        ISkewSink(isBTC ? address(BTCVAULT) : address(VOGUE)).creditSkewPremium(premiumUsd);
        // Also fold it into the decaying RATE register (#107/D3). The cumulative counters above
        // are monotonic totals — useless as a yield; θ needs a rate, which is what this provides.
        _bumpEwma(isBTC ? _premBTC : _premETH, premiumUsd);
        emit SkewPremiumRetained(isBTC, premiumUsd, cum);
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

    mock internal mockETH;
    mock internal mockBTC;
    mock internal mockUSD_ETH; // synthetic $-side of ETH pool (in & out of range)
    mock internal mockUSD_BTC; // synthetic $-side of BTC pool (in & out of range)

    bool public token1isETH;  // ETH pool ordering
    bool public token1isBTC;  // BTC pool ordering

    /// @notice Fused token-ordering accessor. Replaces the
    /// `isBTC ? token1isBTC() : token1isETH()` ternary at callsites.
    function token1is(bool isBTC) external view returns (bool) {
        return _t1(isBTC);
    }

    // ─── isBTC storage-ref selectors (EIP-170 dedup) ─────────────────
    // Each picks the per-pool slot/array so the swap/repack/delta/observation
    // bodies run ONE isBTC-parameterized path instead of mirrored ETH/BTC
    // branches. Value types can't be returned by storage ref, so the scalar
    // observation state is grouped in `_obsState` (ABI-preserving: the old
    // public obs getters were unread externally; only the array getters and
    // POOLED_* getters, which stay, are read by tests).
    function _t1(bool isBTC) internal view returns (bool) {
        return isBTC ? token1isBTC : token1isETH;
    }
    function _poolId(bool isBTC) internal view returns (PoolId) {
        return isBTC ? POOL_ID_VANILLA_BTC : POOL_ID_VANILLA_ETH;
    }
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
    function externalMockDust(bool isBTC) external view returns (uint usdDust, uint tokDust) {
        usdDust = _dustOf(address(_mockUsd(isBTC)));
        tokDust = _dustOf(address(_mockTok(isBTC)));
    }

    function _dustOf(address m) internal view returns (uint) {
        uint held = IERC20Min(m).balanceOf(address(poolManager)) + IERC20Min(m).balanceOf(address(this));
        uint supply = IERC20Min(m).totalSupply();
        return supply > held ? supply - held : 0;   // never counted toward shares or P&L
    }

    function _mockUsd(bool isBTC) internal view returns (mock) {
        return isBTC ? mockUSD_BTC : mockUSD_ETH;
    }
    function _mockTok(bool isBTC) internal view returns (mock) {
        return isBTC ? mockBTC : mockETH;
    }
    // Value types can't be storage-ref'd, so POOLED_* moves go through these
    // isBTC-dispatched mutators (Math.min floors mirror the originals).
    function _addPooledUsd(bool isBTC, uint a) internal {
        if (isBTC) POOLED_USD_BTC += a; else POOLED_USD_ETH += a;
    }
    function _subPooledUsd(bool isBTC, uint a) internal {
        if (isBTC) POOLED_USD_BTC -= Math.min(a, POOLED_USD_BTC);
        else       POOLED_USD_ETH -= Math.min(a, POOLED_USD_ETH);
    }
    function _addPooledTok(bool isBTC, uint a) internal {
        if (isBTC) POOLED_BTC += a; else POOLED_ETH += a;
    }
    function _subPooledTok(bool isBTC, uint a) internal {
        if (isBTC) POOLED_BTC -= Math.min(a, POOLED_BTC);
        else       POOLED_ETH -= Math.min(a, POOLED_ETH);
    }

    Aux AUX; Vogue VOGUE; Basket BASKET; Vault BTCVAULT;

    /// @notice BtcVault — the BTC LP/swap side, regrouped out of Vogue/Aux.
    /// Pinned once (post-deploy, like Vogue's btcChannels) since BtcVault is
    /// deployed after Core. Read for `totalSharesBTC()` (the BTC
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
    function skewPremiumCum(bool isBTC) external view returns (uint) {
        return isBTC ? skewPremiumBTC : skewPremiumETH;
    }

    /// @notice BTC band theta-numerator: the native IL-bearing backing = aggregate locked sats (lpSharesBTC,
    ///         net) + gross debt-funded buffer (totalBufferBTC). The BTC analogue of (vogueETH + totalBuffer)
    ///         on ETH. ONE source of truth for BOTH the LP-add clamp (BtcVaultLib._thetaClampBtc) and the
    ///         reseat clamp (VogueLib.addLiq isBTC) so they throttle on the SAME real capital -- NEVER the
    ///         disjoint WBTC-donation `vogueBTC` pool (that mis-base collapsed the band whenever donations were
    ///         thin, the opposite of what scarcity should do). 0 if no BTC vault wired.
    function btcThetaBacking() external view returns (uint) {
        return address(BTCVAULT) == address(0) ? 0 : BTCVAULT.totalSharesBTC() + BTCVAULT.totalBufferBTC();
    }

    // NOTE: ReseatETH is the LAST ETH action and ReseatBTC the LAST BTC action so
    // the `isBTC = uint8(a) >= uint8(Action.SwapBTC)` split in _unlockCallback
    // stays correct (all ETH actions < SwapBTC, all BTC actions >= SwapBTC).
    enum Action {
        SwapETH, RepackETH, ModLPETH, OutsideRangeETH, CollectETH, ReseatETH,
        SwapBTC, RepackBTC, ModLPBTC, OutsideRangeBTC, CollectBTC, ReseatBTC
    }

    modifier onlyUs {
        require(msg.sender == address(AUX)
             || msg.sender == address(VOGUE)
             || msg.sender == address(BTCVAULT), "403"); _;
    } bytes internal constant ZERO_BYTES = bytes("");

    /// @notice The deployer — the ONLY address that may run `setup`/`setBtcVault`, the authority-wiring pins
    ///         that admit VOGUE/AUX/BASKET/BTCVAULT into `onlyUs`. Captured at construction so a hostile
    ///         party can't FRONT-RUN an un-pinned wiring call in the deploy window and inject a malicious
    ///         `onlyUs` member (Core isn't Ownable; this is the immutable analog of the owner-gate the
    ///         siblings Basket.setBtcVault / Aux.setEthVenue already carry).
    address immutable DEPLOYER;
    constructor(IPoolManager _manager) SafeCallback(_manager) { DEPLOYER = msg.sender; }

    /// @param _vogue            Vogue contract (LP wrapper)
    /// @param _aux              Aux (settlement adapter)
    /// @param _basket           Basket (settlement target)
    /// @param _refKeyETH        Hardcoded V4 PoolKey for the REAL on-chain
    ///                          ETH/stable pool (e.g. ETH/USDT). Its current
    ///                          tick is read at setup time and used to
    ///                          seed VANILLA_ETH at the live market price.
    /// @param _refKeyBTC        Hardcoded V4 PoolKey for the REAL on-chain
    ///                          BTC/stable pool (e.g. USDC/WBTC). Read
    ///                          directly — no composition. WBTC = c0 by
    ///                          V4 lex-ordering (WBTC 0x2260 < USDC 0xA0B8).
    function setup(address _vogue, address _aux, address _basket,
        PoolKey calldata _refKeyETH, PoolKey calldata _refKeyBTC) 
        external { require(msg.sender == DEPLOYER, "403");   
        // auth-wiring pin (deployer only) anti-frontrun
        require(address(VOGUE) == address(0), "!");

        // Mocks are deployed through OracleLib (delegatecall) so the ~3.9 KB of
        // `mock` creation-code lives in the library, not Core's bytecode (EIP-170).
        // address(this) under delegatecall is Core, so ownership is identical.
        (address mE, address mB, 
        address mUE, address mUB) = OracleLib.deployMocks();
        mockUSD_ETH = mock(mUE); mockUSD_BTC = mock(mUB);
        mockETH = mock(mE); mockBTC = mock(mB);
        
        VOGUE = Vogue(payable(_vogue));
        AUX = Aux(payable(_aux));
        BASKET = Basket(_basket);

        // Both reference pools' live ticks are read in ONE library call so they
        // reflect a single consistent block snapshot, and the four mock approvals
        // ride along — see `OracleLib.prepRefs`. Every byte of that was deploy-time
        // code sitting in Core's RUNTIME against a hard EIP-170 deficit.
        // The ref-pool direction probes come back from the same call: they are pure
        // reads of the ref keys, so computing them HERE only put `Currency.unwrap`
        // in Core's runtime twice. `AUX.WBTC()` is queryable because AUX was wired
        // above, and is passed in so OracleLib need not import Aux for one getter.
        (int24 refTickEth, int24 refTickBtc, bool ethVolIsC0, bool btcVolIsC0) =
            OracleLib.prepRefs(poolManager, _refKeyETH, _refKeyBTC,
                mE, mB, mUE, mUB, address(AUX.WBTC()));

        // Both pools init identically; only the direction probe differs.
        _initPool(false, mE, mUE, ethVolIsC0, refTickEth);
        _initPool(true,  mB, mUB, btcVolIsC0, refTickBtc);
    }

    /// @dev Per-pool VANILLA init, shared by ETH and BTC. Builds the lex-sorted
    ///      PoolKey, records the ordering (token1isETH/BTC), initializes the V4
    ///      pool at the reference pool's live tick (direction-corrected via
    ///      `refVolIsC0`, floored toward −∞ to tickSpacing), and seeds the
    ///      oracle ring. Behavior-identical to the two prior inlined blocks.
    function _initPool(bool isBTC, address volMock,
        address usdMock, bool refVolIsC0, int24 refTick) internal {
        // Everything but the two VALUE-TYPE state writes lives in OracleLib: the
        // PoolKey assembly, the lex sort, the tick direction-correction + align, the
        // pool init and the oracle seeding are all deploy-time-only code that was
        // costing Core RUNTIME bytes under a hard EIP-170 deficit. `VANILLA_*` (a
        // struct) and the ring (an array) can be passed by STORAGE POINTER, which is
        // what makes the move possible; `token1is*` and `POOL_ID_*` are value types
        // with no pointer to pass, so those two assignments stay here.
        (bool token1isVol, PoolId id) = OracleLib.initPool(poolManager,
            isBTC ? VANILLA_BTC : VANILLA_ETH, _obsState(isBTC), _obs(isBTC),
            volMock, usdMock, refVolIsC0, refTick);

        if (isBTC) { token1isBTC = token1isVol; POOL_ID_VANILLA_BTC = id; }
        else       { token1isETH = token1isVol; POOL_ID_VANILLA_ETH = id; }
    }

    /// @notice Draw down the BTC pool's committed USD side when an on-chain
    ///         swap-out delivery pays the LP its exact proceeds. `usd6` is 6-dec.
    function drawPooledUsdBtc(uint usd6) external onlyUs {
        // FAIL-LOUD, not silent-clamp: the sole caller (BtcVaultLib.settleDelivered) mints QUI for the FULL
        // `exactUsd` it draws here, so a `Math.min` under-draw would leave that excess QUI unbacked. The
        // request/gate invariant (exactUsd ≤ pendingSwapOutUsd ≤ POOLED_USD_BTC) makes this subtraction never
        // underflow in correct operation; checked math reverts the whole settlement if a future change breaks
        // it — the draw and the mint can never disagree by construction.
        POOLED_USD_BTC -= usd6;
    }

    /// @notice Record a new undelivered on-chain swap-out obligation's USD
    ///         (at requestSwapOutOnchain). The matching `subPendingSwapOut` fires
    ///         on EITHER delivery (paid to the LP) or reversal (settleSwapIn).
    function addPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd += usd6;
    }

    /// @notice Clear an obligation's USD when it is delivered (paid exact to the
    ///         LP) or reversed. Floored at 0.
    function subPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd -= Math.min(usd6, pendingSwapOutUsd);
    }

    // ─── External entrypoints — same surface as before, parallel BTC ──
    /// @notice Fused modLP — isBTC selects which pool. `delta` is the
    /// volatile-side change (ETH amount for ETH pool, BTC sats for BTC).
    /// @notice full-2× band op. The debt-funded buffer leg folds into POOLED_USD_* like any in-range USD;
    ///         committedUsd18 recovers equity by subtracting min(live debt, pooled buffer). No separate buffer
    ///         param — the old `levUsd` slot was a no-op post-fold and has been removed.
    function modLP(bool isBTC, uint160 sqrtPriceX96, uint delta,
        uint deltaUSD, int24 tickLower, int24 tickUpper,
        address sender) public onlyUs returns (uint sent) {
        BalanceDelta d = abi.decode(poolManager.unlock(abi.encode(
            isBTC ? Action.ModLPBTC : Action.ModLPETH,
            sqrtPriceX96, delta, deltaUSD,
            tickLower, tickUpper, sender)), (BalanceDelta));
        int128 amt = _t1(isBTC) ? d.amount1() : d.amount0();
        sent = amt > 0 ? uint(int(amt)) : 0;
    }

    /// @notice Fused outOfRange. Action enum differentiates ETH vs BTC.
    function outOfRange(bool isBTC, address sender, int liquidity,
        int24 tickLower, int24 tickUpper, address token)
        public onlyUs returns (uint tokOut) {
        BalanceDelta d = abi.decode(poolManager.unlock(abi.encode(
            isBTC ? Action.OutsideRangeBTC : Action.OutsideRangeETH,
            sender, liquidity, tickLower, tickUpper, token)),
            (BalanceDelta));
        // On a burn (liquidity<0) the token (BTC/ETH) leg is positive — the mock
        // amount the order held. Returned so a closing BTC LP can net the boundary
        // orders' unfilled (native) sats out of its in-range native burn (callers
        // that don't need it, e.g. Vogue.pull, simply ignore the return).
        int128 t = _t1(isBTC) ? d.amount1() : d.amount0();
        tokOut = t > 0 ? uint(int(t)) : 0;
    }

    /// @notice Fused swap — isBTC selects which V4 pool. The shortfall signal is
    ///         ASYNC per-pool (in-frame refill is unsafe — re-enters Aux on
    ///         half-settled backing): ETH emits ETHRefillRequest (keeper → refillETH
    ///         buys back from free surplus); BTC emits a hop request (we don't mint WBTC).
    function swap(bool isBTC, uint160 sqrtPriceX96, address sender,
        bool forOne, address token, uint amount)
        onlyUs public returns (uint out) {
        BalanceDelta delta = abi.decode(poolManager.unlock(
            abi.encode(isBTC ? Action.SwapBTC : Action.SwapETH,
                sqrtPriceX96, sender, forOne, token, amount)),
            (BalanceDelta));
        out = uint(int(forOne ? delta.amount1() : delta.amount0()));

        // Per-pool shortfall arb. Threshold (1%) and trigger logic are
        // identical across pools; only the remediation differs. Both
        // sides bootstrap symmetrically: at deploy POOLED_X = 0 and
        // totalSharesX = 0, so the trigger naturally doesn't fire until
        // LPs join via modLP (which grows both in lockstep).
        // GROSS fee depth on both sides: for BTC, totalSharesBTC is NET, so add the levered buffer
        // (totalBufferBTC) to match POOLED_BTC (gross, includes the buffer) — keeps the shortfall
        // comparison gross-to-gross (unchanged behavior). ETH: vogueETH(net) vs totalShares(net) already balanced.
        uint totalSharesPool = isBTC
            ? BTCVAULT.totalSharesBTC() + BTCVAULT.totalBufferBTC()
            : VOGUE.totalShares();
        // BOTH sides compare REAL inventory, never just the in-pool token.
        // ETH = vogueETH() (in-range POOLED_ETH + Galaxy/AAVE/ether.fi venue
        // retention + idle). BTC has no yield-venue, but the protocol still HOLDS
        // off-pool WBTC (swept donations + swap deltas, accrued in vogueBTC), so
        // the BTC analogue is POOLED_BTC + vogueBTC. Comparing raw POOLED_BTC
        // over-fired the shortfall arb on off-range retention (lpShares > POOLED_BTC
        // by construction) — requesting a hop-source of BTC the protocol already
        // holds. Adding vogueBTC is monotone-safe: it can only SHRINK the measured
        // shortfall, never grow it, and suppressing a "shortfall" we can cover from
        // our own WBTC is correct (no need to source what we already hold).
        // BTC IL-protect: totalSharesBTC includes each LP's LEVERED slice (levPooledBTC), and its backing is
        // ALREADY inside POOLED_BTC — `syncLevBTC` pairs the net-equity as deltaBTC into POOLED_BTC in lockstep
        // with levPooledBTC (VaultLib.levAddNetBtc/levAddBufBtc), so the lev slice is monotone-neutral here.
        // (The ETH branch is NET-vs-NET: vogueETH() adds the lev book's NET equity (totalNetEquityEth, the
        // debt-funded buffer half offset by the LP's borrow) and totalShares() is NET, so no gross term is added
        // here — POOLED_BTC, by contrast, DOES include the lev slice gross (levAddBtc pairs the gross buffer in),
        // so BTC alone needs the +totalBufferBTC above to keep totalSharesBTC's comparison gross-to-gross.)
        uint pooledTok = isBTC
            ? POOLED_BTC + AUX.vogueBTC()
            : AUX.vogueETH();
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
                // pro-rata of vogueETH, so the IL is socialized via the share price,
                // never patched from surplus.
                if (isBTC) AUX.btcShortfall(sender, shortfall);
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
    // exits read pro-rata of vogueETH at withdrawal). The fair model is the redemption
    // path (BasketLib._depegLoss: pro-rata, no first-out-at-par); withdrawal now matches
    // it (see Vogue._withdraw). BTC keeps its hop delivery rail (Aux.btcShortfall).

    /// @notice Fused repack — replaces separate repack/repackBTC. Pass
    ///         isBTC=true to repack the BTC/USD pool, false for ETH/USD.
    function repack(bool isBTC, uint128 myLiquidity, uint160 sqrtPriceX96,
        int24 oldTickLower, int24 oldTickUpper,
        int24 newTickLower, int24 newTickUpper) public onlyUs
        returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1) {
        (price, fees0, fees1, delta0, delta1) = abi.decode(poolManager.unlock(
            abi.encode(isBTC ? Action.RepackBTC : Action.RepackETH,
                myLiquidity, sqrtPriceX96, oldTickLower,
                oldTickUpper, newTickLower, newTickUpper)),
            (uint, uint, uint, uint, uint));
    }

    /// @notice Re-seat the pool: move slot0 onto `targetSqrt` (the oracle-resolved
    ///         price) and re-range around it. Unlike `repack` (which re-centers the
    ///         RANGE on wherever the curve spot already sits), `reseat` MOVES the
    ///         spot — needed when a fast real-market move leaves the mock curve
    ///         stale (the spot only moves via swaps, which the price guards block
    ///         once it's stale → deadlock). Driven by Vogue/BtcVault, which compute
    ///         `targetSqrt` from `getTWAPforAsset` (Chainlink-resolved) + the new
    ///         range. Mock-only: real assets in the basket/venue are untouched.
    function reseat(bool isBTC, uint128 myLiquidity, uint160 currentSqrt,
        uint160 targetSqrt, int24 oldTickLower, int24 oldTickUpper,
        int24 newTickLower, int24 newTickUpper) public onlyUs
        returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1) {
        (price, fees0, fees1, delta0, delta1) = abi.decode(poolManager.unlock(
            abi.encode(isBTC ? Action.ReseatBTC : Action.ReseatETH,
                myLiquidity, currentSqrt, targetSqrt, oldTickLower,
                oldTickUpper, newTickLower, newTickUpper)),
            (uint, uint, uint, uint, uint));
    }

    /// @notice Force-sync accumulated V4 trading fees on the position
    ///         WITHOUT moving the position. Defends Vogue's MasterChef-
    ///         style yield attribution against JIT snipes: an attacker
    ///         who deposits in the same block as a large swap (or
    ///         immediately before a fee-bearing repack) would otherwise
    ///         capture pro-rata of fees they did not earn. Calling this
    ///         before every Vogue deposit/withdraw bookmark update
    ///         drains the V4-side accrual into feesPerShare for the
    ///         pre-existing LPs only.
    ///
    /// Cost: one V4 modifyLiquidity(0) — read the position's tokensOwed
    /// and zero them, no token movement on liquidity (only on fees).
    function collectFees(int24 tickLower, int24 tickUpper, bool isBTC)
        public onlyUs returns (uint fees0, uint fees1) {
        (fees0, fees1) = abi.decode(poolManager.unlock(
            abi.encode(isBTC ? Action.CollectBTC : Action.CollectETH,
                tickLower, tickUpper)),
            (uint, uint));
    }

    // ─── Unlock dispatcher ───────────────────────────────────────────
    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte;
        assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action a = Action(firstByte);
        bool isBTC = (uint8(a) >= uint8(Action.SwapBTC));
        bytes calldata payload = data[32:];

        if (a == Action.SwapETH || a == Action.SwapBTC)
            return _handleSwap(payload, isBTC);
        if (a == Action.RepackETH || a == Action.RepackBTC)
            return _handleRepack(payload, isBTC);
        if (a == Action.ReseatETH || a == Action.ReseatBTC)
            return _handleReseat(payload, isBTC);
        if (a == Action.ModLPETH || a == Action.ModLPBTC)
            return _handleMod(payload, isBTC);
        if (a == Action.OutsideRangeETH || a == Action.OutsideRangeBTC)
            return _handleOutsideRange(payload, isBTC);
        if (a == Action.CollectETH || a == Action.CollectBTC)
            return _handleCollect(payload, isBTC);
        return "";
    }

    function _key(bool isBTC) internal view returns (PoolKey memory) {
        return isBTC ? VANILLA_BTC : VANILLA_ETH;
    }

    /// @dev §E9 — the swap's price limit: the BAND'S OWN EDGE, unpacked from the two int24 ticks
    ///      `SwapLib.swapToBody` packed into one word. Its OWN frame for two reasons: `_handleSwap`
    ///      is stack-tight (`via_ir = false`), and `TickMath.getSqrtPriceAtTick` is a large inlined
    ///      chain that must land here rather than in `SwapLib`, which sits ~150 bytes from EIP-170.
    ///      `zeroForOne` moves price DOWN, so it bounds at the LOWER tick; otherwise the UPPER.
    ///      int24→uint24→int24 is bit-preserving, so negative ticks round-trip exactly.
    function _bandEdgeLimit(uint160 bandTicks, bool zeroForOne) private pure returns (uint160) {
        return zeroForOne
            ? TickMath.getSqrtPriceAtTick(int24(uint24(uint(bandTicks) >> 24)))
            : TickMath.getSqrtPriceAtTick(int24(uint24(uint(bandTicks) & 0xFFFFFF)));
    }

    function _handleSwap(bytes calldata data, bool isBTC)
        internal returns (bytes memory) {
        // sqrtPriceX96 (1st field) no longer used — the swap now runs to the extreme limit
        // (grinding removed); the pool's own current price drives execution.
        (uint160 bandTicks, address sender, bool forOne,
            address token, uint amount) = abi.decode(data,
            (uint160, address, bool, address, uint));

        PoolKey memory k = _key(isBTC);
        BalanceDelta delta = poolManager.swap(k,
            IPoolManager.SwapParams({ zeroForOne: forOne,
                // GRINDING REMOVED and NOT reinstated: there is still no artificial per-swap price
                // cap. The swap walks the real curve until its input is consumed or the band's
                // in-range liquidity runs out — partial-fill at the TRUE edge, not a 0.5% wall.
                //
                // §E9 — the limit is the BAND EDGE (passed in `sqrtPriceLimit`), not the tick
                // extreme. The comment here used to claim "a swap can't move the spot past the band
                // edge (no liquidity there)". That is BACKWARDS, and measured false
                // (`PooledUsdRepackMatrix::testMatrix_S6`): BECAUSE there is no liquidity there, the
                // price crosses it at ZERO COST. A swap crossing `tickUpper` with input remaining
                // drove the spot to `MAX_SQRT_PRICE - 1` while exchanging zero tokens, where
                // `BasketLib.getPrice` truncates to 0 and `_reseatIfStale` then refuses to heal
                // (`spot == 0`) — a permanently bricked band.
                //
                // This is NOT the removed grinding cap: grinding truncated fills INSIDE liquidity;
                // this bounds price movement OUTSIDE it, where no fill is possible either way. Fills
                // are bit-identical (measured: the crossing swap filled 5,292.59 USD / 2.84 ETH
                // before the boundary and moved ZERO tokens past it) — only the resting spot differs.
                amountSpecified: -int(amount),
                sqrtPriceLimitX96: _bandEdgeLimit(bandTicks, forOne)}),
            ZERO_BYTES);

        (, int24 currentTick,,) = poolManager.getSlot0(_poolId(isBTC));
        _writeObservation(currentTick, isBTC);
        _handleDelta(delta, true, false, sender, token, isBTC);
        // fold this swap's USD notional into the pool's flow EWMA (the adaptive
        // skew target). Every band + well swap routes through here, so this is the ONE bump
        // point. USD leg = the non-volatile side of the delta (token0 when token1 is volatile).
        {
            int128 usdLeg = _t1(isBTC) ? delta.amount0() : delta.amount1();
            uint usd6 = uint(int(usdLeg < 0 ? -usdLeg : usdLeg));
            if (usd6 != 0) _bumpFlow(isBTC, usd6);
        }
        // BTC proceeds are NO LONGER tracked via global curve counters. Per-channel
        // exit P&L is settled EXACTLY at on-chain swap-out delivery: the swapper's
        // actual USD is recorded per-obligation (pendingOnchainSwapOut.usd) at
        // request and paid to the delivering LP at deliverSwapOutOnchain — so there
        // is no shared proceeds pool to race over (see Core.pendingSwapOutUsd). The
        // old netDeliveredBtc/swapUsdBtc rate machinery + clamp are gone.
        return abi.encode(delta);
    }

    function _handleRepack(bytes calldata data, bool isBTC)
        internal returns (bytes memory) {
        // Per-pool zeroing: clear only the side being repacked. The other
        // pool's slice is independent and untouched.
        if (isBTC) { POOLED_USD_BTC = 0; POOLED_BTC = 0; basketUsdBtc = 0; }
        else       { POOLED_USD_ETH = 0; POOLED_ETH = 0; basketUsdEth = 0; }

        (Reseat memory rng, BalanceDelta fees, uint delta0, uint delta1) = _repackBurn(data, isBTC);
        uint price = BasketLib.getPrice(rng.sqrtP, _t1(isBTC));
        // Pull next-round liquidity from Vogue (own frame, isBTC selects path).
        BalanceDelta addDelta = _repackAdd(delta0, delta1, price, rng, isBTC);

        (, int24 currentTick,,) = poolManager.getSlot0(_poolId(isBTC));
        _writeObservation(currentTick, isBTC);

        return abi.encode(price, uint(int(fees.amount0())),
            uint(int(fees.amount1())), uint(int(addDelta.amount0())),
            uint(int(addDelta.amount1())));
    }

    /// @dev The repacked position's new range — bundled so the burn/add helpers
    ///      pass one pointer (not 3 scalars) and stay within the legacy stack.
    struct Reseat { uint160 sqrtP; int24 lower; int24 upper; }

    /// @dev Decode the repack params, burn the old-range position and settle the
    ///      removed amounts — own frame so the old-range ticks / myLiquidity / burn
    ///      delta don't pin _handleRepack's legacy stack. Returns the NEW range +
    ///      collected fees + the two settled token amounts.
    function _repackBurn(bytes calldata data, bool isBTC)
        private returns (Reseat memory rng, BalanceDelta fees, uint delta0, uint delta1) {
        int24 oldLo; int24 oldHi; uint128 myLiquidity;
        (myLiquidity, rng.sqrtP, oldLo, oldHi, rng.lower, rng.upper) =
            abi.decode(data, (uint128, uint160, int24, int24, int24, int24));
        BalanceDelta delta;
        (delta, fees) = _modifyLiquidity(-int(uint(myLiquidity)), oldLo, oldHi, isBTC);
        // TRUSTED-ARG CHECK (audit residual, §A.24). `myLiquidity` is supplied by the caller (from
        // `poolStats`), and `onlyUs` puts it inside the Vogue keeper trust boundary — but a STALE value
        // fails ASYMMETRICALLY: too HIGH already reverts inside `_modifyLiquidity` (cannot remove more
        // than exists), while too LOW silently under-removes and STRANDS liquidity in the old range,
        // where the repack then re-seats around it and POOLED_* no longer equals realized depth.
        // Assert the burn actually emptied the old position — the cheap, direct invariant.
        require(StateLibrary.getPositionLiquidity(poolManager, _poolId(isBTC),
            keccak256(abi.encodePacked(address(this), oldLo, oldHi, bytes32(0)))) == 0, "repack:stale");
        (delta0, delta1) = _handleDelta(delta, false, true, address(0), address(0), isBTC);
    }

    /// @dev Re-seat the repacked position with next-round liquidity pulled from
    ///      Vogue (own frame so _handleRepack's burn locals don't pin the legacy
    ///      stack). token1is(isBTC) selects which leg the volatile token is.
    function _repackAdd(uint delta0, uint delta1, uint price, Reseat memory rng, bool isBTC)
        private returns (BalanceDelta addDelta) {
        if (_t1(isBTC)) {
            (delta0, delta1) = VOGUE.addLiq(delta1, price, isBTC);
            if (delta0 > 0 && delta1 > 0) {
                addDelta = _modLP(delta0, delta1, rng.lower, rng.upper, rng.sqrtP, isBTC);
                _handleDelta(addDelta, true, false, address(0), address(0), isBTC, true);
            }
        } else {
            (delta1, delta0) = VOGUE.addLiq(delta0, price, isBTC);
            if (delta1 > 0 && delta0 > 0) {
                addDelta = _modLP(delta1, delta0, rng.lower, rng.upper, rng.sqrtP, isBTC);
                _handleDelta(addDelta, true, false, address(0), address(0), isBTC, true);
            }
        }
    }

    /// @dev Reseat params (one memory pointer — keeps _handleReseat within the
    ///      legacy stack; no via_ir crutch). ABI-compatible with the flat tuple
    ///      `reseat()` encodes (all-static struct ⇒ same encoding as the tuple).
    struct ReseatParams {
        uint128 myLiquidity; uint160 currentSqrt; uint160 targetSqrt;
        int24 oldLo; int24 oldHi; int24 newLo; int24 newHi;
    }

    /// @dev Reseat handler: burn the stale-range position, MOVE slot0 onto the
    ///      oracle target, then re-add liquidity around it. Mirrors _handleRepack
    ///      but with the explicit spot-move. Mock-only — no AUX.take/VOGUE.takeETH
    ///      (keep=true, who=0) — so basket/venue real assets are untouched; only
    ///      the virtual POOLED slice + the curve spot move.
    function _handleReseat(bytes calldata data, bool isBTC)
        internal returns (bytes memory) {
        ReseatParams memory p = abi.decode(data, (ReseatParams));
        // Per-pool zeroing — re-established by the re-add (as in _handleRepack).
        if (isBTC) { POOLED_USD_BTC = 0; POOLED_BTC = 0; basketUsdBtc = 0; }
        else       { POOLED_USD_ETH = 0; POOLED_ETH = 0; basketUsdEth = 0; }

        (BalanceDelta fees, uint d0, uint d1) = _reseatBurnMove(p, isBTC);

        uint price = BasketLib.getPrice(p.targetSqrt, _t1(isBTC));
        Reseat memory rng = Reseat({ sqrtP: p.targetSqrt, lower: p.newLo, upper: p.newHi });
        BalanceDelta addDelta = _repackAdd(d0, d1, price, rng, isBTC);

        (, int24 currentTick,,) = poolManager.getSlot0(_poolId(isBTC));
        _writeObservation(currentTick, isBTC);
        return abi.encode(price, uint(int(fees.amount0())),
            uint(int(fees.amount1())), uint(int(addDelta.amount0())),
            uint(int(addDelta.amount1())));
    }

    /// @dev Burn the stale-range position (keep=true → no payout; recover fees),
    ///      then move slot0 onto the target. The move is an exact-input swap BOUNDED BY
    ///      THE PRICE LIMIT (sqrtPriceLimitX96 = targetSqrt): with the protocol's in-range
    ///      position burned the path is usually empty (≈0 traded), but a self-managed
    ///      boundary order can sit in the dislocation gap (>5% is exactly the reseat
    ///      regime). A 1-wei probe would STALL on that order — leaving slot0 stale while
    ///      we report success, re-arming the very deadlock this heals. So drive a LARGE
    ///      exact-input toward the limit: the swap walks all the way to targetSqrt,
    ///      CONSUMING (filling) any boundary liquidity in the gap on the way — correct,
    ///      those were limit orders at those prices, and the filled owner is credited in
    ///      V4 + paid at pull. Direction + limit are unchanged from the probe; only the
    ///      input cap grows. The price limit stops the swap at targetSqrt, so the realized
    ///      delta stays int128-bounded by the (bounded) path liquidity. Settle mock-only.
    function _reseatBurnMove(ReseatParams memory p, bool isBTC)
        private returns (BalanceDelta fees, uint d0, uint d1) {
        if (p.myLiquidity > 0) {
            BalanceDelta burnDelta;
            (burnDelta, fees) = _modifyLiquidity(-int(uint(p.myLiquidity)), p.oldLo, p.oldHi, isBTC);
            (d0, d1) = _handleDelta(burnDelta, false, true, address(0), address(0), isBTC);
        }
        if (p.targetSqrt != 0 && p.targetSqrt != p.currentSqrt) {
            BalanceDelta moveDelta = poolManager.swap(_key(isBTC),
                IPoolManager.SwapParams({ zeroForOne: p.targetSqrt < p.currentSqrt,
                    amountSpecified: -int(uint(type(uint128).max)), sqrtPriceLimitX96: p.targetSqrt }),
                ZERO_BYTES);
            _handleDelta(moveDelta, false, true, address(0), address(0), isBTC);
        }
    }

    function _handleOutsideRange(bytes calldata data, bool isBTC)
        internal returns (bytes memory) {
        (address sender, int liquidity, int24 tickLower,
            int24 tickUpper, address token) = abi.decode(data,
            (address, int, int24, int24, address));

        (BalanceDelta delta,) = _modifyLiquidity(liquidity,
                                tickLower, tickUpper, isBTC);
        _handleDelta(delta, false, false, sender, token, isBTC);
        return abi.encode(delta);
    }

    function _handleMod(bytes calldata data, bool isBTC)
        internal returns (bytes memory) {
        // Buffer USD folds into POOLED_USD like any in-range USD (committedUsd18 recovers equity by subtracting
        // min(live debt, pooled buffer)); the old no-op `levUsd` field has been removed from the modLP ABI.
        (uint160 sqrtPriceX96, uint deltaTokenOut, uint deltaUSD,
            int24 tickLower, int24 tickUpper, address sender)
            = abi.decode(data,
            (uint160, uint, uint, int24, int24, address));

        BalanceDelta delta = _modLP(deltaUSD, deltaTokenOut,
            tickLower, tickUpper, sqrtPriceX96, isBTC);

        _handleDelta(delta, true, deltaUSD == 0, sender, address(0), isBTC, true);
        return abi.encode(delta);
    }

    /// @dev Fee-only collect handler. Calls modifyLiquidity with
    ///      liquidityDelta = 0 — V4 still updates the position's fee
    ///      growth and returns the delta credited for accrued fees.
    ///      The position size is unchanged; only outstanding fees move
    ///      from the pool into our balance. Then _handleDelta drains
    ///      both currencies from poolManager (the USD side hits the
    ///      mock-burn path; the token side bumps POOLED_X). The caller
    ///      (Vogue) needs the raw fee magnitudes per currency to drive
    ///      feesPerShare and USD_FEES, so we return them separately.
    function _handleCollect(bytes calldata data, bool isBTC)
        internal returns (bytes memory) {
        (int24 tickLower, int24 tickUpper) =
            abi.decode(data, (int24, int24));

        (BalanceDelta totalDelta, ) = _modifyLiquidity(
            int(0), tickLower, tickUpper, isBTC);

        // With liquidityDelta=0, totalDelta IS the fee credit (V4
        // composes callerDelta = liquidityDelta - feesAccrued; when
        // the first term is zero, the second dominates as fees owed
        // to the caller — positive amounts in both currencies).
        _handleDelta(totalDelta, false, false, address(0), address(0), isBTC);

        bool token1isTok = _t1(isBTC);
        // Order the returned fees so caller can read them as
        // (feesUSD, feesTok). Aligns with Vogue._calcYield's
        // existing variable order.
        uint fees0 = uint(int(totalDelta.amount0()));
        uint fees1 = uint(int(totalDelta.amount1()));
        if (token1isTok) return abi.encode(fees0, fees1);  // c0=USD, c1=tok
        else             return abi.encode(fees1, fees0);  // c0=tok, c1=USD
    }

    /// @dev Per-pool delta handler. `inRange` controls whether the deltas
    /// update POOLED_USD_{ETH|BTC} (only in-range positions count toward
    /// the pool's active slice). The two pools' USD slices are
    /// INDEPENDENT — a swap on the ETH side cannot move BTC-side USD.
    function _handleDelta(BalanceDelta delta, bool inRange, bool keep,
        address who, address token, bool isBTC) internal returns (uint, uint) {
        return _handleDelta(delta, inRange, keep, who, token, isBTC, false);
    }

    /// §#12 `basketLeg`: TRUE only from `_handleMod` (the basket adding/removing depth via
    /// `addLiq`). Swap/collect/reseat legs pass FALSE, so a swap moves the curve mirror
    /// (`POOLED_USD_*`) without moving the basket's contribution (`basketUsd`).
    function _handleDelta(BalanceDelta delta, bool inRange, bool keep,
        address who, address token, bool isBTC, bool basketLeg) internal returns (uint, uint) {
        // Each leg settles in its own frame (legacy stack — no via_ir crutch); they
        // recompute the cheap token ordering rather than thread 4 locals through.
        uint usdAmount = _settleUsdSide(delta, inRange, keep, who, token, isBTC, basketLeg);
        uint tokAmount = _settleTokSide(delta, inRange, who, isBTC);
        return _t1(isBTC) ? (usdAmount, tokAmount) : (tokAmount, usdAmount);
    }

    /// @dev USD-leg of _handleDelta. delta>0 → take+burn; delta<0 → mint+settle and
    ///      (in-range) pool it under the backing invariant.
    ///      ⚠️ This used to say "under the BTC share cap" — a comment describing PAST state. The
    ///      `btcShareBps` median-vote cap was REMOVED in §H (2026-07); see `SwapLib.sol:1304`.
    ///      There is NO per-band cap and NO fixed ETH/BTC split: the ONLY shared bound is the SUM
    ///      (`committedUsd18() <= haircutTvl`), so either band may draw the whole free surplus if
    ///      the other is not using it. Neither side is limited to a share, still less to the
    ///      MINIMUM of the two.
    function _settleUsdSide(BalanceDelta delta, bool inRange, bool keep,
        address who, address token, bool isBTC, bool basketLeg) private returns (uint usdAmount) {
        bool token1isTok = _t1(isBTC);
        Currency usdCurrency = token1isTok ? _key(isBTC).currency0 : _key(isBTC).currency1;
        int128 usdDelta = token1isTok ? delta.amount0() : delta.amount1();
        if (usdDelta > 0) {
            usdAmount = uint(int(usdDelta));
            usdCurrency.take(poolManager, address(this), usdAmount, false);
            _mockUsd(isBTC).burn(usdAmount);
            if (inRange) _poolUsdInRange(isBTC, usdAmount, false, basketLeg);
            if (!keep && token != address(0))
                // §A.50/C2: `usdAmount` is the 6-dec mockUSD leg, but `AUX.take` wants the payout
                // token's NATIVE units (`BasketLib.sol:620-628`; the two callers that already convert
                // are `SwapLib.sol:1170` and `:1222`). The CREATE side of the same position already
                // scales (`VogueLib.sol:662`), so without this the round trip was ASYMMETRIC and an
                // 18-dec redeemer was paid 1e12x too little. `minOut` cannot catch it: `Core.swap`
                // returns the 6-dec delta, a different basis than delivery.
                AUX.take(who, BasketLib.from6(usdAmount, token), token, 0);
        } else if (usdDelta < 0) {
            usdAmount = uint(int(-usdDelta));
            _mockUsd(isBTC).mint(usdAmount);
            usdCurrency.settle(poolManager, address(this), usdAmount, false);
            if (inRange) _poolUsdInRange(isBTC, usdAmount, true, basketLeg);
        }
    }

    /// @dev In-range USD pooling (own frame — keeps _settleUsdSide off the stack limit). The full-2× buffer is
    ///      NOT split off here anymore: the WHOLE `usdAmount` moves POOLED_USD_*, and committedUsd18 recovers the
    ///      equity claim by subtracting live leverage debt. The ≤TVL backing gate is checked against that live
    ///      EQUITY (`committedUsd18`), so the debt-funded buffer consumes no basket-USD headroom — exactly as
    ///      the old `_LEV` segregation did, but drift-free.
    function _poolUsdInRange(bool isBTC, uint usdAmount, bool mint, bool basketLeg) private {
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
            _addPooledUsd(isBTC, usdAmount);
            if (basketLeg) { if (isBTC) basketUsdBtc += usdAmount; else basketUsdEth += usdAmount; }
            require(committedUsd18() <= haircutTvl, "backing");
        } else {
            uint pooledPre = isBTC ? POOLED_USD_BTC : POOLED_USD_ETH;
            _subPooledUsd(isBTC, usdAmount);
            if (basketLeg) {
                // §#12/E28-r — PROPORTIONAL, not first-out. A burn releases a MIX: the band's USD leg
                // holds basket dollars AND the LP-owned increment, and modifyLiquidity returns them in
                // the band's CURRENT ratio. The old `-= min(usdAmount, basket)` drained the basket leg
                // FIRST, so on a partial exit `POOLED_USD - basketUsd` (the increment `_pricingBacking`
                // now reads as LP backing) grew by the whole released basket slice — phantom backing
                // paid to whoever withdrew next. Measured on a FULL exit: basket floored to 0 against a
                // 25.200001 residue, leaving that entire residue mispriced as LP equity.
                uint b = isBTC ? basketUsdBtc : basketUsdEth;
                uint out_ = pooledPre <= usdAmount ? b   // whole leg left: basket leaves with it
                          : Math.mulDiv(b, usdAmount, pooledPre);
                if (isBTC) basketUsdBtc = b - out_; else basketUsdEth = b - out_;
            }
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
    function absorbPaidUsd(bool isBTC, uint lpOwned6) external onlyUs {
        uint pooled = isBTC ? POOLED_USD_BTC : POOLED_USD_ETH;
        uint base = pooled > lpOwned6 ? pooled - lpOwned6 : 0;
        if (isBTC) basketUsdBtc = base; else basketUsdEth = base;
    }

    /// @dev Token-leg (ETH or BTC) of _handleDelta. delta>0 → take+burn (ETH pays
    ///      real ETH out); delta<0 → mint+settle and (in-range) pool it.
    function _settleTokSide(BalanceDelta delta, bool inRange, address who, bool isBTC)
        private returns (uint tokAmount) {
        bool token1isTok = _t1(isBTC);
        Currency tokCurrency = token1isTok ? _key(isBTC).currency1 : _key(isBTC).currency0;
        int128 tokDelta = token1isTok ? delta.amount1() : delta.amount0();
        if (tokDelta > 0) {
            tokAmount = uint(int(tokDelta));
            tokCurrency.take(poolManager, address(this), tokAmount, false);
            _mockTok(isBTC).burn(tokAmount);
            if (inRange) _subPooledTok(isBTC, tokAmount);
            // ETH-only: the burned mockETH is matched by real ETH paid out.
            if (!isBTC && who != address(0)) VOGUE.takeETH(tokAmount, who);
        } else if (tokDelta < 0) {
            tokAmount = uint(int(-tokDelta));
            _mockTok(isBTC).mint(tokAmount);
            tokCurrency.settle(poolManager, address(this), tokAmount, false);
            if (inRange) _addPooledTok(isBTC, tokAmount);
        }
    }

    function _modifyLiquidity(int delta, int24 lowerTick, int24 upperTick,
        bool isBTC) internal returns (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            _key(isBTC), IPoolManager.ModifyLiquidityParams({
                tickLower: lowerTick, tickUpper: upperTick,
                liquidityDelta: delta, salt: bytes32(0)}), ZERO_BYTES);
    }

    function _modLP(uint deltaUSD, uint deltaTok,
        int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96,
        bool isBTC) internal returns (BalanceDelta totalDelta) {
        bool token1isTok = _t1(isBTC);
        int flip = deltaUSD > 0 ? int(1) : int(-1);
        uint128 liquidity = token1isTok ? LiquidityAmounts.getLiquidityForAmount1(
                   TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, deltaTok): 
                    LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96,
                      TickMath.getSqrtPriceAtTick(tickUpper), deltaTok);
        // (deltaTok,
        // deltaUSD) addLiq priced at the TWAP is geometrically exact only when
        // spot is at the range center. Off-center, sizing from the volatile leg
        // alone draws MORE USD than `deltaUSD` (the surplus-clamped budget). Cap
        // liquidity to the smaller of what each single leg funds (the canonical
        // two-sided add) so committedUsd ≤ budget ≤ surplus ≤ TVL and
        // _handleDelta's backing invariant holds. No-op when the volatile leg
        // binds (the usual case); only clips the USD-heavy, off-center case.
        if (flip > 0) {
            uint128 usdLiq = token1isTok ? LiquidityAmounts.getLiquidityForAmount0(
                    sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), deltaUSD): 
                      LiquidityAmounts.getLiquidityForAmount1(
                         TickMath.getSqrtPriceAtTick(tickLower), 
                                        sqrtPriceX96, deltaUSD);

            if (usdLiq < liquidity) liquidity = usdLiq;
        } if (flip < 0) {
            (,, uint128 posLiquidity) = poolStats(tickLower, tickUpper, isBTC);
            if (posLiquidity == 0) return BalanceDeltaLibrary.ZERO_DELTA;
            if (liquidity > posLiquidity) liquidity = posLiquidity;
        }
        (totalDelta,) = _modifyLiquidity(
             flip * int(uint(liquidity)), 
            tickLower, tickUpper, isBTC);
    } 

    function poolStats(int24 tickLower, int24 tickUpper, bool isBTC)
        public view returns (uint160 sqrtPriceX96, int24 currentTick,
        uint128 liquidity) { PoolId pool;
        (pool, sqrtPriceX96, currentTick) = poolTicks(isBTC);
        (liquidity,,) = poolManager.getPositionInfo(pool,
        address(this), tickLower, tickUpper, bytes32(0));
    }

    function poolTicks(bool isBTC) public view
        returns (PoolId, uint160, int24) {
        PoolId pool = _poolId(isBTC);
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pool);
        return (pool, sqrtPriceX96, currentTick);
    }

    function _writeObservation(int24 tick, 
                    bool isBTC) internal {
        OracleLib.writeObservation(_obs(isBTC),
                        _obsState(isBTC), tick);
    }

    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory) {
        return OracleLib.observe(observationsETH, 
                            obsETH, secondsAgos);
    }

    function observeBTC(uint32[] calldata secondsAgos)
        external view returns (int56[] memory) {
        return OracleLib.observe(observationsBTC, 
                            obsBTC, secondsAgos);
    }
}
