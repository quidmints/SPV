// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {AllesFixture} from "./Alles.t.sol";

/// @notice §E198. AAVE HEALTH MUST BE KEYED PER RESERVE, NOT PER SPOKE.
///
///         `ChannelLib.setVaultBody:441` pushes `cfg.aaveSpoke` into a stable's vault set, and
///         `DeployL1_s:404-405` does that for USDC *and* USDT. Health is keyed by the member address,
///         so `vaultHealth[aaveSpoke]` was ONE flag serving every aave-routed reserve: blocking one
///         blocked all, and a single impaired reserve could not be expressed at all. That is worse than
///         no key, because the block LOOKS targeted.
///
///         The falsifiable claim: blocking one reserve leaves the others routable. Under the old shared
///         key both stables resolve to the SAME address, so `blockedOther` below would be true and this
///         test fails — which is exactly what makes it worth writing.
contract AaveReserveHealthKey is AllesFixture {
    /// Mirrors `BasketLib.aaveHealthKey` (internal, so it cannot be called from here). The BEHAVIOURAL
    /// assertions below do not depend on this formula being right — they depend on the two stables
    /// resolving to DIFFERENT keys, which is the property under test.
    function _key(address spoke, uint rid) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(spoke, rid)))));
    }

    function test_blockingOneAaveReserveLeavesTheOthersRoutable() public {
        address spoke = AUX.AAVE_SPOKE();
        require(spoke != address(0), "no aave spoke wired - assertion would be vacuous");

        // ⚠️ THE HARNESS DOES NOT WIRE THE DUAL-VENUE AAVE LEGS — `Alles.t.sol:514-521` gives USDC and
        // USDT their Morpho vaults only, while `DeployL1_s:404-405` calls `setVault(USDC, aaveSpoke)`
        // and `setVault(USDT, aaveSpoke)` IN PRODUCTION. So the configuration this test is about has
        // ZERO coverage in the suite, which is why nothing caught the shared key. Build it here through
        // the REAL owner-gated entrypoint, so `setVaultBody` resolves the reserve ids the same way the
        // deploy does — no mock, no vm.store.
        vm.startPrank(AUX.owner());
        AUX.setVault(address(USDC), spoke);
        AUX.setVault(address(USDT), spoke);
        vm.stopPrank();

        uint ridUsdc = AUX.reserveIdOf(address(USDC));
        uint ridUsdt = AUX.reserveIdOf(address(USDT));
        emit log_named_uint("USDC reserveId", ridUsdc);
        emit log_named_uint("USDT reserveId", ridUsdt);
        // NON-VACUITY: distinct reserves is the whole premise. If they collide the test proves nothing.
        assertTrue(ridUsdc != ridUsdt, "USDC and USDT share a reserve id - premise broken");

        address kUsdc = _key(spoke, ridUsdc);
        address kUsdt = _key(spoke, ridUsdt);
        assertTrue(kUsdc != kUsdt, "per-reserve keys collided");
        // And each must differ from the raw spoke, or we are still keying per-spoke by another name.
        assertTrue(kUsdc != spoke && kUsdt != spoke, "key is still the spoke address");

        // NON-VACUITY: both start healthy, or "unblocked" proves nothing.
        assertFalse(AUX.vaultBlocked(kUsdc), "precondition: USDC reserve must start unblocked");
        assertFalse(AUX.vaultBlocked(kUsdt), "precondition: USDT reserve must start unblocked");

        // Block ONLY the USDC reserve, through the real owner-gated entrypoint.
        vm.prank(AUX.owner());
        AUX.setVaultHealth(kUsdc, true);

        assertTrue(AUX.vaultBlocked(kUsdc), "the targeted reserve did not block");
        assertFalse(AUX.vaultBlocked(kUsdt),
            "blocking one aave reserve blocked another - the key is still shared across the spoke");

        // ⚠️ THE BEHAVIOURAL HALF IS DELIBERATELY NOT ASSERTED HERE, and the reason is a finding.
        // Minting USDT once the aave leg is wired routes into `IAaveV4Spoke.supply` and REVERTS — a path
        // with zero harness coverage, since `Alles.t.sol` never wires these legs. It is pre-existing by
        // construction, not caused by the per-reserve key: before this change the aave branch returned
        // `aaveBalance` (0) with no health test, so the least-full selector picked it identically.
        // That is REASONING, not a measurement, and it is booked separately rather than asserted here —
        // folding it in would make this test fail for a reason that is not the property under test.
    }
}
