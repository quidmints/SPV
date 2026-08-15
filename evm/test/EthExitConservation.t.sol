// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Is ETH-exit value actually LOST, or do the failing assertions assume a pure-ETH burn?
///
/// @notice The ~19.4-20% exit cluster has been read three ways so far (the AAVE fifth; a
///         `deliverableETH` under-count; a venue that cannot deliver). All three were guesses. This
///         settles it by CONSERVATION instead: `Vogue._withdraw` already re-credits whatever the
///         ladder could not source (`LP.pooled += shortfall`, "recoverable deferral … socialized
///         fairly via the share price, no first-out advantage"), and a band burn pays out BOTH legs —
///         ETH *and* USD (minted as QUID). So an LP withdrawing `X` should end up holding
///         `ETH received + QUID received + re-credited pooled ≈ X`, with NO value destroyed.
///
///         If conservation HOLDS, the failing assertions are wrong in principle: they compare a
///         POOLED delta against ETH-only payout and so implicitly assume the band is 100% ETH,
///         which stops being true the moment any swap moves price into the range.
///         If conservation FAILS, the gap is real and this prints exactly where it went.
contract EthExitConservationProbe is Alles {
    function test_Diag_ExitConservation() public {
        vm.prank(User01);
        V4.deposit{value: 10 ether}(0, User01);

        // Move price into the range so the band holds BOTH legs — the condition under which a burn
        // cannot pay out pure ETH. This mirrors testDepositImmediateWithdraw's setup exactly.
        vm.roll(vm.getBlockNumber() + 1); vm.warp(block.timestamp + 15 minutes);
        AUX.swap{value: 0.1 ether}(address(USDC), address(WETH), false, 0, 0);

        // NB: `usd_owed` is the SECOND field and it is load-bearing here — `burnInRange` DEFERS the
        // USD leg to `usd_owed` on a PARTIAL exit and only MINTS QUID on a FULL exit
        // (JIT-DEPTH §4.1). An accounting that reads only `pooled` + QUID balance therefore MISSES
        // the USD leg entirely and looks like an ~18% loss when nothing was lost.
        (uint pooledBefore, uint owedBefore,,) = V4.autoManaged(User01);
        // ETH **+ WETH**: the ladder pays part of an exit as WETH (BUILD-QUEUE §A.9). This test was
        // written to prove conservation and then measured only NATIVE ETH — so it reported the ~19%
        // ETH/WETH split ratio as missing value, which is the very artifact it exists to rule out.
        uint ethBefore  = User01.balance + WETH.balanceOf(User01);
        uint quidBefore = QUID.balanceOf(User01);
        uint poolEthBefore = CORE.POOLED();

        // FULL exit, deliberately. A PARTIAL exit cannot test conservation: the burn's USD leg stays
        // in the basket as backing, which raises the value of the shares the LP STILL holds — so the
        // per-withdrawal delta legitimately fails to balance while the portfolio balances fine
        // ("socialized fairly via the share price, no first-out advantage", `_withdraw`). Exiting
        // everything removes that absorber, so any residual gap is REAL.
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(User01); V4.withdraw(type(uint).max, User01, User01);

        (uint pooledAfter, uint owedAfter,,) = V4.autoManaged(User01);
        uint owedGained = owedAfter > owedBefore ? owedAfter - owedBefore : 0;
        uint ethGained  = (User01.balance + WETH.balanceOf(User01)) - ethBefore;
        uint quidGained = QUID.balanceOf(User01) - quidBefore;
        uint poolEthDrop = poolEthBefore - CORE.POOLED();
        // Re-credited deferral: pooled should fall by LESS than 5 if part was re-credited.
        uint pooledDrop = pooledBefore - pooledAfter;

        emit log_named_decimal_uint("requested (FULL exit)", pooledBefore, 18);
        emit log_named_decimal_uint("ETH received         ", ethGained, 18);
        emit log_named_decimal_uint("QUID received (18dec)", quidGained, 18);
        emit log_named_decimal_uint("pooled DROP          ", pooledDrop, 18);
        emit log_named_decimal_uint("POOLED drop      ", poolEthDrop, 18);
        emit log_named_decimal_uint("re-credited deferral ", pooledBefore > pooledDrop ? pooledBefore - pooledDrop : 0, 18);

        // CONSERVATION: the LP's claim must not evaporate. Everything the LP gave up (pooledDrop)
        // must come back as ETH in hand plus QUID in hand — QUID is a live par claim on the basket,
        // so it counts as value received, not as loss.
        uint ethPrice = AUX.getTWAPforAsset(address(WETH), 1800);
        // Both QUID-in-hand and the DEFERRED `usd_owed` are dollar claims (18-dec, ~$1) — value the
        // LP holds either way. Only their form differs (minted now vs minted on full exit).
        uint usdClaimInEth = ethPrice == 0 ? 0 : ((quidGained + owedGained) * 1e18) / ethPrice;
        emit log_named_decimal_uint("usd_owed gained      ", owedGained, 18);
        emit log_named_decimal_uint("USD claim in ETH     ", usdClaimInEth, 18);
        emit log_named_decimal_uint("TOTAL received (ETH) ", ethGained + usdClaimInEth, 18);

        // 2% tolerance for band geometry + fees; the failures are ~20%, so this cleanly separates
        // "assertion assumed pure-ETH burn" from "value genuinely destroyed".
        assertApproxEqRel(ethGained + usdClaimInEth, pooledDrop, 0.02e18,
            "CONSERVATION: ETH + (QUID + usd_owed) must equal the claim given up");
    }
}
