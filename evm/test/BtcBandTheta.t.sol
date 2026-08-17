// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";

/// @notice Proves the BTC band now gets the SAME theta risk-budget clamp as the ETH band.
///   Before this change BtcVaultLib.addLiqChannel omitted theta entirely -- a real asymmetry
///   (the "locked channel sats" rationale justifies dropping only the PHYSICAL-inventory clamp,
///   not the IL risk-budget throttle; a BTC band bears IL exactly like an ETH band).
///
///   The fork's mock venues accrue ~0 yield, so the LIVE theta = avgYield/(K*sigma^2) = 0 ->
///   fails OPEN (no clamp). That is exactly why every existing BTC test is unaffected (theta
///   inert on the fork). To prove the clamp FIRES we mock the ONE input the fork cannot produce
///   -- a positive-yield theta<1 -- via Vault.derivedThetaWad(), and show the in-range pairing
///   is throttled, while the fail-open baseline pairs fully. The theta VALUE's live-ness itself is
///   covered by the same VogueLib.derivedThetaWad path DerivedTheta.t.sol exercises for ETH.
contract BtcBandThetaProbe is AllesFixture {
    function test_BtcBand_ThetaThrottlesInRangePairing() public {
        AUX.setBTCChannels(address(this)); // impersonate BTCChannels (requestDeposit is gated)

        // Baseline: theta fails open (fork avgYield ~ 0 -> derivedThetaWadBtc()==0 -> 1e18 in the
        // clamp) so the whole surplus-permitted slice pairs in-range (grows POOLED).
        uint p0 = CORE.POOLED();
        BTC.requestDeposit(User01, 2e7);            // 0.2 BTC
        uint d1 = CORE.POOLED() - p0;
        assertGt(d1, 0, "baseline: fail-open theta pairs the BTC slice in-range");

        // Force theta = 0.001 (WAD). The fork cannot make avgYield>0, so mock the theta oracle
        // value ONLY -- the real addLiqChannel/requestDeposit clamp path runs unchanged. With
        // theta*vogueAvail << current POOLED, the in-range headroom collapses to ~0, so the
        // second LP's sats are shed to the unpaired (off-chain-backed) share tracking instead of
        // being force-paired into the IL-bearing band.
        vm.mockCall(address(BTC), abi.encodeWithSignature("derivedThetaWad()"), abi.encode(uint(1e15)));
        uint p1 = CORE.POOLED();
        BTC.requestDeposit(User02, 2e7);            // same sats, theta << 1
        uint d2 = CORE.POOLED() - p1;

        assertLt(d2, d1, "theta<1 must throttle the in-range BTC pairing (the fix); previously omitted");
    }
}
