
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {mock} from "../mock.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapLib} from "./SwapLib.sol";

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
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }
    /// Per-pool ring scalars (grouped so the helpers take one storage ref).
    struct ObsState { int24 lastTick; uint16 cardinality; uint16 index; }

    /// @dev Append the current tick to the ring (or just update lastTick if a
    ///      same-timestamp write already happened this block).
    function writeObservation(
        Observation[65535] storage obs, ObsState storage st, int24 tick
    ) external {
        uint32 blockTimestamp = uint32(block.timestamp);
        uint16 idx = st.index;
        Observation memory last = obs[idx];

        if (last.blockTimestamp == blockTimestamp) {
            st.lastTick = tick;
            return;
        }
        uint32 dt = blockTimestamp - last.blockTimestamp;
        int56 tickCumulative = last.tickCumulative
            + int56(st.lastTick) * int56(uint56(dt));

        uint16 nextIdx = (idx + 1) % 65535;
        uint16 card = st.cardinality;
        if (nextIdx >= card && card < 65535) {
            st.cardinality = nextIdx + 1;
        }
        obs[nextIdx] = Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: tickCumulative,
            initialized: true});
        st.index = nextIdx; st.lastTick = tick;
    }

    function observe(
        Observation[65535] storage obs, ObsState storage st,
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives) {
        tickCumulatives = new int56[](secondsAgos.length);
        uint32 time = uint32(block.timestamp);
        Observation memory latest = obs[st.index];
        Observation memory oldest = _getOldest(obs, st);
        int24 lastTick = st.lastTick;

        for (uint i = 0; i < secondsAgos.length; i++) {
            uint32 target = time - secondsAgos[i];
            if (secondsAgos[i] == 0) {
                uint32 dt = time - latest.blockTimestamp;
                tickCumulatives[i] = latest.tickCumulative
                    + int56(lastTick) * int56(uint56(dt));
            } else if (target <= oldest.blockTimestamp) {
                // Bootstrap-only edge: target predates the oldest observation.
                // Revert — callers should wait until the ring covers their
                // TWAP window.
                revert("twap: pre-history");
            } else if (target >= latest.blockTimestamp) {
                uint32 dt = target - latest.blockTimestamp;
                tickCumulatives[i] = latest.tickCumulative
                    + int56(lastTick) * int56(uint56(dt));
            } else {
                tickCumulatives[i] = _interpolate(obs, st, target, oldest, latest);
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
    ) internal view returns (int56) {
        uint16 card = st.cardinality;

        if (card <= 2) {
            uint32 totalDelta = latest.blockTimestamp - oldest.blockTimestamp;
            uint32 targetDelta = target - oldest.blockTimestamp;
            if (totalDelta == 0) return oldest.tickCumulative;
            int56 cumulativeDelta = latest.tickCumulative - oldest.tickCumulative;
            // Widen to int256 for the multiply-before-divide: across a long
            // observation gap (e.g. a quiet market then a swap/reseat),
            // cumulativeDelta·targetDelta overflows int56 (~3.6e16) even though
            // the interpolated RESULT fits int56. Compute in 256-bit, cast back.
            return oldest.tickCumulative + int56(
                int256(cumulativeDelta) * int256(uint256(targetDelta))
                    / int256(uint256(totalDelta)));
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
        if (totalDelta == 0) return before_.tickCumulative;
        uint32 targetDelta = target - before_.blockTimestamp;
        int56 cumulativeDelta = later_.tickCumulative - before_.tickCumulative;
        // 256-bit intermediate — see the card<=2 branch above (int56 overflow on
        // a long observation gap).
        return before_.tickCumulative + int56(
            int256(cumulativeDelta) * int256(uint256(targetDelta))
                / int256(uint256(totalDelta)));
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
    ///      comparison (it must assign `token1isETH`/`token1isBTC`, which are
    ///      value-type state with no storage pointer to pass) and the tick
    ///      direction-correction + `SwapLib.alignTick` (Core already links SwapLib;
    ///      importing it here would add a lib->lib delegatecall to re-derive three
    ///      lines of arithmetic across the boundary — the exact thing E14 tracks).
    ///      So `token0`/`token1` arrive ALREADY SORTED and `tick` ALREADY ALIGNED.
    function initPool(IPoolManager pm, PoolKey storage k, ObsState storage st,
        Observation[65535] storage obs, address volMock, address usdMock,
        bool refVolIsC0, int24 refTick) external returns (bool token1isVol, PoolId id) {
        token1isVol = volMock > usdMock;                       // V4 lex-ordering
        k.currency0 = Currency.wrap(token1isVol ? usdMock : volMock);
        k.currency1 = Currency.wrap(token1isVol ? volMock : usdMock);
        k.fee = 420; k.tickSpacing = 10; k.hooks = IHooks(address(0));
        id = PoolIdLibrary.toId(k);

        // tick = log_1.0001(c1/c0). If the volatile asset sits on the same side (c0)
        // in both ref and vanilla, the tick transfers directly; otherwise negate.
        // (`volIsC0InVanilla == !token1isVol`.) Then floor toward -inf to tickSpacing:
        // Solidity divides toward zero, which rounds negatives the wrong way.
        // `SwapLib.alignTick` is CALLED, not re-derived here -- three lines of
        // arithmetic duplicated across a library boundary is exactly the drift E14
        // tracks, and OracleLib does not import SwapLib anywhere else, so there is
        // no cycle (checked).
        int24 tick = SwapLib.alignTick(
            (refVolIsC0 == !token1isVol) ? refTick : -refTick, 10);

        pm.initialize(k, TickMath.getSqrtPriceAtTick(tick));
        st.lastTick = tick; st.cardinality = 1;
        obs[0] = Observation({ blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0, initialized: true });
    }

    /// `wbtc` is passed in rather than read here so OracleLib does not have to import
    /// `Aux` for one getter; Core already holds the pin. The two returned bools are the
    /// DIRECTION PROBES `initPool` needs — whether the volatile asset is currency0 in
    /// each REFERENCE pool (ETH ref: native 0x0; BTC ref: WBTC).
    function prepRefs(IPoolManager pm, PoolKey calldata refETH, PoolKey calldata refBTC,
        address mETH, address mBTC, address mUSD_ETH, address mUSD_BTC, address wbtc)
        external returns (int24 tickETH, int24 tickBTC, bool ethVolIsC0, bool btcVolIsC0) {
        (, tickETH, , ) = StateLibrary.getSlot0(pm, PoolIdLibrary.toId(refETH));
        (, tickBTC, , ) = StateLibrary.getSlot0(pm, PoolIdLibrary.toId(refBTC));
        ethVolIsC0 = Currency.unwrap(refETH.currency0) == address(0);
        btcVolIsC0 = Currency.unwrap(refBTC.currency0) == wbtc;
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
    /// had moved. MEASURED: a drain that took `POOLED_ETH` from 400 to 0.00097 ETH reported 0.
    ///
    /// Sampling the ring itself removes the interpolation entirely: every point is a REAL price
    /// update, so a gap contributes one observation rather than a run of identical fabrications.
    /// Intervals are UNEVEN by nature, so each return is normalised by its OWN elapsed time and the
    /// annualisation uses the MEASURED span — no fixed step to mis-match the swap cadence.
    ///
    /// Returns raw tick-variance per second (scaled 1e18) and the span it was measured over; 0 span
    /// means "not enough real updates", which callers must treat as UNKNOWN and NOT as calm.
    function ringVariance(Observation[65535] storage obs, ObsState storage st, uint n)
        external view returns (uint varPerSecWad, uint spanSecs)
    {
        uint card = st.cardinality;
        if (card < 3 || n < 3) return (0, 0);
        if (n > card) n = card;

        // Walk back n stored points from the newest, newest-first.
        int[] memory rate = new int[](n - 1);       // per-interval average tick
        uint32 newest; uint32 oldest;
        {
            uint16 idx = st.index;
            Observation memory hi = obs[idx];
            newest = hi.blockTimestamp;
            for (uint i = 0; i < n - 1; i++) {
                uint16 lo_i = uint16((uint(idx) + card - 1 - i) % card);
                Observation memory lo = obs[lo_i];
                if (!lo.initialized || lo.blockTimestamp >= hi.blockTimestamp) return (0, 0);
                uint32 dt = hi.blockTimestamp - lo.blockTimestamp;
                // §E59 — FIXED-POINT, NOT INTEGER. Truncating to whole ticks was the second half
                // of the zero-variance bug: the band is ~20 ticks wide, so consecutive average
                // ticks round to the SAME INTEGER and every difference is 0. Scale by 1e9 first so
                // sub-tick movement survives; `d*d` then stays far inside uint256.
                rate[i] = (int(hi.tickCumulative - lo.tickCumulative) * 1e9) / int(uint(dt));
                hi = lo;
                oldest = lo.blockTimestamp;
            }
        }
        if (newest <= oldest) return (0, 0);
        spanSecs = newest - oldest;

        // Variance of consecutive rate CHANGES (the returns), sample-corrected.
        uint m = rate.length - 1;
        if (m < 2) return (0, spanSecs);
        int mean;
        for (uint i = 0; i < m; i++) mean += (rate[i] - rate[i + 1]);
        mean /= int(m);
        uint acc;
        for (uint i = 0; i < m; i++) {
            int d = (rate[i] - rate[i + 1]) - mean;
            acc += uint(d * d);
        }
        acc /= (m - 1);
        // Per-second, WAD. The caller annualises with the MEASURED span rather than a fixed step.
        // `acc` is in (1e9-scaled tick)^2 = tick^2 * 1e18, so it is already WAD-scaled tick^2.
        varPerSecWad = acc / spanSecs;
    }
}
