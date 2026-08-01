// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Types} from "./Types.sol";
import {FeeLib} from "./FeeLib.sol";
import {ShareMath} from "./ShareMath.sol";
import {IAaveV4Spoke} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";
import {VaultLib} from "./VaultLib.sol";



/// AAVE-v4 GHO spoke (vault-health evac haven). Mirrors Aux.IAaveV4Spoke.
/// The two reserve-level reads are asset-denominated (verified live: GHO reserve
/// supplied/debt in 1e18); available cash = supplied − debt.
/// EthVenue — the ETH-venue custody (Galaxy/AAVE WETH). vault-health STATE
/// stays Aux-owned, but the Galaxy WETH position is custodied on EthVenue after
/// the venue carve, so the evac/poke Galaxy leg reads + drains via this handle.
interface IVogueRepack { function repack(bool isBTC) external; }
interface IVogueUnwind { function unwindForRedeem(uint usdWanted) external returns (uint usdFreed); }
// §G.6 redeem shortfall sweep: the ETH LevManager's ONE reactive de-lever entry (SHARED with swap-out). Reached
// via core→Vault (IWiredCore.btcVault → IWiredVault.LEV_MANAGER, both existing). `deleverBook` frees levered
// net-equity into the sink (= this Aux) value-neutrally and returns the stable routed there.
interface ILevSweepB { function deleverBook(uint256 usdWanted, address sink, uint256 minOut) external returns (uint256 freed); }

// Deploy-finalize linkage cross-checks (BasketLib.assertFullyWired).
interface IWiredVogue  { function EV() external view returns (address); }
interface IWiredCore   { function btcVault() external view returns (address); }
interface IWiredVault  { function btcChannels() external view returns (address);
                         function ROVER() external view returns (address);
                         function LEV_MANAGER() external view returns (address); }  // §G.6: reach the ETH LevManager
interface IWiredRover  { function AUX() external view returns (address); }
interface IWiredBasket { function AUX() external view returns (address);
                         function BTC_VAULT() external view returns (address); }
interface IBasketTurn {
    function turn(address from, uint value) external returns (uint sent, uint seedBurned);
    function matureSupply() external view returns (uint);
    function immatureBalanceOf(address who) external view returns (uint);
}

interface IVogueCore {
    function POOLED_ETH() external view returns (uint);
    function POOLED_BTC() external view returns (uint);
    function POOLED_USD_ETH() external view returns (uint);
    function POOLED_USD_BTC() external view returns (uint);
    function committedUsd18() external view returns (uint);
    function token1isETH() external view returns (bool);
    function token1isBTC() external view returns (bool);
    function swap(bool isBTC, uint160 sqrtPriceX96, address sender,
        bool forOne, address token, uint amount) external returns (uint);
}

