// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// §E266 — ONE `WAD`. It was declared in TEN places (nine of ours plus Midnight's); this imports
// the single declaration in `Types.sol` instead of restating it. Constants are
// inlined, so this costs no bytecode — except on `FeeLib`/`BasketLib`, where it was `public` and
// the generated getter goes away (no client reads it; checked across spa/ and quid-ln/).
import {WAD} from "./Types.sol";
// §A.52: the canonical Core view (was a file-local variant).
import {ICore} from "./Interfaces.sol";
import {IBandManager} from "./Interfaces.sol";
import {IBasketTurn, IWiredVault, IWiredBasket, ILevSweep, IQuid, ILevHost} from "./Interfaces.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Types} from "./Types.sol";
import {FeeLib} from "./FeeLib.sol";
import {ShareMath} from "./ShareMath.sol";
import {IAaveV4Spoke} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {QuidLib} from "./QuidLib.sol";



/// AAVE-v4 GHO spoke (vault-health evac haven). Mirrors Aux.IAaveV4Spoke.
/// The two reserve-level reads are asset-denominated (verified live: GHO reserve
/// supplied/debt in 1e18); available cash = supplied − debt.
/// EthVenue — the ETH-venue custody (AAVE WETH + ether.fi weETH). vault-health
/// STATE stays Aux-owned; the basket's stable 4626s are held by Aux itself.
// §G.6 redeem shortfall sweep: the ETH LevManager's ONE reactive de-lever entry (SHARED with swap-out). Reached
// via core→Vault (IWiredCore.btcVault → IWiredVault.LEV_MANAGER, both existing). `deleverBook` frees levered
// net-equity into the sink (= this Aux) value-neutrally and returns the stable routed there.
// Deploy-finalize linkage cross-checks (BasketLib.assertFullyWired).
  // §G.6: reach the ETH LevManager
