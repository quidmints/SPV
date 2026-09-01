// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {AaveV3Venue} from "../src/imports/LevVenueBase.sol";
import {IAaveV3DataProvider} from "../src/imports/Interfaces.sol";

/// @notice §CHEAPEST-DOLLAR — `borrowRateRay` is the one accessor the borrow allocator needs, and
///         the only thing that makes "is this venue actually cheaper" checkable ON-CHAIN, which is
///         what lets the reallocator be permissionless instead of keeper-gated.
/// @dev    These are LIVE reads against Aave v3, deliberately. The whole point of the accessor is
///         that it reports the protocol's OWN number rather than a reconstruction of it, so a test
///         against a mock would assert nothing about the property that matters.
contract VenueBorrowRateTest is Test {
    address constant POOL  = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant DATA  = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant GHO   = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address constant USDT  = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    function _venue(address stable) internal returns (AaveV3Venue) {
        return new AaveV3Venue(POOL, DATA, WEETH, stable, address(this), 8000);
    }

    /// THE CONTROL: at `extraBorrow == 0` the accessor must reproduce Aave's OWN live rate exactly.
    /// If the `CalcRatesParams` struct were filled in wrongly this is what catches it — every other
    /// assertion here would still "pass" against a plausible-looking wrong number.
    /// 🔴 §POINT-IN-TIME-IS-NOT-AN-INVARIANT (2026-09-01) — THIS ASSERTED `assertEq(..., live)` AND
    ///    THE WORD "EXACTLY" WAS NEVER TRUE. It passed at the block I first ran it and failed on the
    ///    next full suite by **1.3e-9 relative** (39905845235266631407767588 vs ...183707781360432932).
    ///    ⇒ The two quantities are not the same thing: `borrowRateRay(0)` RECOMPUTES from the reserve's
    ///      CURRENT state via `calculateInterestRates`, while `getReserveData`'s rate was FROZEN at the
    ///      last `updateState()`. Interest accrues in between, `totalDebt` moves, and the recomputed
    ///      rate drifts off the stored one. Nothing is wrong with either number.
    ///    ⚠️ And with no `FORK_BLOCK` pin every run reads a different block, so an exact-equality
    ///      assertion on live market state is a coin flip. The INVARIANT is that the accessor tracks
    ///      Aave's own rate closely enough that venue RANKING is unaffected; 1.3e-9 is ~14 orders of
    ///      magnitude below the smallest spread that could change a routing decision.
    function test_AtZeroItTracksTheLiveRate() public {
        for (uint i; i < 2; ++i) {
            address stable = i == 0 ? GHO : USDT;
            (,,,,,, uint256 live,,,,,) = IAaveV3DataProvider(DATA).getReserveData(stable);
            uint256 ours = _venue(stable).borrowRateRay(0);
            assertGt(live, 0, "control: live rate must be non-zero, else the bound is vacuous");
            uint256 diff = ours > live ? ours - live : live - ours;
            // 1e-6 relative. Tight enough that a real divergence (a wrong reserve, a unit error)
            // still fails loudly; loose enough to survive accrual between two blocks.
            assertLt(diff * 1e6 / live, 1, "accessor must track Aave's own rate to 1e-6");
        }
    }

    /// A borrow MOVES the rate on a sloped market — the whole reason the accessor takes a size.
    /// USDT is sloped (slope1 410, slope2 1000 bps), so a large draw must price strictly higher.
    /// 🔴 §POINT-IN-TIME-IS-NOT-AN-INVARIANT — THE MAGNITUDE WAS ASSERTED AND IT IS MARKET STATE.
    ///    This carried `assertGt(r25 - r0, 10e23, "expected >10bps at 25M")` on the strength of a
    ///    single reading, *"measured ~37bps on 2026-08-30"*. The next full suite measured **3.4bps**
    ///    — a 10x swing in two days, because USDT's utilisation moved relative to the kink and the
    ///    pool's size moved under it. NEITHER number is wrong; the ASSERTION was.
    ///    ⇒ What is invariant is the SHAPE: a sloped market prices our own draw strictly higher.
    ///      That is asserted. The magnitude is logged as an OBSERVATION, because it is a fact about
    ///      Aave's book on the day, not about this accessor.
    ///    ⭐ AND THE OBSERVATION IS LOAD-BEARING FOR THE ROUTER, WHICH IS WHY IT IS EMITTED RATHER
    ///      THAN DROPPED: if our own $25M draw moves the rate only 3.4bps, the APR gain from
    ///      re-allocating between venues is that much smaller relative to the gas + swap cost of
    ///      moving, and the migration threshold has to clear a cost that does not shrink with it.
    function test_ASlopedMarketPricesOurOwnBorrow() public {
        AaveV3Venue v = _venue(USDT);
        uint256 r0 = v.borrowRateRay(0);
        uint256 r25 = v.borrowRateRay(25_000_000e6);
        assertGt(r25, r0, "a 25M draw must raise USDT's rate");
        emit log_named_decimal_uint("USDT impact at +$25M (bps)", (r25 - r0) / 1e23, 0);
    }

    /// GHO is governance-priced: base 375bps, slope1 = slope2 = 0. Our borrow cannot move it.
    /// This is the property that makes GHO the best borrow dollar available, so it is asserted.
    function test_GhoIsFlatBecauseBothSlopesAreZero() public {
        AaveV3Venue v = _venue(GHO);
        assertEq(v.borrowRateRay(0), v.borrowRateRay(5_000_000e18), "GHO must not move with size");
    }

    /// An unfundable draw must NOT return a flattering rate. Aave's own view underflows; we let it.
    function test_AnUnfundableDrawHasNoRate() public {
        AaveV3Venue v = _venue(GHO);
        vm.expectRevert();
        v.borrowRateRay(10_000_000_000e18);   // far beyond GHO's available liquidity
    }
}
