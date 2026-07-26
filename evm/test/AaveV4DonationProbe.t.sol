// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {AaveV4Venue} from "../src/AaveV4Venue.sol";

interface IERC20A {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// EMPIRICAL donation/inflation probe against the LIVE Aave V4 Hub/Spoke (no mocks, no reasoning-from-comments).
/// Question: is `getUserSuppliedAssets` computed as (userShares × interest-accrual index) — donation-IMMUNE, the
/// classic aToken property — or as (userShares × totalUnderlying/totalShares) — 4626-style, donation-INFLATABLE?
/// We supply, snapshot a user's reported supplied assets, DONATE a large chunk of the underlying to every plausible
/// holder (spoke + hub), and re-read. If the read moves, the V4 hub/spoke is donation-manipulable and the basket's
/// Aave legs (Aux.aaveBalance → getUserSuppliedAssets) need a growth cap; if flat, they don't.
contract AaveV4DonationProbeTest is Test {
    address constant SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address constant HUB   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    AaveV4Venue venue;
    address lp  = address(0xB0B);
    address lp2 = address(0xCa11);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        venue = new AaveV4Venue(SPOKE, HUB, WETH, USDC, address(this), 8000);
    }

    function test_AaveV4_DonationInflation() public {
        // Two isolated LPs each supply 5 WETH.
        deal(WETH, address(venue), 5 ether); venue.supply(lp,  5 ether);
        deal(WETH, address(venue), 5 ether); venue.supply(lp2, 5 ether);

        uint c0  = venue.collateralOf(lp);
        uint c0b = venue.collateralOf(lp2);
        emit log_named_uint("lp  supplied before (wei)", c0);
        emit log_named_uint("lp2 supplied before (wei)", c0b);

        // DONATE 500 WETH (100x a position) directly to every plausible underlying holder.
        deal(WETH, address(this), 500 ether);
        IERC20A(WETH).transfer(SPOKE, 250 ether);
        IERC20A(WETH).transfer(HUB,   250 ether);

        uint c1  = venue.collateralOf(lp);
        uint c1b = venue.collateralOf(lp2);
        emit log_named_uint("lp  supplied after donate (wei)", c1);
        emit log_named_uint("lp2 supplied after donate (wei)", c1b);
        emit log_named_int ("lp  delta (wei)", int(c1) - int(c0));
        emit log_named_int ("lp2 delta (wei)", int(c1b) - int(c0b));
        emit log_named_uint("donated (wei)", 500 ether);

        // A rebasing/interest-index venue is donation-IMMUNE: the 500-WETH donation must not inflate either
        // user's reported supplied assets by more than dust. If this fails, V4 getUserSuppliedAssets is
        // share-price (4626-style) and the basket's Aave legs are donation-manipulable → growth cap required.
        assertApproxEqAbs(c1,  c0,  1e12, "lp supplied inflated by donation (V4 spoke is 4626-style!)");
        assertApproxEqAbs(c1b, c0b, 1e12, "lp2 supplied inflated by donation (V4 spoke is 4626-style!)");
    }

    /// VECTOR 2 (user-requested): the INDEX/RATE manipulation vector. getUserSuppliedAssets = shares x
    /// liquidity-index; the index accrues per-second from borrow interest. Can an attacker make the basket's
    /// reported Aave balance JUMP within a block by spiking utilization (flash-manipulable), or is it time-
    /// integrated (a same-block util spike does nothing; only real elapsed time accrues real yield)? Fork-test it.
    function test_AaveV4_IndexRateManipulation() public {
        deal(WETH, address(venue), 5 ether); venue.supply(lp, 5 ether);
        uint c0 = venue.collateralOf(lp);

        // Best-effort utilization spike (may hit an Aave borrow/supply cap on the fork — irrelevant to the
        // point): a (USDC-collateral, WETH-debt) venue borrows WETH to spike WETH utilization, SAME BLOCK.
        AaveV4Venue atk = new AaveV4Venue(SPOKE, HUB, USDC, WETH, address(this), 8000);
        deal(USDC, address(atk), 5_000_000e6);
        try atk.supply(address(0xA771), 5_000_000e6) {
            try atk.borrow(address(0xA771), 50 ether) returns (uint g) { emit log_named_uint("spiked util, borrowed WETH", g); }
            catch { emit log_string("borrow capped on fork - util spike skipped (point stands)"); }
        } catch { emit log_string("supply capped on fork"); }
        uint c1 = venue.collateralOf(lp);                    // SAME BLOCK read
        emit log_named_uint("victim WETH t0", c0);
        emit log_named_uint("victim WETH same-block (post any action)", c1);
        // Same block => ZERO elapsed time => the liquidity index cannot have accrued => the reported balance is
        // EXACTLY unchanged, no matter what happened to utilization/rate this block. Not flash/spot-manipulable.
        assertEq(c1, c0, "SAME-BLOCK index balance changed (FLASH-MANIPULABLE!)");

        // Real elapsed time accrues real yield at the (now-elevated) rate. This is genuine value, not phantom;
        // logged to size how fast a growth cap would need to allow. Bounded by rate*time (no instantaneous jump).
        vm.warp(block.timestamp + 30 days);
        uint c2 = venue.collateralOf(lp);
        emit log_named_uint("victim WETH after 30d real accrual", c2);
        emit log_named_uint("30d accrual bps (real yield, bounded)", c2 > c0 ? (c2 - c0) * 10000 / c0 : 0);
    }
}