/// Canonical view — union of the former per-file variants (`IBasketTurn2`). Two declarations
/// described ONE contract, so a signature change had to be made twice and a missed one still compiled.
library BasketLib {
    /// @notice A take asked for a non-zero amount and delivered nothing — every venue failed.
    ///         §E91-r5: distinct from a partial fill, which is legitimate under fail-soft.
    error NothingDelivered();
    /// @notice §E191 — the draw was too small to express, NOT a venue outage. The pro-rata allocation
    ///         is 18-dec and the withdraw is native, so a request below one native unit of a leg
    ///         (1e12 wei for a 6-dec stable) rounds to zero on every leg. Distinguishing this from
    ///         `NothingDelivered` matters: that error means EVERY VENUE FAILED, and a dust redeem
    ///         reporting it sends the reader hunting a venue outage that never happened.
    error AmountTooSmall();

    uint public constant MONTH = 2420000;

    struct Metrics {
        uint total;
        uint last;
        uint yield;
        uint trackingStart;
        uint yieldAccum;
    }

    /// @param rateWeighted `yieldW[0]` = Σ balanceᵢ × rateᵢ, the balance-weighted ANNUALISED-RATE
    ///        numerator built in `get_deposits`. ⚠️ THIS USED TO BE `amounts[0]` (Σ yieldWeighted) and
    ///        the body derived `yield` as `Σyw/Σb − 1` — the basket's mean SHARE PRICE minus one.
    ///        That is a cumulative LEVEL, and `calcMintYield` consumes it as an ANNUAL rate, so the
    ///        bond premium scaled with venue age and with each venue's arbitrary price base rather
    ///        than with yield. Measured live at the moment of this change: mean level 18.72% against
    ///        a mean true APR of 3.10% — 6.04× over-issuance — with PYUSD alone contributing 101.49%,
    ///        of which 99.80pp was a base offset that no annualisation could ever remove. §E155-overreport.
    function computeMetrics(Metrics memory stats,
        uint elapsed, uint raw, uint rateWeighted,
        uint tvl) internal view returns (Metrics memory) {

        if (stats.trackingStart > 0 && stats.last > 0)
            stats.yieldAccum += stats.yield * elapsed;

        else if (stats.trackingStart == 0)
            stats.trackingStart = block.timestamp;

        // `raw == 0` is the empty-basket case: nothing to divide by, so keep the prior rate rather
        // than crash. Otherwise the weighted mean of the per-leg rates, which are ALREADY annualised
        // and ALREADY floored at 0 per leg in `_refreshOne` — so there is no `< raw` arm any more and
        // no `- WAD`. That matters: the old floor-to-zero arm is what turned the (then-live) decimals
        // defect into PERMANENT suppression rather than a visible wobble, because a basket dragged
        // under `raw` by one broken leg pinned `yield` at 0 forever. With per-leg rates a broken leg
        // can only zero ITS OWN contribution.
        if (raw != 0) stats.yield = SoladyMath.fullMulDiv(WAD, rateWeighted, raw);
        stats.total = tvl; stats.last = block.timestamp;

        return stats;
    }

    function get_deposits(address aux, address[] memory stables,
        mapping(address => Holding) storage storedHoldings,
        mapping(address => uint) storage tranche) external
        returns (uint[15] memory amounts, uint[15] memory yieldW, uint depegLossOut) {
        // GAS: the per-stable seed-reserve (tranche) is a direct SLOAD through
        // a storage-reference param (this runs in Aux's context via delegatecall) —
        // NOT an external IAux(aux) self-call. Depeg severity is read via the SINGLE
        // accessor getDepegSeverityBps (one call, vs the old riskFactor wrapper);
        // loss fraction = FULL live severity (no 3500/65c cap -- see the discount
        // below). The accumulated depegLoss is RETURNED so _depegLoss reads this single
        // pass instead of a redundant second feed loop.
        // amounts[0]     = yield-weighted sum across ALL sources
        // yieldW[i+1]    = PER-STABLE yield-weighted value (post depeg
        //   discount). Same number that's summed into amounts[0]; exposed
        //   per-stable so the fee model can compute each stable's yield
        //   rate (yieldW[i]/amounts[i]) vs the basket baseline
        //   (amounts[0]/amounts[14]) WITHOUT re-reading any vault.
        // amounts[1..N]  = per-token deposit values (18 dec)
        //   N = stables.length - 1 (last slot is BOLD, filled in Aux)
        // amounts[14]    = raw TVL total (all sources)
        //
        // ROUTING DISPATCH (token identity, not slot position):
        //   AAVE  : GHO, USDG → IAux(aux).aaveBalance(token)
        //   ERC4626: everything else → IAux(aux).vaults(token) → convertToAssets
        //   BOLD (last slot): filled in Aux (Liquity SP, not 4626) — skipped here
        //
        // YIELD-WEIGHTING POLICY:
        //   First-pair group (slots 0..len/2-ish) uses principal-only
        //   (yieldWeighted = balance). The "appreciation-boosted" yield
        //   factor (×totalAssets/totalSupply) is reserved for second-loop
        //   stables and applied below for non-AAVE entries from slot 5+.
        //   This preserves existing avgYield semantics in get_metrics.
        uint balance;
        uint len = stables.length - 1; // skip last (BOLD)
        for (uint i = 0; i < len; i++) {
            address stable = stables[i];
            uint yieldWeighted;
            // Cache (step-5 flip): the expensive per-stable vault-sum +
            // decimal-scale is served from storage (storedHoldings), recomputed
            // on a mutation / full-refreshed at mint/redeem — NOT recomputed here
            // (the old _valueStable loop). The reconciliation invariant
            // (test_HoldingsCache_ReconcilesToLive) gates this: the cache == the
            // live vault-sum after any op. The cheap per-read adjustments
            // (tranche, depeg) stay LIVE below — they change without a vault
            // mutation, so they're never cached.
            Holding storage h = storedHoldings[stable];
            balance = h.balance;
            yieldWeighted = h.yieldWeighted;
            if (balance == 0) continue;
            uint reserved = tranche[stable];              // direct SLOAD (was IAux.tranche)
            if (reserved > 0) {
                uint cap = Math.min(balance, reserved);
                // §E190 — REMOVE THE SAME FRACTION FROM BOTH, NOT THE SAME NOMINAL AMOUNT.
                // `yieldWeighted == balance × f` where f is the venue's (dimensionless) share
                // price, so taking `cap` off each leaves `(b·f − cap)/(b − cap)`, which is NOT f:
                // the seniority carve-out silently INFLATED the leg's apparent yield, in
                // proportion to how much of it was reserved. MEASURED at the live Galaxy-USDC
                // price f = 1.012631 on a 100k leg: a 50k tranche read 1.025262 (+1.2%), 80k read
                // 1.063155 (+5.0%), 95k read 1.252620 (+23.7%) — nonlinear, and always upward.
                //   `../quid` (legacy) got this right on its 4626 legs by removing SHARES
                // (`shares -= convertToShares(reserved)`) and valuing the remainder, which
                // preserves the ratio exactly; its AAVE legs carried the same nominal bug we did.
                // We value off the CACHE here and have no share count, so scale instead — which is
                // the same thing: removing `cap` of assets removes `cap × f` of yield-weighted
                // value. `balance != 0` is guaranteed by the guard above, so the mulDiv is safe.
                //   WHY IT BELONGS HERE AND NOT IN THE CLAIM: the tranche is a property of the
                // CLAIM (senior, non-redeemable), not of the VENUE. A seed reserve does not change
                // what a vault earns per share, so excluding it from the MEASUREMENT is what
                // introduced the error. It stays excluded from redeemable backing, as before.
                uint ywCap = SoladyMath.fullMulDiv(yieldWeighted, cap, balance);
                balance -= cap;
                yieldWeighted -= Math.min(yieldWeighted, ywCap);
            }
            // Depeg-yield discount: subtracts balance × severity/10000 from yieldWeighted.
            // Recognize the FULL live severity (no 3500/65c floor). liveDepegBps already
            // absorbs benign sub-peg noise (deadband) and defers stale/dead feeds to 0, so a
            // nonzero `sev` is a REAL depeg -- marking it in full is the honest, first-out-fair
            // value (the old cap counted a 50c stable at 65c: phantom backing that let early
            // redeemers draw at a mark the basket couldn't honor, concentrating the loss on the
            // last redeemers). Severity comes from getDepegSeverityBps (the one source of truth).
            uint sev = IAux(aux).getDepegSeverityBps(stable);
            if (sev > 0) {
                uint lossFrac = sev > 10000 ? 10000 : sev;   // clamp to 100% (worthless)
                uint loss = SoladyMath.fullMulDiv(balance, lossFrac, 10000);
                yieldWeighted = yieldWeighted > loss ? yieldWeighted - loss : 0;
                depegLossOut += loss; // SAME per-stable loss redemption applies; returned
                                   // so _depegLoss needn't re-loop the feeds (2nd pass).
            }
            amounts[i + 1] = balance;
            amounts[14] += balance;
            amounts[0] += yieldWeighted;
            yieldW[i + 1] = yieldWeighted;
            // yieldW[0] = Σ balanceᵢ × rateᵢ — the balance-weighted ANNUALISED rate numerator, which
            // `computeMetrics` divides by amounts[14] to get `metrics.yield`. Slot 0 of `yieldW` was
            // the only unwritten cell in either vector, so this needs no new return value. Weighted by
            // `balance` (post-tranche), the same quantity that lands in amounts[14], so the ratio is a
            // true weighted mean. `amounts[0]` is UNCHANGED — it is `calcFeeL1`'s baseline and moving
            // it would be a second money-path change in one run.
            yieldW[0] += SoladyMath.fullMulDiv(balance, h.rate, WAD);
        }
    }

    /// @notice The EXPENSIVE per-stable valuation: sum a stable's balance +
    ///         yield-weighted value across ALL its venues (Aave-v4 leg via
    ///         aaveBalance, every 4626 leg via convertToAssets; the i>=5
    ///         yield-weighting boost), decimal-scaled to 18-dec. This is the
    ///         only part of get_deposits that hits external vault reads — so it
    ///         is the unit the holdings cache recomputes on a mutation and
    ///         serves from storage on reads. The cheap per-read adjustments
    ///         (tranche subtraction, depeg discount) stay LIVE in the
    ///         callers. Runs in Aux's context (delegatecall), so address(this)
    ///         is Aux. `isAave` = (stable is GHO/USDG); `aaveSpoke` the v4 sentinel.
    // ─── Stored-holdings cache bodies — run in Aux's context via
    // delegatecall (address(this)==Aux), so the storage-ref mappings resolve to
    // Aux's slots. Kept HERE (not Aux) to stay under Aux's EIP-170 ceiling.
    /// @dev `lastLevel`/`rate`/`lastAt` are the RATE ESTIMATOR's per-stable state (§E155-overreport).
    ///      They are PER-STABLE and not aggregate ON PURPOSE: the basket level is a balance-weighted
    ///      mean of per-leg levels that differ by up to 100pp (PYUSD's vault prices at 2.01, USDS at
    ///      1.002), so a deposit that shifts weight between two legs moves the AGGREGATE level with no
    ///      yield involved at all. A finite difference on the aggregate would read that composition
    ///      shift as yield. Differencing each leg against its own previous level is immune to it.
    struct Holding { uint balance; uint yieldWeighted; uint lastLevel; uint rate; uint40 lastAt; }

    /// Minimum spacing between rate samples. `_refreshOne` runs on EVERY mutation, so without this the
    /// estimator would difference two observations seconds apart, where integer truncation makes the
    /// numerator 0 and the reported rate flaps to zero on ordinary traffic.
    /// §E196 — CEILING ON A PER-LEG RATE. A venue whose share price is SELF-REPORTED (an RWA "NAV
    ///  oracle" is structurally identical to a 4626 share price: both are asserted, both accrue
    ///  mechanically) can print any rate it likes, and a FABRICATED one has near-ZERO variance — so it
    ///  reports high AND smooth, dominates the balance-weighted mean, and looks like the SAFEST leg we
    ///  own. sDAI's honest 1.25% ranks below a fabricated 7%.
    ///  ⚠️ THIS IS A BOUND, NOT A DETECTOR, and the distinction matters: it stops a fabricated 50% from
    ///  dominating the projection; it does NOTHING about a fabricated 7%, which is the actual USDX
    ///  shape. Catching that needs a CROSS-SECTIONAL comparison against the cohort — a second pass in
    ///  `get_deposits` — and is deliberately not attempted here.
    ///  The number is MEASURED, not asserted: the live cohort spans 0.62%-7.17% (USDS, USDC, USDT,
    ///  RLUSD, PYUSD, sDAI, sUSDe, AUSD, 30-day annualised), so 20% is ~3x the top of the real range
    ///  and far below what a cumulative LEVEL reports. It earns its place under the inverse of the
    ///  minimise-clamps rule: a fabricated yield is silent and plausible, which is exactly when a
    ///  bound is warranted rather than cosmetic.
    uint internal constant MAX_CREDIBLE_RATE = 0.20e18;
    uint internal constant RATE_SAMPLE_MIN = 1 days;
    uint internal constant YEAR = 365 days;

    /// @dev Recompute ONE stable's cached vault-sum and store it. Shared core.
    ///      Also advances that stable's RATE estimate — see `Holding` above and §E155-overreport.
    ///      MEASURED, which is why this is a delta and not the level: `yieldWeighted/balance` is the
    ///      venue's share price, a CUMULATIVE quantity, so `level - 1` scales with venue AGE and with
    ///      the venue's arbitrary price BASE, not with yield. Live evidence — the five Morpho legs all
    ///      implied the same 0.34-0.37yr age, and PYUSD, whose vault has priced at ~2.0 since it was
    ///      deployed 238 days ago, reported 101.49% of which 99.80pp was pure base offset.
    ///      Subtracting cancels the base; dividing by elapsed cancels the age.
    function _refreshOne(address stable,
        mapping(address => Holding) storage sh) internal {
        address aux = address(this);
        bool isAave = (stable == IAux(aux).GHO() || stable == IAux(aux).USDG());
        (uint b, uint yw) = _valueStable(stable, isAave, IAux(aux).AAVE_SPOKE());
        Holding storage h = sh[stable];
        (uint lastLevel, uint rate, uint40 lastAt) = (h.lastLevel, h.rate, h.lastAt);
        if (b > 0) {
            uint level = SoladyMath.fullMulDiv(WAD, yw, b);
            if (lastAt == 0) {
                // BOOTSTRAP: one observation cannot yield a rate. Anchor it and report 0 until the
                // next sample — the conservative side (under-mints the bond, never over-mints).
                lastLevel = level; lastAt = uint40(block.timestamp);
            } else if (block.timestamp - lastAt >= RATE_SAMPLE_MIN) {
                // A FALLING level (venue loss) reports 0, not a negative rate, and still re-anchors —
                // so the recovery back to the old level is not later paid out as if it were yield.
                rate = level > lastLevel
                    ? SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(WAD, level - lastLevel, lastLevel),
                                      YEAR, block.timestamp - lastAt)
                    : 0;
                if (rate > MAX_CREDIBLE_RATE) rate = MAX_CREDIBLE_RATE;   // §E196
                lastLevel = level; lastAt = uint40(block.timestamp);
            }
        }
        sh[stable] = Holding(b, yw, lastLevel, rate, lastAt);
    }

    /// @notice Refresh one stable's cached vault-sum. Skips unwired (toIndex 0)
    ///         and BOLD (toIndex==nStables; SP leg valued separately).
    function refreshHoldingsBody(address stable,
        mapping(address => Holding) storage sh,
        mapping(address => uint) storage toIndex, uint nStables) external {
        uint ti = toIndex[stable];
        if (ti == 0 || ti == nStables) return;
        _refreshOne(stable, sh);
    }

    /// @notice Refresh every cached stable (the 4626/aave legs; excludes BOLD).
    function refreshAllHoldingsBody(mapping(address => Holding) storage sh,
        address[] storage stables) external {
        uint len = stables.length == 0 ? 0 : stables.length - 1;
        for (uint i; i < len; i++) _refreshOne(stables[i], sh);
    }

    /// @dev Aave-v4 yield-weighting: `assets × (assets/shares)` = assets × the
    ///      reserve liquidity index, mirroring the 4626 `mulDiv(b, b, shares)`
    ///      form so GHO/USDG land on the SAME yield-factor basis as every 4626
    ///      venue (not principal-only). One extra read (suppliedShares); shares==0
    ///      (pre-supply / index unavailable) falls back to principal.
    function _aaveYieldWeighted(address aux, address stable, uint assets)
        internal view returns (uint) {
        if (assets == 0) return 0;
        uint shares = IAux(aux).aaveShares(stable);
        return shares > 0 ? SoladyMath.fullMulDiv(assets, assets, shares) : assets;
    }

    /// @dev The 4626 leg's yield weight = `b × sharePrice`, where sharePrice MUST be
    ///      DIMENSIONLESS. `b/shares` is raw-assets-per-raw-SHARE and equals the share price
    ///      only when the two carry the same decimals. MetaMorpho issues an 18-dec share
    ///      against a 6-dec asset, so the raw ratio came out 1e-12 too small and EVERY 6-dec
    ///      leg valued at zero yield — dragging `amounts[0]` under `amounts[14]` and pinning
    ///      `metrics.yield` at 0 (E155; measured live: Galaxy USDC read 1e-12 against a true
    ///      1.012358). ⚠️ THE LIFT MUST BE INSIDE THE DIVISION. `mulDiv(b, b, shares) * lift`
    ///      returns exactly 1.0 — the inner divide has already truncated the appreciation
    ///      away — so it looks repaired and silently reports zero yield.
    ///      Guarded like every other vault read in this loop, but the fallback is the NEUTRAL
    ///      factor (`b`, i.e. 1.0), never 0: a vault whose `decimals()` reverts must not drag
    ///      the basket average the way a 0 would.
    ///      Pinned by `test/YieldFactorDimensions.t.sol` — the factor is asserted DIMENSIONLESS
    ///      (within [0.5, 2.0] of 1.0) for every funded stable, so a future decimals slip fails
    ///      loudly instead of silently zeroing the bond premium.
    function _yieldWeight(address v, uint b, uint shares, uint assetDec)
        internal view returns (uint) {
        try IERC20(v).decimals() returns (uint8 sd) {
            return SoladyMath.fullMulDiv(b,
                sd > assetDec ? b * (10 ** (uint(sd) - assetDec)) : b, shares);
        } catch { return b; }
    }

    function _valueStable(address stable, bool isAave, address aaveSpoke)
        internal returns (uint balance, uint yieldWeighted) {
        address aux = address(this);
        // Read ONCE, up here: the 4626 yield factor below needs it to normalise the
        // share price, and the tail scaling needs it too.
        uint dec = IERC20(stable).decimals();
        address[] memory vs = IAux(aux).getVaults(stable);
        if (vs.length == 0) {
            // GHO/USDG are Aave-native (vault=0); any other unwired stable → 0.
            if (!isAave) return (0, 0);
            balance = IAux(aux).aaveBalance(stable);
            yieldWeighted = _aaveYieldWeighted(aux, stable, balance);
        } else {
            for (uint j = 0; j < vs.length; j++) {
                address v = vs[j];
                if (v == aaveSpoke) {
                    // Aave-v4 leg: assets are yield-accrued; the factor is
                    // suppliedAssets/suppliedShares (= the reserve liquidity
                    // index), the exact analog of a 4626 share price.
                    uint ab = IAux(aux).aaveBalance(stable);
                    balance += ab;
                    yieldWeighted += _aaveYieldWeighted(aux, stable, ab);
                    continue;
                }
                // Morpho-style 4626 leg. Every external vault read is
                // try/catch'd: a reverting / gas-bombing vault contributes 0
                // and is skipped, never bricking the whole-basket valuation.
                uint b; uint shares;
                try IERC4626(v).balanceOf(aux) returns (uint sh) {
                    if (sh == 0) continue;
                    shares = sh;
                    try IERC4626(v).convertToAssets(sh) returns (uint a) { b = a; }
                    catch { continue; }
                } catch { continue; }
                if (b == 0) continue;
                balance += b;
                // Yield-weight EVERY 4626 venue by its share price so the per-
                // stable yield factor (yieldWeighted/balance) is on a COMMON basis
                // across all stables. The share price = assets/share = b/shares
                // (ERC4626: convertToAssets(sh)=sh×totalAssets/totalSupply, so
                // b/shares IS that ratio) — REUSING the two reads already made, so
                // NO totalSupply/totalAssets calls (a gas cut vs the old path). The
                // old `i>=5` gate forced slots 0-4 to factor 1.0, silently dropping
                // the Morpho-vault yield of USDC/USDT/PYUSD/RLUSD → understated
                // avgYield + cherry-pick fee firing on the wrong stables.
                yieldWeighted += _yieldWeight(v, b, shares, dec);
            }
        }
        if (balance == 0) return (0, 0);
        // Decimal scaling: detect 6-dec stables via token decimals(). Avoids the
        // prior `i < 3 ? 1e12 : 1` slot-hardcode which broke when USDG (6-dec)
        // joined at slot 5. ⚠️ This scales balance and yieldWeighted by the SAME
        // factor, so it cannot repair a RATIO — that is why the fix lives in
        // `_yieldWeight` above and not here.
        if (dec < 18) {
            uint scale = 10 ** (18 - dec);
            balance *= scale;
            yieldWeighted *= scale;
        }
    }

    function avgYield(Metrics memory stats)
        external view returns (uint) {
        if (stats.trackingStart == 0) return 0;
        uint totalTime = block.timestamp - stats.trackingStart;
        uint timeSinceUpdate = block.timestamp - stats.last;
        uint currentAccum = stats.yieldAccum
            + stats.yield * timeSinceUpdate;
        return currentAccum / (totalTime + 1);
    }

    /// @notice ONE MONTH of the deposit's own yield, clamped to what the tranche still needs.
    /// @dev §E195 — the `sqrt(deficit) × avgYield / 4` term is GONE, and removing it is nearly
    ///      behaviour-neutral by measurement, not by hope. `seedFee` took `min` of that term and
    ///      `usd × avgYield / 12`, and the SECOND one binds whenever
    ///        `sqrt(deficit)·y/4 > y/12  ⟺  sqrt(deficit) > 1/3  ⟺  deficit > 11.1%`
    ///      — i.e. for the ENTIRE raise except its last 11%. The sqrt was inert almost everywhere it
    ///      ran. Below that threshold the fee is now bounded by `target − trancheTotal` instead, which
    ///      is itself small exactly there, so the deficit taper SURVIVES through the clamp rather than
    ///      through a curve.
    ///      What remains is one self-describing rule: charge at most one month of what this deposit
    ///      will earn, never more than the tranche still needs. That unit is why §E195 needed no
    ///      recalibration when `avgYield` was corrected from a cumulative LEVEL (mean 18.72%) to a true
    ///      annualised RATE (mean 3.10%) — the fee moved 1.56% → 0.26% of deposit on its own.
    function seedFee(uint usd,
        uint trancheTotal, uint target,
        uint avgYieldIn) internal pure returns (uint) {
        if (target == 0 || trancheTotal >= target || avgYieldIn == 0) return 0;
        return Math.min(SoladyMath.fullMulDiv(usd, avgYieldIn, WAD * 12),
                        target - trancheTotal);
    }

    /// @param amount Amount being deposited
    /// @return cut Fee amount to deduct from deposit
    /// @notice Deposit fee driven by weighted median vote (K).
    ///         Symmetric with withdrawal: stressed (high haircut)
    ///         → higher fee → reserves build faster.
    ///         K=0 → 900bps (9%), K=32 → 100bps (1%)

    // §DE-TICK 2026-08-18 — `getPrice(uint spotPrice, bool token0isUSD)` DELETED. It squared a
    // sqrt-price (`fullMulDiv(casted, casted, 1 << 64)`) and inverted by orientation: pure v4
    // tick/sqrt math, and the last thing that could carry a sqrt-price into this library.
    // ZERO call sites — every remaining mention across `Core` and `SwapLib` is a COMMENT saying
    // where it USED to sit. The ring stores a plain WAD price and `twapBody` reads it directly.

    /// §TICK-REMOVAL — the ring stores PLAIN PRICE, so the TWAP is just the cumulative difference
    /// over the period. This deletes the tick→sqrt→price round trip that was the single largest
    /// `TickMath` consumer, AND the `token0isUSD` argument: orientation is resolved once at write
    /// time rather than on every read, so it can no longer disagree between writer and reader.
    /// ⚠️ The mean is now ARITHMETIC in price where it was geometric in log-price. Across the ±0.2%
    /// `BAND_DELTA` the two differ by O(σ²/8) ≈ 1e-6 relative — inside the rounding already here.
    function cumsToPrice(uint192 cum0, uint192 cum1, uint32 period)
        external pure returns (uint price) {
        price = uint256(cum1 - cum0) / period;
    }

    /// @notice Find index of last mature batch
    function matureBatches(uint[] memory batches,
        uint currentTimestamp, uint deployedTime)
        external pure returns (int i) {
        if (batches.length == 0) return -1;
        uint currentMonth = (currentTimestamp - deployedTime) / MONTH;
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--)
            if (batches[uint(i)] <= currentMonth) return i;

        return -1;
    }

    /// @notice True if `spot` deviates from `twap` by more than `thresholdBps`
    ///         (1e4 = 100%). Threshold is in BPS so sub-1% bands are expressible.
    function isManipulated(uint spot, uint twap,
        uint thresholdBps) public pure returns (bool) {
        uint dev = spot > twap ? spot - twap : twap - spot;
        return dev * 10000 > twap * thresholdBps;
    }

    /// @notice Scale token amounts between precisions...
    /// @notice 6-dec USD → `token`'s NATIVE units. The INVERSE of `SwapLib.scaleTo6`, and the helper
    ///         that did not exist until §A.72 proved it was missing. **Do NOT substitute
    ///         `scaleTokenAmount`**: that converts native↔18-dec, a DIFFERENT basis, and using it here
    ///         divided 6-dec USDC by 1e12 and delivered ~0 (333 failing tests).
    ///         No-op for 6-dec stables; ×1e12 for the seven 18-dec ones (GHO/RLUSD/BOLD/DAI/USDS/USDe/cUSD).
    function from6(uint amount6, address token) internal view returns (uint) {
        uint decimals = IERC20(token).decimals();
        return decimals == 6 ? amount6
             : decimals > 6 ? amount6 * (10 ** (decimals - 6))
                            : amount6 / (10 ** (6 - decimals));
    }

    function scaleTokenAmount(uint amount, address token,
        bool scaleUp) internal view returns (uint scaled) {
        uint decimals = IERC20(token).decimals();
        uint scale = decimals < 18 ? 18 - decimals : 0;
        scaled = scale > 0 ? (scaleUp ? amount * (10 ** scale):
              amount / (10 ** scale)) : amount; return scaled;
    }

    /// @notice Body of Aux._tip — apply a fee tranche credit/debit (`sign`>0 credit, else clamped debit). Scales
    ///         `cut` to 18-dec, mutates the `tranche` mapping (storage ref), and returns the new `trancheTotal`
    ///         (value-type, written back by the Aux forwarder). Byte-identical relocation for EIP-170 headroom.
    function tipBody(mapping(address => uint) storage tranche, uint trancheTotal, uint cut, address token, int sign)
        public returns (uint) {
        cut = scaleTokenAmount(cut, token, true);
        if (sign > 0) {
            tranche[token] += cut;
            return trancheTotal + cut;
        }
        cut = Math.min(cut, tranche[token]);
        tranche[token] -= cut;
        return trancheTotal - Math.min(trancheTotal, cut);
    }

    /// @notice Convert amount between volatile asset and USDC using price.
    /// Flat 1e18 for BOTH assets: the WBTC price carries a x1e10 lift (usd*1e28 vs WETH's
    /// usd*1e18) which ALREADY closes the 8<->18-dec gap, so a per-asset 10**decimals scale
    /// would double-count it (SwapLib:950-954 states the same rule for poolVolUsd).
    /// `price` is always WAD-scaled USD-per-asset; USDC is always 1e6.
    function convert(uint amount, uint price, bool toVol)
        public pure returns (uint) {
        return toVol
            ? SoladyMath.fullMulDiv(amount * 1e12, 1e18, price)   // USDC → vol
            : SoladyMath.fullMulDiv(amount, price, 1e18) / 1e12;  // vol → USDC
    }

    function routeSwap(Types.AuxContext memory ctx,
        Types.RouteParams memory p) external returns
        (uint out, uint poolSupplied, uint consumed) {
        // GRINDING REMOVED: no pre-swap manipulation revert. A swap executes even when
        // the pool spot is off the TWAP — it pays the real curve slippage, and VALUE reads use
        // the anchored getTWAPforAsset (30-min TWAP + 5% Chainlink anchor), never this spot.
        // The old revert DoS'd every swap after a large move until the 30-min TWAP caught up;
        // the anchor + curve-reseat are the actual protection. minOut absorbs partial fills.
        // `consumed` = the caller-input amount actually routed to the swap (before any 4626 revaluation);
        // the excess p.amount-consumed is a partial fill the caller must reclaim/cap (#105).
        consumed = Math.min(p.amount, convert(p.pooled,
                        p.v4Price, p.token != address(0)));
        uint pooled = consumed;
        if (pooled > 0) {
            if (p.token != address(0) && ctx.vault != address(0)) {
                // Uniform Morpho 4626 supply path. Every yield venue is
                // ERC4626 now, so the supply call is a single shape
                // regardless of asset (the aToken-direct branch is
                // gone). Skipped when ctx.vault is zero — WBTC has no
                // vault at all (single-tx swap leg only; never held by
                // Aux), so a vault-zero context means "swap, don't
                // supply" and we go straight to the V4 leg below.
                //
                // SHARES go to address(this) — i.e. Aux when called via
                // library delegatecall. (The original `ctx.v4` field
                // pointed at the Quid contract, which would have
                // orphaned shares there with no Quid-side redemption
                // path — see takeETH / _sendETH, which draw from Aux's
                // wethVault position via bandOp, never from Quid's
                // own balance. Routing to Aux keeps every supply
                // symmetric: Aux is the sole share-owner, bandETH()
                // and _syncVenue see the full position.)
                pooled = IERC4626(ctx.vault).convertToAssets(
                       IERC4626(ctx.vault).deposit(pooled, address(this)));

                poolSupplied = pooled;
            }
            out = ICore(ctx.core).swap(p.recipient, p.inputIsUsd, p.token, pooled);
        }
        // If p.amount > V4 capacity, `out` is less than amount. minOut at
        // outer layer enforces slippage / partial-fill tolerance.
    }

    /// @notice Yield-enhanced mint amount calculation.
    ///
    /// Non-seed branch: forward-projects `avgYield` over the lockup
    /// window. This is a PROJECTION — assumes future realized yield over
    /// the lockup matches the historical time-averaged yield. If realized
    /// yield falls short, the QUID minted here exceeds what the basket
    /// will produce, and supply runs ahead of backing (peg pressure).
    /// Mitigants: `avgYield` is depeg-risk-adjusted at the source
    /// (Aux.riskFactor), seedFee bites when basket is under target, and
    /// the lockup window is bounded.
    ///
    /// Seed branch: lockup target is literally month 13 AND the seed
    /// tranche (`seeded < CAP`) is still open. Seed depositors get a
    /// FIXED 100% APR projection — independent of current basket yield.
    /// This is the founder/early-adopter reward and IS the seed tier's
    /// economic justification. Projection time = `month - (nextMonth-1)`,
    /// which ranges from 13 months (at protocol launch) down to 1 month
    /// (as nextMonth approaches 13). Bonus shrinks linearly as the seed
    /// window closes. Once `nextMonth > 12`, isSeed is structurally
    /// unreachable: month is capped at the user's `when`, but seed
    /// requires `when == 13`, and `nextMonth` can't go above 13 before
    /// `month==13` is impossible. The tranche also closes when
    /// `seeded ≥ CAP` (600k QUID).
    ///
    /// The previous implementation used `avgYield * 2` for the seed
    /// branch — that approximated ~10% APR at typical yields, nowhere
    /// near 100%. Corrected here.
    function calcMintYield(uint deposited, uint decimals,
        uint when, uint nextMonth,
        uint avgYieldIn, bool isSeed) external pure
        returns (uint normalized, uint month) {
        normalized = decimals < 18 ? deposited
            * (10 ** (18 - decimals)) : deposited;
        month = isSeed ? nextMonth + 1 : nextMonth;
        if (when > month) month = when;
        // Seed tranche: yield is a fixed CONSTANT (100% APR projection)
        // — the bootstrap incentive doesn't track observed vault yield
        // because in the very early days the basket hasn't had time to
        // earn anything. Constant lets seed depositors get a real
        // bonus while we're raising the seed tranche. Once seeded
        // reaches CAP, isSeed flips false permanently and the regular
        // flow takes over (yield = avgYield, a function of the
        // constituent vault yields).
        uint yield = isSeed ? WAD : avgYieldIn;
        normalized += SoladyMath.fullMulDiv(normalized * yield,
                        month - (nextMonth - 1), WAD * 12);
    }

    /// @notice Body of Aux.take. Aux wraps this, pre-passing cheap state
    ///         (stables array, LINK, toIndex value, QUID, WETH), then
    ///         DELEGATECALL's here. State mutations route back via
    ///         IAux's self-gated entries (withdrawSelf, tipSelf,
    ///         checkBacking) — same DELEGATECALL → external self-CALL
    ///         pattern as SwapLib uses. See Aux.supplySelf docblock for
    ///         the security invariants.
    ///
    ///         WRAPPER MUST hold the `onlyUs` gate. This library function
    ///         trusts that the caller is authorized.
    /// @notice takeBody's args bundled into one struct — a single memory pointer
    ///         keeps the redemption entry within the legacy stack (10 scalar params
    ///         would overflow it without via_ir).
    struct TakeArgs {
        address who;
        uint    amount;
        address token;
        uint    seed;
        address weth;
        address quid;
        uint    index;
        address[] stables;
        address linkAddr;
        // Targeted redemption (token==quid + preferred!=0): the stable to shed
        // FIRST, and its 1-indexed slot. address(0)/0 ⇒ pure pro-rata (default).
        address preferred;
        uint    prefIndex;
        // Trusted swap-out SETTLE drain (delivery-side de-lever): the terminal solvency check uses the
        // non-reverting tryCheckBacking instead of the strict checkBacking, because the drain is IMMEDIATELY
        // offset by an in-tx debt-repay so the FINAL state is solvent even though the mid-drain instant is not.
        // Only Aux.takeToSettle sets this; every user-facing drain (redeem/withdraw/arb) leaves it false (strict).
        bool    softBacking;
    }

    function takeBody(TakeArgs memory a) external returns (uint sent) {
        IAux aux = IAux(address(this));
        if (a.token == a.weth) {
            sent = aux.withdrawSelf(a.weth, a.amount, a.who);
            aux.checkBacking();
            return sent;
        }
        (uint[15] memory amounts, uint[15] memory yieldW,,) = aux.get_deposits();
        sent = _takeCore(a, amounts, yieldW);
        // §E91-r5 / S16 — AGGREGATE DELIVERY GUARD. The per-venue `try/catch` in `_takePreferred`
        // and `_takeProRata` is CORRECT and stays: the basket holds up to 15 stables in separate
        // venues (Aave, 4626 vaults, the Stability Pool), and one paused, exploited or
        // reverting-`decimals()` venue must NOT brick redemption for every holder — that exact
        // regression already happened ("was a bare `require(bad-dec)` outside the try, so one weird
        // token reverted every holder's redeem").
        //   But fail-soft must mean "ROUTE AROUND the broken venue", not "deliver NOTHING, quietly".
        // With every path swallowing its own failure, ALL of them failing produced `sent == 0` with
        // NO revert: MEASURED on the swap-out path, where the mock USD was burned, `Core.swap`
        // returned a non-zero `max` (37943101858) and the recipient received ZERO. `max` reports the
        // SWAP's delta, not the USER's receipt, so the `max == 0` guard upstream cannot see this —
        // and `minOut = 0` (the SPA default, §S16) hides it from the caller too.
        //   One aggregate check closes it without touching the per-venue resilience: asking for a
        // non-zero amount and receiving nothing is never a valid outcome.
        if (a.amount > 0 && sent == 0) revert NothingDelivered();
    }

    /// @notice Pre-fetched-deposits variant of takeBody: the redeem path fetches
    ///         get_deposits ONCE (for the depeg haircut) and — when no seed/tranche
    ///         QUI was burned, so `tranche` (which get_deposits nets out) is
    ///         unchanged by the turn — threads the SAME (amounts, yieldW) here instead
    ///         of a second full basket scan. Non-WETH only (the redeem token==quid
    ///         path); the WETH short-circuit stays in takeBody. The caller guarantees
    ///         the arrays are still current (no stable-balance mutation since fetch).
    function takeBodyWith(TakeArgs memory a, uint[15] memory amounts, uint[15] memory yieldW)
        external returns (uint sent) {
        sent = _takeCore(a, amounts, yieldW);
        // §E91-r5 / S16 — AGGREGATE DELIVERY GUARD. The per-venue `try/catch` in `_takePreferred`
        // and `_takeProRata` is CORRECT and stays: the basket holds up to 15 stables in separate
        // venues (Aave, 4626 vaults, the Stability Pool), and one paused, exploited or
        // reverting-`decimals()` venue must NOT brick redemption for every holder — that exact
        // regression already happened ("was a bare `require(bad-dec)` outside the try, so one weird
        // token reverted every holder's redeem").
        //   But fail-soft must mean "ROUTE AROUND the broken venue", not "deliver NOTHING, quietly".
        // With every path swallowing its own failure, ALL of them failing produced `sent == 0` with
        // NO revert: MEASURED on the swap-out path, where the mock USD was burned, `Core.swap`
        // returned a non-zero `max` (37943101858) and the recipient received ZERO. `max` reports the
        // SWAP's delta, not the USER's receipt, so the `max == 0` guard upstream cannot see this —
        // and `minOut = 0` (the SPA default, §S16) hides it from the caller too.
        //   One aggregate check closes it without touching the per-venue resilience: asking for a
        // non-zero amount and receiving nothing is never a valid outcome.
        if (a.amount > 0 && sent == 0) revert NothingDelivered();

    }

    /// @dev Shared body of takeBody / takeBodyWith. `amounts`/`yieldW` are the basket
    ///      deposit vectors (from get_deposits); the entrypoints differ only in whether
    ///      those were just-fetched here or threaded in by a caller that already had them.
    function _takeCore(TakeArgs memory a, uint[15] memory amounts, uint[15] memory yieldW)
        private returns (uint sent) {
        IAux aux = IAux(address(this));
        FeeLib.FeeCtx memory fc = FeeLib.FeeCtx(a.stables, a.linkAddr);
        // §D5 — ONE preferred-token path, not two. Both branches did the SAME job: name the stable
        // to serve FIRST, then skip it in the pro-rata leg below. They differed only in which index
        // they validate and whether the amount needs converting to native units. This is legacy
        // `Aux._take`'s shape (`skip` + a single loop) with our `decimals()`-based scaling KEPT.
        //
        // ⚠️ Legacy's remaining brevity came from a POSITIONAL divisor (`i < 4 || i == 11 ? 1e12 : 1`)
        // which broke when a 6-dec stable joined at a later slot (see :282). That is deliberately NOT
        // restored — the decimals lookup is the fix, not the complexity.
        //
        // SWAP take (token != quid): the named stable IS the preferred leg, already in NATIVE units.
        // TARGETED REDEEM (token == quid, preferred set, seed == 0): shed the chosen stable first —
        // the cherry-pick concentration fee rides on this leg via calcNeeded. Its `a.amount` is USD
        // 1e18 (a share of amounts[14]), so it MUST be converted to native units first: §A.50, where
        // a 6-dec stable was asked for 1e12x the intended draw and declining pro-rata PAID the
        // redeemer. Seed-bearing redemptions (seed > 0) are excluded so the seed keeps its pro-rata
        // un-tip distribution instead of routing onto one stable (preferred is ignored, not an error).
        bool viaToken = a.token != a.quid;
        address skip = viaToken ? a.token : (a.seed == 0 ? a.preferred : address(0));
        if (skip != address(0)) {
            uint idx = viaToken ? a.index : a.prefIndex;
            require(idx > 0 && idx <= a.stables.length, "unknown-stable");
            bool done;
            (sent, a.amount, done) = _takePreferred(aux, a.who, skip,
                viaToken ? a.amount : scaleTokenAmount(a.amount, skip, false),
                a.seed, amounts, yieldW, fc);
            if (done) return sent;
        }
        if (amounts[14] == 0 || a.amount == 0) { _finalBacking(aux, a.softBacking); return sent; }
        if (a.seed == 0) a.amount = Math.min(amounts[14], a.amount);
        {   (uint pr, bool subUnit) = _takeProRata(aux, a.who, a.amount, a.seed, skip, amounts, fc);
            sent += pr;
            // Own scope so the two locals leave the frame before `_finalBacking` — this function is at
            // the legacy stack limit and `via_ir` stays off by design.
            if (sent == 0 && subUnit) revert AmountTooSmall();
        }
        _finalBacking(aux, a.softBacking);
    }

    /// @dev Terminal solvency check of a take. STRICT by default (reverts on committed>liquid, protecting the
    ///      user-facing drains); the trusted swap-out settle drain passes softBacking=true to use the
    ///      non-reverting variant, since its mid-drain instant is offset by an in-tx debt-repay.
    function _finalBacking(IAux aux, bool soft) private {
        if (soft) aux.tryCheckBacking(); else aux.checkBacking();
    }

    /// @dev Preferred-stable leg of takeBody, in its own frame (legacy stack — no
    ///      via_ir crutch). Try the named token first; if its vault is
    ///      paused/frozen, swallow the revert and fall through to the pro-rata leg
    ///      (without this, a single halted Morpho/AAVE/SP venue would freeze every
    ///      QUID redemption that names that stable). Returns (sent, remaining 18-dec
    ///      amount, done); done=true means the seed (turn) path already settled and
    ///      takeBody must return immediately.
    ///
    ///      UNITS — ASYMMETRIC, and the caller owns the input side: `amount` must be in
    ///      `token`'s NATIVE units (it reaches withdrawSelf unchanged, only grossed up for
    ///      depeg), while `sent`/`remaining` come back as USD 1e18 so the pro-rata leg and
    ///      takeBody's return value stay in one currency. The redeem call site converts;
    ///      the swap call site already holds native units.
    function _takePreferred(
        IAux aux, address who, address token, uint amount, uint seed,
        uint[15] memory amounts, uint[15] memory yieldW, FeeLib.FeeCtx memory fc
    ) private returns (uint sent, uint remaining, bool done) {
        uint needed = FeeLib.calcNeeded(token, amount, amounts, yieldW, fc);
        if (seed > 0) {
            aux.tipSelf(seed, token, -1);
            sent = aux.withdrawSelf(token, needed, who);
            aux.checkBacking();
            return (sent, 0, true);
        }
        try aux.withdrawSelf(token, needed, who) returns (uint s) {
            sent = s;
        } catch {
            sent = 0;
        }
        remaining = needed > sent ? needed - sent : 0;
        sent = scaleTokenAmount(sent, token, true);
        remaining = scaleTokenAmount(remaining, token, true);
    }

    /// @dev Pro-rata cross-stable leg of takeBody, own frame for the legacy stack.
    ///      Per-slot try/catch: a single halted venue doesn't revert the whole
    ///      redemption — the user gets the sum of slots that worked (failed slot
    ///      contributes 0).
    /// @return sent delivered, 18-dec.
    /// @return subUnit TRUE when at least one leg was ALLOCATED a non-zero 18-dec share that then
    ///         truncated to ZERO native units. §E191 — the allocation is 18-dec and the withdraw is
    ///         native, so a draw below one native unit of a leg (1e12 wei for a 6-dec stable) rounds
    ///         away on EVERY leg and `sent` comes back 0. That is not "every venue failed", which is
    ///         what `NothingDelivered` means; it is a request too small to express. Reporting them as
    ///         the same thing is what let a dust redeem masquerade as a venue outage.
    function _takeProRata(
        IAux aux, address who, uint amount, uint seed, address skip,
        uint[15] memory amounts, FeeLib.FeeCtx memory fc
    ) private returns (uint sent, bool subUnit) {
        for (uint i = 1; i <= fc.stables.length; i++) {
            address token = fc.stables[i - 1]; if (token == skip) continue;
            // §E191 — capture the leg's DEPOSIT before overwriting it with the allocation. A funded leg
            // whose pro-rata share comes back 0 means the draw is too small to express THERE; if that
            // holds everywhere and nothing is delivered, the request was sub-unit, not a venue outage.
            // The truncation happens INSIDE `allocate` (its own `if (amount == 0) return 0`), which is
            // why testing after the divisor below was too late — the first version of this fix put the
            // flag there and never fired.
            // No local: `amounts[i]` IS the leg's deposit until it is overwritten, so the funded test
            // happens in place. A funded leg whose share comes back 0 means the draw is too small to
            // express there. (`uint dep = amounts[i]` was the obvious spelling and went stack-too-deep;
            // `via_ir` stays off by design.)
            if (amounts[i] != 0) {
                amounts[i] = FeeLib.allocate(token, amount, amounts[i], amounts[14], fc);
                if (amounts[i] == 0) subUnit = true;
            }
            if (seed > 0) aux.tipSelf(SoladyMath.fullMulDiv(amounts[i], seed, amount), token, -1);
            if (amounts[i] > 0) {
                // A bad/reverting-decimals stable (e.g. one bound via the permissionless
                // registry hook) must contribute 0, NOT brick the whole pro-rata redeem — the
                // same fail-soft posture as the withdrawSelf try/catch below. (Was a bare
                // `require(bad-dec)` outside the try, so one weird token reverted every holder's
                // redeem.)
                uint d;
                try IERC20(token).decimals() returns (uint8 dd) { d = dd; } catch { d = 0; }
                if (d == 0 || d > 18) { amounts[i] = 0; continue; }
                uint divisor = d < 18 ? 10 ** (18 - d) : 1;
                if (amounts[i] / divisor == 0) { subUnit = true; amounts[i] = 0; continue; }
                try aux.withdrawSelf(token, amounts[i] / divisor, who) returns (uint w) {
                    amounts[i] = w;
                    sent += amounts[i] * divisor;
                } catch {
                    amounts[i] = 0;
                }
            }
        }
    }

    /// @notice ETH→stable fallback body for redemption. Pulls `ethAmount`
    ///         WETH from the ETH venue via the self-gated withdraw, then opens a
    ///         V4 unlock that the host's `unlockCallback` recognizes as
    ///         the ETH-source variant (sourceAsset = WETH, first hop's
    ///         currency0 = native ETH). PoolKey is the canonical V4
    ///         ETH/USDC pool (currency0 = native, currency1 = USDC,
    ///         fee = 500, tickSpacing = 10, no hooks).
    /// @notice Body of Aux._redeemAs (delegatecall, address(this)==Aux).
    /// Returns ethPart+price so the Aux wrapper runs the ETH-fallback leg.
    /// @notice (C) Total depeg loss across the basket, for fair-valuing the
    /// redemption total. get_deposits stores per-stable amounts at PAR (only
    /// the yield slot is riskFactor-discounted), so a held stable that depegs
    /// AFTER deposit overstates redeemable backing. Subtracting
    /// Σ amountᵢ × (1 − riskFactorᵢ) prices redemption at the live haircut —
    /// no race, no first-out-at-par. Applied ONLY in the redemption path;
    /// get_deposits / FeeLib / backing keep their existing par semantics.
    function _depegLoss() internal returns (uint loss) {
        // get_deposits already reads every feed and accumulates the per-stable depeg
        // loss in its single pass (Σ balance × min(sev,3500)/10000, incl. BOLD/SP) —
        // so we read that value, NOT a redundant second riskFactor loop over the
        // feeds. Still LIVE (get_deposits recomputes), so a depeg between metrics
        // refreshes is caught at redemption time. Byte-identical to the old loop.
        (,,, loss) = IAux(address(this)).get_deposits();
    }

    /// @notice External accessor for the redemption depeg haircut so the MINT path
    /// can discount its redeemability headroom by the SAME loss. Without it, backing
    /// for the mint cap is PAR (`amounts[14]`) while redemption is par−`_depegLoss`,
    /// so during a depeg the cap would let the forward-yield slice mint against the
    /// par-phantom value of depegged holdings → supply could exceed redeemable
    /// backing. Mint↔redeem symmetry closes that. (Delegatecalled by Aux; runs in
    /// Aux's context, so the same per-stable scaling applies.)
    function depegLoss() external returns (uint) { return _depegLoss(); }
    /// @notice The DELIVERABILITY haircut (Σ max(0, convertToAssets − maxWithdraw) + Aave util cap), exposed
    ///         so the MINT side can bind on DELIVERABLE backing symmetrically with redemption (which already
    ///         subtracts `_illiquidLoss` in redeemAsBody/redeemableBody). Closes the freeze-window
    ///         over-issuance that does NOT self-heal when a frozen venue is IMPAIRED (stale-high
    ///         convertToAssets it can never actually deliver).
    function illiquidLoss() external view returns (uint) { (uint l,,) = _illiquidLoss(); return l; }

    /// @notice §E203 — the same deliverability haircut, but it also STARTS/CLEARS the vault-health clock.
    ///         `Basket._finishMint`'s protocol-mint headroom gate already ran this loop and discarded the
    ///         per-vault verdict, exactly as the redeem path did before §E197 — and that gate is NOT a
    ///         view, so the flag costs NOTHING EXTRA: no additional external call, no additional read.
    ///         ⚠️ NARROW, AND DELIBERATELY SO — do not read this as "mint drives detection". Its one
    ///         call site sits behind TWO gates: `if (auth(msg.sender))`, i.e. the PROTOCOL-INTERNAL mint
    ///         path only (fee mints, `creditLPForSwap` swap-out reissuance, Quid fee distribution) and
    ///         NOT user deposits; and `if (currentMonth() >= 12)`, so it is DORMANT FOR THE FIRST YEAR.
    ///         The USER deposit path (`_finishMint`) intentionally does not compute `illiquidLoss` at
    ///         all, and hooking it would be a NEW read plus a change to the documented mint↔redeem
    ///         valuation asymmetry — not free, so not done.
    ///         ⇒ REDEEM REMAINS THE PRIMARY DRIVER. This is a free second one after month 12, no more.
    ///         DETECTION ONLY — evacuation still requires the deliberate `pokeVaultHealth`.
    function illiquidLossFlagging() external returns (uint loss) {
        address worst; uint worstBps;
        (loss, worst, worstBps) = _illiquidLoss();
        if (worst != address(0)) IAux(address(this)).flagIlliquidSelf(worst, worstBps < LIQ_TOL_BPS);
    }

    /// @notice Redemption-only DELIVERABILITY haircut. get_deposits values
    /// each 4626 leg at convertToAssets (PAR/solvency), which can exceed what the
    /// vault can actually pay out NOW (maxWithdraw) — e.g. a solvent-but-frozen
    /// Morpho/Euler market. Without this, redeemSplit would `reserve` (and `turn`
    /// would BURN) QU!D against backing that take() can't deliver, leaving the
    /// "under-delivery on user" (redeemAsBody:846) — QU!D destroyed for value not
    /// received. Subtracting Σ max(0, convertToAssets − maxWithdraw) caps the
    /// redemption total at DELIVERABLE funds, so a frozen vault's slice DEFERS (the
    /// redeemer's QU!D stays redeemable once it thaws) instead of being burned.
    /// Mirrors _depegLoss: same per-stable native→18-dec scaling, redemption path
    /// ONLY (get_deposits/FeeLib/backing keep PAR semantics). Conservative — uses
    /// raw convertToAssets (not the vault-health-reduced value), clamped at total,
    /// so a both-haircut-and-illiquid vault is over-deferred, never over-paid.
    /// The Aave-v4 leg IS deliverable-capped: a reserve can be utilization-bound
    /// (cash = suppliedAssets − totalDebt < our balance), so the slice we can't
    /// withdraw NOW defers like a frozen 4626 (verified live: GHO reserve ~78%
    /// utilized). BOLD/SP needs no cap — getCompoundedBoldDeposit is withdrawable
    /// (the SP doesn't lend it out), so deliverable == solvent there.
    /// @return loss the deliverability haircut, unchanged.
    /// @return worst the 4626 leg with the LOWEST liquidity ratio, and @return worstBps that ratio.
    ///         §E197 — THIS LOOP ALREADY COMPUTES THE VAULT-HEALTH POKE'S TWO INPUTS. `solv` IS the
    ///         poke's `reported` and `deliv` IS its `liquid`; we were paying for both reads on every
    ///         redeem and discarding the per-vault verdict, keeping only the aggregate. Reporting the
    ///         worst leg lets the caller start the health clock off ORGANIC TRAFFIC — no scheduler, no
    ///         extra external call. Worst-only (not a list) keeps this within the legacy stack; repeated
    ///         traffic walks the set, and the worst leg is the one that matters first.
    function _illiquidLoss() internal view returns (uint loss, address worst, uint worstBps) {
        worstBps = type(uint).max;      // sentinel: the FIRST leg seen must always win.
        // ⚠️ NOT 10000. Initialising at "perfectly liquid" with a strict `<` means a fully-liquid
        // basket (every bps == 10000) never beats the sentinel, so `worst` stays address(0) and the
        // caller skips the flag call — which silently disables the RELEASE direction while leaving
        // blocking intact. Caught by test_trafficReleasesTheVaultOnceLiquidAgain, which is the whole
        // reason that test exists. Callers gate on `worst != address(0)`, so the no-legs case is safe.
        address aux = address(this);
        address[] memory stables = IAux(aux).getStables();
        address aaveSpoke = IAux(aux).AAVE_SPOKE();
        uint len = stables.length - 1;          // skip last (BOLD): deliverable==solvent (SP)
        for (uint i = 0; i < len; i++) {
            address stable = stables[i];
            address[] memory vs = IAux(aux).getVaults(stable);
            uint shortfall;                     // native decimals, summed per stable
            for (uint j = 0; j < vs.length; j++) {
                address v = vs[j];
                if (v == aaveSpoke) {           // Aave leg: cap at the reserve's CASH
                    // Generalized reserve-id: GHO/USDG via their immutables,
                    // dual-venue USDC/USDT via the aaveReserveId mapping.
                    uint rid = stable == IAux(aux).GHO()
                        ? IAux(aux).GHO_RESERVE_ID()
                        : stable == IAux(aux).USDG()
                        ? IAux(aux).USDG_RESERVE_ID()
                        : IAux(aux).aaveReserveId(stable);
                    if (rid == 0) continue;
                    uint supA = IAux(aux).aaveBalance(stable); // our supplied (asset-dec)
                    uint avail;                  // reserve cash = supplied − debt
                    try IAaveV4Spoke(aaveSpoke).getReserveSuppliedAssets(rid) returns (uint rs) {
                        try IAaveV4Spoke(aaveSpoke).getReserveTotalDebt(rid) returns (uint rd) {
                            avail = rs > rd ? rs - rd : 0;
                        } catch { avail = 0; }   // debt unreadable → conservative (defer all)
                    } catch { avail = 0; }       // supplied unreadable → conservative
                    if (supA > avail) shortfall += supA - avail;
                    // §E198 — the aave leg can now be nominated, keyed PER RESERVE. Until this, the
                    // `continue` below was the only thing stopping §E197's traffic flagging from
                    // blocking every aave-routed stable at once off one reserve's dip — a safety
                    // property held by accident, which is not a safe place to leave one.
                    if (supA > 0) {
                        uint abps = SoladyMath.fullMulDiv(avail > supA ? supA : avail, 10000, supA);
                        if (abps < worstBps) { worstBps = abps; worst = aaveHealthKey(aaveSpoke, rid); }
                    }
                    continue;
                }
                try IERC4626(v).balanceOf(aux) returns (uint sh) {
                    if (sh == 0) continue;
                    uint solv;
                    try IERC4626(v).convertToAssets(sh) returns (uint a) { solv = a; }
                    catch { continue; }
                    // ONE definition, shared with the ETH ladder (QuidLib._withdrawableOf). MEASURED
                    // 2026-07-26: 6 of our 8 registered stable vaults are Morpho-V2 (sky/wintermute/
                    // rockaway USDC, sky USDT, gauntlet USDC+USDT) holding ~124M of ~126M stable TVL.
                    // Their max-views are IDLE-ONLY and report 0 against a fully withdrawable position,
                    // so the raw read treated `solv` as ENTIRELY undeliverable and haircut the whole
                    // position here — and this shortfall feeds the REDEMPTION haircut. Still returns 0
                    // for an unreadable view (conservative: over-haircut, never over-promise).
                    uint deliv = QuidLib._withdrawableOf(v, aux);
                    if (solv > deliv) shortfall += solv - deliv;
                    // Free: `solv` and `deliv` are already in hand. Same ratio the poke computes.
                    uint bps = SoladyMath.fullMulDiv(deliv, 10000, solv);
                    if (bps < worstBps) { worstBps = bps; worst = v; }
                } catch { continue; }
            }
            if (shortfall == 0) continue;
            uint dec = IERC20(stable).decimals();
            if (dec < 18) shortfall *= 10 ** (18 - dec);
            loss += shortfall;
        }
    }

    /// @notice redeemAsBody's args bundled — one memory pointer keeps the
    ///         redemption body within the legacy stack (no via_ir crutch).
    struct RedeemArgs {
        uint amount;
        address source;
        address recipient;
        address core;
        address quid;
        address v4;
        address weth;
        // Optional targeted draw: a basket stable to shed FIRST (then pro-rata
        // remainder), or address(0) for the default cherry-pick-free pro-rata draw.
        address preferred;
    }

    /// @dev Pre-burn redemption quote, own stack frame (redeemAsBody stays within the legacy pipeline, no via_ir).
    ///      Separates VALUE from DELIVERABILITY:
    ///        • perShare — what ONE mature QU!D is worth: min(par, SOLVENT backing / matureSupply). SOLVENT = par
    ///          backing − depeg only; temporary illiquidity (Morpho-lent stables, band-committed USD) is NOT
    ///          subtracted (solvent, WILL pay → must not discount value — only depeg/drift moves perShare below
    ///          par). The IDENTICAL perShare prices a QD-in swap (SwapLib), so QD is never worth more swapped than
    ///          redeemed. Force-fresh metrics reflect a mid-cache write-down.
    ///        • freeUsd — stables withdrawable from the vaults RIGHT NOW = solvent − max(il, committed). `il` and
    ///          `committed` OVERLAP (band-committed USD shows as throttled maxWithdraw, counted in `il`), so
    ///          subtract the MAX not the sum; `committed` can exceed `il` when the band's USD leg > vault-missing.
    ///          BOTH bands are excluded here; redeemAsBody unwinds ONLY the ETH band for the remainder.
    function _redeemQuote(RedeemArgs memory r, uint raw, uint rateWeighted, uint depegLossIn)
        private returns (uint perShare, uint freeUsd) {
        (uint solvent,) = IAux(address(this)).get_metricsWith(raw, rateWeighted);
        solvent = solvent > depegLossIn ? solvent - depegLossIn : 0;
        uint mature = IBasketTurn(r.quid).matureSupply();
        // ONE valuation for redeem AND swap (no swap↔redeem arb): per-share = qdShareValue of a single share.
        // Byte-equivalent to the old `min(WAD, solvent·WAD/mature)` incl. the mature==0→WAD guard. #U1.
        perShare = ShareMath.qdShareValue(WAD, solvent, mature);
        (uint il, address worst, uint worstBps) = _illiquidLoss();
        // DETECTION ONLY — never evacuation. A user's redeem must not trigger a multi-vault drain,
        // so this starts the EVAC_DWELL clock and leaves the fund-moving step to the existing
        // permissionless poke. That is the §E152-nerve gap: `flaggedAt` could not start until
        // somebody poked, so a 30-minute dwell had an UNBOUNDED start. It now starts on traffic.
        if (worst != address(0)) IAux(address(this)).flagIlliquidSelf(worst, worstBps < LIQ_TOL_BPS);
        uint committed = ICore(r.core).committedUsd18();
        uint locked = il > committed ? il : committed;
        freeUsd = solvent > locked ? solvent - locked : 0;
    }

    function redeemAsBody(RedeemArgs memory r) external {
        // DEDUP: fetch the basket deposit vectors ONCE here (pre-burn) for the depeg haircut + the take leg.
        (uint[15] memory amts, uint[15] memory yW,, uint depegLossOut) =
            IAux(address(this)).get_deposits();
        // yW[0] (Σ balance×rate), NOT amts[0] (Σ yieldWeighted) — see computeMetrics's @param.
        (uint perShare, uint freeUsd) = _redeemQuote(r, amts[14], yW[0], depegLossOut);
        // UNWIND-FIRST, BURN-EXACT (own frame): free what this redemption can ACTUALLY deliver, then burn ONLY
        // that — burn follows delivery, so there is never a burn without delivery and never an over-unwind.
        (uint usdPart, uint seedBurned, bool unwound) = _settleRedeem(r, perShare, freeUsd);
        _dispatchTake(r, usdPart, seedBurned, amts, yW, unwound);
    }

    /// @dev Deliver + burn for redeemAsBody, own frame. Redeems the holder's MATURE QU!D only (immature/forward
    ///      defers), valued at `perShare`. Pays from free vault stables first; unwinds the ETH band for the
    ///      remainder (LP ETH untouched — unwindForRedeem frees the exact USD asked, ratio-sized). Then burns
    ///      EXACTLY `delivered/perShare`: if the ETH unwind frees LESS than asked — a shallow ETH band, or the
    ///      shortfall was BTC-band USD the ETH unwind can't reach — `delivered` shrinks and the burn shrinks with
    ///      it; the un-served QU!D is RETAINED as a live deferred claim (redeems once liquid). No capacity
    ///      estimate, no cap, no over-burn: burn is derived FROM actual delivery, never assumed ahead of it.
    function _settleRedeem(RedeemArgs memory r, uint perShare, uint freeUsd)
        private returns (uint usdPart, uint seedBurned, bool unwound) {
        if (perShare == 0) return (0, 0, false);                        // fully depegged → nothing deliverable
        uint mature = IERC20(r.quid).balanceOf(r.source);
        { uint imm = IBasketTurn(r.quid).immatureBalanceOf(r.source); mature = mature > imm ? mature - imm : 0; }
        uint wantUsd = SoladyMath.fullMulDiv(Math.min(r.amount, mature), perShare, WAD);   // value the holder wants out
        uint delivered = wantUsd < freeUsd ? wantUsd : freeUsd;         // pay from free vault stables first
        if (wantUsd > freeUsd) {
            uint need = wantUsd - freeUsd;
            uint freed = IQuid(r.v4).unwindForRedeem(need);      // PLAIN band first; frees the exact USD asked
            // §G.6: if the plain unwind came up SHORT, the residual is levered backing being unbanded — de-lever
            // the in-band ETH levers (value-neutral, LTV-improving) to free it. Invariant (nothing leaves the band
            // without de-levering) holds; balanced unband ⇒ NO JIT/skew. No-op when there are no open levers.
            if (freed < need) freed += _deleverBookForRedeem(r.core, need - freed);
            delivered = freeUsd + (freed < need ? freed : need);        // = wantUsd unless still short (retained deferred)
            unwound = true;
        }
        uint burned;
        (burned, seedBurned) = IBasketTurn(r.quid).turn(r.source, SoladyMath.fullMulDiv(delivered, WAD, perShare));
        usdPart = SoladyMath.fullMulDiv(burned, perShare, WAD);              // == delivered (turn burns mature-only, <= ask)
    }

    /// @dev §G.6 redeem shortfall sweep — the REACTIVE half of the ONE de-lever mechanism (shared with swap-out;
    ///      the keeper's `cascadeDelever` is the proactive half). After the plain-band unwind comes up short, the
    ///      residual IS levered backing being unbanded; the LevManager's `deleverBook` frees `usdWanted` (USD 1e18)
    ///      by de-levering the open in-band ETH levers value-neutrally (LTV PRESERVED, capped per-LP at #67
    ///      deliverableDollars) into THIS Aux (address(this) == the redeem sink; the freed stable is picked up by
    ///      `_dispatchTake`). De-levering also shrinks `committed` (net-equity ↓), relaxing the backing gate. The
    ///      book-walk + fault-tolerance live in the manager (it owns the book). Delegatecall ⇒ address(this) == Aux.
    function _deleverBookForRedeem(address core, uint usdWanted) private returns (uint) {
        address vault = ICore(core).btcVault();
        if (vault == address(0)) return 0;
        // ETH lev manager lives on the ETH-VENUE contract; reach it the way QuidLib does.
        address mgr = ILevHost(IAux(address(this)).ethVenue()).LEV_MANAGER();
        if (mgr == address(0)) return 0;
        return ILevSweep(mgr).deleverBook(usdWanted, address(this), 0);
    }

    /// @dev Final take leg of redeemAsBody, extracted to its own frame. Reuses the pre-burn deposit fetch
    ///      (amts, yW) ONLY when no seed was burned AND no unwind ran: then `tranche` (which get_deposits nets
    ///      out of the per-stable balances) is unchanged, so the cached arrays equal a fresh fetch.
    function _dispatchTake(RedeemArgs memory r, uint usdPart, uint seedBurned,
        uint[15] memory amts, uint[15] memory yW, bool fresh) private {
        // Reuse the pre-burn (amts, yW) ONLY when no seed burned AND no unwind. A seed redemption shifts
        // `tranche`; an unwind is a COUNTER shrink (POOLED_USD ↓, relaxing the committed<=backing gate so
        // take can withdraw the already-in-vault stables) — the pre-fetch vectors don't reflect the relaxed gate,
        // so re-fetch to be safe. (No real stables move on unwind; deposits[14] is unchanged.)
        if (seedBurned == 0 && !fresh) {
            IAux(address(this)).takeWith(r.recipient, usdPart, r.quid, 0, r.preferred, amts, yW);
        } else {
            IAux(address(this)).take(r.recipient, usdPart, r.quid, seedBurned, r.preferred);
        }
    }

    /// @notice Body of Aux._backingCore (delegatecall, address(this)==Aux).
    /// Reads backing vs commitment; up to two V4 repacks to heal an
    /// over-commit. Returns current values regardless.
    function backingCoreBody(address core, address btcCore, address v4, address btcVault)
        external returns (uint committedSum, uint totalLiquid) {
        // Terminal solvency gate counts standing holdings at PAR (drain side — intentional mint/drain asymmetry;
        // the issuance side haircuts depeg to block over-mint). See DepegBackingProbe / SwapLib.swapToBody.
        (uint[15] memory deposits,,,) = IAux(address(this)).get_deposits();
        totalLiquid = deposits[14];
        committedSum = ICore(core).committedUsd18();
        if (committedSum <= totalLiquid) return (committedSum, totalLiquid);
        // §ISBTC-SPLIT — THIS COMPARED A VALUE TO ITSELF. It was `POOLED_USD_ETH >= POOLED_USD_BTC`
        // before the fields collapsed to one per instance, and the collapse rewrote both sides to the
        // same expression -- so `ethFirst` was unconditionally true and the "repack the LARGER pool
        // first" intent was dead. Not a solvency break (both pools repack if the first is not enough,
        // and `committedUsd18` is the shared sum either way), but the ordering it chose was never the
        // one it claimed. Same shape as `token1isVol = token1isVol`: a rename/collapse producing an
        // expression the compiler cannot object to. Now it reads the two INSTANCES.
        bool ethFirst = ICore(core).POOLED_USD() >= ICore(btcCore).POOLED_USD();
        // ETH pool repack → Quid (v4); BTC pool repack → BtcVault (regrouped).
        IBandManager(ethFirst ? v4 : btcVault).repack();   // repack the LARGER pool first
        committedSum = ICore(core).committedUsd18();
        if (committedSum > totalLiquid) {
            IBandManager(ethFirst ? btcVault : v4).repack();   // then the other one
            committedSum = ICore(core).committedUsd18();
        }
    }

    // ⛔ `_repackPool` IS DELETED — it wrapped ONE external call and added nothing.
    // Its own docstring recorded why it had stopped doing work: it used to ROUTE by boolean, and
    // "a boolean plus both addresses was a dispatch the caller had already made". Once the target
    // became the band address itself, the body was `IBandManager(band).repack()` and the wrapper
    // was a second name for `.repack()`. Both call sites now say that directly, and the choice of
    // WHICH band stays where it was always made — in the `ethFirst` ternary at the call site.

    /// @notice All-or-nothing deploy-finalize linkage assert (delegatecall from
    ///         Aux.finalize, so address(this)==Aux). Reverts unless every
    ///         external linkage EQUALS Aux's owner-set view — catching a
    ///         front-runner's malicious-but-non-zero pin in an ungated setter.
    function assertFullyWired(address q, address ethVenue, address btcChannels,
        address core, address v4) external view {
        // ETH-VENUE CUSTODY AND THE BTC BAND MANAGER ARE DIFFERENT CONTRACTS since the venue carve.
        // This assert used to take one address for both because they used to BE one address; each
        // fact is now checked against the contract that actually holds it. `btcVault` is derived
        // from Core rather than passed, so a caller cannot supply a mismatched pair.
        address btcVault = ICore(core).btcVault();
        require(q != address(0),                                    "wire:quid");
        require(ethVenue != address(0),                             "wire:ethv");
        require(btcVault != address(0),                              "wire:vault");
        // §ETHVENUE-FOLD — was `IQuid(v4).EV() == ethVenue`, checking that Quid's venue pointer and
        // Aux's agreed. Quid IS the venue now, so the pointer is gone; what still needs asserting is
        // that Aux's pin names the band manager and not some other address.
        require(ethVenue == v4,                                     "wire:band");
        require(btcChannels != address(0)
             && IWiredVault(btcVault).btcChannels() == btcChannels,  "wire:chan");  // Vault→Channels
        require(IWiredBasket(q).AUX() == address(this),             "wire:bAux");  // Basket→Aux
        require(IWiredBasket(q).BTC_VAULT() == btcVault,            "wire:bVlt");  // Basket→Vault
    }

    /// @notice Body of Aux.redeemableAmount (delegatecall, address(this)==Aux).
    function redeemableBody(address core) external returns (uint) {
        (uint total,) = IAux(address(this)).get_metrics(false);
        { uint dl = _depegLoss(); total = total > dl ? total - dl : 0; }
        // Cap at DELIVERABLE backing (Σ max(0, convertToAssets −
        // maxWithdraw) per 4626) so QU!D is never quoted against a frozen-but-solvent
        // vault's undeliverable slice; that portion defers until the vault is liquid again.
        { (uint il, address worst, uint worstBps) = _illiquidLoss();
          total = total > il ? total - il : 0;
          if (worst != address(0)) IAux(address(this)).flagIlliquidSelf(worst, worstBps < LIQ_TOL_BPS); }
        // NB: this quotes AGGREGATE deliverable dollars (a capacity view). The per-QD `min(par, share)` cap lives
        // in the money path (redeemAsBody + SwapLib); `total` is a conservative upper bound and never under-reports.
        // STABLES-ONLY with the Option-4 unwind: QU!D's dollars deployed as the ETH band's
        // USD side are freeable on redemption (Quid.unwindForRedeem), so the redeemable is ALL
        // haircut stables EXCEPT what is committed to the BTC band (an ETH-side redemption cannot
        // unwind the BTC band). Conservative: subtract POOLED_USD (>= BTC-band equity; ignores
        // the debt that would only shrink it), so the quote never over-reports.
        uint btcCommitted = ICore(core).POOLED_USD() * 1e12;
        return total > btcCommitted ? total - btcCommitted : 0;
    }

    // (ethToStableFallback removed -- redemption is stables-only; the committed dollars
    //  are freed by unwinding the band, Quid.unwindForRedeem, not by selling an LP's venue ETH.)

    // ─── CRE vault-health watcher bodies (extracted from Aux) ────────────
    // DELEGATECALL'd — address(this)==Aux, so every IERC4626/IAaveV4Spoke
    // call runs against Aux's real positions. The ACCESS-CONTROL GATES stay
    // in the Aux wrappers (setVaultHealth/pokeVaultHealth/evacuate); these bodies
    // carry NEITHER the gate NOR the nonReentrant lock. Caller storage is
    // passed as `mapping(...) storage` reference params (the slot travels).

    uint public constant EVAC_DWELL = 30 minutes;
    uint16 internal constant LIQ_TOL_BPS = 5000; // need ≥50% of position withdrawable

    /// @notice Immutables/consts the vault-health bodies reference — the
    ///         delegatecalled library can't read Aux's immutables, so the
    ///         wrapper passes them in.
    struct VaultHealthCfg {
        address ethVenue;   // holder of the AAVE WETH position (post-carve)
    }

    /// @notice Per-VENUE health state. BINARY (blocked) + the evac clock —
    ///         mirroring the depeg model: an incident BLOCKS the vault (valued
    ///         at maxWithdraw in bandETH/get_deposits, no new deposits routed)
    ///         and auto-RECOVERS when liquid again. The former graded
    ///         `haircutBps` was a vestige of the removed CRE onReport path
    ///         (owner-only setter, owner renounced at finalize → always 0 in
    ///         production); dropped (frees bytecode, removes dead branches).
    ///   • blocked    → _supply stops routing NEW deposits; valued at maxWithdraw.
    ///   • flaggedAt  → when first flagged for evac (the EVAC_DWELL clock).
    struct VaultHealth {
        bool   blocked;
        uint40 flaggedAt;
    }

    function setVaultHealthBody(
        address vault, bool blocked,
        mapping(address => VaultHealth) storage vaultHealth
    ) internal {
        VaultHealth storage vh = vaultHealth[vault];
        vh.blocked = blocked;
        // Recovery clears the evac clock so a future incident dwells afresh.
        if (!blocked) vh.flaggedAt = 0;
    }

    /// @notice PERMISSIONLESS on-chain vault-health trigger body — the
    ///         trust-minimized on-chain health check (reads only ERC4626 ground
    ///         truth). It can only TIGHTEN (block + dwell→evacuate when
    ///         liquidity is genuinely impaired); it NEVER unblocks or haircuts
    ///         except the auto-unblock of a vault THIS path itself flagged.
    function pokeVaultHealthBody(
        address vault, VaultHealthCfg memory cfg,
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => address) storage tokens
    ) external {
        // Every vault reaching here is a basket STABLE vault held by Aux (== address(this)).
        uint reported = IERC4626(vault).convertToAssets(IERC4626(vault).balanceOf(address(this)));
        // ONE `withdrawable` definition (see the haircut above). This is the PERMISSIONLESS poke: a
        // Morpho-V2 stable vault reads 0 liquid on the raw max-view, so `liqBps` was 0 and ANY caller
        // could block-then-evacuate a perfectly healthy vault holding real TVL.
        uint liquid = QuidLib._withdrawableOf(vault, address(this));
        if (reported == 0) return;                       // empty position → no-op
        uint liqBps = SoladyMath.fullMulDiv(liquid, 10000, reported);
        if (liqBps >= LIQ_TOL_BPS) {
            // NON-BLOCKING recovery: auto-unblock a vault THIS path blocked once it
            // is liquid again — so a transient dip doesn't strand the vault waiting
            // on owner intervention. `vaultFlaggedAt != 0` means the poke/dwell path
            // flagged it; an OWNER/CRE block via setVaultHealth leaves flaggedAt==0
            // and is NEVER auto-unblocked here (off-chain reasons are respected).
            if (vaultHealth[vault].blocked && vaultHealth[vault].flaggedAt != 0)
                setVaultHealthBody(vault, false, vaultHealth); // clears flaggedAt too
            return;
        }
        // Illiquid-but-solvent: block + evacuate the withdrawable part (no haircut),
        // gated by the same EVAC_DWELL as pokeVaultHealth (first poke flags, a later poke
        // ≥30 min on drains) so a momentary maxWithdraw dip can't trigger a drain.
        setVaultHealthBody(vault, true, vaultHealth);
        uint40 flagged = vaultHealth[vault].flaggedAt;
        if (flagged == 0) vaultHealth[vault].flaggedAt = uint40(block.timestamp);
        else if (block.timestamp - flagged >= EVAC_DWELL)
            evacuateBody(vault, cfg, vaultHealth, vaultsOf, tokens);
    }

    /// @notice §E197 — DETECTION-ONLY half of the poke, driven by organic traffic. Blocks the vault and
    ///         STARTS the `EVAC_DWELL` clock; it never evacuates and never unblocks. Evacuation stays on
    ///         the deliberate `pokeVaultHealth`/`evacuate` calls, so a redeem can never drain vaults
    ///         mid-call. Idempotent: a vault already flagged keeps its ORIGINAL `flaggedAt`, so repeated
    ///         traffic cannot keep resetting the clock and postponing the evacuation forever.
    /// @dev ⚠️ SYMMETRIC ON PURPOSE, AND MY FIRST VERSION WAS NOT. Blocking on traffic while leaving the
    ///      RELEASE to `pokeVaultHealth` reads as conservative and is a LIVENESS BUG: nothing calls the
    ///      poke (§E152-nerve), so a vault that dipped below tolerance for one block would stay blocked
    ///      forever — new deposits permanently unrouted — on a transient reading. If traffic is trusted to
    ///      tighten it must be trusted to release. A ONE-WAY GUARD IS NOT THE SAFE HALF OF A TWO-WAY ONE;
    ///      the same shape as `computeMetrics`' old floor-to-zero arm, which could tighten but never
    ///      recover and so turned a mis-measurement into permanent suppression (§E155).
    ///      The release reuses the poke's OWN guard: only a vault THIS path flagged (`flaggedAt != 0`) is
    ///      auto-released, so an owner block via `setVaultHealth` (which leaves `flaggedAt == 0`) is never
    ///      overridden. Blocking stays idempotent, so repeated traffic cannot reset the dwell clock.
    /// @notice §E198 — PER-RESERVE health key for an Aave member. The spoke is ONE address registered
    ///         in MANY stables' vault sets (`ChannelLib.setVaultBody:441` pushes `cfg.aaveSpoke`, and
    ///         `DeployL1_s:404-405` does it for USDC AND USDT), so keying health by the member address
    ///         gives every aave-routed reserve a SHARED flag: blocking one blocks all, and a single
    ///         impaired reserve cannot be expressed at all. A 4626 leg gets per-position granularity for
    ///         free because each curator vault has its own address; this restores the same for Aave.
    ///         Deterministic and collision-free against real addresses, and no storage-layout change —
    ///         it is just a different key into the existing `vaultHealth` mapping.
    function aaveHealthKey(address spoke, uint reserveId) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(spoke, reserveId)))));
    }

    function flagIlliquidBody(address vault, bool illiquid,
        mapping(address => VaultHealth) storage vaultHealth) external {
        if (illiquid) {
            setVaultHealthBody(vault, true, vaultHealth);
            if (vaultHealth[vault].flaggedAt == 0) vaultHealth[vault].flaggedAt = uint40(block.timestamp);
        } else if (vaultHealth[vault].blocked && vaultHealth[vault].flaggedAt != 0) {
            setVaultHealthBody(vault, false, vaultHealth);   // clears flaggedAt too
        }
    }

    function evacuateBody(
        address vault, VaultHealthCfg memory /*cfg*/,   // §V4-RESIDUE 2026-08-18: unread. Name commented
        // rather than removed: `public` library function, so dropping it changes the SELECTOR.
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => address) storage tokens
    ) public {
        vaultHealth[vault].blocked = true; // block first → spread skips it
        // Basket STABLE vaults only: redeem the position and spread it across that stable's
        // healthy vaults. A frozen vault stays blocked and haircut'd; the loss is socialized.
        uint sh = IERC4626(vault).balanceOf(address(this));
        if (sh == 0) return;
        address stable = tokens[vault];
        if (stable == address(0)) return;
        try IERC4626(vault).redeem(sh, address(this), address(this))
            returns (uint got) {
            if (got > 0) spreadEquallyBody(stable, got, vaultHealth, vaultsOf);
        } catch { /* frozen: stays blocked + haircut'd, loss socialized */ }
    }

    /// @dev Deposit `amount` of `stable` EQUALLY across its unblocked vaults
    ///      (the last one absorbs the rounding remainder so nothing is lost).
    ///      If no healthy vault remains, funds stay at Aux (uninvested) until a
    ///      vault is unblocked/added — surfaces the all-blocked state rather
    ///      than forcing a deposit into an unhealthy venue.
    function spreadEquallyBody(
        address stable, uint amount,
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf
    ) internal {
        address[] memory vs = vaultsOf[stable];
        address spoke = IAux(address(this)).AAVE_SPOKE();
        uint n;
        // §E198 — the AAVE member is EXCLUDED from the spread, not merely health-checked. It is not a
        // 4626, so the `deposit(assets, receiver)` below does not exist on it: with the spoke unblocked
        // this loop would have called it and REVERTED THE WHOLE EVACUATION — the one path that exists to
        // rescue a failing venue. Its health is keyed per-reserve elsewhere (`aaveHealthKey`); here it is
        // simply not a destination.
        for (uint j; j < vs.length; j++)
            if (vs[j] != spoke && !vaultHealth[vs[j]].blocked) n++;
        if (n == 0) return;
        uint each = amount / n;
        uint rem = amount;
        for (uint j; j < vs.length; j++) {
            if (vs[j] == spoke || vaultHealth[vs[j]].blocked) continue;
            uint a = (--n == 0) ? rem : each; // last healthy vault takes remainder
            rem -= a;
            if (a > 0) IERC4626(vs[j]).deposit(a, address(this));
        }
    }
}

/// @notice Aux's self-gated surface that BasketLib.takeBody calls back into.
