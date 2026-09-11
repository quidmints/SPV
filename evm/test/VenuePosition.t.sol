// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {VenuePosition, IERC20Min, MarketParams} from "../src/imports/Interfaces.sol";

/// A trivial fixed-price Morpho oracle. Morpho's convention: collateralValue = coll * price / 1e36,
/// expressed in LOAN-token units — so for 18-dec collateral against a 6-dec loan token the scale is
/// 1e24 per unit of price.
contract FixedMorphoOracle {
    uint256 public immutable P;
    constructor(uint256 usdcPerWeeth) { P = usdcPerWeeth * 1e24; }
    function price() external view returns (uint256) { return P; }
}

/// @notice `position()` on the Morpho venue. A Morpho market is ISOLATED and single-asset, so the
///         venue's quote unit is simply the loan token — and this asserts that the numbers come out
///         in that unit, at Morpho's OWN oracle, rather than in some unit of ours.
contract MorphoVenuePositionTest is Test {
    address constant MORPHO       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant WEETH        = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant LP           = address(0xBEEF);

    MorphoEscrowVenue venue;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        MarketParams memory mp = MarketParams({
            loanToken: USDC, collateralToken: WEETH,
            oracle: address(new FixedMorphoOracle(4000)), irm: ADAPTIVE_IRM, lltv: 0.86e18});
        IMorphoMkt(MORPHO).createMarket(mp);
        deal(USDC, address(this), 5_000_000e6);
        IERC20Min(USDC).approve(MORPHO, 5_000_000e6);
        IMorphoMkt(MORPHO).supply(mp, 5_000_000e6, 0, address(this), "");
        venue = new MorphoEscrowVenue(MORPHO, mp, address(this));
    }

    /// REGRESSION: `tba += uint128(extraBorrow)` narrowed WITHOUT a check, and an explicit cast is
    /// not covered by 0.8's checked arithmetic — so a draw above 2**128 wrapped to a small number and
    /// came back with a flattering rate instead of a revert. An allocator fed that would pick a venue
    /// that cannot fund it. Both values below wrap to something small if the cast is unguarded.
    function test_AnAbsurdDrawRevertsRatherThanWrapping() public {
        vm.expectRevert();
        venue.borrowRateRay(uint256(type(uint128).max) + 1);      // wraps to 0
        vm.expectRevert();
        venue.borrowRateRay(uint256(type(uint128).max) + 1_000e6); // wraps to 1_000e6 - a FUNDABLE size
    }

    function test_ItReportsInLoanTokenTermsAtMorphosOwnOracle() public {
        deal(WEETH, address(venue), 100e18);
        venue.supply(LP, 100e18);
        // 100 weETH at 4,000 USDC each = 400,000 USDC of collateral, lifted to 18 decimals.
        VenuePosition memory p = venue.position();
        assertApproxEqRel(p.collateral, 400_000e18, 0.001e18, "collateral not in loan-token terms");
        assertEq(p.debt, 0, "control: nothing borrowed yet");
        assertEq(p.liqThresholdBps, 8600, "LLTV 0.86e18 must render as 8600 bps");

        venue.borrow(LP, 50_000e6);
        assertApproxEqRel(venue.position().debt, 50_000e18, 0.001e18, "debt not in loan-token terms");
    }
}

interface IMorphoMkt {
    function createMarket(MarketParams memory) external;
    function supply(MarketParams memory, uint256, uint256, address, bytes memory)
        external returns (uint256, uint256);
}
