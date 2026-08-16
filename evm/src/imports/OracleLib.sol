
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {mock} from "../mock.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapLib} from "./SwapLib.sol";
import {BasketLib} from "./BasketLib.sol";

/// @title  OracleLib — the per-pool V4 TWAP observation ring, extracted from
///         Core to free its deployed bytecode under EIP-170.
///
/// Core runs TWO independent rings (ETH/USD and BTC/USD). Each is a
/// `Observation[65535]` array plus an `ObsState` scalar trio. The write +
/// observe/interpolate logic is pool-agnostic, so it lives here ONCE and
/// Core passes the relevant pool's `storage` refs in. `external` library
/// functions run via DELEGATECALL in Core's storage context, so this
/// engine is deployed once and shared — saving Core's bytecode.
library OracleLib {
    /// §TICK-REMOVAL (2026-08-15) — THE RING STORES PLAIN PRICE, NOT TICKS AND NOT SQRT-PRICES.
    /// Both encodings are leaving the tree, and every consumer of this ring already wanted a price:
    /// `twapBody` converted tick→sqrt→price on EVERY read (21 of the 28 live `TickMath` calls in
    /// `src`), and the skew consumes `r.px`. Storing the price directly deletes the whole round trip,
    /// the `int56` walks, and the per-read orientation flag — orientation is resolved ONCE at write.
    /// `uint192` is ample: the BTC leg's usd18 price carries the ×1e10 WBTC lift (~6.3e32) and an
    /// elapsed-seconds accumulator over a decade (~3e8) reaches ~2e41, against a 6.3e57 ceiling.
    struct Observation {
        uint32 blockTimestamp;
        uint192 priceCumulative;
        bool initialized;
    }
    /// Per-pool ring scalars (grouped so the helpers take one storage ref).
    struct ObsState { uint lastPrice; uint16 cardinality; uint16 index; }   // §DE-TICK: uniform width

    /// @dev Append the current price to the ring (or just update lastPrice if a
    ///      same-timestamp write already happened this block).
    function writeObservation(
        Observation[65535] storage obs, ObsState storage st, uint price
    ) external {
        uint32 blockTimestamp = uint32(block.timestamp);
        uint16 idx = st.index;
        Observation memory last = obs[idx];

        if (last.blockTimestamp == blockTimestamp) {
            st.lastPrice = price;
            return;
        }
        uint32 dt = blockTimestamp - last.blockTimestamp;
        uint192 priceCumulative = last.priceCumulative
            + uint192(uint256(st.lastPrice) * dt);

        uint16 nextIdx = (idx + 1) % 65535;
        uint16 card = st.cardinality;
        if (nextIdx >= card && card < 65535) {
            st.cardinality = nextIdx + 1;
        }
        obs[nextIdx] = Observation({
            blockTimestamp: blockTimestamp,
            priceCumulative: priceCumulative,
            initialized: true});
        st.index = nextIdx; st.lastPrice = price;
    }

    function observe(
        Observation[65535] storage obs, ObsState storage st,
        uint32[] calldata secondsAgos
    ) external view returns (uint192[] memory priceCumulatives) {
        priceCumulatives = new uint192[](secondsAgos.length);
        uint32 time = uint32(block.timestamp);
        Observation memory latest = obs[st.index];
        Observation memory oldest = _getOldest(obs, st);
        uint lastPrice = st.lastPrice;

        for (uint i = 0; i < secondsAgos.length; i++) {
            uint32 target = time - secondsAgos[i];
            if (secondsAgos[i] == 0) {
                uint32 dt = time - latest.blockTimestamp;
                priceCumulatives[i] = latest.priceCumulative
                    + uint192(uint256(lastPrice) * dt);
            } else if (target <= oldest.blockTimestamp) {
                // Bootstrap-only edge: target predates the oldest observation.
                // Revert — callers should wait until the ring covers their
                // TWAP window.
                revert("twap: pre-history");
            } else if (target >= latest.blockTimestamp) {
                uint32 dt = target - latest.blockTimestamp;
                priceCumulatives[i] = latest.priceCumulative
                    + uint192(uint256(lastPrice) * dt);
            } else {
                priceCumulatives[i] = _interpolate(obs, st, target, oldest, latest);
            }
        }
    }

    function _getOldest(Observation[65535] storage obs, ObsState storage st)
        internal view returns (Observation memory) {
        uint16 card = st.cardinality;
        if (card == 1) return obs[0];
        uint16 oldestIdx = (st.index + 1) % card;
        Observation memory oldest = obs[oldestIdx];
        if (!oldest.initialized) return obs[0];
        return oldest;
    }

    function _interpolate(
        Observation[65535] storage obs, ObsState storage st,
        uint32 target, Observation memory oldest, Observation memory latest
    ) internal view returns (uint192) {
        uint16 card = st.cardinality;

        if (card <= 2) {
            uint32 totalDelta = latest.blockTimestamp - oldest.blockTimestamp;
            uint32 targetDelta = target - oldest.blockTimestamp;
            if (totalDelta == 0) return oldest.priceCumulative;
            uint192 cumulativeDelta = latest.priceCumulative - oldest.priceCumulative;
            // Widen to int256 for the multiply-before-divide: across a long
            // observation gap (e.g. a quiet market then a swap/reseat),
            // cumulativeDelta·targetDelta overflows int56 (~3.6e16) even though
            // the interpolated RESULT fits int56. Compute in 256-bit, cast back.
            return oldest.priceCumulative + uint192(
                uint256(cumulativeDelta) * uint256(targetDelta)
                    / uint256(totalDelta));
        }

        uint16 oldestIdx = (st.index + 1) % card;
        if (!obs[oldestIdx].initialized) oldestIdx = 0;

        uint16 lo = 0; uint16 hi = card - 1;
        while (lo < hi) {
            uint16 mid = lo + (hi - lo + 1) / 2;
            if (obs[(oldestIdx + mid) % card].blockTimestamp <= target) lo = mid;
            else hi = mid - 1;
        }
        Observation memory before_ = obs[(oldestIdx + lo) % card];
        Observation memory later_  = obs[(oldestIdx + lo + 1) % card];

        uint32 totalDelta = later_.blockTimestamp - before_.blockTimestamp;
        if (totalDelta == 0) return before_.priceCumulative;
        uint32 targetDelta = target - before_.blockTimestamp;
        uint192 cumulativeDelta = later_.priceCumulative - before_.priceCumulative;
        // 256-bit intermediate — see the card<=2 branch above (int56 overflow on
        // a long observation gap).
        return before_.priceCumulative + uint192(
            uint256(cumulativeDelta) * uint256(targetDelta)
                / uint256(totalDelta));
    }

    /// @dev Deploy Core's four per-pool mocks here (not in Core) so the ~3.9 KB
    ///      of `mock` creation-code lives in THIS library's bytecode, shedding it
    ///      from Core under EIP-170. Runs via DELEGATECALL in Core's context, so
    ///      owner (rover) == address(this) == Core. Decimals mirror the originals:
    ///      ETH 18, BTC 8, USD_ETH/USD_BTC 6. (Homed here only because OracleLib
    ///      is the one existing Core-lib with bytecode headroom — no new file.)
    /// @dev Assemble one VANILLA PoolKey, initialize its V4 pool, and seed its
    ///      oracle ring — the deploy-time half of `Core._initPool`, homed here for
    ///      the same reason `deployMocks` is: it runs ONCE, via DELEGATECALL in
    ///      Core's storage context, and every byte of it was sitting in Core's
    ///      RUNTIME code against a hard EIP-170 deficit.
    ///
    ///      Core keeps the parts that are cheap there and dear here: the lex-order
    ///      comparison (it must assign `token1isVol`/`token1isVol`, which are
    ///      value-type state with no storage pointer to pass) and the tick
    ///      direction-correction + `SwapLib.alignTick` (Core already links SwapLib;
    ///      importing it here would add a lib->lib delegatecall to re-derive three
    ///      lines of arithmetic across the boundary — the exact thing E14 tracks).
    ///      So `token0`/`token1` arrive ALREADY SORTED and `tick` ALREADY ALIGNED.
    /// §V4-CUT — THIS IS A RING SEEDER NOW, AND THE NAME SAYS SO. It used to assemble a lex-sorted
    /// PoolKey, derive its PoolId, align a reference tick to the grid and call `pm.initialize` so v4
    /// would host the band. Nothing calls the PoolManager any more, so the pool was never created --
    /// which made the PoolKey, the PoolId and the `volMock > usdMock` ordering all write-only
    /// vestigia of a pool that does not exist. `VANILLA_*` and `POOL_ID_VANILLA_*` went with them.
    /// What actually mattered was always these three lines: seed `lastPrice` from the reference
    /// price and open the ring.
    function seedRing(ObsState storage st, Observation[65535] storage obs, uint refPrice)
        external {
        st.lastPrice = refPrice;
        st.cardinality = 1;
        obs[0] = Observation({ blockTimestamp: uint32(block.timestamp),
            priceCumulative: 0, initialized: true });
    }

    /// `wbtc` is passed in rather than read here so OracleLib does not have to import
    /// `Aux` for one getter; Core already holds the pin.
    ///
    /// 🔴 §DE-TICK — RETURNS PRICES, NOT TICKS. THIS WAS A LIVE UNIT BUG. These reads used to hand
    /// back the reference pools' `slot0` TICKS, and `initPool` converted them to a sqrt price to
    /// initialise our own v4 pool at the same ratio. That pool is gone, so the tick travelled
    /// straight into `st.lastPrice` through a `uint(int(refTick))` cast -- seeding the observation
    /// ring with a TICK reinterpreted as a WAD price, which for a NEGATIVE tick is ~2^256.
    /// MEASURED: `poolStats()` returned 1.157e77 and every fixture's setUp died one step later on
    /// an arithmetic underflow. A tick and a price are both `uint` after the cast, so nothing
    /// objected.
    /// The orientation probes are CONSUMED HERE now (`token0isUSD == !volIsC0`) instead of
    /// travelling onward, so writer and reader cannot disagree about which way up the price is --
    /// the same argument `cumsToPrice` already makes for the ring.
    /// ⚠️ The reference pools are still READ, deliberately: they are the independent v3/v4
    /// observation the Chainlink cross-check is measured against.
    function prepRefs(IPoolManager pm, PoolKey calldata refETH, PoolKey calldata refBTC,
        address mETH, address mBTC, address mUSD_ETH, address mUSD_BTC, address wbtc)
        external returns (uint priceETH, uint priceBTC) {
        (uint160 spETH, , , ) = StateLibrary.getSlot0(pm, PoolIdLibrary.toId(refETH));
        (uint160 spBTC, , , ) = StateLibrary.getSlot0(pm, PoolIdLibrary.toId(refBTC));
        // `volIsC0` says the VOLATILE asset is currency0, so token0 is NOT the USD side.
        priceETH = BasketLib.getPrice(spETH, !(Currency.unwrap(refETH.currency0) == address(0)));
        priceBTC = BasketLib.getPrice(spBTC, !(Currency.unwrap(refBTC.currency0) == wbtc));
        mock(mETH).approve(address(pm), type(uint).max);
        mock(mBTC).approve(address(pm), type(uint).max);
        mock(mUSD_ETH).approve(address(pm), type(uint).max);
        mock(mUSD_BTC).approve(address(pm), type(uint).max);
    }

    function deployMocks() external returns (
        address mETH, address mBTC, address mUSD_ETH, address mUSD_BTC
    ) {
        mETH     = address(new mock(address(this), 18));
        mBTC     = address(new mock(address(this),  8));
        mUSD_ETH = address(new mock(address(this),  6));
        mUSD_BTC = address(new mock(address(this),  6));
    }

    /// @notice §E59 — REALIZED TICK VARIANCE FROM THE **STORED OBSERVATIONS**, not a wall-clock grid.
    ///
    /// WHY THIS EXISTS. The previous estimator sampled `observe` every `THETA_STEP` seconds, but the
    /// ring only advances ON A SWAP and `observe` LINEARLY INTERPOLATES between stored points.
    /// Linear interpolation has ZERO SECOND DERIVATIVE, so every sample inside one inter-swap gap
    /// returned the same average tick and the variance came out EXACTLY 0 — however violently price
    /// had moved. MEASURED: a drain that took `POOLED` from 400 to 0.00097 ETH reported 0.
    ///
    /// Sampling the ring itself removes the interpolation entirely: every point is a REAL price
    /// update, so a gap contributes one observation rather than a run of identical fabrications.
    /// Intervals are UNEVEN by nature, so each return is normalised by its OWN elapsed time and the
    /// annualisation uses the MEASURED span — no fixed step to mis-match the swap cadence.
    ///
    /// Returns tick-variance per second (WAD). **0 means UNKNOWN — too few real updates — NOT calm**;
    /// the span is not returned because it is redundant (it is 0 exactly when this is).
    function ringVariance(Observation[65535] storage obs, ObsState storage st, uint n)
        external view returns (uint varPerSecWad)
    {
        uint card = st.cardinality;
        if (card < 3 || n < 3) return 0;
        if (n > card) n = card;

        // Walk back n stored points from the newest, newest-first.
        uint[] memory rate = new uint[](n - 1);     // per-interval average PRICE
        uint32 newest; uint32 oldest;
        {
            uint16 idx = st.index;
            Observation memory hi = obs[idx];
            newest = hi.blockTimestamp;
            for (uint i = 0; i < n - 1; i++) {
                uint16 lo_i = uint16((uint(idx) + card - 1 - i) % card);
                Observation memory lo = obs[lo_i];
                if (!lo.initialized || lo.blockTimestamp >= hi.blockTimestamp) return 0;
                uint32 dt = hi.blockTimestamp - lo.blockTimestamp;
                // §TICK-REMOVAL — THE 1e9 LIFT IS GONE WITH THE TICKS. §E59 added it because
                // truncating to WHOLE TICKS zeroed every difference on a ~20-tick band. A usd18
                // price carries 18 decimals natively, so sub-basis-point movement survives without
                // any rescaling, and omitting the lift keeps `d*d` far inside uint256.
                rate[i] = uint(hi.priceCumulative - lo.priceCumulative) / uint(dt);
                hi = lo;
                oldest = lo.blockTimestamp;
            }
        }
        if (newest <= oldest) return 0;
        uint spanSecs = newest - oldest;

        // Variance of consecutive RELATIVE returns, sample-corrected.
        // §TICK-REMOVAL — THE RETURN IS NOW RELATIVE *EXPLICITLY*, WHICH IS WHAT KEEPS σ²'s UNITS
        // AND LEAVES Γ UNTOUCHED. A tick difference was ALREADY a relative return in disguise (1
        // tick = 1 bp), which is precisely why `Core.realizedVarianceWad` multiplied by
        // 1e10 = 1e-8 (tick²→relative²) × 1e18 (WAD). Taking the relative return of a plain price
        // makes that conversion unnecessary rather than merely moving it, so the 1e10 goes with the
        // ticks and the ANNUALIZED NUMBER KEEPS ITS MAGNITUDE AND MEANING.
        uint m = rate.length - 1;
        if (m < 2) return 0;
        int[] memory ret = new int[](m);
        for (uint i = 0; i < m; i++) {
            uint prev = rate[i + 1];
            if (prev == 0) return 0;
            ret[i] = (int(rate[i]) - int(prev)) * 1e18 / int(prev);   // WAD relative return
        }
        int mean;
        for (uint i = 0; i < m; i++) mean += ret[i];
        mean /= int(m);
        uint acc;
        for (uint i = 0; i < m; i++) {
            int d = ret[i] - mean;
            acc += uint(d * d);
        }
        acc /= (m - 1);
        // §E63 — SECOND MOMENT, NOT CENTRAL SECOND MOMENT: add the DRIFT back in.
        //
        // `acc` alone is the variance ABOUT THE MEAN, and a band walking STEADILY one way has every
        // difference equal ⇒ every deviation 0 ⇒ variance EXACTLY 0. That is arithmetically right
        // and economically wrong: a monotone walk carries real inventory risk while measuring as
        // perfectly calm. MEASURED: 16 swaps moving the tick −1 read 0; only a −2 move registered.
        // Four memory policies (latch / erase / decay / widen) all failed trying to REMEMBER a
        // number that was correctly zero — the number itself was the wrong quantity.
        //
        // The drift () was already computed and discarded. Squaring it back in costs no extra loads
        // and no constant, and gives E[x²] = Var + E[x]² — the drift AND the wobble, which is what
        // an inventory-risk measure has to price.
        acc += uint(mean * mean);   //  is the drift term computed above
        // Per-second. The caller annualises with the MEASURED span rather than a fixed step.
        // `acc` is (WAD relative return)^2 = relative^2 * 1e36, so the caller divides by 1e18 ONCE
        // to land on WAD relative variance — replacing the old `* 1e10 / 1e18`.
        varPerSecWad = acc / spanSecs;
    }
}
