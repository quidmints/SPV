// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

interface IAggV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title §E232 — THE OBSERVATION SOURCE MUST BE CHEAP, AND NOTHING ASSERTED THAT UNTIL NOW
///
/// @notice **THIS FILE EXISTS BECAUSE A GREEN SUITE SHIPPED AN UNEXECUTABLE CONTRACT.** §E222 wired
///         the ring's independent observation to 1inch's OffchainOracle and put the call on the swap
///         path. `getRate` iterates all fourteen registered DEX oracles and their connectors, so one
///         read is a full multi-venue aggregation: **31,722,803 gas against a 30M block limit.**
///         Every ETH swap and repack exceeded an entire block, and `main` carried it for a day.
///
///         The gas figure was PRINTED in a passing test hours before anyone noticed, and read as a
///         PASS. ⇒ **A test whose gas number exceeds a block is not a pass; it is a design
///         refutation wearing a green tick.** The correctness assertions below would ALL have passed
///         against 1inch too — they did. **Only `test_TheReadFitsInABlock` discriminates**, which is
///         the whole point of this file: the property that failed was never the one under test.
contract CurveObserverIsCheapAndSaneTest is Test {
    /// A Curve 3-coin crypto pool (USDC/WBTC/WETH) — an EXEMPLAR for the read cost, not our source.
    /// Ordering READ FROM CHAIN (not assumed): USDC=0, WBTC=1, WETH=2.
    address constant POOL       = 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B;
    address constant CL_ETHUSD  = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    /// `price_oracle(k)` prices coin `k+1` in coin-0 units ⇒ 1 = coin2/coin0 = WETH/USDC.
    uint256 constant ETH_IDX    = 1;
    /// The 1inch read that had to be replaced. Kept as the CONTROL, not as documentation.
    address constant ONEINCH    = 0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8;
    address constant WETH       = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC       = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        // (§LOOSE-ENDS-SCAN) THE SKIP COVERS THE ENV VAR ONLY — NOT THE FORK.
        // This used to wrap `createSelectFork` in the same `try`, so a DEAD RPC or a bad URL was
        // swallowed as "no ETH_RPC_URL set" and the suite reported a skip. An endpoint failure then
        // looks exactly like a deliberate absence, which is §SUITE-RPC-INFLATION in miniature.
        // Now: no env var ⇒ announced skip; env var present but the fork FAILS ⇒ a real failure.
        string memory url;
        try vm.envString("ETH_RPC_URL") returns (string memory u) { url = u; }
        catch { emit log("SKIP: ETH_RPC_URL unset - this is a fork test"); vm.skip(true); return; }
        vm.createSelectFork(url);   // deliberately UNGUARDED: a fork failure must fail, not skip
    }

    function _clWad(address feed) internal view returns (uint) {
        (, int256 ans,,,) = IAggV3(feed).latestRoundData();
        require(ans > 0, "premise: feed is dark");
        return uint(ans) * (10 ** (18 - IAggV3(feed).decimals()));
    }

    function _observe() internal view returns (bool ok, uint priceWad) {
        bytes memory out;
        (ok, out) = POOL.staticcall(abi.encodeWithSignature("price_oracle(uint256)", ETH_IDX));
        if (!ok || out.length < 32) return (false, 0);
        priceWad = abi.decode(out, (uint));
    }

    /// 🔑 **THE ASSERTION THAT WOULD HAVE CAUGHT §E222.** A mainnet block is 30M gas and this read
    ///    sits on the swap path, so it shares a block with the whole trade. 1M is already two orders
    ///    of magnitude of headroom over a storage read and still ~3% of a block.
    function test_TheReadFitsInABlock() public view {
        uint g0 = gasleft();
        (bool ok,) = _observe();
        uint used = g0 - gasleft();
        assertTrue(ok, "premise: the pool answered");
        assertLt(used, 1_000_000, "the observation must not dominate the block it shares");
        // The control: the source this replaced, measured the same way in the same run, so the
        // comparison cannot be blamed on fork state or gas schedule.
        uint g1 = gasleft();
        (bool ok1,) = ONEINCH.staticcall(
            abi.encodeWithSignature("getRate(address,address,bool)", WETH, USDC, false));
        uint oneInchUsed = g1 - gasleft();
        ok1; // the call's SUCCESS is irrelevant — its COST is the finding
        assertGt(oneInchUsed, used * 10,
                 "control: 1inch must be dramatically dearer, else this test proves nothing");
    }

    /// The scaling is right. Curve returns coin1-per-coin0 already WAD-scaled, so the correct
    /// conversion is NONE — a `10**VOL_DECIMALS` step would be a 1e18 double-count, which a 5% range
    /// against Chainlink catches instantly.
    function test_ScalingIsIdentity_andTracksChainlink() public view {
        (bool ok, uint curveWad) = _observe();
        assertTrue(ok, "premise: the pool answered");
        uint cl = _clWad(CL_ETHUSD);
        uint lo = cl * 95 / 100;
        uint hi = cl * 105 / 100;
        assertGt(curveWad, lo, "ETH/USD below a 5% range: wrong index or wrong scaling");
        assertLt(curveWad, hi, "ETH/USD above a 5% range: wrong index or wrong scaling");
    }

    /// ⚠️ **THE INDEX IS THE SILENT FAILURE.** `price_oracle(0)` is WBTC/USDC on this pool, so an
    ///    off-by-one prices ETH at the BTC price — a number that is positive, plausible and ~35x
    ///    wrong. Nothing in the call reverts, so only a cross-source check can see it.
    function test_TheOtherIndexIsBtc_soAnOffByOneIsNotSilent() public view {
        (bool ok, bytes memory out) = POOL.staticcall(
            abi.encodeWithSignature("price_oracle(uint256)", uint256(0)));
        assertTrue(ok && out.length >= 32, "premise: index 0 answers");
        uint wbtcWad = abi.decode(out, (uint));
        (, uint ethWad) = _observe();
        assertGt(wbtcWad, ethWad * 3,
                 "index 0 must be the BTC leg; if these are close, the ordering assumption is stale");
    }

    /// It is a genuinely different MECHANISM from Chainlink: an on-pool EMA of executed trades
    /// versus a pushed feed. Were it Chainlink republished, the deviation test it feeds would be
    /// decorative — the same objection that ruled out reading one feed twice.
    function test_ItIsNotChainlinkRepublished() public view {
        (, uint curveWad) = _observe();
        assertTrue(curveWad != _clWad(CL_ETHUSD), "identical to Chainlink: not an independent observer");
    }
}
