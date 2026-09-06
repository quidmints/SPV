// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {IMorphoStaticTyping as IMorphoMarketRead, MarketParams, Id} from "../src/imports/Interfaces.sol";
import {Deploy} from "../script/DeployL1_s.sol";
import {IAaveV4Spoke, IAaveV4Hub} from "../src/imports/Interfaces.sol";

/// @notice Pins the LIVE Morpho market that `Deploy._ethLevVenues` joins for the ETH-denominated-debt
///         lev venue (collateral weETH, debt WETH).
///
/// WHY THIS FILE EXISTS. Before it, **no test imported anything from `script/`** — measured 2026-08-09,
/// zero `import` lines across `test/*.sol` referenced that directory. So the deploy script's market
/// constants were entirely unguarded: a 1,099-test lev/venue run passed with 0 failures immediately
/// after the weETH/WETH venue was added, and would have passed identically had every constant in it
/// been wrong. That run could not distinguish working from broken, which is the only reason this file
/// is a fork test against live state rather than a unit test.
///
/// WHAT IT ACTUALLY GUARDS — the failure mode is silent, which is what earns the check:
/// `_mkMorphoVenue` does `if (lastUpdate == 0) createMarket(mp)`. So a WRONG constant does not revert.
/// It CREATES a brand-new empty market and wraps a venue around it, and every structural assertion
/// downstream still passes — the venue exists, is allowlisted, reports the right tokens. It simply can
/// never fill a borrow. TWO REAL DECOY MARKETS make this concrete rather than hypothetical: mainnet
/// carries two other correctly-formed weETH/WETH markets at 86% LLTV holding $0.0002 and $2,095.
/// The discriminator is LIQUIDITY, not well-formedness, so this file asserts on depth.
///
/// It inherits `Deploy` so it reads the SHIPPING constants. Asserting a copy pasted into the test would
/// verify the copy and let the deploy script drift, which is the exact bug class it exists to catch.
/// (`Test` and `Script` both descend from forge-std's `CommonBase`, so the diamond resolves.)