library BasketLib {
    uint public constant WAD = 1e18;
    uint public constant MONTH = 2420000;

    struct Metrics {
        uint total;
        uint last;
        uint yield;
        uint trackingStart;
        uint yieldAccum;
    }

    function computeMetrics(Metrics memory stats,
        uint elapsed, uint raw, uint yieldWeighted,
        uint tvl) internal view returns (Metrics memory) {

        if (stats.trackingStart > 0 && stats.last > 0)
            stats.yieldAccum += stats.yield * elapsed;

        else if (stats.trackingStart == 0)
            stats.trackingStart = block.timestamp;

        // Yield-rate update with three cases:
        //   raw == 0:                 nothing to compute; keep prior
        //     (this is the "empty basket" case — no deposits, no
        //     meaningful yield rate; preserving prior is the right
        //     no-op rather than crashing on divide-by-zero)
        //   yieldWeighted >= raw:     positive yield, compute rate
        //   yieldWeighted < raw:      zero yield for this period
        //     (depeg-discounted contribution dragged yieldWeighted
        //     below raw, OR a vault is genuinely losing money. Either
        //     way the SPOT yield rate is non-positive — since `yield`
        //     is uint we floor at 0 instead of keeping a stale prior
        //     value. yieldAccum then accrues at 0 for this window, so
        //     the time-weighted average decays toward zero in
        //     proportion to how long the non-positive period lasts.
        //     That is just the ordinary behavior of a time-average —
        //     NOT a special "depression" regime; there is no extra
        //     mechanism, the decay falls straight out of accruing 0.
        //     Returning 0 instead of stale removes the indeterminacy in
        //     heavily-discounted regimes where the depeg signal would
        //     otherwise be lost.)
        if (raw == 0) {
            // keep stats.yield as is
        } else if (yieldWeighted >= raw) {
            stats.yield = FullMath.mulDiv(WAD, yieldWeighted, raw) - WAD;
        } else {
            stats.yield = 0;
        }
        stats.total = tvl; stats.last = block.timestamp;

        return stats;
    }

    function get_deposits(address aux, address[] memory stables,
        mapping(address => Holding) storage storedHoldings,
        mapping(address => uint) storage tranche) external
        returns (uint[15] memory amounts, uint[15] memory yieldW, uint depegLoss) {
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
                balance -= cap;
                yieldWeighted -= Math.min(yieldWeighted, cap);
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
                uint loss = FullMath.mulDiv(balance, lossFrac, 10000);
                yieldWeighted = yieldWeighted > loss ? yieldWeighted - loss : 0;
                depegLoss += loss; // SAME per-stable loss redemption applies; returned
                                   // so _depegLoss needn't re-loop the feeds (2nd pass).
            }
            amounts[i + 1] = balance;
            amounts[14] += balance;
            amounts[0] += yieldWeighted;
            yieldW[i + 1] = yieldWeighted;
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
    struct Holding { uint balance; uint yieldWeighted; }

    /// @dev Recompute ONE stable's cached vault-sum and store it. Shared core.
    function _refreshOne(address stable,
        mapping(address => Holding) storage sh) internal {
        address aux = address(this);
        bool isAave = (stable == IAux(aux).GHO() || stable == IAux(aux).USDG());
        (uint b, uint yw) = _valueStable(stable, isAave, IAux(aux).AAVE_SPOKE());
        sh[stable] = Holding(b, yw);
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
        return shares > 0 ? FullMath.mulDiv(assets, assets, shares) : assets;
    }

    function _valueStable(address stable, bool isAave, address aaveSpoke)
        internal returns (uint balance, uint yieldWeighted) {
        address aux = address(this);
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
                yieldWeighted += FullMath.mulDiv(b, b, shares);
            }
        }
        if (balance == 0) return (0, 0);
        // Decimal scaling: detect 6-dec stables via token decimals(). Avoids the
        // prior `i < 3 ? 1e12 : 1` slot-hardcode which broke when USDG (6-dec)
        // joined at slot 5.
        uint dec = IERC20(stable).decimals();
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

    // sqrt(deficit) × avgYield / 4
    function seedFee(uint usd,
        uint trancheTotal, uint target,
        uint avgYield) internal pure returns (uint) {
        if (target == 0 || trancheTotal >= target) return 0;
        uint deficit = FullMath.mulDiv(
        target - trancheTotal, WAD, target);
        uint sqrtDef = Math.sqrt(deficit * WAD);
        if (sqrtDef == 0 || avgYield == 0) return 0;
        uint fee = Math.min(FullMath.mulDiv(FullMath.mulDiv(
            usd, sqrtDef, WAD), avgYield, WAD * 4),
            target - trancheTotal);
        return Math.min(fee,
            FullMath.mulDiv(usd, avgYield, WAD * 12));
    }

    /// @param amount Amount being deposited
    /// @return cut Fee amount to deduct from deposit
    /// @notice Deposit fee driven by weighted median vote (K).
    ///         Symmetric with withdrawal: stressed (high haircut)
    ///         → higher fee → reserves build faster.
    ///         K=0 → 900bps (9%), K=32 → 100bps (1%)

    /// @notice ETH price from sqrtPriceX96
    /// @param sqrtPriceX96 Square root price
    /// @param token0isUSD Whether token0 is USD
    /// @return price ETH price in USD 1e18
    function getPrice(uint160 sqrtPriceX96, bool token0isUSD)
        public pure returns (uint price) {
        uint casted = uint(sqrtPriceX96);
        uint ratioX128 = FullMath.mulDiv(
               casted, casted, 1 << 64);

        if (token0isUSD) {
          price = FullMath.mulDiv(1 << 128,
              WAD * 1e12, ratioX128);
        } else {
          price = FullMath.mulDiv(ratioX128,
              WAD * 1e12, 1 << 128);
        }
    }

    function ticksToPrice(int56 tickCum0,
        int56 tickCum1, uint32 period, bool token0isUSD) external
        pure returns (uint price) { int56 delta = tickCum1 - tickCum0;
        int24 averageTick = int24(delta / int56(uint56(period)));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(averageTick);
        price = getPrice(sqrtPriceX96, token0isUSD);
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
            ? FullMath.mulDiv(amount * 1e12, 1e18, price)   // USDC → vol
            : FullMath.mulDiv(amount, price, 1e18) / 1e12;  // vol → USDC
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
                // pointed at the Vogue contract, which would have
                // orphaned shares there with no Vogue-side redemption
                // path — see takeETH / _sendETH, which draw from Aux's
                // wethVault position via vogueOp, never from Vogue's
                // own balance. Routing to Aux keeps every supply
                // symmetric: Aux is the sole share-owner, vogueETH()
                // and _syncVenue see the full position.)
                pooled = IERC4626(ctx.vault).convertToAssets(
                       IERC4626(ctx.vault).deposit(pooled, address(this)));

                poolSupplied = pooled;
            }
            out = IVogueCore(ctx.core).swap(p.isBTC, p.sqrtPriceX96,
                      p.recipient, p.zeroForOne, p.token, pooled);
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
        uint avgYield, bool isSeed) external pure
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
        uint yield = isSeed ? WAD : avgYield;
        normalized += FullMath.mulDiv(normalized * yield,
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
        return _takeCore(a, amounts, yieldW);
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
        return _takeCore(a, amounts, yieldW);
    }

    /// @dev Shared body of takeBody / takeBodyWith. `amounts`/`yieldW` are the basket
    ///      deposit vectors (from get_deposits); the entrypoints differ only in whether
    ///      those were just-fetched here or threaded in by a caller that already had them.
    function _takeCore(TakeArgs memory a, uint[15] memory amounts, uint[15] memory yieldW)
        private returns (uint sent) {
        IAux aux = IAux(address(this));
        FeeLib.FeeCtx memory fc = FeeLib.FeeCtx(a.stables, a.linkAddr);
        address skip;
        if (a.token != a.quid) {
            // SWAP take: the named stable IS the preferred leg (unchanged).
            skip = a.token;
            require(a.index > 0 && a.index <= a.stables.length, "unknown-stable");
            bool done;
            (sent, a.amount, done) = _takePreferred(aux, a.who, a.token, a.amount, a.seed, amounts, yieldW, fc);
            if (done) return sent;
        } else if (a.preferred != address(0) && a.seed == 0) {
            // TARGETED REDEEM: shed the chosen stable FIRST (cherry-pick concentration
            // fee rides on this leg via calcNeeded; the redemption baseRate already
            // applies — set by the Aux wrapper since token==quid). The unsatisfied
            // remainder falls through to the pro-rata leg below (skip=preferred).
            // Seed-bearing redemptions (seed>0, tranche/seed tranche) are excluded:
            // they keep the pro-rata seed un-tip distribution unchanged rather than
            // routing the whole seed onto one stable (preferred is ignored, not an error
            // — the Aux entry already validated it).
            skip = a.preferred;
            require(a.prefIndex > 0 && a.prefIndex <= a.stables.length, "unknown-stable");
            bool done;
            // UNIT BOUNDARY (§A.50). `_takePreferred` asks for the withdrawal in the token's NATIVE
            // units — it hands `needed` straight to withdrawSelf. A redemption's `a.amount` is USD
            // 1e18 (it is a share of amounts[14]); the pro-rata leg below divides by the same power
            // of ten before ITS withdrawSelf, which is why it never had this bug. Without the
            // conversion a 6-decimal stable was asked for 1e12x the intended draw, the leg emptied
            // whatever the venue held, and declining pro-rata PAID the redeemer instead of costing
            // them. The swap branch above already hands over native units, so the conversion belongs
            // at this call site rather than inside the shared helper.
            (sent, a.amount, done) = _takePreferred(aux, a.who, a.preferred,
                scaleTokenAmount(a.amount, a.preferred, false), a.seed, amounts, yieldW, fc);
            if (done) return sent;
        }
        if (amounts[14] == 0 || a.amount == 0) { _finalBacking(aux, a.softBacking); return sent; }
        if (a.seed == 0) a.amount = Math.min(amounts[14], a.amount);
        sent += _takeProRata(aux, a.who, a.amount, a.seed, skip, amounts, fc);
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
    function _takeProRata(
        IAux aux, address who, uint amount, uint seed, address skip,
        uint[15] memory amounts, FeeLib.FeeCtx memory fc
    ) private returns (uint sent) {
        for (uint i = 1; i <= fc.stables.length; i++) {
            address token = fc.stables[i - 1]; if (token == skip) continue;
            amounts[i] = FeeLib.allocate(token,
                             amount, amounts[i], amounts[14], fc);
            if (seed > 0) aux.tipSelf(FullMath.mulDiv(amounts[i], seed, amount), token, -1);
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
    ///         WETH from Galaxy via the self-gated withdraw, then opens a
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
    function illiquidLoss() external view returns (uint) { return _illiquidLoss(); }

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
    function _illiquidLoss() internal view returns (uint loss) {
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
                    continue;
                }
                try IERC4626(v).balanceOf(aux) returns (uint sh) {
                    if (sh == 0) continue;
                    uint solv;
                    try IERC4626(v).convertToAssets(sh) returns (uint a) { solv = a; }
                    catch { continue; }
                    // ONE definition, shared with the ETH ladder (VaultLib._withdrawableOf). MEASURED
                    // 2026-07-26: 6 of our 8 registered stable vaults are Morpho-V2 (sky/wintermute/
                    // rockaway USDC, sky USDT, gauntlet USDC+USDT) holding ~124M of ~126M stable TVL.
                    // Their max-views are IDLE-ONLY and report 0 against a fully withdrawable position,
                    // so the raw read treated `solv` as ENTIRELY undeliverable and haircut the whole
                    // position here — and this shortfall feeds the REDEMPTION haircut. Still returns 0
                    // for an unreadable view (conservative: over-haircut, never over-promise).
                    uint deliv = VaultLib._withdrawableOf(v, aux);
                    if (solv > deliv) shortfall += solv - deliv;
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
    function _redeemQuote(RedeemArgs memory r, uint raw, uint yw, uint depegLoss)
        private returns (uint perShare, uint freeUsd) {
        (uint solvent,) = IAux(address(this)).get_metricsWith(raw, yw);
        solvent = solvent > depegLoss ? solvent - depegLoss : 0;
        uint mature = IBasketTurn(r.quid).matureSupply();
        // ONE valuation for redeem AND swap (no swap↔redeem arb): per-share = qdShareValue of a single share.
        // Byte-equivalent to the old `min(WAD, solvent·WAD/mature)` incl. the mature==0→WAD guard. #U1.
        perShare = ShareMath.qdShareValue(WAD, solvent, mature);
        uint il = _illiquidLoss();
        uint committed = IVogueCore(r.core).committedUsd18();
        uint locked = il > committed ? il : committed;
        freeUsd = solvent > locked ? solvent - locked : 0;
    }

    function redeemAsBody(RedeemArgs memory r) external {
        // DEDUP: fetch the basket deposit vectors ONCE here (pre-burn) for the depeg haircut + the take leg.
        (uint[15] memory amts, uint[15] memory yW,, uint depegLoss) =
            IAux(address(this)).get_deposits();
        (uint perShare, uint freeUsd) = _redeemQuote(r, amts[14], amts[0], depegLoss);
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
        uint wantUsd = FullMath.mulDiv(Math.min(r.amount, mature), perShare, WAD);   // value the holder wants out
        uint delivered = wantUsd < freeUsd ? wantUsd : freeUsd;         // pay from free vault stables first
        if (wantUsd > freeUsd) {
            uint need = wantUsd - freeUsd;
            uint freed = IVogueUnwind(r.v4).unwindForRedeem(need);      // PLAIN band first; frees the exact USD asked
            // §G.6: if the plain unwind came up SHORT, the residual is levered backing being unbanded — de-lever
            // the in-band ETH levers (value-neutral, LTV-improving) to free it. Invariant (nothing leaves the band
            // without de-levering) holds; balanced unband ⇒ NO JIT/skew. No-op when there are no open levers.
            if (freed < need) freed += _deleverBookForRedeem(r.core, need - freed);
            delivered = freeUsd + (freed < need ? freed : need);        // = wantUsd unless still short (retained deferred)
            unwound = true;
        }
        uint burned;
        (burned, seedBurned) = IBasketTurn(r.quid).turn(r.source, FullMath.mulDiv(delivered, WAD, perShare));
        usdPart = FullMath.mulDiv(burned, perShare, WAD);              // == delivered (turn burns mature-only, <= ask)
    }

    /// @dev §G.6 redeem shortfall sweep — the REACTIVE half of the ONE de-lever mechanism (shared with swap-out;
    ///      the keeper's `cascadeDelever` is the proactive half). After the plain-band unwind comes up short, the
    ///      residual IS levered backing being unbanded; the LevManager's `deleverBook` frees `usdWanted` (USD 1e18)
    ///      by de-levering the open in-band ETH levers value-neutrally (LTV PRESERVED, capped per-LP at #67
    ///      deliverableDollars) into THIS Aux (address(this) == the redeem sink; the freed stable is picked up by
    ///      `_dispatchTake`). De-levering also shrinks `committed` (net-equity ↓), relaxing the backing gate. The
    ///      book-walk + fault-tolerance live in the manager (it owns the book). Delegatecall ⇒ address(this) == Aux.
    function _deleverBookForRedeem(address core, uint usdWanted) private returns (uint) {
        address vault = IWiredCore(core).btcVault();
        if (vault == address(0)) return 0;
        address mgr = IWiredVault(vault).LEV_MANAGER();
        if (mgr == address(0)) return 0;
        return ILevSweepB(mgr).deleverBook(usdWanted, address(this), 0);
    }

    /// @dev Final take leg of redeemAsBody, extracted to its own frame. Reuses the pre-burn deposit fetch
    ///      (amts, yW) ONLY when no seed was burned AND no unwind ran: then `tranche` (which get_deposits nets
    ///      out of the per-stable balances) is unchanged, so the cached arrays equal a fresh fetch.
    function _dispatchTake(RedeemArgs memory r, uint usdPart, uint seedBurned,
        uint[15] memory amts, uint[15] memory yW, bool fresh) private {
        // Reuse the pre-burn (amts, yW) ONLY when no seed burned AND no unwind. A seed redemption shifts
        // `tranche`; an unwind is a COUNTER shrink (POOLED_USD_ETH ↓, relaxing the committed<=backing gate so
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
    function backingCoreBody(address core, address v4, address btcVault)
        external returns (uint committedSum, uint totalLiquid) {
        // Terminal solvency gate counts standing holdings at PAR (drain side — intentional mint/drain asymmetry;
        // the issuance side haircuts depeg to block over-mint). See DepegBackingProbe / SwapLib.swapToBody.
        (uint[15] memory deposits,,,) = IAux(address(this)).get_deposits();
        totalLiquid = deposits[14];
        committedSum = IVogueCore(core).committedUsd18();
        if (committedSum <= totalLiquid) return (committedSum, totalLiquid);
        bool ethFirst = IVogueCore(core).POOLED_USD_ETH() >= IVogueCore(core).POOLED_USD_BTC();
        // ETH pool repack → Vogue (v4); BTC pool repack → BtcVault (regrouped).
        _repackPool(!ethFirst, v4, btcVault);
        committedSum = IVogueCore(core).committedUsd18();
        if (committedSum > totalLiquid) {
            _repackPool(ethFirst, v4, btcVault);
            committedSum = IVogueCore(core).committedUsd18();
        }
    }

    /// @dev Route a pool repack to its owning contract: BTC → BtcVault,
    ///      ETH → Vogue. (The BTC LP side was regrouped out of Vogue.)
    function _repackPool(bool isBTC, address v4, address btcVault) private {
        if (isBTC) IVogueRepack(btcVault).repack(true);
        else       IVogueRepack(v4).repack(false);
    }

    /// @notice All-or-nothing deploy-finalize linkage assert (delegatecall from
    ///         Aux.finalize, so address(this)==Aux). Reverts unless every
    ///         external linkage EQUALS Aux's owner-set view — catching a
    ///         front-runner's malicious-but-non-zero pin in an ungated setter.
    function assertFullyWired(address q, address ethVenue, address btcChannels,
        address core, address v4) external view {
        require(q != address(0),                                    "wire:quid");
        require(ethVenue != address(0),                             "wire:vault");
        require(IWiredVogue(v4).EV() == ethVenue,                 "wire:vogue"); // Vogue→Vault
        require(IWiredCore(core).btcVault() == ethVenue,            "wire:core");  // Core→Vault
        require(btcChannels != address(0)
             && IWiredVault(ethVenue).btcChannels() == btcChannels, "wire:chan");  // Vault→Channels
        address rover = IWiredVault(ethVenue).ROVER();
        require(rover != address(0)
             && IWiredRover(rover).AUX() == ethVenue,               "wire:rover"); // Rover↔Vault
        require(IWiredBasket(q).AUX() == address(this),             "wire:bAux");  // Basket→Aux
        require(IWiredBasket(q).BTC_VAULT() == ethVenue,            "wire:bVlt");  // Basket→Vault
    }

    /// @notice Body of Aux.redeemableAmount (delegatecall, address(this)==Aux).
    function redeemableBody(address core) external returns (uint) {
        (uint total,) = IAux(address(this)).get_metrics(false);
        { uint dl = _depegLoss(); total = total > dl ? total - dl : 0; }
        // Cap at DELIVERABLE backing (Σ max(0, convertToAssets −
        // maxWithdraw) per 4626) so QU!D is never quoted against a frozen-but-solvent
        // vault's undeliverable slice; that portion defers until the vault is liquid again.
        { uint il = _illiquidLoss(); total = total > il ? total - il : 0; }
        // NB: this quotes AGGREGATE deliverable dollars (a capacity view). The per-QD `min(par, share)` cap lives
        // in the money path (redeemAsBody + SwapLib); `total` is a conservative upper bound and never under-reports.
        // STABLES-ONLY with the Option-4 unwind: QU!D's dollars deployed as the ETH band's
        // USD side are freeable on redemption (Vogue.unwindForRedeem), so the redeemable is ALL
        // haircut stables EXCEPT what is committed to the BTC band (an ETH-side redemption cannot
        // unwind the BTC band). Conservative: subtract POOLED_USD_BTC (>= BTC-band equity; ignores
        // the debt that would only shrink it), so the quote never over-reports.
        uint btcCommitted = IVogueCore(core).POOLED_USD_BTC() * 1e12;
        return total > btcCommitted ? total - btcCommitted : 0;
    }

    // (ethToStableFallback removed -- redemption is stables-only; the committed dollars
    //  are freed by unwinding the band, Vogue.unwindForRedeem, not by selling an LP's venue ETH.)

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
        address galaxyVault;
        address ethVenue;   // holder of the Galaxy/Euler/Gauntlet/AAVE WETH position (post-carve)
        address eulerVault; // second WETH 4626 curator (0 if unwired)
        address gauntletVault; // third WETH 4626 curator (0 if unwired)
    }

    /// @notice Per-VENUE health state. BINARY (blocked) + the evac clock —
    ///         mirroring the depeg model: an incident BLOCKS the vault (valued
    ///         at maxWithdraw in vogueETH/get_deposits, no new deposits routed)
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
        // The Galaxy WETH position is custodied on EthVenue (the venue carve), so
        // its illiquidity is read from THERE; all other (stable) vaults are held
        // by Aux (== address(this)) and read directly.
        uint reported; uint liquid;
        bool isEthVenue = vault == cfg.galaxyVault
            || (cfg.eulerVault != address(0) && vault == cfg.eulerVault)
            || (cfg.gauntletVault != address(0) && vault == cfg.gauntletVault);
        if (isEthVenue) {
            (reported, liquid) = IEthVenue(cfg.ethVenue).venuePosition(vault);
        } else {
            reported = IERC4626(vault).convertToAssets(IERC4626(vault).balanceOf(address(this)));
            // Same ONE definition (see the haircut above). This is the PERMISSIONLESS poke: a
            // Morpho-V2 stable vault reads 0 liquid on the raw max-view, so `liqBps` was 0 and ANY
            // caller could block-then-evacuate a perfectly healthy vault holding real TVL. The ETH
            // branch above already routes through the fixed `venuePosition`; this else-branch did not.
            liquid = VaultLib._withdrawableOf(vault, address(this));
        }
        if (reported == 0) return;                       // empty position → no-op
        uint liqBps = FullMath.mulDiv(liquid, 10000, reported);
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

    function evacuateBody(
        address vault, VaultHealthCfg memory cfg,
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => address) storage tokens
    ) public {
        vaultHealth[vault].blocked = true; // block first → spread skips it
        // ETH-VENUE incident (Galaxy/Morpho WETH): pull the WITHDRAWABLE WETH to
        // the AAVE haven (the spec: send the ETH to the AAVE spoke). WETH is not a
        // basket stable, so the stable path below skips it (tokens[GALAXY]==0); we
        // handle it here. We move only `maxWithdraw` — the on-chain-measurable
        // withdrawable amount (no fuzzy solvency oracle) — and any frozen remainder
        // stays in the blocked venue, written down in vogueETH (valued at
        // maxWithdraw). If AAVE-WETH isn't wired (AAVE_SPOKE==0 — NOT a zero reserve
        // id, which is a VALID reserve: mainnet WETH is asset 0) the pulled
        // WETH simply rests at Aux — still OUT of the failing venue.
        if (vault == cfg.galaxyVault
            || (cfg.eulerVault != address(0) && vault == cfg.eulerVault)
            || (cfg.gauntletVault != address(0) && vault == cfg.gauntletVault)) {
            // A WETH 4626 curator (Galaxy or Euler) is custodied on EthVenue (the
            // venue carve); the drain (maxWithdraw → AAVE haven) runs THERE.
            // EthVenue.evacuateVenue is gated to Aux (== address(this) here, since
            // this body is delegatecalled from Aux). maxWithdraw-only, AAVE-or-idle.
            IEthVenue(cfg.ethVenue).evacuateVenue(vault);
            return;
        }
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
        uint n;
        for (uint j; j < vs.length; j++) if (!vaultHealth[vs[j]].blocked) n++;
        if (n == 0) return;
        uint each = amount / n;
        uint rem = amount;
        for (uint j; j < vs.length; j++) {
            if (vaultHealth[vs[j]].blocked) continue;
            uint a = (--n == 0) ? rem : each; // last healthy vault takes remainder
            rem -= a;
            if (a > 0) IERC4626(vs[j]).deposit(a, address(this));
        }
    }
}

/// @notice Aux's self-gated surface that BasketLib.takeBody calls back into.
