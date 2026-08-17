// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {AllesFixture} from "./Alles.t.sol";

interface IV4626 { function convertToAssets(uint) external view returns (uint); function balanceOf(address) external view returns (uint); }

/// @notice §E197. THE VAULT-HEALTH CLOCK MUST START ON ORGANIC TRAFFIC, NOT ON A POKE.
///
///         §E152-nerve's sharp finding was never "the dwell is 30 minutes" — it was that `flaggedAt` is
///         written ONLY by `pokeVaultHealthBody`, so the 30-minute `EVAC_DWELL` had an UNBOUNDED START:
///         the clock could not begin until somebody called the permissionless poke, and nothing ever did.
///         A scheduler was the obvious fix and the wrong one; the measurement was already being made.
///
///         `_illiquidLoss()` loops every 4626 leg computing `convertToAssets` (the poke's `reported`) and
///         `_withdrawableOf` (its `liquid`) — the poke's two inputs, already paid for — and kept only the
///         aggregate. It now also reports the WORST leg, and the two non-view callers (`_redeemQuote`,
///         `redeemableBody`) flag it. Detection rides free on redeem traffic; EVACUATION still requires the
///         deliberate `pokeVaultHealth`, so a user's redeem can never drain vaults mid-call.
///
///         ⚠️ THE `mockCall`s SIMULATE AN EXTERNAL VENUE'S ILLIQUIDITY, WHICH IS UNREACHABLE ON A FORK —
///         they stub the VAULT's own ERC-4626 views, never our logic. `liquidityAdapter()` is forced to
///         address(0) so `_withdrawableOf` takes its `maxWithdraw` branch rather than the Morpho-V2 branch
///         (which reports a V2 position as fully withdrawable by design), and `maxWithdraw` then reports a
///         genuinely rationed vault. Everything under test — the loop, the ratio, the gate, the storage
///         write — is the real code.
contract VaultHealthOnTraffic is AllesFixture {
    function _seed() internal {
        deal(address(USDC), User01, 100_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 100_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    function test_redeemTrafficStartsTheHealthClock_withoutAnyPoke() public {
        _seed();
        address[] memory vs = AUX.getVaults(address(USDC));
        require(vs.length > 0, "no USDC vault wired - assertion would be vacuous");
        address v = vs[0];

        uint reported = IV4626(v).convertToAssets(IV4626(v).balanceOf(address(AUX)));
        require(reported > 0, "AUX holds nothing in this vault - assertion would be vacuous");

        // NON-VACUITY: it must be healthy first, or "blocked" proves nothing.
        (bool blocked0, uint40 flagged0) = AUX.vaultHealth(v);
        assertFalse(blocked0, "precondition: vault must start unblocked");
        assertEq(uint(flagged0), 0, "precondition: the dwell clock must start unstarted");

        // Ration the venue to 10% of what it reports — well under LIQ_TOL_BPS (5000).
        vm.mockCall(v, abi.encodeWithSignature("liquidityAdapter()"), abi.encode(address(0)));
        vm.mockCall(v, abi.encodeWithSignature("maxWithdraw(address)", address(AUX)), abi.encode(reported / 10));

        // ORGANIC TRAFFIC. No pokeVaultHealth anywhere in this test — this is a redeem-side quote,
        // one of the two paths that already ran the deliverability loop.
        AUX.redeemableAmount();

        (bool blocked1, uint40 flagged1) = AUX.vaultHealth(v);
        emit log_named_uint("reported", reported);
        emit log_named_uint("flaggedAt", uint(flagged1));
        assertTrue(blocked1, "traffic did not block a 10%-liquid vault - the clock never started");
        assertGt(uint(flagged1), 0, "EVAC_DWELL clock did not start on traffic (E152-nerve unbounded start)");
        assertEq(uint(flagged1), block.timestamp, "flaggedAt should be the moment traffic observed it");
    }

    /// The clock must not be RESETTABLE by traffic, or repeated redeems postpone evacuation forever.
    function test_repeatedTrafficDoesNotResetTheDwellClock() public {
        _seed();
        address v = AUX.getVaults(address(USDC))[0];
        uint reported = IV4626(v).convertToAssets(IV4626(v).balanceOf(address(AUX)));
        vm.mockCall(v, abi.encodeWithSignature("liquidityAdapter()"), abi.encode(address(0)));
        vm.mockCall(v, abi.encodeWithSignature("maxWithdraw(address)", address(AUX)), abi.encode(reported / 10));

        AUX.redeemableAmount();
        (, uint40 first) = AUX.vaultHealth(v);
        assertGt(uint(first), 0, "first touch must start the clock");

        vm.warp(block.timestamp + 20 minutes);
        vm.roll(block.number + 1);
        AUX.redeemableAmount();
        (, uint40 second) = AUX.vaultHealth(v);
        assertEq(uint(second), uint(first),
            "traffic reset the dwell clock - evacuation would be postponed indefinitely by ordinary flow");
    }

    /// THE RELEASE DIRECTION. Added because the first version of this change blocked on traffic but left
    /// the release to `pokeVaultHealth` — and nothing calls the poke (§E152-nerve), so a one-block dip
    /// would have stranded the vault blocked forever with new deposits unrouted. An untested recovery
    /// path is exactly the thing that defect was made of, so it gets its own assertion.
    function test_trafficReleasesTheVaultOnceLiquidAgain() public {
        _seed();
        address v = AUX.getVaults(address(USDC))[0];
        uint reported = IV4626(v).convertToAssets(IV4626(v).balanceOf(address(AUX)));

        vm.mockCall(v, abi.encodeWithSignature("liquidityAdapter()"), abi.encode(address(0)));
        vm.mockCall(v, abi.encodeWithSignature("maxWithdraw(address)", address(AUX)), abi.encode(reported / 10));
        AUX.redeemableAmount();
        (bool blocked, uint40 flagged) = AUX.vaultHealth(v);
        assertTrue(blocked, "precondition: traffic must have blocked it");
        assertGt(uint(flagged), 0, "precondition: the clock must be running");

        // The venue recovers. Same organic path, no poke.
        vm.mockCall(v, abi.encodeWithSignature("maxWithdraw(address)", address(AUX)), abi.encode(reported));
        AUX.redeemableAmount();

        (bool blocked2, uint40 flagged2) = AUX.vaultHealth(v);
        assertFalse(blocked2, "traffic did not release a recovered vault - deposits stay unrouted forever");
        assertEq(uint(flagged2), 0, "release must clear the dwell clock so a later incident dwells afresh");
    }
}
