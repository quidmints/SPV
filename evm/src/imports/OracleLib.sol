// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {ICurveOracle, IOffchainOracle} from "./Interfaces.sol";

import {IAggregatorV3} from "./Interfaces.sol";

uint256 constant RING = 256;

library OracleLib {

    struct Observation {
        uint32 blockTimestamp;
        uint192 priceCumulative;
        bool initialized;
    }

    struct ObsState { uint lastPrice; uint16 cardinality; uint16 index; }

    function writeObservation(
        Observation[RING] storage obs, ObsState storage st, uint price
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

        uint16 nextIdx = uint16((idx + 1) % RING);
        uint16 card = st.cardinality;
        if (nextIdx >= card && card < uint16(RING)) {
            st.cardinality = nextIdx + 1;
        }
        obs[nextIdx] = Observation({
            blockTimestamp: blockTimestamp,
            priceCumulative: priceCumulative,
            initialized: true});
        st.index = nextIdx; st.lastPrice = price;
    }

    function observe(
        Observation[RING] storage obs, ObsState storage st,
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

    function _getOldest(Observation[RING] storage obs, ObsState storage st)
        internal view returns (Observation memory) {
        uint16 card = st.cardinality;
        if (card == 1) return obs[0];
        uint16 oldestIdx = (st.index + 1) % card;
        Observation memory oldest = obs[oldestIdx];
        if (!oldest.initialized) return obs[0];
        return oldest;
    }

    function _interpolate(
        Observation[RING] storage obs, ObsState storage st,
        uint32 target, Observation memory oldest, Observation memory latest
    ) internal view returns (uint192) {
        uint16 card = st.cardinality;

        Observation memory before_;
        Observation memory later_;
        if (card <= 2) {
            before_ = oldest;
            later_  = latest;
        } else {
            uint16 oldestIdx = (st.index + 1) % card;
            if (!obs[oldestIdx].initialized) oldestIdx = 0;

            uint16 lo = 0; uint16 hi = card - 1;
            while (lo < hi) {
                uint16 mid = lo + (hi - lo + 1) / 2;
                if (obs[(oldestIdx + mid) % card].blockTimestamp <= target) lo = mid;
                else hi = mid - 1;
            }
            before_ = obs[(oldestIdx + lo) % card];
            later_  = obs[(oldestIdx + lo + 1) % card];
        }

        uint32 totalDelta = later_.blockTimestamp - before_.blockTimestamp;
        if (totalDelta == 0) return before_.priceCumulative;
        uint32 targetDelta = target - before_.blockTimestamp;
        uint192 cumulativeDelta = later_.priceCumulative - before_.priceCumulative;

        return before_.priceCumulative + uint192(
            uint256(cumulativeDelta) * uint256(targetDelta)
                / uint256(totalDelta));
    }

    function seedRing(ObsState storage st, Observation[RING] storage obs, uint refPrice)
        external {
        st.lastPrice = refPrice;
        st.cardinality = 1;
        obs[0] = Observation({ blockTimestamp: uint32(block.timestamp),
            priceCumulative: 0, initialized: true });
    }

    function seedPrices(address ethFeed, address btcFeed)
        external view returns (uint priceETH, uint priceBTC) {
        priceETH = _feed18(ethFeed, false);
        priceBTC = _feed18(btcFeed, true);
    }

    function _feed18(address feed, bool isWbtc) private view returns (uint) {
        (, int256 ans, , , ) = IAggregatorV3(feed).latestRoundData();
        require(ans > 0, "seed feed");
        uint8 d = IAggregatorV3(feed).decimals();
        require(d <= 18, "seed dec");
        uint p = uint(ans) * (10 ** (18 - d));
        return isWbtc ? p * 1e10 : p;
    }

    error NoExternalPrice();

    function curvePriceWad(address pool, uint256 k) internal view returns (uint priceWad) {
        priceWad = ICurveOracle(pool).price_oracle(k);
        if (priceWad == 0) revert NoExternalPrice();
    }

    function curvePriceWad(address pool) internal view returns (uint priceWad) {
        priceWad = ICurveOracle(pool).price_oracle();
        if (priceWad == 0) revert NoExternalPrice();
    }

    function oneInchRateWad(address oracle, address src, address dst, uint8 srcDec, uint8 dstDec)
        internal view returns (uint priceWad) {
        uint rate = IOffchainOracle(oracle).getRate(src, dst, false);
        if (rate == 0) revert NoExternalPrice();
        priceWad = SoladyMath.fullMulDiv(rate, 10 ** srcDec, 10 ** dstDec);
        if (priceWad == 0) revert NoExternalPrice();
    }

}
