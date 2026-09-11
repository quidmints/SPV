// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {MarketParams} from "../src/imports/Interfaces.sol";

/// @notice §6 CHECK 3 (TARGET-DESIGN) — **WHAT DOES CARRY ACTUALLY COST AT OUR NOTIONAL, ON THE
///         VENUES WE DEPLOY?** `borrowRateRay(extraBorrow)` has zero production callers and had
///         never been called at size. Two things depend on the answer and neither can be settled
///         without it:
///           1. §3's premise that *"transient is free"* — the balance sheet absorbs a swap by
///              borrowing, and holds the borrow until flow reverses. If carry is expensive at our
///              size that premise fails and the sell-in leg needs a time-priced charge, not just a
///              capacity one.
///           2. `LevBase._bandBps`, which is a constant placeholder `300` since §DERIVED-BAND's
///              `kLvrWad` was deleted with θ. A no-trade band is the LTV drift you tolerate before
///              re-levering pays for itself, so it is CARRY over round-trip cost — the owner's
///              ruling that *"gas has nothing to do with lvr"* rules the other two derivations out.
///
/// @dev    THE VENUE SET IS THE DEPLOYED ONE, read from `script/DeployL1_s.sol`, not invented:
///           · ETH   — `MorphoEscrowVenue{loanToken: RLUSD, collateral: weETH}`
///           · ETH   — `MorphoEscrowVenue{loanToken: PYUSD, collateral: weETH}`
///         (The two Aave V3 venues that were ladders here left with the AAVE integration; the BTC
///         leg currently has no venue at all.)
///
/// ⚠️ **EVERY NUMBER BELOW IS AN OBSERVATION, NOT AN INVARIANT** — the standing lesson of
///    §POINT-IN-TIME-IS-NOT-AN-INVARIANT, which this file obeys rather than rediscovers: a previous
///    suite asserted a measured 37 bps impact and met 3.4 bps two days later, because utilisation
///    moved relative to the kink. What is asserted here is SHAPE (monotone in size, and an
///    unfundable draw has no rate). The levels are emitted for the two decisions above.
contract CarryAtOurNotionalTest is Test {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant RLUSD_WEETH_ORACLE = 0x6ab351FfDe101BB24a97332f4f7162C1711f110b;
    address constant PYUSD_WEETH_ORACLE = 0x221898dA0890Fc5fb6c890Fcdc051FA97946eE11;
    uint256 constant LLTV86 = 0.86e18;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    /// RAY/yr → bps, so every venue prints in one unit whatever its native model is.
    function _bps(uint256 ray) internal pure returns (uint256) { return ray / 1e23; }

    function _morpho(address loan, address oracle) internal returns (MorphoEscrowVenue) {
        return new MorphoEscrowVenue(MORPHO, MarketParams({
            loanToken: loan, collateralToken: WEETH,
            oracle: oracle, irm: ADAPTIVE_IRM, lltv: LLTV86 }), address(this));
    }

    /// Walk a notional ladder, printing the rate and the marginal cost of OUR OWN draw.
    /// `try` on every rung: a venue that cannot fund the rung has NO rate (by design — see
    /// `VenueCannotFund`), and that refusal is itself the answer for that size.
    function _ladder(string memory name, address venue, uint256 unit) internal {
        // 🔴 THE LADDER STARTED AT $1M AND I DREW A CONCLUSION BELOW IT (2026-09-11). "PYUSD cannot
        //    fund $1M" was measured; "the Morpho venues are decorative" was NOT — nothing here had
        //    looked under $1M. The low rungs are the correction, and they change the answer.
        uint256[9] memory sizes = [uint256(0.05e6), 0.1e6, 0.25e6, 0.5e6, 1e6, 5e6, 10e6, 25e6, 100e6];
        emit log_string(string.concat("  --- ", name));
        uint256 r0;
        try ILevRate(venue).borrowRateRay(0) returns (uint256 r) {
            r0 = r;
            emit log_named_uint("    base APR (bps)            ", _bps(r0));
        } catch { emit log_string("    base APR: REVERTED"); return; }
        for (uint i; i < sizes.length; ++i) {
            uint256 draw = sizes[i] * unit;
            try ILevRate(venue).borrowRateRay(draw) returns (uint256 r) {
                emit log_named_uint(
                    string.concat("    +$", vm.toString(sizes[i] / 1e4), "k -> MARGINAL APR (bps)"), _bps(r));
            } catch {
                emit log_named_string(
                    string.concat("    +$", vm.toString(sizes[i] / 1e4), "k"), "UNFUNDABLE (no rate)");
            }
        }
    }

    /// @notice THE MEASUREMENT. Both deployed venues, one ladder each.
    function test_CarryLadderAcrossEveryDeployedVenue() public {
        emit log_string("=== CARRY AT OUR NOTIONAL (RAY/yr -> bps) ===");
        _ladder("Morpho  weETH coll / RLUSD debt",           address(_morpho(RLUSD, RLUSD_WEETH_ORACLE)), 1e18);
        _ladder("Morpho  weETH coll / PYUSD debt",           address(_morpho(PYUSD, PYUSD_WEETH_ORACLE)), 1e18);
    }

    /// THE SHAPE, WHICH *IS* INVARIANT: a sloped market prices our own draw strictly higher, so the
    /// optimum across venues is INTERIOR and a single-venue allocator is leaving money on the table.
    /// (This is the property §MULTI-VENUE rests on, asserted rather than assumed.)
    function test_OurOwnDrawRaisesTheRateOnASlopedMarket() public {
        MorphoEscrowVenue v = _morpho(RLUSD, RLUSD_WEETH_ORACLE);
        uint256 r0 = v.borrowRateRay(0);
        uint256 r1 = v.borrowRateRay(1_000_000e18);
        assertGt(r0, 0, "control: a zero base rate would make the comparison vacuous");
        assertGt(r1, r0, "the adaptive curve is sloped: our own $1M draw must price strictly higher");
    }

    /// AND THE REFUSAL IS PART OF THE ANSWER: an unfundable draw must not return a flattering rate,
    /// because a flattering number for a draw that cannot happen is the exact input that would make
    /// an allocator pick that venue.
    function test_AnUnfundableDrawHasNoRate() public {
        MorphoEscrowVenue v = _morpho(RLUSD, RLUSD_WEETH_ORACLE);
        vm.expectRevert();
        v.borrowRateRay(100_000_000_000e18);
    }
}

interface ILevRate { function borrowRateRay(uint256) external view returns (uint256); }
