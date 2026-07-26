// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title Diagnostic: where does `deliverableETH()` lose the AAVE-v4 fifth?
/// @notice Enabling ETH venue 2 (the sentinel-zero fix) left 6 tests failing with an EXACT ~1/5
///         shortfall on LP exit. The trace proved it is NOT the AAVE pull — `withdrawSelf` is
///         invoked for only 4/5 of the ask, so `deliverableETH()` is already short before any
///         venue is touched. This isolates the term responsible by printing the whole breakdown
///         against the SAME 10-ETH SPLIT deposit `testDepositImmediateWithdraw` uses.
contract EthVenueDeliverableProbe is Alles {
    function test_Diag_DeliverableBreakdownAfterSplitDeposit() public {
        vm.prank(User01);
        V4.deposit{value: 10 ether}(0, User01);

        uint vogue = ETH.vogueETH();
        uint deliv = ETH.deliverableETH();
        uint aave  = ETH.aaveEthBalance();

        emit log_named_decimal_uint("deposited          ", 10 ether, 18);
        emit log_named_decimal_uint("vogueETH           ", vogue, 18);
        emit log_named_decimal_uint("deliverableETH     ", deliv, 18);
        emit log_named_decimal_uint("aaveEthBalance     ", aave, 18);

        // Per-venue share value, to see which leg the caps eat.
        address gx = ETH.GALAXY_VAULT();
        address eu = ETH.EULER_VAULT();
        address gt = ETH.GAUNTLET_VAULT();
        emit log_named_address("galaxy             ", gx);
        emit log_named_address("euler              ", eu);
        emit log_named_address("gauntlet           ", gt);
        emit log_named_string ("euler == gauntlet? ", eu == gt ? "YES (double-counted)" : "no");
        if (gx != address(0)) emit log_named_decimal_uint("galaxy shares      ", IERC20(gx).balanceOf(address(ETH)), 18);
        if (eu != address(0)) emit log_named_decimal_uint("euler shares       ", IERC20(eu).balanceOf(address(ETH)), 18);

        emit log_named_decimal_uint("idle WETH @Vault   ", IERC20(address(WETH)).balanceOf(address(ETH)), 18);
        emit log_named_decimal_uint("idle WETH @Aux     ", IERC20(address(WETH)).balanceOf(address(AUX)), 18);

        // IS OUR OWN DEPOSITED CAPACITY WITHDRAWABLE? `_deliverableCap` subtracts
        // (convertToAssets - maxWithdraw) per vault, so this is the term that decides whether the
        // real curator vaults are usable. The premise being tested: WE supplied this WETH, nobody
        // has borrowed it, so it should come back out — i.e. gap ≈ 0, NOT gap == position.
        _reportVault("galaxy  ", gx);
        _reportVault("euler   ", eu);
        _reportVault("gauntlet", gt);

        // The subtracted lev term (deliverableETH removes totalNetEquityEth).
        address lm = ETH.LEV_MANAGER();
        emit log_named_address("levManager         ", lm);

        // THE POINT: a 5-ETH exit out of a 10-ETH position must be fully deliverable.
        assertGe(deliv, 5 ether, "deliverableETH must cover a 5 ETH exit from a 10 ETH position");
    }

    /// @dev Print the ONE term that decides whether a real curator vault is usable as an ETH venue:
    ///      `_deliverableCap` subtracts `convertToAssets(shares) - maxWithdraw` per vault, so a vault
    ///      whose `maxWithdraw` sits below our own position silently shrinks `deliverableETH`.
    ///
    ///      HYPOTHESIS UNDER TEST (user: "if you add capacity to them then that capacity is
    ///      withdrawable"): we SUPPLIED this WETH and nobody has borrowed it, so it should come
    ///      straight back out ⇒ expect gap ≈ 0. If that holds, the long-standing
    ///      `Alles.t.sol:52-57` claim that the real Galaxy vault has "maxWithdraw=0 … which would
    ///      block every LP withdraw" was measuring `maxWithdraw` for a holder with NO shares —
    ///      trivially 0, and not a statement about liquidity at all.
    function _reportVault(string memory name, address v) internal {
        if (v == address(0)) { emit log_named_string(name, "unwired"); return; }
        uint shares = IERC4626(v).balanceOf(address(ETH));
        uint solvent = IERC4626(v).convertToAssets(shares);
        uint deliv;
        try IERC4626(v).maxWithdraw(address(ETH)) returns (uint m) { deliv = m; } catch { deliv = 0; }
        emit log_named_string(name, "----");
        emit log_named_decimal_uint("  convertToAssets", solvent, 18);
        emit log_named_decimal_uint("  maxWithdraw    ", deliv, 18);
        emit log_named_decimal_uint("  GAP (subtracted)", solvent > deliv ? solvent - deliv : 0, 18);
        // Morpho V2 holds liquidity in ADAPTERS, so `maxWithdraw` is bounded by what is withdrawable
        // NOW, not by totalAssets. Live pre-deposit idle: Galaxy 0, Euler 472.9, Gauntlet ~0 — which is
        // exactly why Euler alone works. THE QUESTION THIS ANSWERS: our own 2 WETH deposit should land
        // as idle and therefore be withdrawable; if idle is ~2 here but maxWithdraw is 0, something
        // OTHER than liquidity is gating it (auto-allocation on deposit, a cap, or a deallocate penalty).
        emit log_named_decimal_uint("  vault idle WETH", IERC20(address(WETH)).balanceOf(v), 18);
        emit log_named_decimal_uint("  vault totalAsts", IERC4626(v).totalAssets(), 18);
        // WHICH of the two deallocate calls fails? `_pull4626` wraps both in try/catch, so a wrong
        // signature degrades to a SILENT no-op — which is what the suite shows. Log each separately.
        try IMorphoV2Probe(v).liquidityAdapter() returns (address adapter) {
            emit log_named_address("  liquidityAdapter", adapter);
            try IMorphoV2Probe(v).liquidityData() returns (bytes memory data) {
                emit log_named_uint("  liquidityData len", data.length);
                try IMorphoV2Probe(v).forceDeallocate(adapter, data, 1 ether, address(ETH))
                    returns (uint penalty) { emit log_named_decimal_uint("  forceDeallocate OK, penalty", penalty, 18); }
                catch { emit log_named_string("  forceDeallocate", "REVERTED (wrong sig or needs auth)"); }
            } catch { emit log_named_string("  liquidityData", "REVERTED"); }
        } catch { emit log_named_string("  liquidityAdapter", "REVERTED (not Morpho V2?)"); }
    }
}

/// Probe-local copy of the Morpho-V2 surface (the diagnostic must not import from src/imports).
interface IMorphoV2Probe {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function forceDeallocate(address adapter, bytes memory data, uint assets, address onBehalf)
        external returns (uint penaltyAssets);
}