contract LevVenueMarketPins is ForkPin, Deploy {
    // The deep market these constants must resolve to. Verified on-chain 2026-08-09.
    bytes32 constant EXPECTED_ID = 0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7;
    address constant WEETH       = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// @dev Rebuilds the id the way Morpho itself does — a market id IS `keccak(abi.encode(params))` —
    ///      from the constants the deploy script will actually use.
    function _idFromDeployConstants() internal view returns (bytes32) {
        return keccak256(abi.encode(
            address(WETH),        // loanToken   — ETH-denominated debt, the whole point of this venue
            WEETH,                // collateralToken
            WEETH_WETH_ORACLE,
            ADAPTIVE_IRM,
            MORPHO_LLTV_945
        ));
    }

    /// The constants resolve to the intended market, and that market is the DEEP one, not a decoy.
    function test_WeethWethVenue_JoinsTheDeepLiveMarket() public view {
        bytes32 id = _idFromDeployConstants();
        assertEq(id, EXPECTED_ID, "deploy constants no longer resolve to the pinned weETH/WETH market");

        IMorphoMarketRead m = IMorphoMarketRead(MORPHO_BLUE);

        // The market must ALREADY exist, or `_mkMorphoVenue` silently creates an empty twin.
        (uint128 supply,, uint128 borrow,, uint128 lastUpdate,) = m.market(Id.wrap(id));
        assertGt(lastUpdate, 0, "market unlisted -> deploy would createMarket an empty twin");

        // Depth is the property the decoys fail. Assert on LIQUIDITY, since a decoy is well-formed.
        assertGt(supply, 1_000 ether, "supply too thin - this looks like one of the empty 86% decoys");
        assertGt(supply - borrow, 100 ether, "no free WETH liquidity - the borrow leg could not fill");
    }

    /// Read the params back from Morpho and check each field against the deploy constants. This catches a
    /// constant that still hashes to a live id but describes a market we did not mean to join.
    function test_WeethWethVenue_OnChainParamsMatchDeployConstants() public view {
        (address loan, address coll, address oracle, address irm, uint256 lltv) =
            IMorphoMarketRead(MORPHO_BLUE).idToMarketParams(Id.wrap(EXPECTED_ID));

        assertEq(loan,   address(WETH),      "loanToken drifted - debt must be ETH-denominated");
        assertEq(coll,   WEETH,              "collateralToken drifted");
        assertEq(oracle, WEETH_WETH_ORACLE,  "oracle constant drifted from the live market");
        assertEq(irm,    ADAPTIVE_IRM,       "irm constant drifted from the live market");
        assertEq(lltv,   MORPHO_LLTV_945,    "lltv constant drifted - 86% would be a DIFFERENT market");
    }

    /// The Aave ETH leg must be DEEP, not merely configured. A correctly-configured EMPTY market is the
    /// failure mode that has now appeared THREE times: two 86% weETH/WETH Morpho markets holding $0.0002
    /// and $2,095, and Euler's eWETH-14 -- which accepts the eweETH-1 escrow at 67% LTVBorrow / 77%
    /// LTVLiquidation with a renounced governor, and has totalAssets, cash AND totalBorrows all ZERO.
    /// Every structural check passes on all three. Only depth separates them, so only depth is asserted.
    /// \U0001f534 **§S12 — THIS USED TO ASSERT ON `supplied - debt` AND CALL IT "free WETH". IT IS NOT.**
    ///    MEASURED 2026-09-05 at `FORK_BLOCK=25800000`: `getReserveSuppliedAssets(0)` and
    ///    `getReserveTotalDebt(0)` are both **this spoke's own book against the hub** — they equal
    ///    `hub.getSpokeAddedAssets(aid, spoke)` and `hub.getSpokeTotalOwed(aid, spoke)` to the unit —
    ///    so their difference is a NET INTERCOMPANY POSITION, not cash. On this very reserve it read
    ///    **27,608 WETH** of "free" liquidity against **5,635 WETH** actually held by the hub: a 5x
    ///    over-statement, on the exact axis (`the discriminator is LIQUIDITY`) this file exists to test.
    ///    ⚠️ It also **underflow-reverts** whenever a spoke owes more than it added, which is an ordinary
    ///    state — the USDC reserve on this same spoke sits at 123.1% at this block.
    /// \U0001f511 In v4's hub-and-spoke shape the HUB custodies the asset, so hub liquidity is the only
    ///    number that answers "can the borrow leg fill". Verified the same day against the hub's raw
    ///    token balance: drift **0** on both reserves read here.
    function test_AaveV4Legs_HaveRealDepth() public view {
        IAaveV4Spoke sp = IAaveV4Spoke(aaveSpoke);
        IAaveV4Hub   hb = IAaveV4Hub(aaveHub);
        // WETH -- the leg we BORROW. Depth is the hub's cash for the asset, shared across its spokes.
        assertGt(hb.getAssetLiquidity(hb.getAssetId(address(WETH))), 100 ether,
            "no free WETH on the Aave v4 hub - the borrow leg cannot fill");
        // weETH is supply-only here (borrowable=false, correctly). Depth still matters: an empty collateral
        // reserve means no liquidator has any reason to be watching it. Kept SPOKE-scoped deliberately —
        // the question is whether anyone uses this reserve through THIS spoke, not hub-wide custody.
        assertGt(sp.getReserveSuppliedAssets(2), 10 ether, "weETH collateral reserve is empty");
    }

    /// The collateral factor must be live and sane, or LevManager sizes positions off nothing.
    function test_AaveV4_CollateralFactorIsLive() public view {
        IAaveV4Spoke sp = IAaveV4Spoke(aaveSpoke);
        (uint24 cfg,,,,) = sp.getReserveConfig(2);
        (uint16 cf,,)    = sp.getDynamicReserveConfig(2, uint32(cfg));
        assertGt(cf, 0, "weETH collateralFactor 0 - positions would size off zero");
        assertLe(cf, 10_000, "collateralFactor above 100% is not a bps value");
    }

    /// @dev The LLTV is deliberately NOT the 86% every USDC leg uses. Pinning the difference stops a
    ///      well-meaning "consistency" edit from silently repointing this venue at an empty decoy.
    function test_WeethWethVenue_LltvIsNotTheStableLegLltv() public pure {
        assertTrue(MORPHO_LLTV_945 != MORPHO_LLTV_86, "945 collapsed onto the 86% stable-leg LLTV");
        assertEq(MORPHO_LLTV_945, 0.945e18, "LLTV is not the market's actual 94.5%");
    }
}
