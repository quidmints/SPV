
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {mock} from "../mock.sol";

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
    function deployMocks() external returns (
        address mETH, address mBTC, address mUSD_ETH, address mUSD_BTC
    ) {
        mETH     = address(new mock(address(this), 18));
        mBTC     = address(new mock(address(this),  8));
        mUSD_ETH = address(new mock(address(this),  6));
        mUSD_BTC = address(new mock(address(this),  6));
    }
}
