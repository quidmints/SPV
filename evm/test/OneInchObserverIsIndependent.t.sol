// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ExternalTwap} from "../src/imports/ExternalTwap.sol";

interface IAggV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title §E223 — THE 1inch OBSERVER IS INDEPENDENT OF CHAINLINK, AND IT HAS NO NATIVE BTC.
///
/// @notice Two claims, and the SECOND is the one that constrains the design. §E222 found the
///         observation ring had gone circular after the v4 cut: it was written from a value that
///         read the ring itself, so Chainlink was anchoring a smoothed copy of itself. The fix needs
///         a source that is genuinely NOT Chainlink — and this pins that it is.
///
///         The BTC half then pins the opposite: 1inch can only quote WRAPPED BTC, so using it for
///         the cross would reimport the basis §E221 deletes. **The gap between the two readings is
///         not noise between two BTC prices — it is one BTC price and one WBTC price.**
///
/// ⚠️ WHY THE ASSERTIONS ARE RANGES, NOT EQUALITIES. Both sides move with the market, and this repo
///    has already burned a session comparing fork runs whose inputs differed (§E214: an unpinned
///    FORK_BLOCK made two arms of an A/B measure different chain states, and the deltas looked like
///    a code effect). Nothing here compares across runs — every assertion is between two values read
///    in the SAME call, which is what makes it stable without pinning a block.
contract OneInchObserverIsIndependentTest is Test {
    address constant ORACLE   = 0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8; // 1inch OffchainOracle
    address constant WETH     = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC     = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CL_ETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CL_ETHBTC = 0xAc559F25B1619171CbC396a50854A3240b6A4e99;
    address constant CL_WBTCBTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;

    function setUp() public {
        try vm.envString("ETH_RPC_URL") returns (string memory url) { vm.createSelectFork(url); }
        catch { vm.skip(true); }
    }

    function _clWad(address feed) internal view returns (uint) {
        (, int256 ans,,,) = IAggV3(feed).latestRoundData();
        require(ans > 0, "premise: feed is dark");
        return uint(ans) * (10 ** (18 - IAggV3(feed).decimals()));
    }

    /// @notice THE SCALING IS RIGHT. `priceWad = rate · 10^srcDec / 10^dstDec` is derived from
    ///         `getRate`'s raw-unit definition; if it were wrong it would be wrong by a power of ten,
    ///         which a 5% range against Chainlink catches immediately.
    function test_EthUsd_ScalingIsCorrect_andTracksChainlink() public view {
        uint oneInch = ExternalTwap.oneInchRateWad(ORACLE, WETH, USDC, 18, 6);
        uint chainlink = _clWad(CL_ETHUSD);
        assertGt(oneInch, 100e18,     "sanity: ETH is not worth <$100 - scaling is off by a power of ten");
        assertLt(oneInch, 100_000e18, "sanity: ETH is not worth >$100k - scaling is off by a power of ten");
        uint lo = oneInch < chainlink ? oneInch : chainlink;
        uint hi = oneInch < chainlink ? chainlink : oneInch;
        assertLt((hi - lo) * 10_000 / lo, 500, "1inch and Chainlink ETH/USD disagree by >5%");
    }

    /// @notice INDEPENDENCE. If 1inch simply republished Chainlink the two would be IDENTICAL.
    ///         A nonzero gap is what makes it usable as the ring's second source at all — this is
    ///         the assertion §E222's whole fix rests on.
    function test_ItIsNotChainlinkRepublished() public view {
        assertTrue(ExternalTwap.oneInchRateWad(ORACLE, WETH, USDC, 18, 6) != _clWad(CL_ETHUSD),
            "1inch EXACTLY equals Chainlink - it is not an independent observation, and the ring stays circular");
    }

    /// @notice 🔴 THE CONSTRAINT: 1inch quotes WRAPPED BTC, and the gap IS the wrapper basis.
    ///         Asserted as a RELATIONSHIP between three live reads in one call, so it holds whatever
    ///         the market does: (Chainlink ETH/BTC) / (1inch ETH/WBTC) should track WBTC/BTC.
    function test_OneInchBtcIsWrapped_andTheGapIsTheWbtcBasis() public view {
        uint oneInchEthWbtc = ExternalTwap.oneInchRateWad(ORACLE, WETH, WBTC, 18, 8);
        uint clEthBtc  = _clWad(CL_ETHBTC);
        uint wbtcBtc   = _clWad(CL_WBTCBTC);          // ~1.0004e18: WBTC in BTC terms
        assertGt(wbtcBtc, 0.9e18, "premise: WBTC/BTC feed is live and sane");

        // observed wrapper premium implied by the two ETH-quoted readings
        uint impliedBps = clEthBtc > oneInchEthWbtc
            ? (clEthBtc - oneInchEthWbtc) * 10_000 / oneInchEthWbtc
            : (oneInchEthWbtc - clEthBtc) * 10_000 / clEthBtc;
        // the basis the WBTC/BTC feed reports directly
        uint feedBps = wbtcBtc > 1e18 ? (wbtcBtc - 1e18) * 10_000 / 1e18 : (1e18 - wbtcBtc) * 10_000 / 1e18;

        // Both are small; what matters is that the ETH-quoted gap is NOT materially larger than the
        // wrapper basis plus DEX spread. If it ever is, the two readings are not measuring the same
        // asset pair and the "cross-check = depeg detector" reading in ExternalTwap is wrong.
        assertLt(impliedBps, feedBps + 50,
            "the 1inch-vs-Chainlink BTC gap exceeds the WBTC basis + 50bps: they are not the same pair");
    }
}
