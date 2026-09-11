// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {ICurveOracle, IOffchainOracle} from "./Interfaces.sol";

library OracleLib {

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
