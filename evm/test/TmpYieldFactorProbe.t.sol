// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IV {
    function decimals() external view returns (uint8);
    function asset() external view returns (address);
    function convertToAssets(uint256) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
}

/// TEMPORARY PROBE — executes the control named in QUEUE §E154 blocker ①:
/// does `metrics.yield` actually report the vaults' appreciation, or does the
/// decimal mismatch between 18-dec MetaMorpho shares and a 6-dec asset collapse
/// the yield factor? Reads REAL mainnet vaults; no mocks, no protocol state.
contract TmpYieldFactorProbe is Test {
    address constant GALAXY_USDC = 0x91600E31fBeDc72433d4a57F16639cfe661Be7d8;
    address constant GALAXY_USDT = 0x71ffB6a81786eC285D429d531Cf655107B9D878d;
    address constant RLUSD_V     = 0x6dC58a0FdfC8D694e571DC59B9A52EEEa780E6bf;
    address constant USDS_V      = 0xE15fcC81118895b67b6647BBd393182dF44E11E0;

    /// Use a REALISTIC position — $1M of the vault's own asset — so the reported
    /// factor is the live one, not an artifact of an unrealistically small share
    /// count. `shares` here is what `IERC4626(v).balanceOf(aux)` would return.
    function _factorBps(address v) internal view returns (uint b, uint yw, uint shares) {
        uint dec = IV(IV(v).asset()).decimals();
        shares = IV(v).convertToShares(1_000_000 * (10 ** dec));
        b = IV(v).convertToAssets(shares);
        yw = FullMath.mulDiv(b, b, shares); // EXACTLY BasketLib._valueStable:265
    }

    function test_YieldFactorCollapsesOn6DecAssets() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        address[4] memory vs = [GALAXY_USDC, GALAXY_USDT, RLUSD_V, USDS_V];
        uint rawSum; uint ywSum;

        for (uint i; i < vs.length; i++) {
            (uint b, uint yw, uint sh) = _factorBps(vs[i]);
            uint dec = IV(IV(vs[i]).asset()).decimals();
            uint scale = dec < 18 ? 10 ** (18 - dec) : 1;
            // BasketLib._valueStable:272-277 scales BOTH by the same factor
            uint bS = b * scale;
            uint ywS = yw * scale;
            emit log_named_uint("--- vault idx", i);
            emit log_named_uint("  asset decimals", dec);
            emit log_named_uint("  shares held ($1M position)", sh);
            emit log_named_uint("  balance (scaled)", bS);
            emit log_named_uint("  yieldWeighted (scaled)", ywS);
            emit log_named_uint("  factor x1e6 (yw/bal)", bS == 0 ? 0 : FullMath.mulDiv(ywS, 1e6, bS));
            rawSum += bS;
            ywSum += ywS;
        }

        emit log_named_uint("AGGREGATE raw   (amounts[14])", rawSum);
        emit log_named_uint("AGGREGATE yield (amounts[0])", ywSum);

        // computeMetrics:83-87 — this is the whole decision
        uint reported = ywSum >= rawSum ? FullMath.mulDiv(1e18, ywSum, rawSum) - 1e18 : 0;
        emit log_named_uint("metrics.yield WOULD BE", reported);

        assertLt(ywSum, rawSum, "expected the 6-dec legs to drag yieldWeighted below raw");
        assertEq(reported, 0, "expected metrics.yield to floor at ZERO");
    }
}
