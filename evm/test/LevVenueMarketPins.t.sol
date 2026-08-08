// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {Deploy} from "../script/DeployL1_s.sol";

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
interface IMorphoMarketRead {
    function market(bytes32 id)
        external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares,
                               uint128 totalBorrowAssets, uint128 totalBorrowShares,
                               uint128 lastUpdate, uint128 fee);
    function idToMarketParams(bytes32 id)
        external view returns (address loanToken, address collateralToken,
                               address oracle, address irm, uint256 lltv);
}

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
        (uint128 supply,, uint128 borrow,, uint128 lastUpdate,) = m.market(id);
        assertGt(lastUpdate, 0, "market unlisted -> deploy would createMarket an empty twin");

        // Depth is the property the decoys fail. Assert on LIQUIDITY, since a decoy is well-formed.
        assertGt(supply, 1_000 ether, "supply too thin - this looks like one of the empty 86% decoys");
        assertGt(supply - borrow, 100 ether, "no free WETH liquidity - the borrow leg could not fill");
    }

    /// Read the params back from Morpho and check each field against the deploy constants. This catches a
    /// constant that still hashes to a live id but describes a market we did not mean to join.
    function test_WeethWethVenue_OnChainParamsMatchDeployConstants() public view {
        (address loan, address coll, address oracle, address irm, uint256 lltv) =
            IMorphoMarketRead(MORPHO_BLUE).idToMarketParams(EXPECTED_ID);

        assertEq(loan,   address(WETH),      "loanToken drifted - debt must be ETH-denominated");
        assertEq(coll,   WEETH,              "collateralToken drifted");
        assertEq(oracle, WEETH_WETH_ORACLE,  "oracle constant drifted from the live market");
        assertEq(irm,    ADAPTIVE_IRM,       "irm constant drifted from the live market");
        assertEq(lltv,   MORPHO_LLTV_945,    "lltv constant drifted - 86% would be a DIFFERENT market");
    }

    /// @dev The LLTV is deliberately NOT the 86% every USDC leg uses. Pinning the difference stops a
    ///      well-meaning "consistency" edit from silently repointing this venue at an empty decoy.
    function test_WeethWethVenue_LltvIsNotTheStableLegLltv() public pure {
        assertTrue(MORPHO_LLTV_945 != MORPHO_LLTV_86, "945 collapsed onto the 86% stable-leg LLTV");
        assertEq(MORPHO_LLTV_945, 0.945e18, "LLTV is not the market's actual 94.5%");
    }
}
