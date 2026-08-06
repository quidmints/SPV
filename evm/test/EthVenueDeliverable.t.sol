// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {VaultLib} from "../src/imports/VaultLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title Diagnostic: where does `deliverableETH()` lose the AAVE-v4 fifth?
/// @notice Enabling ETH venue 2 (the sentinel-zero fix) left 6 tests failing with an EXACT ~1/5
///         shortfall on LP exit. The trace proved it is NOT the AAVE pull — `withdrawSelf` is
///         invoked for only 4/5 of the ask, so `deliverableETH()` is already short before any
///         venue is touched. This isolates the term responsible by printing the whole breakdown
///         against the SAME 10-ETH SPLIT deposit `testDepositImmediateWithdraw` uses.

interface I4626Depth {
    function maxWithdraw(address owner) external view returns (uint);
    function convertToAssets(uint shares) external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
}

interface IDecimals { function decimals() external view returns (uint8); }

contract EthVenueDeliverableProbe is Alles {
    struct Acc {
        uint own18;          // par value of every vault position we hold
        uint deliv18;        // the slice withdrawable NOW, same state
        uint rawDeliv18;     // what a naive maxWithdraw reader would have concluded
        uint seen;
        uint rationed;       // withdrawable < own
        uint empty;          // withdrawable == 0 against a live position
        uint rawZero;        // maxWithdraw == 0 against a live position (the artefact count)
    }

    function _scanVault(Acc memory a, address v, uint scale, uint8 dec) private {
        uint own;
        try I4626Depth(v).balanceOf(address(AUX)) returns (uint sh) {
            if (sh == 0) return;
            try I4626Depth(v).convertToAssets(sh) returns (uint x) { own = x; } catch { return; }
        } catch { return; }
        if (own == 0) return;

        uint deliv = VaultLib._withdrawableOf(v, address(AUX));
        uint raw;
        try I4626Depth(v).maxWithdraw(address(AUX)) returns (uint m) { raw = m; } catch { raw = 0; }

        a.seen++;
        if (deliv == 0) a.empty++;
        else if (deliv < own) a.rationed++;
        if (raw == 0) a.rawZero++;

        a.own18      += own * scale;
        a.deliv18    += (deliv > own ? own : deliv) * scale;
        a.rawDeliv18 += (raw   > own ? own : raw)   * scale;

        emit log_named_address("  vault", v);
        emit log_named_decimal_uint("    own (par)   ", own, dec);
        emit log_named_decimal_uint("    withdrawable", deliv, dec);
        emit log_named_decimal_uint("    rawMaxWithdr", raw, dec);
        emit log_named_uint("    coverage bps", (deliv > own ? own : deliv) * 10_000 / own);
    }

    function test_E101_PerVaultDeliverableCoverage() public {
        Acc memory a;
        address[] memory stables = AUX.getStables();
        emit log_named_uint("stables in basket", stables.length);

        for (uint i = 0; i < stables.length; i++) {
            uint8 dec = IDecimals(stables[i]).decimals();
            address[] memory vs = AUX.getVaults(stables[i]);
            for (uint j = 0; j < vs.length; j++) {
                if (vs[j] != address(0)) _scanVault(a, vs[j], 10 ** (18 - dec), dec);
            }
        }

        emit log("---- AGGREGATE ----");
        emit log_named_uint("vaults with a position", a.seen);
        emit log_named_uint("  rationed (withdrawable < own)", a.rationed);
        emit log_named_uint("  zero-withdrawable", a.empty);
        emit log_named_uint("  maxWithdraw==0 ARTEFACTS", a.rawZero);
        emit log_named_decimal_uint("own total    (18d)", a.own18, 18);
        emit log_named_decimal_uint("withdrawable (18d)", a.deliv18, 18);
        if (a.own18 > 0) {
            emit log_named_uint("DELIVERABLE FRACTION bps", a.deliv18 * 10_000 / a.own18);
            emit log_named_uint("  (naive maxWithdraw would say)", a.rawDeliv18 * 10_000 / a.own18);
        }
        emit log_named_decimal_uint("AUX.illiquidLoss()", AUX.illiquidLoss(), 18);

        // ⚠️ Say out loud what this run can and cannot support.
        if (a.seen == 0) emit log("VOID: no vault position - this run measured NOTHING");
        if (a.seen < 4) emit log("NOTE: fixture holds few vault positions - NOT a sample of a live basket");
    }

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
