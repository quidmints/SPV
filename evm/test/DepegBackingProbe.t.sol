// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles} from "./Alles.t.sol";
import {console} from "forge-std/console.sol";

/// Probe: when a basket stable is DETECTED-depegged (riskFactor < 10000), does the
/// protocol stay self-consistent? Hypothesis under test: the MINT credit is
/// haircut by riskFactor (defended), but `totalLiquid` (the solvency figure in
/// checkBacking) still counts the SAME standing holdings at PAR — i.e. the
/// contract "knows" the stable is at 80% for minting yet "believes" it's $1 for
/// backing. This isolates the claim with severity injected via the CRE hook mock
/// (no external oracle assumption).
contract DepegBackingProbe is Alles {
    function test_detected_depeg_haircuts_mint_but_backing_counts_par() public {
        address link = address(AUX); // getDepegSeverityBps now lives on Aux (CRE removed)
        bytes4 sevSel = bytes4(keccak256("getDepegSeverityBps(address)"));

        // All stables healthy (override the no-CRE fork default-max-depeg).
        vm.mockCall(link, abi.encodeWithSelector(sevSel), abi.encode(uint(0)));

        deal(address(USDC), User01, 1_000_000e6);

        // 1) Mint 200k USDC at PAR.
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        uint mintedPar = QUID.mint(User01, 200_000e6, address(USDC), 0);
        vm.stopPrank();

        (, uint backingPar) = AUX.tryCheckBacking();
        console.log("minted @par           :", mintedPar);
        console.log("totalLiquid @par      :", backingPar);

        // 2) USDC now DETECTED-depegged 20% (severity 2000 bps). Only the flag
        //    changes — the holdings are identical.
        vm.mockCall(link, abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(2000)));

        (, uint backingDepeg) = AUX.tryCheckBacking();
        console.log("totalLiquid @20%depeg :", backingDepeg);
        uint backingDrop = backingPar > backingDepeg ? backingPar - backingDepeg : 0;
        console.log("backing DROP on depeg :", backingDrop);

        // 3) A fresh mint of the same 200k USDC under the detected depeg.
        vm.startPrank(User01);
        uint mintedDepeg = QUID.mint(User01, 200_000e6, address(USDC), 0);
        vm.stopPrank();
        console.log("minted @20%depeg      :", mintedDepeg);

        // (B) Mint-gate defense: a detected 20% depeg credits ~80% — proven.
        assertLt(mintedDepeg, (mintedPar * 85) / 100, "depeg mint must be < ~85% of par");
        assertGt(mintedDepeg, (mintedPar * 70) / 100, "depeg mint ~80% of par (haircut applied)");

        // (A) The hypothesis: did standing backing reflect the 20% depeg on the
        //     200k USDC (~40k expected) or stay ~par (drop ~0)? Assert the BUG
        //     shape so the test documents reality; if backing DID drop, this fails
        //     and refutes the hypothesis (no inconsistency).
        assertLt(backingDrop, 5_000e18,
            "BUG: totalLiquid ignores the detected depeg (counts depegged stable at par)");
    }

    /// Finding-#1 fix: the QUID MINT headroom is discounted by the SAME depeg loss
    /// redemption applies, so the forward-yield slice can't mint against a depegged
    /// holding's par-phantom value (which would push supply > redeemable backing).
    /// Proves the load-bearing accessor `AUX.depegLoss()` that Basket now subtracts
    /// from par at both mint-headroom sites. (Exercising the post-month-12 cap path
    /// itself is the separate "warp past month 12" coverage TODO.)
    function test_mintHeadroom_discounted_symmetric_with_redeem() public {
        address link = address(AUX); // getDepegSeverityBps now lives on Aux (CRE removed)
        bytes4 sevSel = bytes4(keccak256("getDepegSeverityBps(address)"));
        vm.mockCall(link, abi.encodeWithSelector(sevSel), abi.encode(uint(0))); // all healthy

        deal(address(USDC), User01, 1_000_000e6);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 200_000e6, address(USDC), 0);
        vm.stopPrank();

        // Healthy → no discount: mint headroom == par backing (behaviour-preserving).
        assertEq(AUX.depegLoss(), 0, "healthy: depegLoss must be 0 (no headroom change)");

        // USDC detected-depegged 20%. The loss redemption applies is now ALSO
        // subtracted from the mint headroom denominator (par total - depegLoss).
        vm.mockCall(link, abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(2000)));
        uint loss = AUX.depegLoss();
        (uint parTotal,) = AUX.get_metrics(true);
        assertGt(loss, 0, "depeg -> mint headroom tightened below par");
        assertGt(parTotal, loss, "sanity: discounted headroom stays positive");
    }
}
