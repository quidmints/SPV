// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {AaveV3Venue, MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {IAaveV3Pool, VenuePosition, IERC20Min, MarketParams} from "../src/imports/Interfaces.sol";

/// @notice §CHEAPEST-DOLLAR — `position()` is what lets ONE collateral position carry SEVERAL debts
///         without any basket accounting of ours. The property under test is exactly that: put two
///         DIFFERENT debts on one Aave account and check the venue reports their aggregate, priced
///         the way Aave prices it.
/// @dev    Live Aave v3, deliberately — a mock would assert nothing about the property, since the
///         property IS "we report the lender's own valuation".
contract VenuePositionTest is Test {
    address constant POOL  = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant DATA  = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant GHO   = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address constant USDT  = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant LP    = address(0xBEEF);

    AaveV3Venue venue;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        venue = new AaveV3Venue(POOL, DATA, WEETH, GHO, address(this), 8000);
    }

    function _seed(uint256 coll) internal {
        deal(WEETH, address(venue), coll);   // MANAGER sends collateral to the venue first
        venue.supply(LP, coll);
    }

    /// An unopened venue is genuinely empty, and must say so rather than revert. This is what makes
    /// the pre-escrow case cost no special-casing anywhere upstream.
    function test_AnUnopenedVenueIsEmptyNotReverting() public view {
        VenuePosition memory p = venue.position();
        assertEq(p.collateral, 0); assertEq(p.debt, 0); assertEq(p.liqThresholdBps, 0);
    }

    /// THE PROPERTY: two DIFFERENT debts on one account aggregate into one reported debt.
    function test_TwoDifferentDebtsOnOneAccountAggregate() public {
        _seed(100e18);
        VenuePosition memory p0 = venue.position();
        assertGt(p0.collateral, 0, "collateral must register");
        assertEq(p0.debt, 0, "control: nothing borrowed yet");

        venue.borrow(LP, 50_000e18);                       // debt #1: GHO, via the venue
        VenuePosition memory p1 = venue.position();
        assertApproxEqRel(p1.debt, 50_000e18, 0.02e18, "GHO leg mispriced");

        // debt #2: USDT, drawn on the SAME Aave account. This is the shared-pool property the
        // whole allocator design rests on, and nothing in the venue had to know about it.
        address escrow = address(venue.poolEscrow());
        vm.prank(escrow);
        IAaveV3Pool(POOL).borrow(USDT, 50_000e6, 2, 0, escrow);

        VenuePosition memory p2 = venue.position();
        assertApproxEqRel(p2.debt, 100_000e18, 0.02e18, "aggregate of two debts is wrong");
        assertGt(p2.debt, p1.debt, "a second debt in a DIFFERENT asset must raise reported debt");
        assertEq(p2.collateral, p1.collateral, "borrowing must not change collateral");
    }

    /// §V4-IS-FULL — a headroom NUMBER is worth nothing unless it PREDICTS THE CAP REVERT, so this
    /// ties it to behaviour rather than restating the two reads it is computed from (which would be
    /// tautological). Supplying inside the headroom must work; supplying past it must revert.
    function test_HeadroomPredictsTheCapRevert() public {
        uint256 room = venue.supplyHeadroom();
        assertGt(room, 0, "control: weETH must have room, else both halves below are vacuous");
        assertLt(room, 1_350_000e18, "control: headroom cannot exceed the cap itself");

        deal(WEETH, address(venue), room / 2);
        venue.supply(LP, room / 2);                       // comfortably inside: must succeed
        assertGt(venue.position().collateral, 0, "supply inside the headroom should register");

        uint256 left = venue.supplyHeadroom();
        assertLt(left, room, "headroom must FALL after we consume some of it");
        deal(WEETH, address(venue), left + 1_000e18);
        vm.expectRevert();                                // past the cap: Aave must refuse
        venue.supply(LP, left + 1_000e18);
    }

    /// THE HAZARD `positionOf` EXISTS FOR: an LP's debt share and collateral share are INDEPENDENT
    /// fractions, so per-LP LTV is NOT pool LTV. Two LPs put up identical collateral and only one
    /// borrows; if `positionOf` were (wrongly) returning pool-level numbers, both would report the
    /// same health and the borrower's risk would be smeared across someone who took none.
    function test_PerLpHealthIsNotPoolHealth() public {
        address LP2 = address(0xCAFE);
        _seed(100e18);                                   // LP supplies
        deal(WEETH, address(venue), 100e18);
        venue.supply(LP2, 100e18);                       // LP2 supplies the SAME collateral
        venue.borrow(LP, 50_000e18);                     // ...and only LP borrows

        VenuePosition memory pool = venue.position();
        VenuePosition memory a = venue.positionOf(LP);
        VenuePosition memory b = venue.positionOf(LP2);

        // collateral splits evenly; debt does not split at all
        assertApproxEqRel(a.collateral, b.collateral, 0.01e18, "collateral should be ~50/50");
        assertApproxEqRel(a.debt, pool.debt, 0.01e18, "the borrower owns ~all of the debt");
        assertEq(b.debt, 0, "the non-borrower must owe NOTHING");

        // and therefore the two LPs' LTVs differ, while pool LTV is between them
        uint256 ltvA = a.debt * 10_000 / a.collateral;
        uint256 ltvPool = pool.debt * 10_000 / pool.collateral;
        assertGt(ltvA, ltvPool, "borrower must be riskier than the pool average");
        assertGt(ltvA, 0, "control: a zero LTV would make the comparison vacuous");
    }

    /// `liqThresholdBps` is live and position-weighted. With weETH as the only collateral it must
    /// equal weETH's own reserve threshold (8000), which is a real cross-check on the field rather
    /// than a restatement of the constructor argument.
    function test_TheThresholdIsLiveNotTheConstructorConstant() public {
        _seed(100e18);
        assertEq(venue.position().liqThresholdBps, 8000, "should be weETH's live reserve LT");
    }
}

/// A trivial fixed-price Morpho oracle. Morpho's convention: collateralValue = coll * price / 1e36,
/// expressed in LOAN-token units — so for 18-dec collateral against a 6-dec loan token the scale is
/// 1e24 per unit of price.
contract FixedMorphoOracle {
    uint256 public immutable P;
    constructor(uint256 usdcPerWeeth) { P = usdcPerWeeth * 1e24; }
    function price() external view returns (uint256) { return P; }
}

/// @notice The Morpho half of `position()`. A Morpho market is ISOLATED and single-asset, so the
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
