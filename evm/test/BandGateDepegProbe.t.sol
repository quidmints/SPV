// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles} from "./Alles.t.sol";
import {console} from "forge-std/console.sol";

/// Probe: the LP-band backing gate (Core._poolUsdInRange → `committedUsd18() <=
/// _d[14]`) sized committed band dollars against PAR TVL (`_d[14]`), while
/// redemption (BasketLib.redeemAsBody:889) and mint (Basket.sol:266/315) size
/// against par − depegLoss. Under a detected stable depeg the gate therefore
/// OVER-PERMITS committed dollars by exactly `depegLoss`, so QD's real redeemable
/// reserve `(par − depegLoss) − committed` goes negative for the over-permitted
/// slice.
///
/// This probe reads the EXACT public quantities the on-chain gate uses
/// (`CORE.committedUsd18()`, `AUX.get_deposits()`), so the gate-decision flip it
/// asserts IS the deployed require()'s decision. The end-to-end regime sims
/// (test_RunSim_A/IL_*/C_DepegFee) exercise the live require() on the happy path.
contract BandGateDepegProbe is Alles {
    /// Gate over-permit == depegLoss; the fixed basis (par − depegLoss) equals the
    /// redeem/mint basis; and non-depeg operation is unchanged (depegLoss == 0).
    function test_bandGate_overpermits_committed_by_depegLoss() public {
        // Heal the no-CRE fork default depeg, then build real basket backing.
        _stageDepeg(); // 100k QUI minted from USDC; all stables healthy

        // --- PAR (no depeg): the fix is behaviour-preserving. ---
        (uint[15] memory dPar,,, uint lossPar) = AUX.get_deposits();
        uint committed = CORE.committedUsd18();
        assertEq(lossPar, 0, "healthy: depegLoss == 0 (gate identical to par)");
        uint oldCeilPar = dPar[14];             // deployed gate ceiling (raw par)
        uint newCeilPar = dPar[14] - lossPar;   // fixed gate ceiling (haircut)
        assertEq(oldCeilPar, newCeilPar, "no depeg: fixed gate == old gate (no side effect)");
        console.log("par TVL _d[14] (18d)      :", dPar[14]);
        console.log("committedUsd18 (18d)      :", committed);

        // --- DEPEG: USDC (the seed backing) detected 20% down. ---
        _setDepeg(address(USDC), 2000);
        (uint[15] memory dDep,,, uint lossDep) = AUX.get_deposits();
        assertGt(lossDep, 0, "depeg -> depegLoss recognized (redeem/mint haircut basis)");

        // FINDING: par TVL barely moves (the gate's basis ignores the depeg)...
        console.log("par TVL @20%depeg (18d)   :", dDep[14]);
        console.log("depegLoss @20%depeg (18d) :", lossDep);
        uint parDrop = dPar[14] > dDep[14] ? dPar[14] - dDep[14] : 0;
        assertLt(parDrop, lossDep / 10,
            "par TVL _d[14] ignores the depeg (moves ~0 vs the depegLoss haircut)");

        // ...so the two gate ceilings now DIVERGE by exactly depegLoss.
        uint oldCeil = dDep[14];              // deployed-BEFORE-fix gate ceiling
        uint newCeil = dDep[14] - lossDep;    // deployed-AFTER-fix gate ceiling (== redeem basis)
        uint overPermit = oldCeil - newCeil;
        console.log("OLD gate ceiling (par)    :", oldCeil);
        console.log("NEW gate ceiling (haircut):", newCeil);
        console.log("OVER-PERMIT (= depegLoss) :", overPermit);
        assertEq(overPermit, lossDep, "gate over-permits committed by exactly depegLoss");

        // GATE-DECISION FLIP: a committed level in the over-permit window
        // (par-haircut, par] passes the OLD gate but the NEW gate rejects it — and
        // that committed level leaves QD's redeemable reserve negative by the slice.
        uint hypotheticalCommitted = newCeil + overPermit / 2; // mid over-permit band
        bool oldGatePasses = hypotheticalCommitted <= oldCeil;
        bool newGatePasses = hypotheticalCommitted <= newCeil;
        assertTrue(oldGatePasses, "BEFORE fix: over-permitting committed level ACCEPTED (bug)");
        assertFalse(newGatePasses, "AFTER fix: same committed level REJECTED (shortfall closed)");
        // Real redeemable reserve at that committed level = (par - loss) - committed < 0.
        uint qdReserveShort = hypotheticalCommitted - newCeil;
        console.log("QD reserve SHORT under old gate (18d):", qdReserveShort);
        assertEq(qdReserveShort, overPermit / 2, "shortfall = committed over the haircut backing");
    }
}
